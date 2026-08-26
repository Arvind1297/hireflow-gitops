#!/usr/bin/env bash

set -Eeuo pipefail

# =========================================================
# HireFlow Kubernetes Deployment
# =========================================================

NAMESPACE="hireflow"

LOCAL_PATH_MANIFEST="https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml"
STORAGE_CLASS="local-path"

FILES=(
    "namespace.yaml"
    "database-pvc.yaml"
    "database-deployment.yaml"
    "database-service.yaml"
    "backend-deployment.yaml"
    "backend-service.yaml"
    "frontend-deployment.yaml"
    "frontend-service.yaml"
    "ingress.yaml"
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

    echo "========================================================="
    echo "Kubernetes Diagnostics"
    echo "========================================================="

    echo
    echo "Nodes:"
    kubectl get nodes -o wide 2>/dev/null || true

    echo
    echo "StorageClasses:"
    kubectl get storageclass 2>/dev/null || true

    echo
    echo "Pods:"
    kubectl get pods \
        -n "${NAMESPACE}" \
        -o wide 2>/dev/null || true

    echo
    echo "Services:"
    kubectl get svc \
        -n "${NAMESPACE}" 2>/dev/null || true

    echo
    echo "PVC:"
    kubectl get pvc \
        -n "${NAMESPACE}" 2>/dev/null || true

    echo
    echo "Ingress:"
    kubectl get ingress \
        -n "${NAMESPACE}" 2>/dev/null || true

    echo
    fail "Fix the problem and run the script again."

    exit "${exit_code}"
}

trap on_error ERR

# =========================================================
# Header
# =========================================================

echo
echo "========================================================="
echo "        HireFlow Kubernetes Deployment"
echo "========================================================="
echo

# =========================================================
# 1. Check kubectl
# =========================================================

CURRENT_STEP="checking kubectl"

if ! command -v kubectl >/dev/null 2>&1; then
    fail "kubectl is not installed."
    exit 1
fi

success "kubectl found."

# =========================================================
# 2. Kubernetes Connectivity
# =========================================================

CURRENT_STEP="checking Kubernetes connection"

log "Checking Kubernetes cluster..."

if ! kubectl cluster-info >/dev/null 2>&1; then
    fail "Cannot connect to Kubernetes cluster."

    echo
    echo "Run:"
    echo "  kubectl get nodes"

    exit 1
fi

success "Kubernetes cluster is reachable."

# =========================================================
# 3. Check Nodes
# =========================================================

CURRENT_STEP="checking Kubernetes nodes"

log "Checking Kubernetes nodes..."

if ! kubectl get nodes >/dev/null 2>&1; then
    fail "Unable to read Kubernetes nodes."
    exit 1
fi

kubectl get nodes -o wide

# =========================================================
# 4. Check Manifest Files
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
# 5. Create Namespace
# =========================================================

CURRENT_STEP="creating namespace"

log "Creating namespace..."

kubectl apply -f namespace.yaml

if kubectl wait \
    --for=jsonpath='{.status.phase}'=Active \
    "namespace/${NAMESPACE}" \
    --timeout=60s >/dev/null 2>&1
then
    success "Namespace ${NAMESPACE} is ready."
else
    fail "Namespace ${NAMESPACE} did not become ready."
    exit 1
fi

# =========================================================
# 6. Install / Verify Local Path Provisioner
# =========================================================

CURRENT_STEP="checking local-path storage provisioner"

log "Checking StorageClass ${STORAGE_CLASS}..."

if kubectl get storageclass "${STORAGE_CLASS}" >/dev/null 2>&1; then

    success "StorageClass ${STORAGE_CLASS} already exists."

else

    warn "StorageClass ${STORAGE_CLASS} not found."
    log "Installing Rancher Local Path Provisioner..."

    kubectl apply -f "${LOCAL_PATH_MANIFEST}"

    success "Local Path Provisioner manifest applied."

fi

# =========================================================
# 7. Wait for Local Path Provisioner
# =========================================================

CURRENT_STEP="waiting for local-path provisioner"

log "Waiting for Local Path Provisioner..."

if kubectl wait \
    --for=condition=available \
    deployment/local-path-provisioner \
    -n local-path-storage \
    --timeout=180s >/dev/null 2>&1
then

    success "Local Path Provisioner is ready."

else

    fail "Local Path Provisioner did not become ready."

    kubectl get pods \
        -n local-path-storage \
        -o wide || true

    exit 1

fi

# =========================================================
# 8. Verify StorageClass
# =========================================================

CURRENT_STEP="verifying storage class"

log "Verifying StorageClass ${STORAGE_CLASS}..."

if ! kubectl get storageclass "${STORAGE_CLASS}" >/dev/null 2>&1; then

    fail "StorageClass ${STORAGE_CLASS} is still unavailable."
    exit 1

fi

success "StorageClass ${STORAGE_CLASS} is available."

# =========================================================
# 9. Validate Kubernetes Manifests
# =========================================================

CURRENT_STEP="validating Kubernetes manifests"

log "Validating manifests..."

VALIDATION_FILES=(
    "database-pvc.yaml"
    "database-deployment.yaml"
    "database-service.yaml"
    "backend-deployment.yaml"
    "backend-service.yaml"
    "frontend-deployment.yaml"
    "frontend-service.yaml"
    "ingress.yaml"
)

for file in "${VALIDATION_FILES[@]}"; do

    if ! kubectl apply \
        --dry-run=server \
        -f "${file}" >/dev/null
    then

        fail "Invalid Kubernetes manifest: ${file}"
        exit 1

    fi

    success "Validated ${file}"

done

# =========================================================
# 10. Database PVC
# =========================================================

CURRENT_STEP="creating database PVC"

log "Creating database PVC..."

