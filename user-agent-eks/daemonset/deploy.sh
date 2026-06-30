#!/usr/bin/env bash
#
# Deploy the PRM attribution DaemonSet sample to an EKS Auto Mode cluster.
#
# Prerequisite: deploy daemonset-stack.yaml first. That CloudFormation stack
# creates the cluster, the dedicated DaemonSet IAM role, and the EKS Pod Identity
# association for the DaemonSet service account.
#
# This script:
#   1. Builds the image and pushes it to ECR.
#   2. Applies the namespace, service account, and DaemonSet to the cluster.
#
# Usage:
#   ./deploy.sh --product-code <PRM_PRODUCT_CODE> [options]
#
# Required:
#   --product-code CODE     PRM product code (the part after pc_)
#
# Options:
#   --cluster NAME          EKS cluster name      (default: prm-daemonset)
#   --region REGION         AWS region            (default: from AWS config, else eu-west-1)
#   --profile PROFILE       AWS CLI profile       (default: none)
#   --namespace NS          Kubernetes namespace  (default: prm-daemonset)
#   --repo NAME             ECR repository name   (default: prm-daemonset)
#   --image URI             Use a prebuilt image URI and skip the build/push step
#   --selector KEY=VALUE    nodeSelector for the partner's dedicated nodes
#                           (default: prm-partner=this-partner)
#   --all-nodes             Run on ALL nodes (removes the nodeSelector). NOT
#                           recommended for intermixed multi-tenant clusters; it
#                           touches nodes the partner does not use.
#   --container-cli CLI     Container CLI for build/push: docker or finch (default: docker)
#   --test-interval SECS    TESTING ONLY: touch every SECS seconds instead of once
#                           per calendar month (default: 0 = monthly, production).
#                           PRM only requires one touch per node ARN per month.
#   -h, --help              Show this help
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="${SCRIPT_DIR}/k8s"

# Defaults
CLUSTER_NAME="prm-daemonset"
REGION=""
PROFILE=""
NAMESPACE="prm-daemonset"
REPO_NAME="prm-daemonset"
IMAGE_URI=""
PRODUCT_CODE=""
SELECTOR="prm-partner=this-partner"
ALL_NODES="false"
CONTAINER_CLI="docker"
TEST_INTERVAL_SECONDS="0"

usage() { sed -n '2,36p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --product-code) PRODUCT_CODE="$2"; shift 2 ;;
    --cluster)      CLUSTER_NAME="$2"; shift 2 ;;
    --region)       REGION="$2"; shift 2 ;;
    --profile)      PROFILE="$2"; shift 2 ;;
    --namespace)    NAMESPACE="$2"; shift 2 ;;
    --repo)         REPO_NAME="$2"; shift 2 ;;
    --image)        IMAGE_URI="$2"; shift 2 ;;
    --selector)     SELECTOR="$2"; shift 2 ;;
    --all-nodes)    ALL_NODES="true"; shift 1 ;;
    --container-cli) CONTAINER_CLI="$2"; shift 2 ;;
    --test-interval) TEST_INTERVAL_SECONDS="$2"; shift 2 ;;
    -h|--help)      usage 0 ;;
    *) echo "Unknown argument: $1" >&2; usage 1 ;;
  esac
done

if [ -z "${PRODUCT_CODE}" ]; then
  echo "ERROR: --product-code is required." >&2
  usage 1
fi

AWS_ARGS=()
[ -n "${PROFILE}" ] && AWS_ARGS+=(--profile "${PROFILE}")
if [ -z "${REGION}" ]; then
  REGION="$(aws configure get region "${AWS_ARGS[@]}" 2>/dev/null || true)"
  REGION="${REGION:-eu-west-1}"
fi
AWS_ARGS+=(--region "${REGION}")

APP_ID="APN_1.1/pc_${PRODUCT_CODE}\$"
ACCOUNT_ID="$(aws sts get-caller-identity "${AWS_ARGS[@]}" --query Account --output text)"

# Parse selector KEY=VALUE
SELECTOR_KEY="${SELECTOR%%=*}"
SELECTOR_VALUE="${SELECTOR#*=}"

