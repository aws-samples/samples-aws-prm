# DaemonSet Attribution (partitioned compute)

A **DaemonSet** that runs one attribution pod per node. Each pod touches its own node's
EC2 instance ARN at startup and once per calendar month, with the partner product code in
the SDK User-Agent (`AWS_SDK_UA_APP_ID`).

> **Use only for PARTITIONED compute.** A DaemonSet
> runs on every node it is allowed to schedule on. In a multi-tenant cluster with
> **intermixed** compute this **over-attributes** — it touches nodes the partner does not
> use and takes even-split share from the partners who do, violating PRM's "calls directly
> made by your solution" rule. This pattern is correct **only** when restricted (via
> `nodeSelector`) to a node pool **dedicated** to this partner. For intermixed compute use
> the [`../sidecar/`](../sidecar/) pattern instead.

> **Sample code — not production-ready.** Review IAM scope and pin the image to a digest
> before any real use.

## What it does

```
DaemonSet (one pod per selected node)
  └─ Pod (ServiceAccount: prm-daemonset-sa, nodeSelector: dedicated pool)
       ├─ EKS Pod Identity → assumes the dedicated IAM role → temp credentials
       ├─ AWS_SDK_UA_APP_ID = APN_1.1/pc_<PRODUCT-CODE>$
       ├─ resolve this node's EC2 instance ID (node name on Auto Mode; else DescribeInstances)
       ├─ touch: ec2:DescribeInstanceAttribute on the instance ARN
       └─ loop: re-touch once at the start of each CALENDAR month
```

- **Calendar-month cadence**, one touch per node per month (even-split counts distinct
  partners, not touches).
- **Fails closed**: EC2 nodes only; if no instance ID resolves or a call fails, it logs and
  idles — never crash-loops.
- **Dedicated identity**: its own namespace, service account, and IAM role.
- **Scoping**: the `nodeSelector` (rendered by `deploy.sh`) restricts the DaemonSet to the
  partner's dedicated nodes. `--all-nodes` removes the selector (NOT recommended for
  intermixed clusters).

## Pros and cons

**Pros**
- **Automatic per-node coverage** — Kubernetes places one pod on every matching node,
  including new nodes the moment they join, so node churn is handled with no extra logic.
- **No per-pod coupling** — independent of the partner's workloads; nothing changes in
  their Deployments.
- **Simple, declarative** — a plain DaemonSet manifest, no custom controller code.

**Cons**
- **Over-attributes on intermixed compute** — runs on every selected node; without strict
  partitioning it touches nodes the partner does not use, taking even-split share from
  other partners and violating PRM's direct-call rule. **Only safe with a dedicated node
  pool + `nodeSelector`.**
- **Requires partitioned compute** — needs dedicated, labeled nodes to be correct, which
  not every multi-tenant cluster has.
- **Per-node footprint** — one always-on (mostly sleeping) pod per node in scope.

## Files

| File | Purpose |
|---|---|
| `daemonset-stack.yaml` | CloudFormation: EKS Auto Mode cluster, the dedicated DaemonSet IAM role and Pod Identity association, **and the ECR repository** for the image. |
| `touch-loop.sh` | Pod entrypoint: calendar-aligned touch loop with fail-closed logic. |
| `Dockerfile` | Builds the image (AWS CLI v2 + `touch-loop.sh`). |
| `deploy.sh` | Builds/pushes the image and applies the namespace, service account, and DaemonSet. |
| `k8s/namespace.yaml` | `prm-daemonset` namespace. |
| `k8s/serviceaccount.yaml` | `prm-daemonset-sa` service account. |
| `k8s/daemonset.yaml` | The DaemonSet (placeholders rendered by `deploy.sh`). |

## Prerequisites

- `aws` CLI v2, `kubectl`, and `docker` installed locally.
- Your **PRM product code** (the part after `pc_`).

## Step 1 — Deploy the stack (cluster + DaemonSet IAM)

```bash
aws cloudformation deploy \
  --template-file user-agent-eks/daemonset/daemonset-stack.yaml \
  --stack-name prm-daemonset \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides SubnetIds=subnet-aaa,subnet-bbb \
  --region eu-west-1 \
  --profile aryaml-admin
```

## Step 2 — Build the image and deploy the DaemonSet

```bash
cd user-agent-eks/daemonset
./deploy.sh \
  --product-code 884v80briot95klzp4c8b5inu \
  --cluster prm-daemonset \
  --region eu-west-1 \
  --profile aryaml-admin \
  --selector prm-partner=this-partner
```

Then label the partner's dedicated nodes so they receive a pod:

```bash
kubectl label node <NODE_NAME> prm-partner=this-partner
```

Run `./deploy.sh --help` for all options (including `--all-nodes` and `--image`).

### Cadence and PRM requirement

PRM only **requires one successful API call against a given node's instance ARN per
calendar month**. By default each DaemonSet pod touches its node on startup and then once
per calendar month — the correct production cadence.

For **testing only**, pass `--test-interval` to touch every N seconds so you can watch
activity quickly:

```bash
./deploy.sh --product-code <CODE> --test-interval 60   # touch every minute (TEST ONLY)
```

This sets `TEST_INTERVAL_SECONDS` on the pods. It is **not** how PRM works — leave it unset
(or `0`) for production.

## Verify

```bash
kubectl -n prm-daemonset logs -l app=prm-daemonset --prefix -f

aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=DescribeInstanceAttribute \
  --region eu-west-1 --max-results 5 \
  --query 'Events[].CloudTrailEvent' --output text | grep -o 'app/APN_1.1[^ "]*'
```

## Clean up

```bash
kubectl delete namespace prm-daemonset
aws cloudformation delete-stack --stack-name prm-daemonset --region eu-west-1
```

## License

MIT-0 — see [../../LICENSE](../../LICENSE).
