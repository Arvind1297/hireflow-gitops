#!/usr/bin/env bash

set -Eeuo pipefail

# =========================================================
# HireFlow Kubernetes Deployment
# =========================================================

NAMESPACE="hireflow"

FILES=(
  "namespace.yaml"
  "database-pvc.yaml"
  "database-deployment.yaml"
  "database-service.yaml"
  "backend-deployment.yaml"
  "backend-service.yaml"
  "frontend-deployment.yaml"
  "frontend-service.yaml"
  "frontend-ingress.yaml"
)

CURRENT_STEP="initialization"

# =========================================================
# Colors
# =========================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# =========================================================
# Logging
# =========================================================

log() {
  echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $*"
}

success() {
  echo -e "${GREEN}✓ $*${NC}"
}

warn() {
  echo -e "${YELLOW}⚠ $*${NC}"
}

fail() {
  echo -e "${RED}✗ $*${NC}"
}

# =========================================================
# Error Handler
# =========================================================

on_error() {
  local exit_code=$?

  echo
  fail "Deployment failed."
  echo
  echo "Failed step : ${CURRENT_STEP}"
  echo "Exit code   : ${exit_code}"
  echo

  echo "Current Kubernetes status:"
  kubectl get pods -n "${NAMESPACE}" -o wide 2>/dev/null || true

  echo
  echo "Services:"
  kubectl get svc -n "${NAMESPACE}" 2>/dev/null || true

  echo
  echo "PVC:"
  kubectl get pvc -n "${NAMESPACE}" 2>/dev/null || true

  echo
  echo "Ingress:"
  kubectl get ingress -n "${NAMESPACE}" 2>/dev/null || true

  echo
  fail "Fix the problem and run the script again."
  exit "${exit_code}"
}

trap on_error ERR

# =========================================================
# Preflight
# =========================================================

echo
echo "========================================================="
echo "        HireFlow Kubernetes Deployment"
echo "========================================================="
echo

CURRENT_STEP="checking kubectl"

if ! command -v kubectl >/dev/null 2>&1; then
  fail "kubectl is not installed."
  exit 1
fi

success "kubectl found."

# =========================================================
# Kubernetes connectivity
# =========================================================

CURRENT_STEP="checking Kubernetes connection"

log "Checking Kubernetes cluster..."

if ! kubectl cluster-info >/dev/null 2>&1; then
  fail "Cannot connect to Kubernetes cluster."
  echo
  echo "Check:"
  echo "  kubectl get nodes"
  exit 1
fi

success "Kubernetes cluster is reachable."

# =========================================================
# Check all files
# =========================================================

CURRENT_STEP="checking manifest files"

log "Checking manifest files..."

for file in "${FILES[@]}"; do
  if [[ ! -f "${file}" ]]; then
    fail "Missing file: ${file}"
    exit 1
  fi

  success "Found ${file}"
done

# =========================================================
# Validate manifests
# =========================================================

CURRENT_STEP="validating Kubernetes manifests"

log "Validating manifests..."

for file in "${FILES[@]}"; do

  if ! kubectl apply \
      --dry-run=server \
      -f "${file}" >/dev/null; then

    fail "Invalid Kubernetes manifest: ${file}"
    exit 1
  fi

  success "Validated ${file}"
done

# =========================================================
# 1. Namespace
# =========================================================

CURRENT_STEP="creating namespace"

log "Creating namespace..."

kubectl apply -f namespace.yaml

if kubectl wait \
    --for=jsonpath='{.status.phase}'=Active \
    namespace/"${NAMESPACE}" \
    --timeout=60s >/dev/null 2>&1; then

  success "Namespace ${NAMESPACE} is ready."

else

  fail "Namespace ${NAMESPACE} did not become ready."
  exit 1

fi

# =========================================================
# 2. Database PVC
# =========================================================

CURRENT_STEP="creating database PVC"

log "Creating database PVC..."

kubectl apply -f database-pvc.yaml

success "Database PVC created/updated."

log "Waiting for database PVC..."

for i in {1..60}; do

  PVC_STATUS=$(kubectl get pvc database-pvc \
    -n "${NAMESPACE}" \
    -o jsonpath='{.status.phase}' 2>/dev/null || true)

  if [[ "${PVC_STATUS}" == "Bound" ]]; then
    success "Database PVC is Bound."
    break
  fi

  if [[ "${PVC_STATUS}" == "Lost" ]]; then
    fail "Database PVC entered Lost state."
    exit 1
  fi

  echo "  PVC status: ${PVC_STATUS:-Pending}"
  sleep 2

  if [[ "${i}" == "60" ]]; then
    fail "Database PVC did not become Bound within 120 seconds."
    kubectl describe pvc database-pvc -n "${NAMESPACE}" || true
    exit 1
  fi

done

# =========================================================
# 3. Database Deployment
# =========================================================

CURRENT_STEP="deploying database"

log "Deploying database..."

kubectl apply -f database-deployment.yaml

log "Waiting for database rollout..."

kubectl rollout status \
  deployment/database \
  -n "${NAMESPACE}" \
  --timeout=180s

success "Database is ready."

# =========================================================
# 4. Database Service
# =========================================================

CURRENT_STEP="creating database service"

log "Creating database service..."

kubectl apply -f database-service.yaml

success "Database service is ready."

# =========================================================
# 5. Backend Deployment
# =========================================================

CURRENT_STEP="deploying backend"

log "Deploying backend..."

kubectl apply -f backend-deployment.yaml

log "Waiting for backend rollout..."

kubectl rollout status \
  deployment/backend \
  -n "${NAMESPACE}" \
  --timeout=180s

success "Backend is ready."

# =========================================================
# 6. Backend Service
# =========================================================

CURRENT_STEP="creating backend service"

log "Creating backend service..."

kubectl apply -f backend-service.yaml

success "Backend service is ready."

# =========================================================
# 7. Frontend Deployment
# =========================================================

CURRENT_STEP="deploying frontend"

log "Deploying frontend..."

kubectl apply -f frontend-deployment.yaml

log "Waiting for frontend rollout..."

kubectl rollout status \
  deployment/frontend \
  -n "${NAMESPACE}" \
  --timeout=180s

success "Frontend is ready."

# =========================================================
# 8. Frontend Service
# =========================================================

CURRENT_STEP="creating frontend service"

log "Creating frontend service..."

kubectl apply -f frontend-service.yaml

success "Frontend service is ready."

# =========================================================
# 9. Ingress
# =========================================================

CURRENT_STEP="creating frontend ingress"

log "Creating frontend ingress..."

kubectl apply -f frontend-ingress.yaml

success "Frontend ingress is created."

# =========================================================
# Final Status
# =========================================================

echo
echo "========================================================="
echo "                DEPLOYMENT COMPLETE"
echo "========================================================="
echo

echo "Namespace:"
kubectl get namespace "${NAMESPACE}"

echo
echo "Pods:"
kubectl get pods -n "${NAMESPACE}" -o wide

echo
echo "Services:"
kubectl get svc -n "${NAMESPACE}"

echo
echo "PVC:"
kubectl get pvc -n "${NAMESPACE}"

echo
echo "Ingress:"
kubectl get ingress -n "${NAMESPACE}"

echo
success "HireFlow deployment completed successfully."
echo