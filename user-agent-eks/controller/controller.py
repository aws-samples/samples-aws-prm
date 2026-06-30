#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
"""
PRM User-Agent attribution controller.

Watches a partner's pods, derives the DISTINCT set of EC2 nodes those pods run
on, and touches each node's instance ARN exactly once per CALENDAR MONTH by
calling ec2:DescribeInstanceAttribute with the partner product code in the SDK
User-Agent. This is the de-duplicated, minimal-call form of the attribution
patterns:

  - Touches only nodes the partner actually runs on (correct under PRM even-split;
    no over-attribution).
  - Exactly one touch per (node, calendar month), regardless of how many of the
    partner's pods share a node.
  - Follows churn: a periodic re-scan picks up newly scheduled pods/nodes.
  - EC2 nodes only; non-EC2 (e.g. Fargate) nodes are skipped. Failures are logged
    and never crash the loop.

Configuration (environment variables):
  AWS_SDK_UA_APP_ID   PRM User-Agent, e.g. APN_1.1/pc_<PRODUCT-CODE>$  (required)
  AWS_REGION          AWS region                                       (required)
  TARGET_NAMESPACE    Only consider pods in this namespace ("" = all)  (default: "")
  TARGET_LABEL_SELECTOR  Only consider pods matching this selector,
                         e.g. "app=my-partner-app"  (default: "")
  RESCAN_INTERVAL_SECONDS  How often to re-scan for new nodes           (default: 300)

PRM cadence:
  PRM only REQUIRES one successful API call against a given node's instance ARN per
  CALENDAR MONTH for that month's consumption to be attributed to the product code.
  This controller therefore touches each node at most once per calendar month (tracked
  in `touched`), re-scanning every RESCAN_INTERVAL_SECONDS only to pick up new nodes.

  TESTING ONLY:
  TEST_INTERVAL_SECONDS  If set (>0), the controller bypasses the once-per-month
                         de-duplication and re-touches every node on each scan, sleeping
                         this many seconds between scans. This produces visible activity
                         quickly but is NOT how PRM works — do not use in production.
"""
import datetime
import os
import sys
import time

import boto3
from kubernetes import client, config


def log(msg):
    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    print(f"[prm-controller] {now} {msg}", flush=True)


def current_month_key():
    now = datetime.datetime.now(datetime.timezone.utc)
    return f"{now.year:04d}-{now.month:02d}"


def load_k8s():
    """Use in-cluster config when running as a pod; fall back to local kubeconfig."""
    try:
        config.load_incluster_config()
    except config.ConfigException:
        config.load_kube_config()
    return client.CoreV1Api()


def node_names_for_target(v1, namespace, label_selector):
    """Return the distinct set of node names hosting the targeted (Running) pods."""
    kwargs = {"label_selector": label_selector} if label_selector else {}
    if namespace:
        pods = v1.list_namespaced_pod(namespace, **kwargs).items
    else:
        pods = v1.list_pod_for_all_namespaces(**kwargs).items
    nodes = set()
    for p in pods:
        node = p.spec.node_name if p.spec else None
        phase = p.status.phase if p.status else None
        if node and phase in ("Running", "Pending"):
            nodes.add(node)
    return nodes


def resolve_instance_id(ec2, node_name):
    """
    Map a Kubernetes node name to an EC2 instance ID.
      - EKS Auto Mode: the node name is already the instance ID (i-...).
      - Other EC2 nodes: resolve via DescribeInstances on the private DNS name.
    Returns None if it cannot be resolved (e.g. non-EC2 compute).
    """
    if node_name.startswith("i-"):
        return node_name
    try:
        resp = ec2.describe_instances(
            Filters=[{"Name": "private-dns-name", "Values": [node_name]}]
        )
        for res in resp.get("Reservations", []):
            for inst in res.get("Instances", []):
                return inst["InstanceId"]
    except Exception as e:  # noqa: BLE001 - never let resolution crash the loop
        log(f"WARN: failed to resolve instance ID for node {node_name}: {e}")
    return None


def touch(ec2, instance_id):
    """Touch one instance ARN. Returns True on success."""
    try:
        ec2.describe_instance_attribute(InstanceId=instance_id, Attribute="instanceType")
        return True
    except Exception as e:  # noqa: BLE001
        log(f"WARN: touch failed for {instance_id}: {e}")
        return False


