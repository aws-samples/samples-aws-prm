# User-Agent Attribution for PRM (EKS Context)

> **Work in progress.** This folder is the starting point for implementing the
> User-Agent string mechanism of AWS Partner Revenue Measurement (PRM) for
> workloads running in an Amazon EKS cluster. It is a sample and not yet
> production-ready.

## Overview

AWS PRM supports two complementary ways to attribute AWS service consumption to a
partner product:

1. **Resource tagging** — apply the `aws-apn-id` tag to resources. This is covered by
   the existing automations in this repo: [`deployment/`](../deployment/) (auto-tagging),
   [`remediation/`](../remediation/) (tag remediation), and [`backfill/`](../backfill/)
   (historical backfill).
2. **User-Agent string** — inject the partner APN product code into the AWS SDK / CLI
   `User-Agent` header so that the API calls themselves are attributed to the partner,
   without depending on a tag being present on the resource. **This folder addresses
   this second mechanism.**

For containerized partner workloads, the User-Agent approach attributes consumption at
the point of the API call. The goal in EKS is to ensure every pod that makes AWS API
calls emits the correct partner product code in its User-Agent, regardless of which
language SDK or CLI the container uses.

## Contents

| File | Description |
|---|---|
| [`DESIGN.md`](./DESIGN.md) | Design decision record: how to attribute node compute via User-Agent in a **multi-tenant** cluster, how PRM's even-split rule shapes the options, and the tradeoffs of each pattern. |
| [`cronjob/`](./cronjob/) | **Single-instance demo.** A CloudFormation cluster stack (`eks-auto-mode-cluster.yaml`) plus a scheduled **CronJob** that runs an `aws-cli` container calling `ec2:DescribeInstanceAttribute`, with the PRM partner product code injected into the SDK User-Agent. Proves the User-Agent plumbing end-to-end; touches only the one node its pod lands on, so see the other patterns for full coverage. |
| [`sidecar/`](./sidecar/) | A native sidecar that rides alongside a partner's workload and touches the EC2 node it runs on once per calendar month, so attribution follows the partner's pods. Self-contained CloudFormation stack (cluster + dedicated sidecar IAM/Pod Identity) plus image and manifests. |
| [`controller/`](./controller/) | A single controller that watches the partner's pods, derives the distinct set of nodes they run on, and touches each once per calendar month — no redundant calls, no per-pod coupling. Self-contained stack + image + manifests. |
| [`daemonset/`](./daemonset/) | One pod per node via a `nodeSelector` on the partner's dedicated node pool — suited to partitioned compute. Self-contained stack + image + manifests. See `DESIGN.md` for why this fits partitioned rather than intermixed compute. |

## Choosing a pattern

All patterns make the same underlying call — `ec2:DescribeInstanceAttribute` against a
node's instance ARN, with the PRM product code in the User-Agent, once per calendar month.
They differ in **which nodes** they touch and **how**. Under PRM's even-split rule, the
goal is to touch exactly the nodes the partner actually runs on (see [`DESIGN.md`](./DESIGN.md)).
The right choice depends on your environment — there is no single best pattern.

| Pattern | Fits | Coverage of "nodes I use" | Over-attribution risk | Per-pod coupling | Footprint | Complexity |
|---|---|---|---|---|---|---|
| **sidecar** | Intermixed multi-tenant | Exact (rides with the pod) | None | Yes (in pod spec) | 1 sidecar per pod | Low |
| **controller** | Intermixed multi-tenant, minimal calls | Exact (distinct node set) | None | No | 1 pod per cluster | High (real code) |
| **daemonset** | Partitioned compute (dedicated node pool) | Exact *iff* partitioned | High if run on all nodes | No | 1 pod per node | Low |
| **cronjob** | Plumbing demo only | One node only; misses churn | High | No | 1 pod per run | Low |

Quick guidance:

- **Partner pods intermixed with others on shared nodes** → `sidecar` (simple, follows the
  pods) or `controller` (exact, no redundant calls, no pod changes).
- **Each partner has dedicated, labeled nodes** → `daemonset` with a `nodeSelector`.
- **Just proving the mechanism** → `cronjob`.

