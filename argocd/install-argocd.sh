#!/usr/bin/env bash

set -Eeuo pipefail

NAMESPACE="argocd"
CONTROLLER_NODE="controller"
ARGOCD_MANIFEST="https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"
TIMEOUT="300s"

ARGOCD_DEPLOYMENTS=(
  "argocd-server"
  "argocd-repo-server"
  "argocd-dex-server"
  "argocd-notifications-controller"
  "argocd-applicationset-controller"
  "argocd-redis"
)

RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
BLUE="\033[0;34m"
NC="\033[0m"

header() {
  echo
  echo "============================================================"
  echo "$1"
  echo "============================================================"
}

success() {
  echo -e "${GREEN}SUCCESS:${NC} $1"
}

warning() {
  echo -e "${YELLOW}WARNING:${NC} $1"
}

error() {
  echo -e "${RED}ERROR:${NC} $1"
}

info() {
  echo -e "${BLUE}INFO:${NC} $1"
}

diagnostics() {
  echo
  echo "============================================================"
  echo "INSTALLATION FAILED - DIAGNOSTICS"
  echo "============================================================"

  echo
  echo "Argo CD Pods:"
  kubectl get pods -n "${NAMESPACE}" -o wide 2>/dev/null || true

  echo
  echo "Argo CD Deployments:"
  kubectl get deployments -n "${NAMESPACE}" 2>/dev/null || true

  echo
  echo "Argo CD StatefulSets:"
  kubectl get statefulsets -n "${NAMESPACE}" 2>/dev/null || true

  echo
  echo "Recent Argo CD Events:"
  kubectl get events \
    -n "${NAMESPACE}" \
    --sort-by='.lastTimestamp' \
    2>/dev/null | tail -30 || true

  echo
  echo "Pending Pods:"

  kubectl get pods \
    -n "${NAMESPACE}" \
    --field-selector=status.phase=Pending \
    -o wide \
    2>/dev/null || true
}

trap diagnostics ERR

header "Checking Required Commands"

if ! command -v kubectl >/dev/null 2>&1; then
  error "kubectl is not installed or not in PATH."
  exit 1
fi

success "kubectl found"

if ! command -v base64 >/dev/null 2>&1; then
  warning "base64 command not found."
  warning "Password decoding command may differ on your system."
else
  success "base64 found"
fi

header "Checking Kubernetes Cluster Connection"

if ! kubectl cluster-info >/dev/null 2>&1; then
  error "Cannot connect to Kubernetes cluster."
  error "Check kubeconfig and cluster status."
  exit 1
fi

success "Kubernetes cluster connection successful"

header "Checking Controller Node"

if ! kubectl get node "${CONTROLLER_NODE}" >/dev/null 2>&1; then
  error "Controller node '${CONTROLLER_NODE}' does not exist."

  echo
  echo "Available nodes:"
  kubectl get nodes

  exit 1
fi

success "Controller node exists: ${CONTROLLER_NODE}"

header "Checking Controller Hostname Label"

NODE_HOSTNAME=$(
  kubectl get node "${CONTROLLER_NODE}" \
    -o jsonpath='{.metadata.labels.kubernetes\.io/hostname}'
)

if [[ -z "${NODE_HOSTNAME}" ]]; then
  error "Node does not have kubernetes.io/hostname label."
  kubectl get node "${CONTROLLER_NODE}" --show-labels
  exit 1
fi

if [[ "${NODE_HOSTNAME}" != "${CONTROLLER_NODE}" ]]; then
  error "Controller hostname label mismatch."

  echo
  echo "Expected node:"
  echo "${CONTROLLER_NODE}"

  echo
  echo "Actual hostname label:"
  echo "${NODE_HOSTNAME}"

  exit 1
fi

success "Controller hostname label verified"

header "Checking Controller Node Taints"

CONTROLLER_TAINTS=$(
  kubectl get node "${CONTROLLER_NODE}" \
    -o jsonpath='{.spec.taints[*].key}' 2>/dev/null || true
)

echo "Detected taints:"
echo "${CONTROLLER_TAINTS:-None}"

header "Creating Argo CD Namespace"

kubectl create namespace "${NAMESPACE}" \
  --dry-run=client \
  -o yaml | kubectl apply -f -

success "Namespace ready: ${NAMESPACE}"

header "Checking Existing Argo CD Installation"

EXISTING_RESOURCES=$(
  kubectl get deployments,statefulsets \
    -n "${NAMESPACE}" \
    --no-headers \
    2>/dev/null || true
)

if [[ -n "${EXISTING_RESOURCES}" ]]; then
  warning "Existing Argo CD workloads detected."
  kubectl get deployments,statefulsets -n "${NAMESPACE}"
else
  success "No existing workloads detected"
fi

header "Checking Argo CD CRDs"