echo "==> Configuration"
echo "    Cluster:    ${CLUSTER_NAME}"
echo "    Region:     ${REGION}"
echo "    Namespace:  ${NAMESPACE}"
echo "    UA app id:  ${APP_ID}"
if [ "${ALL_NODES}" = "true" ]; then
  echo "    Node scope: ALL NODES (no selector) -- not recommended for intermixed clusters"
else
  echo "    Node scope: ${SELECTOR_KEY}=${SELECTOR_VALUE}"
fi
if [ "${TEST_INTERVAL_SECONDS}" != "0" ]; then
  echo "    Cadence:    TEST MODE — every ${TEST_INTERVAL_SECONDS}s (NOT production; PRM needs monthly)"
else
  echo "    Cadence:    once per calendar month (production)"
fi

# ---------------------------------------------------------------------------
# 1. Build + push image (unless a prebuilt --image was supplied)
# ---------------------------------------------------------------------------
if [ -z "${IMAGE_URI}" ]; then
  ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
  IMAGE_URI="${ECR_REGISTRY}/${REPO_NAME}:latest"
  # The ECR repository is created by the CloudFormation stack (daemonset-stack.yaml),
  # so it shares the stack's lifecycle and is removed by `delete-stack`.

  echo "==> Logging in to ECR"
  aws ecr get-login-password "${AWS_ARGS[@]}" \
    | "${CONTAINER_CLI}" login --username AWS --password-stdin "${ECR_REGISTRY}"

  echo "==> Building and pushing ${IMAGE_URI} (using ${CONTAINER_CLI})"
  "${CONTAINER_CLI}" build --platform linux/amd64 -t "${IMAGE_URI}" "${SCRIPT_DIR}"
  "${CONTAINER_CLI}" push "${IMAGE_URI}"
else
  echo "    Image:      ${IMAGE_URI} (prebuilt; skipping build)"
fi

# ---------------------------------------------------------------------------
# 2. kubeconfig + manifests
# ---------------------------------------------------------------------------
echo "==> Updating kubeconfig for ${CLUSTER_NAME}"
aws eks update-kubeconfig --name "${CLUSTER_NAME}" "${AWS_ARGS[@]}" >/dev/null

echo "==> Applying namespace and service account"
kubectl apply -f "${K8S_DIR}/namespace.yaml"
kubectl apply -f "${K8S_DIR}/serviceaccount.yaml"

echo "==> Applying DaemonSet"
RENDERED="$(mktemp)"
trap 'rm -f "${RENDERED}"' EXIT
sed -e "s#__DAEMONSET_IMAGE__#${IMAGE_URI}#g" \
    -e "s#__APP_ID__#${APP_ID}#g" \
    -e "s#__REGION__#${REGION}#g" \
    -e "s#__NODE_SELECTOR_KEY__#${SELECTOR_KEY}#g" \
    -e "s#__NODE_SELECTOR_VALUE__#${SELECTOR_VALUE}#g" \
    -e "s#__TEST_INTERVAL_SECONDS__#${TEST_INTERVAL_SECONDS}#g" \
    "${K8S_DIR}/daemonset.yaml" > "${RENDERED}"

if [ "${ALL_NODES}" = "true" ]; then
  # Remove the nodeSelector block (the key line and the line after "nodeSelector:").
  # Done with a small python filter for reliability across sed variants.
  python3 - "${RENDERED}" <<'PY'
import sys
path = sys.argv[1]
out, skip = [], 0
for line in open(path):
    if skip:
        skip -= 1
        continue
    if line.strip() == "nodeSelector:":
        skip = 1  # also drop the single selector line that follows
        continue
    out.append(line)
open(path, "w").writelines(out)
PY
fi
kubectl apply -f "${RENDERED}"

echo
echo "==> Done."
echo "Watch the DaemonSet pods attribute their nodes:"
echo "    kubectl -n ${NAMESPACE} logs -l app=prm-daemonset --prefix -f"
echo "Label a node to receive a pod (dedicated-pool model):"
echo "    kubectl label node <NODE_NAME> ${SELECTOR_KEY}=${SELECTOR_VALUE}"
