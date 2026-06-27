# Controller Attribution (exact, minimal-call — multi-tenant)

A single **controller** (one Deployment for the whole cluster) that watches a partner's
pods, computes the **distinct set of EC2 nodes** those pods run on, and touches each
node's instance ARN **exactly once per calendar month** with the partner product code in
the SDK User-Agent (`AWS_SDK_UA_APP_ID`).

This is the de-duplicated, minimal-call form of the attribution patterns (see
[`../DESIGN.md`](../DESIGN.md)). Compared to the [`../sidecar/`](../sidecar/) pattern it:

- makes **no redundant calls** — one touch per (node, month) regardless of how many of the
  partner's pods share a node, and
- needs **no change to the partner's pod spec** — it observes pods via the Kubernetes API.

It is correct under PRM's even-split rule because it touches **only** nodes the partner
actually runs on (scoped by namespace and/or label selector), so it never over-attributes.

> **Sample code — not production-ready.** This is a simple poll-based control loop, not a
> hardened operator (no leader election beyond a single replica, no informer cache, basic
> error handling). Review RBAC and IAM scope and pin the image to a digest before real use.

## What it does

```
Controller (1 replica)
  ├─ EKS Pod Identity → assumes the dedicated IAM role → temp credentials (EC2 describe)
  ├─ RBAC → lists the partner's pods (by namespace / label selector)
  ├─ derive the DISTINCT set of nodes those pods run on
  ├─ resolve each node's EC2 instance ID (node name on Auto Mode; else DescribeInstances)
  ├─ touch each instance ARN once for the current calendar month (DescribeInstanceAttribute)
  └─ re-scan every RESCAN_INTERVAL_SECONDS to pick up churn; re-touch all at month rollover
```

Behavior matches the resolved decisions in `DESIGN.md`: calendar-month cadence, one touch
per node per month, EC2 nodes only, and failures are logged without crashing the loop.

## Pros and cons

**Pros**
- **Exact, no over-attribution** — touches only the distinct nodes the partner's pods run
  on (scoped by namespace/label), correct under PRM's even-split rule.
- **Minimal calls** — exactly one touch per (node, calendar month), regardless of how many
  of the partner's pods share a node. No redundancy.
- **No per-pod coupling** — observes pods via the Kubernetes API; the partner's workloads
  need no sidecar or spec changes.

**Cons**
- **It is real software to own** — a control loop you build, deploy, monitor, and patch
  (this sample is intentionally simple, not a hardened operator).
- **Needs cluster RBAC** — read access to pods/nodes, plus correct scoping so it only
  attributes this partner's workloads.
- **Single point of attribution** — if the controller is down across a month boundary, that
  month's touches can be missed (production would add leader election / alerting).

## Files

| File | Purpose |
|---|---|
| `controller-stack.yaml` | CloudFormation: EKS Auto Mode cluster, the dedicated controller IAM role and Pod Identity association, **and the ECR repository** for the image. |
| `controller.py` | The control loop (Python, boto3 + kubernetes client). |
| `requirements.txt` | Python dependencies. |
| `Dockerfile` | Builds the controller image. |
| `deploy.sh` | Builds/pushes the image and applies the namespace, RBAC, and Deployment. |
| `k8s/namespace.yaml` | `prm-controller` namespace. |
| `k8s/rbac.yaml` | Service account + cluster-scoped read access to pods/nodes. |
| `k8s/deployment.yaml` | The controller Deployment (placeholders rendered by `deploy.sh`). |

## Configuration

The controller is scoped by environment variables (set via `deploy.sh` flags):

| Env var | Flag | Default | Meaning |
|---|---|---|---|
| `TARGET_NAMESPACE` | `--target-namespace` | `""` (all) | Only count pods in this namespace. |
| `TARGET_LABEL_SELECTOR` | `--target-selector` | `""` (all) | Only count pods matching this label selector. |
| `RESCAN_INTERVAL_SECONDS` | `--rescan` | `300` | How often to re-scan for new nodes. |

Scope the controller to **this partner's** workloads (namespace and/or label) so it does
not touch nodes used only by other tenants.

## Prerequisites

- `aws` CLI v2, `kubectl`, and `docker` installed locally.
- Your **PRM product code** (the part after `pc_`).

## Step 1 — Deploy the stack (cluster + controller IAM)

```bash
aws cloudformation deploy \
  --template-file user-agent-eks/controller/controller-stack.yaml \
  --stack-name prm-controller \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides SubnetIds=subnet-aaa,subnet-bbb \
  --region eu-west-1 \
  --profile aryaml-admin
```

## Step 2 — Build the image and deploy the controller

```bash
cd user-agent-eks/controller
./deploy.sh \
  --product-code 884v80briot95klzp4c8b5inu \
  --cluster prm-controller \
  --region eu-west-1 \
  --profile aryaml-admin \
  --target-selector app=my-partner-app
```

Run `./deploy.sh --help` for all options (including `--target-namespace`, `--rescan`, and
`--image`).

### Cadence and PRM requirement

PRM only **requires one successful API call against a given node's instance ARN per
calendar month**. By default the controller touches each node-in-use once per calendar
month (tracked internally), re-scanning every `--rescan` seconds only to discover new
nodes — the correct production cadence.

For **testing only**, pass `--test-interval` to make the controller re-touch every node on
each scan (bypassing the monthly de-dup) at that interval:

```bash
./deploy.sh --product-code <CODE> --test-interval 60   # re-touch every minute (TEST ONLY)
```

This sets `TEST_INTERVAL_SECONDS` on the controller. It is **not** how PRM works — leave it
unset (or `0`) for production.

## Verify

```bash
kubectl -n prm-controller logs deploy/prm-controller -f

aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=DescribeInstanceAttribute \
  --region eu-west-1 --max-results 5 \
  --query 'Events[].CloudTrailEvent' --output text | grep -o 'app/APN_1.1[^ "]*'
```

## Clean up

```bash
kubectl delete namespace prm-controller
kubectl delete clusterrole prm-controller-reader
kubectl delete clusterrolebinding prm-controller-reader-binding
aws cloudformation delete-stack --stack-name prm-controller --region eu-west-1
```

## License

MIT-0 — see [../../LICENSE](../../LICENSE).
