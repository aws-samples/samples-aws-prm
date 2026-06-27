#!/usr/bin/env bash
#
# Deploy the PRM DescribeInstanceAttribute CronJob to an EKS Auto Mode cluster.
#
# This script handles ONLY the in-cluster (kubectl) part: namespace, service
# account, and CronJob. The IAM role and EKS Pod Identity association are
# provisioned by the cluster CloudFormation template (./eks-auto-mode-cluster.yaml)
# — deploy that stack first so the service account has AWS permissions.
#
# Usage:
#   ./deploy.sh --product-code <PRM_PRODUCT_CODE> [options]
#
# Required:
#   --product-code CODE     PRM product code (the part after pc_), e.g. 5ugbbrmu7ud3u5hsipfzug61p
#
# Options:
#   --cluster NAME          EKS cluster name        (default: prm-auto-mode)
#   --region REGION         AWS region              (default: from AWS config, else eu-west-1)
#   --profile PROFILE       AWS CLI profile         (default: none)
#   --schedule "CRON"       CronJob schedule        (default: "* * * * *" = every minute, for testing)
#   --namespace NS          Kubernetes namespace    (default: prm-demo)
#   -h, --help              Show this help
#
# NOTE: --namespace must match the WorkloadNamespace used when deploying
#       ./eks-auto-mode-cluster.yaml, or Pod Identity will not grant credentials.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="${SCRIPT_DIR}/k8s"

# Defaults
CLUSTER_NAME="prm-auto-mode"
REGION=""
PROFILE=""
SCHEDULE="* * * * *"
NAMESPACE="prm-demo"
PRODUCT_CODE=""

usage() { sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --product-code) PRODUCT_CODE="$2"; shift 2 ;;
    --cluster)      CLUSTER_NAME="$2"; shift 2 ;;
    --region)       REGION="$2"; shift 2 ;;
    --profile)      PROFILE="$2"; shift 2 ;;
    --schedule)     SCHEDULE="$2"; shift 2 ;;
    --namespace)    NAMESPACE="$2"; shift 2 ;;
    -h|--help)      usage 0 ;;
    *) echo "Unknown argument: $1" >&2; usage 1 ;;
  esac
done

if [ -z "${PRODUCT_CODE}" ]; then
  echo "ERROR: --product-code is required." >&2
  usage 1
fi

# Build AWS CLI base args (profile/region optional)
AWS_ARGS=()
[ -n "${PROFILE}" ] && AWS_ARGS+=(--profile "${PROFILE}")
if [ -z "${REGION}" ]; then
  REGION="$(aws configure get region "${AWS_ARGS[@]}" 2>/dev/null || true)"
  REGION="${REGION:-eu-west-1}"
fi
AWS_ARGS+=(--region "${REGION}")

APP_ID="APN_1.1/pc_${PRODUCT_CODE}\$"

echo "==> Configuration"
echo "    Cluster:    ${CLUSTER_NAME}"
echo "    Region:     ${REGION}"
echo "    Namespace:  ${NAMESPACE}"
echo "    Schedule:   ${SCHEDULE}"
echo "    UA app id:  ${APP_ID}"
echo

# ---------------------------------------------------------------------------
# 1. kubeconfig
# ---------------------------------------------------------------------------
echo "==> Updating kubeconfig for ${CLUSTER_NAME}"
aws eks update-kubeconfig --name "${CLUSTER_NAME}" "${AWS_ARGS[@]}" >/dev/null

# ---------------------------------------------------------------------------
# 2. Namespace + ServiceAccount
#    (Namespace is created from manifest; if you customized --namespace, the
#    manifests use prm-demo — override there too if needed.)
# ---------------------------------------------------------------------------
echo "==> Applying namespace and service account"
kubectl apply -f "${K8S_DIR}/namespace.yaml"
kubectl apply -f "${K8S_DIR}/serviceaccount.yaml"

# ---------------------------------------------------------------------------
# 3. CronJob (render placeholders, then apply)
# ---------------------------------------------------------------------------
echo "==> Applying CronJob"
RENDERED="$(mktemp)"
trap 'rm -f "${RENDERED}"' EXIT
sed -e "s#__SCHEDULE__#${SCHEDULE}#g" \
    -e "s#__APP_ID__#${APP_ID}#g" \
    -e "s#__REGION__#${REGION}#g" \
    "${K8S_DIR}/cronjob.yaml" > "${RENDERED}"
kubectl apply -f "${RENDERED}"

echo
echo "==> Done."
echo "Trigger an immediate test run:"
echo "    kubectl -n ${NAMESPACE} create job --from=cronjob/describe-instance-attribute describe-now"
echo "View logs:"
echo "    kubectl -n ${NAMESPACE} logs -l job-name=describe-now --tail=-1"
