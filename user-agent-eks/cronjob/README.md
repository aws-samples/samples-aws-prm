# DescribeInstanceAttribute CronJob (PRM User-Agent demo)

A scheduled Kubernetes **CronJob** that runs an `aws-cli` container on the EKS Auto Mode
cluster. On each run the container calls `ec2:DescribeInstanceAttribute` for the
`instanceType` of the node it is scheduled on, and **every AWS API call carries the PRM
partner product code in its User-Agent** via the `AWS_SDK_UA_APP_ID` environment
variable. This demonstrates the User-Agent attribution mechanism of AWS Partner Revenue
Measurement (PRM) for a containerized workload in EKS.

> **Single-instance demo.** This proves the User-Agent plumbing end-to-end (credentials
> via Pod Identity → API call → product code in the CloudTrail `userAgent`). It touches
> only the one node the CronJob pod happens to land on, so it does **not** solve
> multi-tenant, per-node, monthly attribution. For that, see the
> [`../sidecar/`](../sidecar/), [`../controller/`](../controller/), and
> [`../daemonset/`](../daemonset/) patterns.

> **Sample code — not production-ready.** Review IAM scope, scheduling, and image
> pinning before any real use.

## Two-part deployment

The setup is split so that all AWS/IAM provisioning is Infrastructure as Code, and only
the in-cluster objects are applied with `kubectl`:

1. **CloudFormation** ([`./eks-auto-mode-cluster.yaml`](./eks-auto-mode-cluster.yaml)) —
   the cluster template also provisions the IAM role and the EKS Pod Identity association
   that binds the role to the Kubernetes service account. Deploying the cluster gives you
   everything on the AWS side.
2. **Deploy script** (`deploy.sh`) — applies the namespace, service account, and CronJob
   manifests to the cluster.

## How it works

```
CronJob (schedule)
  └─ Pod (ServiceAccount: describe-instance-sa)
       ├─ EKS Pod Identity → assumes IAM role → temporary AWS credentials (no static keys)
       ├─ AWS_SDK_UA_APP_ID = APN_1.1/pc_<PRODUCT-CODE>$   (PRM attribution)
       ├─ resolve node instance ID  (DescribeInstances, filtered on node DNS name)
       └─ DescribeInstanceAttribute --attribute instanceType  → stdout
```

- **Credentials:** [EKS Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html),
  whose agent is **pre-installed on EKS Auto Mode clusters**. The cluster CloudFormation
  template creates an IAM role trusted by `pods.eks.amazonaws.com` and the
  `AWS::EKS::PodIdentityAssociation` that binds it to the service account. The association
  matches by namespace + service-account *name*, so it can be created before the service
  account exists in the cluster.
- **Instance ID:** the pod gets its node name through the Kubernetes Downward API
  (`spec.nodeName`), then resolves the EC2 instance ID with `DescribeInstances`. This
  avoids depending on IMDS, which is restricted from pods on EKS by default.
- **User-Agent:** `AWS_SDK_UA_APP_ID` is the SDK/CLI application-id setting that PRM uses.
  The value format is `APN_1.1/pc_<PRODUCT-CODE>$` — the trailing `$` is required.

## Pros and cons

**Pros**
- **Simplest possible demo** — one CronJob, no image to build, no per-pod or per-node
  footprint between runs.
- **Great for proving the plumbing** — confirms Pod Identity credentials, the API call, and
  the product code in the CloudTrail `userAgent` end-to-end.

**Cons**
- **Touches only one node** — the single node the CronJob pod lands on, so it does **not**
  cover all nodes a workload uses.
- **Misses churn** — a node that lives and dies between two monthly runs is never touched.
- **Not multi-tenant aware** — no notion of "the nodes this partner runs on". Use
  [`../sidecar/`](../sidecar/) or [`../controller/`](../controller/) for real attribution.

## Files

| File | Purpose |
|---|---|
| `eks-auto-mode-cluster.yaml` | CloudFormation: EKS Auto Mode cluster + the workload IAM role and Pod Identity association. |
| `deploy.sh` | Applies the namespace, service account, and CronJob with `kubectl`. |
| `k8s/namespace.yaml` | `prm-demo` namespace. |
| `k8s/serviceaccount.yaml` | `describe-instance-sa` ServiceAccount. |
| `k8s/cronjob.yaml` | The CronJob (placeholders rendered by `deploy.sh`). |

