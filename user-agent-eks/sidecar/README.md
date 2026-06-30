# Sidecar Attribution (multi-tenant)

A pattern for attributing EC2 node compute to a
partner's PRM product code in a **multi-tenant** EKS cluster.

A sidecar container runs alongside the partner's own workload pods. Because attribution
rides with the pod, the sidecar touches exactly the nodes the partner's software runs on —
never others — which is what PRM's even-split rule requires (touching nodes you do not use
would steal attribution share from the partners who do).

> **Sample code — not production-ready.** Review IAM scope and pin the container image to a
> digest before any real use.

## What it does

```
Partner pod
  ├─ native sidecar (init container, restartPolicy: Always)
  │    ├─ EKS Pod Identity → assumes the dedicated sidecar IAM role → temp credentials
  │    ├─ AWS_SDK_UA_APP_ID = APN_1.1/pc_<PRODUCT-CODE>$   (PRM attribution)
  │    ├─ resolve this node's EC2 instance ID (node name on Auto Mode; else DescribeInstances)
  │    ├─ touch: ec2:DescribeInstanceAttribute on the instance ARN
  │    └─ loop: re-touch once at the start of each CALENDAR month
  └─ app container (the partner's real workload — always takes priority)
```

Key design points:

- **Calendar-month cadence.** Touch on startup, then once after each calendar-month
  boundary. PRM evaluates coverage per calendar month, so the loop aligns to the boundary
  rather than using a 30-day timer that could drift past a month.
- **One touch per node per month is enough.** Even-split counts each product code once per
  ARN per month regardless of touch count, so co-located pods touching the same node are
  redundant but harmless. No cross-pod de-duplication is attempted (that is the
  [`../controller/`](../controller/) pattern).
- **Fails closed.** PRM supports EC2 nodes only. If the sidecar cannot resolve an EC2
  instance ID, or an API call fails, it **logs and idles** — it never crash-loops and never
  disrupts the application container.
- **Native sidecar.** Declared as an init container with `restartPolicy: Always` (stable
  since Kubernetes 1.28): starts before the app, lives for the whole pod, exits cleanly
  with it, and never gates pod readiness on its own completion.
- **Dedicated identity.** This pattern has its **own** namespace, service account, and IAM
  role (separate from the `cronjob/` demo), matching the multi-tenant model where each
  partner owns its own attribution identity.

## Pros and cons

**Pros**
- **Correct by construction** for intermixed multi-tenant compute: touches exactly the
  nodes the partner's pods run on, never others, so it never over-attributes under PRM's
  even-split rule.
- **Automatic node-churn coverage** — a newly scheduled pod touches its new node at
  startup; nodes the partner stops using are no longer touched.
- **No central component or cluster-wide permissions** — each partner ships its own
  sidecar, identity, and product code, matching the multi-tenant trust model.

**Cons**
- **Couples to the partner's pod spec** — the sidecar must be added to the workload's
  Deployment/Pod templates.
- **Redundant calls** — multiple of the partner's pods on one node each touch that node
  (harmless under even-split, but wasteful). The [`../controller/`](../controller/) pattern
  removes this.
- **Per-pod footprint** — one always-on (mostly sleeping) sidecar per pod.

## Files

| File | Purpose |
|---|---|
| `sidecar-stack.yaml` | CloudFormation: EKS Auto Mode cluster, the dedicated sidecar IAM role and Pod Identity association, **and the ECR repository** for the image. |
| `touch-loop.sh` | The sidecar entrypoint: calendar-aligned touch loop with fail-closed logic. |
| `Dockerfile` | Builds the sidecar image (AWS CLI v2 + `touch-loop.sh`). |
| `deploy.sh` | Builds/pushes the image and applies the namespace, service account, and sample Deployment. |
| `k8s/namespace.yaml` | `prm-sidecar` namespace. |
| `k8s/serviceaccount.yaml` | `prm-sidecar-sa` service account. |
| `k8s/deployment.yaml` | Sample app Deployment with the native sidecar attached. |

## Prerequisites

- `aws` CLI v2, `kubectl`, and `docker` installed locally.
- Your **PRM product code** (the part after `pc_`). See
  [Product Code Retrieval](https://docs.aws.amazon.com/PRM/latest/aws-prm-onboarding-guide/product-code-retrieval.html).

## Step 1 — Deploy the stack (cluster + sidecar IAM)

```bash
aws cloudformation deploy \
  --template-file user-agent-eks/sidecar/sidecar-stack.yaml \
  --stack-name prm-sidecar \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides SubnetIds=subnet-aaa,subnet-bbb \
  --region eu-west-1 \
  --profile aryaml-admin
```

`CAPABILITY_NAMED_IAM` is required (named IAM roles). The cluster takes ~15 minutes to
become `ACTIVE`.

## Step 2 — Build the image and deploy the workload

```bash
cd user-agent-eks/sidecar
./deploy.sh \
  --product-code 884v80briot95klzp4c8b5inu \
  --cluster prm-sidecar \
  --region eu-west-1 \
  --profile aryaml-admin
```

Run `./deploy.sh --help` for all options (including `--image` to skip the build and use a
prebuilt image URI).

### Cadence and PRM requirement

PRM only **requires one successful API call against a given node's instance ARN per
calendar month** for that month's compute to be attributed to your product code.
Additional calls in the same month add nothing (and for a shared ARN, attribution is
even-split across the distinct partners that touched it that month). By default the
sidecar touches on startup and then once per calendar month — the correct production
cadence.

For **testing only**, pass `--test-interval` to make the sidecar touch every N seconds so
you can watch activity without waiting for a month boundary:

```bash
./deploy.sh --product-code <CODE> --test-interval 60   # touch every minute (TEST ONLY)
```

This sets the `TEST_INTERVAL_SECONDS` env var on the sidecar. It is **not** how PRM works
and must not be used in real deployments. Leave it unset (or `0`) for production.

## Verify

```bash
# Sidecar logs: startup touch, then the sleep-until-next-month line.
kubectl -n prm-sidecar logs deploy/sample-app -c prm-sidecar -f

# Confirm the product code reached AWS in the CloudTrail userAgent field.
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=DescribeInstanceAttribute \
  --region eu-west-1 --max-results 5 \
  --query 'Events[].CloudTrailEvent' --output text | grep -o 'app/APN_1.1[^ "]*'
```

> The SDK renders the app-id in the User-Agent as `app/APN_1.1-pc_<CODE>$` (the `/` after
> `APN_1.1` becomes `-` in that token); the product code and trailing `$` are preserved.

## Clean up

```bash
kubectl delete namespace prm-sidecar
aws cloudformation delete-stack --stack-name prm-sidecar --region eu-west-1
```

## License

MIT-0 — see [../../LICENSE](../../LICENSE).