def main():
    app_id = os.environ.get("AWS_SDK_UA_APP_ID")
    region = os.environ.get("AWS_REGION")
    namespace = os.environ.get("TARGET_NAMESPACE", "")
    label_selector = os.environ.get("TARGET_LABEL_SELECTOR", "")
    rescan = int(os.environ.get("RESCAN_INTERVAL_SECONDS", "300"))
    # TESTING ONLY: when > 0, re-touch every node on each scan (bypassing the
    # once-per-calendar-month de-duplication) and use this as the scan interval.
    test_interval = int(os.environ.get("TEST_INTERVAL_SECONDS", "0") or "0")

    if not app_id:
        log("ERROR: AWS_SDK_UA_APP_ID is not set; cannot attribute. Exiting idle loop.")
        # Fail closed but stay alive so the pod does not crash-loop.
        while True:
            time.sleep(86400)
    if not region:
        log("ERROR: AWS_REGION is not set. Idling.")
        while True:
            time.sleep(86400)

    if test_interval > 0:
        log(
            f"Controller starting (TEST MODE). UA app id: {app_id}, region: {region}, "
            f"namespace: {namespace or '<all>'}, selector: {label_selector or '<none>'}, "
            f"re-touch every {test_interval}s (NOT production; PRM only needs monthly)."
        )
    else:
        log(
            f"Controller starting. UA app id: {app_id}, region: {region}, "
            f"namespace: {namespace or '<all>'}, selector: {label_selector or '<none>'}, "
            f"rescan: {rescan}s"
        )

    # boto3 honors AWS_SDK_UA_APP_ID automatically; set user_agent_appid explicitly
    # too so attribution works regardless of botocore version.
    boto_cfg = boto3.session.Config(user_agent_appid=app_id)
    ec2 = boto3.client("ec2", region_name=region, config=boto_cfg)
    v1 = load_k8s()

    # Tracks which (node, month) pairs have already been touched, so each node is
    # touched at most once per calendar month even across re-scans.
    touched = {}  # instance_id -> month_key

    while True:
        month = current_month_key()
        # Drop bookkeeping from previous months so the dict does not grow forever
        # and so every node gets re-touched when a new month starts.
        for inst in [i for i, m in touched.items() if m != month]:
            del touched[inst]

        try:
            nodes = node_names_for_target(v1, namespace, label_selector)
        except Exception as e:  # noqa: BLE001
            sleep_s = test_interval if test_interval > 0 else rescan
            log(f"WARN: failed to list pods: {e}; retrying after {sleep_s}s")
            time.sleep(sleep_s)
            continue

        log(f"Scan: {len(nodes)} distinct node(s) hosting targeted pods this cycle.")
        for node_name in sorted(nodes):
            instance_id = resolve_instance_id(ec2, node_name)
            if not instance_id:
                log(f"SKIP: node {node_name} has no resolvable EC2 instance (non-EC2?).")
                continue
            # Classify the touch BEFORE updating bookkeeping:
            #   - first time we see this instance this month  -> NEW NODE (a pod was
            #     scheduled onto a node we had not attributed yet, e.g. churn/scale-out).
            #   - already attributed this month               -> SCHEDULED re-touch
            #     (the periodic loop; no new placement).
            first_touch = touched.get(instance_id) != month
            # In production we touch a node only once per month; in TEST MODE we
            # re-touch every scan so the "scheduled re-touch" path is visible.
            if test_interval == 0 and not first_touch:
                continue  # already attributed this month
            if touch(ec2, instance_id):
                touched[instance_id] = month
                if first_touch:
                    log(f"Touched {instance_id} (node {node_name}) for {month} "
                        f"[reason=NEW NODE — pod launched on a newly attributed node].")
                else:
                    log(f"Touched {instance_id} (node {node_name}) for {month} "
                        f"[reason=SCHEDULED re-touch — periodic loop].")

        if test_interval > 0:
            log(f"TEST MODE: sleeping {test_interval}s before next scan (NOT for production).")
            time.sleep(test_interval)
        else:
            time.sleep(rescan)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
