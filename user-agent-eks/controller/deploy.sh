#!/usr/bin/env bash
#
# Deploy the PRM attribution controller sample to an EKS Auto Mode cluster.
#
# Prerequisite: deploy controller-stack.yaml first. That CloudFormation stack
# creates the cluster, the dedicated controller IAM role, and the EKS Pod Identity
# association for the controller service account.
#
# This script:
#   1. Builds the controller image and pushes it to ECR.
#   2. Applies the namespace, RBAC (service account + read access to pods/nodes),
#      and the controller Deployment.
#
# Usage:
#   ./deploy.sh --product-code <PRM_PRODUCT_CODE> [options]
#
# Required:
#   --product-code CODE     PRM product code (the part after pc_)
#
# Options:
#   --cluster NAME          EKS cluster name        (default: prm-controller)
#   --region REGION         AWS region              (default: from AWS config, else eu-west-1)
#   --profile PROFILE       AWS CLI profile         (default: none)
#   --repo NAME             ECR repository name     (default: prm-controller)
#   --image URI             Use a prebuilt image URI and skip the build/push step
#   --target-namespace NS   Only attribute nodes hosting pods in this namespace
#                           (default: "" = all namespaces)
#   --target-selector SEL   Only attribute nodes hosting pods matching this label
#                           selector, e.g. app=my-partner-app (default: "" = all pods)
#   --rescan SECONDS        Re-scan interval for new nodes (default: 300)
#   --container-cli CLI     Container CLI for build/push: docker or finch (default: docker)
#   --test-interval SECS    TESTING ONLY: re-touch every node each scan (bypassing
#                           the monthly de-dup) every SECS seconds (default: 0 =
#                           monthly, production). PRM only needs monthly per ARN.
#   -h, --help              Show this help
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="${SCRIPT_DIR}/k8s"

# Defaults
CLUSTER_NAME="prm-controller"
REGION=""
PROFILE=""
REPO_NAME="prm-controller"
IMAGE_URI=""
PRODUCT_CODE=""
TARGET_NAMESPACE=""
TARGET_SELECTOR=""
RESCAN="300"
CONTAINER_CLI="docker"
TEST_INTERVAL_SECONDS="0"

usage() { sed -n '2,36p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --product-code)     PRODUCT_CODE="$2"; shift 2 ;;
    --cluster)          CLUSTER_NAME="$2"; shift 2 ;;
    --region)           REGION="$2"; shift 2 ;;
    --profile)          PROFILE="$2"; shift 2 ;;
    --repo)             REPO_NAME="$2"; shift 2 ;;
    --image)            IMAGE_URI="$2"; shift 2 ;;
    --target-namespace) TARGET_NAMESPACE="$2"; shift 2 ;;
    --target-selector)  TARGET_SELECTOR="$2"; shift 2 ;;
    --rescan)           RESCAN="$2"; shift 2 ;;
    --container-cli)    CONTAINER_CLI="$2"; shift 2 ;;
    --test-interval)    TEST_INTERVAL_SECONDS="$2"; shift 2 ;;
    -h|--help)          usage 0 ;;
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

echo "==> Configuration"
echo "    Cluster:          ${CLUSTER_NAME}"
echo "    Region:           ${REGION}"
echo "    UA app id:        ${APP_ID}"
echo "    Target namespace: ${TARGET_NAMESPACE:-<all>}"
echo "    Target selector:  ${TARGET_SELECTOR:-<none>}"
echo "    Rescan interval:  ${RESCAN}s"
if [ "${TEST_INTERVAL_SECONDS}" != "0" ]; then
  echo "    Cadence:          TEST MODE — re-touch every ${TEST_INTERVAL_SECONDS}s (NOT production; PRM needs monthly)"
else
  echo "    Cadence:          once per calendar month (production)"
fi

# ---------------------------------------------------------------------------
# 1. Build + push image (unless a prebuilt --image was supplied)
# ---------------------------------------------------------------------------
if [ -z "${IMAGE_URI}" ]; then
  ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
  IMAGE_URI="${ECR_REGISTRY}/${REPO_NAME}:latest"
  # The ECR repository is created by the CloudFormation stack (controller-stack.yaml),
  # so it shares the stack's lifecycle and is removed by `delete-stack`.

  echo "==> Logging in to ECR"
  aws ecr get-login-password "${AWS_ARGS[@]}" \
    | "${CONTAINER_CLI}" login --username AWS --password-stdin "${ECR_REGISTRY}"

  echo "==> Building and pushing ${IMAGE_URI} (using ${CONTAINER_CLI})"
  "${CONTAINER_CLI}" build --platform linux/amd64 -t "${IMAGE_URI}" "${SCRIPT_DIR}"
  "${CONTAINER_CLI}" push "${IMAGE_URI}"
else
  echo "    Image:            ${IMAGE_URI} (prebuilt; skipping build)"
fi

# ---------------------------------------------------------------------------
# 2. kubeconfig + manifests
# ---------------------------------------------------------------------------
echo "==> Updating kubeconfig for ${CLUSTER_NAME}"
aws eks update-kubeconfig --name "${CLUSTER_NAME}" "${AWS_ARGS[@]}" >/dev/null

echo "==> Applying namespace and RBAC"
kubectl apply -f "${K8S_DIR}/namespace.yaml"
kubectl apply -f "${K8S_DIR}/rbac.yaml"

echo "==> Applying controller Deployment"
RENDERED="$(mktemp)"
trap 'rm -f "${RENDERED}"' EXIT
sed -e "s#__CONTROLLER_IMAGE__#${IMAGE_URI}#g" \
    -e "s#__APP_ID__#${APP_ID}#g" \
    -e "s#__REGION__#${REGION}#g" \
    -e "s#__TARGET_NAMESPACE__#${TARGET_NAMESPACE}#g" \
    -e "s#__TARGET_LABEL_SELECTOR__#${TARGET_SELECTOR}#g" \
    -e "s#__RESCAN__#${RESCAN}#g" \
    -e "s#__TEST_INTERVAL_SECONDS__#${TEST_INTERVAL_SECONDS}#g" \
    "${K8S_DIR}/deployment.yaml" > "${RENDERED}"
kubectl apply -f "${RENDERED}"

echo
echo "==> Done."
echo "Watch the controller scan and touch nodes:"
echo "    kubectl -n prm-controller logs deploy/prm-controller -f"