Each folder's README has a detailed **Pros and cons** section to help you decide.

## EKS Auto Mode Cluster (cronjob demo stack)

The [`cronjob/eks-auto-mode-cluster.yaml`](./cronjob/eks-auto-mode-cluster.yaml) template
backs the single-instance demo. [EKS Auto Mode](https://docs.aws.amazon.com/eks/latest/userguide/automode.html)
lets AWS manage compute, networking (load balancing), and block storage for the cluster,
so you do not provision or operate node groups yourself. (The sidecar pattern has its own
self-contained stack, [`sidecar/sidecar-stack.yaml`](./sidecar/sidecar-stack.yaml).) The
template creates:

| Resource | Type | Purpose |
|---|---|---|
| `ClusterRole` | IAM Role | Cluster IAM role assumed by `eks.amazonaws.com`, with the five AWS-managed Auto Mode cluster policies. |
| `NodeRole` | IAM Role | Node IAM role assumed by `ec2.amazonaws.com`, with the worker-node minimal and ECR pull-only policies. |
| `Cluster` | EKS Cluster | Auto Mode cluster with `general-purpose` and `system` node pools, managed ELB, and managed EBS. |
| `DescribeInstanceRole` | IAM Role | Workload role assumed by `pods.eks.amazonaws.com` (EKS Pod Identity), allowing `ec2:DescribeInstanceAttribute` + `ec2:DescribeInstances`. |
| `DescribeInstancePodIdentity` | Pod Identity Association | Binds the `describe-instance-sa` service account in the `prm-demo` namespace to `DescribeInstanceRole`. |

### Important Notices

> **Sample code — not production-ready.** Review and harden before any real deployment.

- **Public endpoint enabled.** The template sets `EndpointPublicAccess: true` for ease of
  access during testing. For production, disable public access (or restrict it with
  `PublicAccessCidrs`) and use private access from within the VPC.
- **Cost implications.** An EKS cluster control plane bills hourly, and Auto Mode launches
  EC2 instances, EBS volumes, and load balancers on demand to run your workloads. Delete
  the stack when you are done to stop charges.
- **Authentication mode.** The cluster uses `API` authentication mode (required by Auto
  Mode). The IAM principal that creates the stack becomes the cluster admin; add EKS
  access entries for any other principals that need access.

### Parameters

| Parameter | Default | Description |
|---|---|---|
| `ClusterName` | `prm-auto-mode` | Name of the EKS cluster |
| `KubernetesVersion` | `1.36` | Kubernetes control plane version |
| `SubnetIds` | — | Subnets where Auto Mode deploys nodes (at least two AZs) |
| `WorkloadNamespace` | `prm-demo` | Namespace for the DescribeInstanceAttribute workload (Pod Identity) |
| `WorkloadServiceAccount` | `describe-instance-sa` | Service account bound to the workload IAM role |

### Deployment

Find subnets to use (e.g., your default VPC):

```bash
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$(aws ec2 describe-vpcs --query 'Vpcs[?IsDefault==`true`].VpcId' --output text)" \
  --query 'Subnets[*].SubnetId' --output text
```

Deploy the stack (`CAPABILITY_NAMED_IAM` is required because the template creates named
IAM roles):

```bash
aws cloudformation deploy \
  --template-file user-agent-eks/cronjob/eks-auto-mode-cluster.yaml \
  --stack-name prm-auto-mode \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides SubnetIds=subnet-aaa,subnet-bbb \
  --region YOUR-REGION
```

Configure `kubectl` once the cluster is active (~15 minutes):

```bash
aws eks update-kubeconfig --name prm-auto-mode --region YOUR-REGION
kubectl get nodepools
```

### Delete the stack

```bash
aws cloudformation delete-stack --stack-name prm-auto-mode --region YOUR-REGION
```

## Planned Next Steps

- Per-language examples (Python/boto3, JS, Go, Java) for appending the partner product code.
- A mutating admission webhook to inject `AWS_SDK_UA_APP_ID` cluster-wide automatically.

## License

MIT-0 — see [LICENSE](../LICENSE).