## Prerequisites

- The EKS Auto Mode cluster from [`./eks-auto-mode-cluster.yaml`](./eks-auto-mode-cluster.yaml)
  deployed and `ACTIVE` — this also creates the workload IAM role and Pod Identity association.
- `aws` CLI v2 and `kubectl` installed locally.
- Your **PRM product code** (the part after `pc_`). See
  [Product Code Retrieval](https://docs.aws.amazon.com/PRM/latest/aws-prm-onboarding-guide/product-code-retrieval.html).

## Step 1 — Deploy the cluster (provides IAM + Pod Identity)

The cluster template ([`./eks-auto-mode-cluster.yaml`](./eks-auto-mode-cluster.yaml)) also
provisions the workload IAM role and Pod Identity association. Its `WorkloadNamespace`
(`prm-demo`) and `WorkloadServiceAccount` (`describe-instance-sa`) defaults match the
manifests in this folder.

```bash
aws cloudformation deploy \
  --template-file user-agent-eks/cronjob/eks-auto-mode-cluster.yaml \
  --stack-name prm-auto-mode \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides SubnetIds=subnet-aaa,subnet-bbb \
  --region eu-west-1 \
  --profile aryaml-admin
```

See [`../README.md`](../README.md) for the full parameter and resource reference.

## Step 2 — Deploy the CronJob (kubectl)

```bash
cd user-agent-eks/cronjob
./deploy.sh \
  --product-code 5ugbbrmu7ud3u5hsipfzug61p \
  --cluster prm-auto-mode \
  --region eu-west-1 \
  --profile aryaml-admin
```

Default schedule is **`* * * * *` (every minute) — for testing only**, so you can watch
runs happen without waiting. Override with `--schedule "..."`. Run `./deploy.sh --help`
for all options. If you change `--namespace`, deploy the cluster stack with matching
`WorkloadNamespace` / `WorkloadServiceAccount`.

### Schedule and PRM cadence

The every-minute default exists purely so the demo produces visible activity quickly. **It
is not how PRM works.** PRM only requires **one API call against a given resource ARN per
calendar month** for that month's consumption to be attributed to your product code —
additional calls in the same month add nothing (and for a shared ARN, attribution is
even-split across the distinct partners that touched it that month).

For anything beyond a quick test, use a monthly schedule:

```bash
./deploy.sh --product-code <CODE> --schedule "0 0 1 * *"   # 00:00 UTC on the 1st each month
```

A per-minute CronJob left running needlessly re-calls the API ~43,000 times a month with
no attribution benefit. This demo also only touches the single node its pod lands on — see
the [`../sidecar/`](../sidecar/), [`../controller/`](../controller/), and
[`../daemonset/`](../daemonset/) patterns, which cover every node a workload runs on once
per calendar month for real (and multi-tenant) use.

## Test it immediately

CronJobs only fire on schedule, so spawn a one-off Job from the CronJob to test now:

```bash
kubectl -n prm-demo create job --from=cronjob/describe-instance-attribute describe-now
kubectl -n prm-demo logs -l job-name=describe-now --tail=-1
```

Expected output (instance ID and type will vary):

```
User-Agent app id: APN_1.1/pc_5ugbbrmu7ud3u5hsipfzug61p$
Resolving instance ID for node: ip-10-0-1-23.eu-west-1.compute.internal
Instance ID: i-0abc123def4567890
Calling DescribeInstanceAttribute (instanceType)...
{
    "InstanceId": "i-0abc123def4567890",
    "InstanceType": {
        "Value": "c6g.large"
    }
}
```

> **Note:** EKS Auto Mode only runs nodes when there are pods to place. The first run may
> wait a short time while Auto Mode provisions a node for the Job.

## Verify PRM attribution

After a run, confirm the product code reached AWS in the CloudTrail `userAgent` field:

```bash
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=DescribeInstanceAttribute \
  --region eu-west-1 --max-results 5 \
  --query 'Events[].CloudTrailEvent' --output text | grep -o 'APN_1.1/pc_[^ "]*'
```

## Clean up

```bash
# In-cluster objects
kubectl delete namespace prm-demo
```

The workload IAM role and Pod Identity association are part of the cluster stack, so they
are removed when you delete that stack (see [`../README.md`](../README.md)).

## License

MIT-0 — see [../../LICENSE](../../LICENSE).
