#!/usr/bin/env sh
#
# PRM User-Agent attribution DaemonSet entrypoint.
#
# One pod of this DaemonSet runs on each (selected) node. It touches the EC2
# instance ARN of its node by calling ec2:DescribeInstanceAttribute with the
# partner product code in the SDK User-Agent (AWS_SDK_UA_APP_ID). PRM attributes
# the node's compute to the product code, even-split across all partners that
# touch the same ARN within a calendar month.
#
# Behavior:
#   - Touch once on startup, then once at the start of each new CALENDAR month.
#   - One touch per node per month is sufficient (even-split counts distinct
#     partners, not touch count).
#   - FAIL CLOSED: if the node's EC2 instance ID cannot be resolved (PRM does not
#     support non-EC2 compute) or an API call fails, log and idle — never
#     crash-loop.
#
# IMPORTANT: a DaemonSet touches EVERY node it is scheduled on. In a multi-tenant
# cluster with INTERMIXED compute this OVER-ATTRIBUTES (you would touch nodes you
# do not use, stealing even-split share from other partners). This pattern is only
# correct when the DaemonSet is restricted (via nodeSelector/affinity) to a node
# pool DEDICATED to this partner.
#
# PRM CADENCE — IMPORTANT:
#   PRM only REQUIRES one successful API call against a given resource ARN per
#   CALENDAR MONTH for that month's consumption to be attributed to the product
#   code. Additional calls in the same month add nothing (and for a shared ARN,
#   attribution is even-split across the distinct partners that touched it that
#   month). The monthly loop below is therefore the correct production cadence.
#
#   For TESTING ONLY, set TEST_INTERVAL_SECONDS to a small value (e.g. 60) to make
#   the pod touch every N seconds so you can observe activity quickly. This is NOT
#   how PRM works and must NOT be used in real deployments.
#
# Required environment:
#   AWS_SDK_UA_APP_ID   PRM User-Agent, e.g. APN_1.1/pc_<PRODUCT-CODE>$
#   NODE_NAME           Node name, injected via the Downward API (spec.nodeName)
#   AWS_REGION          AWS region
#
# Optional environment:
#   TEST_INTERVAL_SECONDS  TESTING ONLY. If set (>0), touch every N seconds instead
#                          of once per calendar month. Leave unset for production.
#
set -u

log() { echo "[prm-daemonset] $(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }

idle_forever() {
  log "Entering idle state; the node and other workloads are unaffected."
  while true; do sleep 86400; done
}

if [ -z "${AWS_SDK_UA_APP_ID:-}" ]; then
  log "ERROR: AWS_SDK_UA_APP_ID is not set; cannot attribute. Idling."
  idle_forever
fi
if [ -z "${NODE_NAME:-}" ]; then
  log "ERROR: NODE_NAME is not set (Downward API missing); cannot resolve node. Idling."
  idle_forever
fi

log "DaemonSet pod starting. UA app id: ${AWS_SDK_UA_APP_ID}, node: ${NODE_NAME}, region: ${AWS_REGION:-unset}"

# Resolve the EC2 instance ID for this node.
#   - EKS Auto Mode: the node name is already the instance ID (i-...).
#   - Other EC2 nodes: resolve via DescribeInstances on the private DNS name.
resolve_instance_id() {
  case "${NODE_NAME}" in
    i-*)
      echo "${NODE_NAME}"
      return 0
      ;;
  esac
  aws ec2 describe-instances \
    --filters "Name=private-dns-name,Values=${NODE_NAME}" \
    --query 'Reservations[0].Instances[0].InstanceId' \
    --output text 2>/dev/null
}

INSTANCE_ID="$(resolve_instance_id)"
if [ -z "${INSTANCE_ID}" ] || [ "${INSTANCE_ID}" = "None" ]; then
  log "ERROR: could not resolve an EC2 instance ID for node ${NODE_NAME} (non-EC2 compute is unsupported). Idling."
  idle_forever
fi
log "Resolved instance ID: ${INSTANCE_ID}"

touch_instance() {
  log "Touching ${INSTANCE_ID} (DescribeInstanceAttribute instanceType)..."
  if aws ec2 describe-instance-attribute \
       --instance-id "${INSTANCE_ID}" \
       --attribute instanceType >/dev/null 2>&1; then
    log "Touch succeeded for ${INSTANCE_ID} (month $(date -u +%Y-%m))."
  else
    log "WARN: touch failed for ${INSTANCE_ID}; will retry next cycle."
  fi
}

# Seconds until just after the start of the next calendar month (00:00:30 UTC on
# the 1st), so each calendar month gets exactly one touch.
seconds_until_next_month() {
  now_y="$(date -u +%Y)"
  now_m="$(date -u +%m)"
  now_m=$((10#${now_m}))
  if [ "${now_m}" -eq 12 ]; then
    next_y=$((now_y + 1)); next_m=1
  else
    next_y=${now_y}; next_m=$((now_m + 1))
  fi
  next_str="$(printf '%04d-%02d-01T00:00:30' "${next_y}" "${next_m}")"
  next_epoch="$(date -u -d "${next_str}" +%s 2>/dev/null \
    || date -u -j -f '%Y-%m-%dT%H:%M:%S' "${next_str}" +%s 2>/dev/null \
    || echo '')"
  now_epoch="$(date -u +%s)"
  if [ -z "${next_epoch}" ]; then
    echo $((28 * 86400))
    return
  fi
  diff=$((next_epoch - now_epoch))
  [ "${diff}" -lt 60 ] && diff=60
  echo "${diff}"
}

touch_instance
while true; do
  if [ -n "${TEST_INTERVAL_SECONDS:-}" ] && [ "${TEST_INTERVAL_SECONDS}" -gt 0 ] 2>/dev/null; then
    log "TEST MODE: sleeping ${TEST_INTERVAL_SECONDS}s before next touch (NOT for production; PRM only needs monthly)."
    sleep "${TEST_INTERVAL_SECONDS}"
  else
    wait_s="$(seconds_until_next_month)"
    log "Sleeping ${wait_s}s until the next calendar month boundary."
    sleep "${wait_s}"
  fi
  touch_instance
done