kubectl apply -f database-pvc.yaml

success "Database PVC created/updated."

# =========================================================
# 11. Database Deployment
# =========================================================

CURRENT_STEP="deploying database"

log "Deploying database..."

kubectl apply -f database-deployment.yaml

success "Database Deployment created/updated."

# =========================================================
# 12. Wait for Database PVC
# =========================================================
#
# IMPORTANT:
#
# local-path normally uses WaitForFirstConsumer.
# Therefore PVC may stay Pending until the database
# Pod is scheduled.
#
# We deploy the database BEFORE waiting for Bound.
#
# =========================================================

CURRENT_STEP="waiting for database PVC"

log "Waiting for database PVC to become Bound..."

PVC_READY=false

for i in {1..90}; do

    PVC_STATUS=$(
        kubectl get pvc database-pvc \
            -n "${NAMESPACE}" \
            -o jsonpath='{.status.phase}' \
            2>/dev/null || true
    )

    if [[ "${PVC_STATUS}" == "Bound" ]]; then

        success "Database PVC is Bound."
        PVC_READY=true
        break

    fi

    if [[ "${PVC_STATUS}" == "Lost" ]]; then

        fail "Database PVC entered Lost state."

        kubectl describe pvc \
            database-pvc \
            -n "${NAMESPACE}" || true

        exit 1

    fi

    echo "  PVC status: ${PVC_STATUS:-Pending}"

    sleep 2

done

if [[ "${PVC_READY}" != true ]]; then

    fail "Database PVC did not become Bound within 180 seconds."

    echo
    echo "PVC details:"
    kubectl describe pvc \
        database-pvc \
        -n "${NAMESPACE}" || true

    echo
    echo "Database pods:"
    kubectl get pods \
        -n "${NAMESPACE}" \
        -l app=database \
        -o wide || true

    exit 1

fi

# =========================================================
# 13. Wait for Database
# =========================================================

CURRENT_STEP="waiting for database rollout"

log "Waiting for database rollout..."

if kubectl rollout status \
    deployment/database \
    -n "${NAMESPACE}" \
    --timeout=180s
then

    success "Database is ready."

else

    fail "Database rollout failed."

    kubectl get pods \
        -n "${NAMESPACE}" \
        -o wide || true

    exit 1

fi

# =========================================================
# 14. Database Service
# =========================================================

CURRENT_STEP="creating database service"

log "Creating database service..."

kubectl apply -f database-service.yaml

success "Database service is ready."

# =========================================================
# 15. Backend Deployment
# =========================================================

CURRENT_STEP="deploying backend"

log "Deploying backend..."

kubectl apply -f backend-deployment.yaml

success "Backend Deployment created/updated."

# =========================================================
# 16. Backend Rollout
# =========================================================

CURRENT_STEP="waiting for backend rollout"

log "Waiting for backend rollout..."

if kubectl rollout status \
    deployment/backend \
    -n "${NAMESPACE}" \
    --timeout=180s
then

    success "Backend is ready."

else

    fail "Backend rollout failed."

    kubectl get pods \
        -n "${NAMESPACE}" \
        -o wide || true

    exit 1

fi

# =========================================================
# 17. Backend Service
# =========================================================

CURRENT_STEP="creating backend service"

log "Creating backend service..."

kubectl apply -f backend-service.yaml

success "Backend service is ready."

# =========================================================
# 18. Frontend Deployment
# =========================================================

CURRENT_STEP="deploying frontend"

log "Deploying frontend..."

kubectl apply -f frontend-deployment.yaml

success "Frontend Deployment created/updated."

# =========================================================
# 19. Frontend Rollout
# =========================================================

CURRENT_STEP="waiting for frontend rollout"

log "Waiting for frontend rollout..."

if kubectl rollout status \
    deployment/frontend \
    -n "${NAMESPACE}" \
    --timeout=180s
then

    success "Frontend is ready."

else

    fail "Frontend rollout failed."

    kubectl get pods \
        -n "${NAMESPACE}" \
        -o wide || true

    exit 1

fi

# =========================================================
# 20. Frontend Service
# =========================================================

CURRENT_STEP="creating frontend service"

log "Creating frontend service..."

kubectl apply -f frontend-service.yaml

success "Frontend service is ready."

# =========================================================
# 21. Ingress
# =========================================================

CURRENT_STEP="creating ingress"

log "Creating ingress..."

kubectl apply -f ingress.yaml

success "Ingress is created."

# =========================================================
# 22. Final Pod Health Check
# =========================================================

CURRENT_STEP="checking final application health"

log "Checking application pods..."

if kubectl wait \
    --for=condition=Ready \
    pods \
    -n "${NAMESPACE}" \
    --all \
    --timeout=180s
then

    success "All application pods are Ready."

else

    warn "Not all application pods became Ready."

    kubectl get pods \
        -n "${NAMESPACE}" \
        -o wide

    fail "Application health check failed."
    exit 1

fi

# =========================================================
# 23. Final Status
# =========================================================

echo
echo "========================================================="
echo "             DEPLOYMENT COMPLETE"
echo "========================================================="
echo

echo "Namespace:"
kubectl get namespace "${NAMESPACE}"

echo
echo "StorageClass:"
kubectl get storageclass "${STORAGE_CLASS}"

echo
echo "Pods:"
kubectl get pods \
    -n "${NAMESPACE}" \
    -o wide

echo
echo "Services:"
kubectl get svc \
    -n "${NAMESPACE}"

echo
echo "PVC:"
kubectl get pvc \
    -n "${NAMESPACE}"

echo
echo "Ingress:"
kubectl get ingress \
    -n "${NAMESPACE}"

echo
echo "========================================================="
success "HireFlow deployment completed successfully."
echo "========================================================="
echo