if kubectl get crd applicationsets.argoproj.io >/dev/null 2>&1; then

  CRD_SIZE=$(
    kubectl get crd applicationsets.argoproj.io \
      -o jsonpath='{.metadata.annotations.kubectl\.kubernetes\.io/last-applied-configuration}' \
      2>/dev/null | wc -c
  )

  if [[ "${CRD_SIZE}" -gt 200000 ]]; then
    warning "Large last-applied annotation detected."
    warning "Removing problematic ApplicationSet CRD."

    kubectl delete crd applicationsets.argoproj.io \
      --ignore-not-found
  else
    success "ApplicationSet CRD does not contain oversized annotation"
  fi

else
  success "ApplicationSet CRD does not exist yet"
fi

header "Installing Argo CD"

info "Using server-side apply"

kubectl apply \
  --server-side \
  --force-conflicts \
  -n "${NAMESPACE}" \
  -f "${ARGOCD_MANIFEST}"

success "Argo CD manifests applied"

header "Waiting for Argo CD Deployments"

for deployment in "${ARGOCD_DEPLOYMENTS[@]}"; do

  info "Waiting for deployment/${deployment}"

  until kubectl get deployment "${deployment}" \
    -n "${NAMESPACE}" \
    >/dev/null 2>&1
  do
    sleep 2
  done

done

success "All Argo CD deployments created"

header "Waiting for Argo CD Application Controller"

until kubectl get statefulset \
  argocd-application-controller \
  -n "${NAMESPACE}" \
  >/dev/null 2>&1
do
  sleep 2
done

success "Application controller created"

header "Configuring Controller Scheduling"

PATCH=$(cat <<EOF
{
  "spec": {
    "template": {
      "spec": {
        "nodeSelector": {
          "kubernetes.io/hostname": "${CONTROLLER_NODE}"
        },
        "tolerations": [
          {
            "operator": "Exists"
          }
        ]
      }
    }
  }
}
EOF
)

header "Scheduling Argo CD Deployments on Controller"

for deployment in "${ARGOCD_DEPLOYMENTS[@]}"; do

  info "Patching deployment/${deployment}"

  kubectl patch deployment \
    "${deployment}" \
    -n "${NAMESPACE}" \
    --type=merge \
    -p "${PATCH}"

done

success "Deployments patched"

header "Scheduling Application Controller on Controller"

kubectl patch statefulset \
  argocd-application-controller \
  -n "${NAMESPACE}" \
  --type=merge \
  -p "${PATCH}"

success "Application controller patched"

header "Waiting for Argo CD Deployments"

for deployment in "${ARGOCD_DEPLOYMENTS[@]}"; do

  info "Waiting for deployment/${deployment}"

  kubectl rollout status \
    deployment/"${deployment}" \
    -n "${NAMESPACE}" \
    --timeout="${TIMEOUT}"

done

success "All Argo CD deployments are ready"

header "Waiting for Application Controller"

kubectl rollout status \
  statefulset/argocd-application-controller \
  -n "${NAMESPACE}" \
  --timeout="${TIMEOUT}"

success "Application controller is ready"

header "Argo CD Pod Status"

kubectl get pods \
  -n "${NAMESPACE}" \
  -o wide

header "Verifying Pod Placement"

BAD_PODS=0

while read -r POD NODE; do

  if [[ "${NODE}" != "${CONTROLLER_NODE}" ]]; then
    warning "Pod ${POD} is running on ${NODE}, expected ${CONTROLLER_NODE}"
    BAD_PODS=1
  fi

done < <(
  kubectl get pods \
    -n "${NAMESPACE}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.nodeName}{"\n"}{end}'
)

if [[ "${BAD_PODS}" -eq 1 ]]; then
  error "Some Argo CD pods are not running on the controller."
  kubectl get pods -n "${NAMESPACE}" -o wide
  exit 1
fi

success "All Argo CD pods are running on controller"

header "Verifying Pod Readiness"

NOT_READY=$(
  kubectl get pods \
    -n "${NAMESPACE}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"="}{range .status.containerStatuses[*]}{.ready}{" "}{end}{"\n"}{end}' \
    | grep "false" || true
)

if [[ -n "${NOT_READY}" ]]; then
  error "Some Argo CD containers are not ready."
  echo "${NOT_READY}"
  exit 1
fi

success "All Argo CD containers are ready"

header "Argo CD Installation Completed Successfully"

kubectl get pods \
  -n "${NAMESPACE}" \
  -o wide

echo
echo "============================================================"
echo "Argo CD UI Access"
echo "============================================================"

echo
echo "Run this command on the controller:"
echo

echo "kubectl port-forward svc/argocd-server -n argocd 8080:443"

echo
echo "Then open:"
echo
echo "https://localhost:8080"

echo
echo "Username:"
echo
echo "admin"

echo
echo "Initial password:"
echo

echo "kubectl -n argocd get secret argocd-initial-admin-secret \\"
echo "  -o jsonpath=\"{.data.password}\" | base64 -d"

echo
