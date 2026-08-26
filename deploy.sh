#!/usr/bin/env bash

set -Eeuo pipefail

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

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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

show_diagnostics() {
    echo
    echo "========================================================="
    echo "                 KUBERNETES DIAGNOSTICS"
    echo "========================================================="

    echo
    echo ">>> Nodes"
    kubectl get nodes -o wide 2>/dev/null || true

    echo
    echo ">>> StorageClasses"
    kubectl get storageclass 2>/dev/null || true

    echo
    echo ">>> Local Path Provisioner"
    kubectl get pods \
        -n local-path-storage \
        -o wide 2>/dev/null || true

    echo
    echo ">>> Application Pods"
    kubectl get pods \
        -n "${NAMESPACE}" \
        -o wide 2>/dev/null || true

    echo
    echo ">>> Deployments"
    kubectl get deployments \
        -n "${NAMESPACE}" 2>/dev/null || true

    echo
    echo ">>> ReplicaSets"
    kubectl get rs \
        -n "${NAMESPACE}" 2>/dev/null || true

    echo
    echo ">>> Services"
    kubectl get svc \
        -n "${NAMESPACE}" 2>/dev/null || true

    echo
    echo ">>> PVC"
    kubectl get pvc \
        -n "${NAMESPACE}" 2>/dev/null || true

    echo
    echo ">>> Ingress"
    kubectl get ingress \
        -n "${NAMESPACE}" 2>/dev/null || true

    echo
    echo ">>> Recent Events"
    kubectl get events \
        -n "${NAMESPACE}" \
        --sort-by='.lastTimestamp' 2>/dev/null \
        | tail -40 || true

    echo
}

on_error() {
    local exit_code=$?

    echo
    fail "Deployment failed."
    echo
    echo "Failed step : ${CURRENT_STEP}"
    echo "Exit code   : ${exit_code}"

    show_diagnostics

    fail "Fix the problem and run the script again."

    exit "${exit_code}"
}

trap on_error ERR

echo
echo "========================================================="
echo "              HireFlow Kubernetes Deployment"
echo "========================================================="
echo

CURRENT_STEP="checking kubectl"

if ! command -v kubectl >/dev/null 2>&1; then
    fail "kubectl is not installed."
    exit 1
fi

success "kubectl found."

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

CURRENT_STEP="checking Kubernetes nodes"

log "Checking Kubernetes nodes..."

NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)

if [[ "${NODE_COUNT}" -eq 0 ]]; then
    fail "No Kubernetes nodes found."
    exit 1
fi

NOT_READY_NODES=$(
    kubectl get nodes \
        --no-headers 2>/dev/null \
        | awk '$2 != "Ready" {print $1}'
)

if [[ -n "${NOT_READY_NODES}" ]]; then
    fail "Some Kubernetes nodes are not Ready:"
    echo "${NOT_READY_NODES}"
    exit 1
fi

success "All Kubernetes nodes are Ready."

kubectl get nodes -o wide

CURRENT_STEP="checking manifest files"

log "Checking manifest files..."

for file in "${FILES[@]}"; do
    if [[ ! -f "${file}" ]]; then
        fail "Missing file: ${file}"
        exit 1
    fi

    success "Found ${file}"
done

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

CURRENT_STEP="verifying storage class"

log "Verifying StorageClass ${STORAGE_CLASS}..."

if ! kubectl get storageclass "${STORAGE_CLASS}" >/dev/null 2>&1; then
    fail "StorageClass ${STORAGE_CLASS} is unavailable."
    exit 1
fi

success "StorageClass ${STORAGE_CLASS} is available."

kubectl get storageclass "${STORAGE_CLASS}"

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

CURRENT_STEP="creating database PVC"

log "Creating database PVC..."

kubectl apply -f database-pvc.yaml

success "Database PVC created/updated."

CURRENT_STEP="deploying database"

log "Deploying database..."

kubectl apply -f database-deployment.yaml

success "Database Deployment created/updated."

CURRENT_STEP="checking database ReplicaSet"

log "Checking database ReplicaSet..."

DB_RS_READY=false

for i in {1..30}; do
    DB_RS_COUNT=$(
        kubectl get rs \
            -n "${NAMESPACE}" \
            -l app=database \
            --no-headers 2>/dev/null \
            | wc -l
    )

    if [[ "${DB_RS_COUNT}" -gt 0 ]]; then
        DB_RS_READY=true
        break
    fi

    sleep 2
done

if [[ "${DB_RS_READY}" != true ]]; then
    fail "Database ReplicaSet was not created."

    echo
    echo "Database Deployment:"
    kubectl describe deployment database \
        -n "${NAMESPACE}" || true

    echo
    echo "Recent events:"
    kubectl get events \
        -n "${NAMESPACE}" \
        --sort-by='.lastTimestamp' \
        | tail -30 || true

    exit 1
fi

success "Database ReplicaSet exists."

CURRENT_STEP="waiting for database pod"

log "Waiting for database Pod to be created..."

DB_POD_FOUND=false

for i in {1..30}; do
    DB_POD_COUNT=$(
        kubectl get pods \
            -n "${NAMESPACE}" \
            -l app=database \
            --no-headers 2>/dev/null \
            | wc -l
    )

    if [[ "${DB_POD_COUNT}" -gt 0 ]]; then
        DB_POD_FOUND=true
        break
    fi

    sleep 2
done

if [[ "${DB_POD_FOUND}" != true ]]; then
    fail "Database Pod was not created."

    echo
    echo "Database Deployment:"
    kubectl describe deployment database \
        -n "${NAMESPACE}" || true

    echo
    echo "ReplicaSets:"
    kubectl get rs \
        -n "${NAMESPACE}" || true

    echo
    echo "Recent events:"
    kubectl get events \
        -n "${NAMESPACE}" \
        --sort-by='.lastTimestamp' \
        | tail -40 || true

    exit 1
fi

success "Database Pod was created."

kubectl get pods \
    -n "${NAMESPACE}" \
    -l app=database \
    -o wide

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

    DB_POD_NAME=$(
        kubectl get pods \
            -n "${NAMESPACE}" \
            -l app=database \
            -o jsonpath='{.items[0].metadata.name}' \
            2>/dev/null || true
    )

    if [[ -n "${DB_POD_NAME}" ]]; then
        POD_PHASE=$(
            kubectl get pod "${DB_POD_NAME}" \
                -n "${NAMESPACE}" \
                -o jsonpath='{.status.phase}' \
                2>/dev/null || true
        )

        if [[ "${POD_PHASE}" == "Failed" ]]; then
            fail "Database Pod entered Failed state."

            kubectl describe pod \
                "${DB_POD_NAME}" \
                -n "${NAMESPACE}" || true

            exit 1
        fi
    fi

    echo "  PVC status: ${PVC_STATUS:-Pending}"

    sleep 2
done

if [[ "${PVC_READY}" != true ]]; then
    fail "Database PVC did not become Bound within 180 seconds."

    echo
    echo "PVC:"
    kubectl describe pvc \
        database-pvc \
        -n "${NAMESPACE}" || true

    echo
    echo "Database Pod:"
    kubectl get pods \
        -n "${NAMESPACE}" \
        -l app=database \
        -o wide || true

    echo
    echo "Database Pod details:"

    DB_POD_NAME=$(
        kubectl get pods \
            -n "${NAMESPACE}" \
            -l app=database \
            -o jsonpath='{.items[0].metadata.name}' \
            2>/dev/null || true
    )

    if [[ -n "${DB_POD_NAME}" ]]; then
        kubectl describe pod \
            "${DB_POD_NAME}" \
            -n "${NAMESPACE}" || true
    fi

    echo
    echo "Recent events:"
    kubectl get events \
        -n "${NAMESPACE}" \
        --sort-by='.lastTimestamp' \
        | tail -40 || true

    exit 1
fi

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

    DB_POD_NAME=$(
        kubectl get pods \
            -n "${NAMESPACE}" \
            -l app=database \
            -o jsonpath='{.items[0].metadata.name}' \
            2>/dev/null || true
    )

    if [[ -n "${DB_POD_NAME}" ]]; then
        kubectl describe pod \
            "${DB_POD_NAME}" \
            -n "${NAMESPACE}" || true

        echo
        echo "Database logs:"
        kubectl logs \
            "${DB_POD_NAME}" \
            -n "${NAMESPACE}" \
            --all-containers=true \
            --tail=100 || true
    fi

    exit 1
fi

CURRENT_STEP="creating database service"

log "Creating database service..."

kubectl apply -f database-service.yaml

success "Database service is ready."

CURRENT_STEP="deploying backend"

log "Deploying backend..."

kubectl apply -f backend-deployment.yaml

success "Backend Deployment created/updated."

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
        -l app=backend \
        -o wide || true

    BACKEND_POD=$(
        kubectl get pods \
            -n "${NAMESPACE}" \
            -l app=backend \
            -o jsonpath='{.items[0].metadata.name}' \
            2>/dev/null || true
    )

    if [[ -n "${BACKEND_POD}" ]]; then
        kubectl describe pod \
            "${BACKEND_POD}" \
            -n "${NAMESPACE}" || true

        echo
        echo "Backend logs:"
        kubectl logs \
            "${BACKEND_POD}" \
            -n "${NAMESPACE}" \
            --all-containers=true \
            --tail=100 || true
    fi

    exit 1
fi

CURRENT_STEP="creating backend service"

log "Creating backend service..."

kubectl apply -f backend-service.yaml

success "Backend service is ready."

CURRENT_STEP="deploying frontend"

log "Deploying frontend..."

kubectl apply -f frontend-deployment.yaml

success "Frontend Deployment created/updated."

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
        -l app=frontend \
        -o wide || true

    FRONTEND_POD=$(
        kubectl get pods \
            -n "${NAMESPACE}" \
            -l app=frontend \
            -o jsonpath='{.items[0].metadata.name}' \
            2>/dev/null || true
    )

    if [[ -n "${FRONTEND_POD}" ]]; then
        kubectl describe pod \
            "${FRONTEND_POD}" \
            -n "${NAMESPACE}" || true

        echo
        echo "Frontend logs:"
        kubectl logs \
            "${FRONTEND_POD}" \
            -n "${NAMESPACE}" \
            --all-containers=true \
            --tail=100 || true
    fi

    exit 1
fi

CURRENT_STEP="creating frontend service"

log "Creating frontend service..."

kubectl apply -f frontend-service.yaml

success "Frontend service is ready."

CURRENT_STEP="checking ingress controller"

log "Checking Kubernetes Ingress controller..."

INGRESS_CLASS=$(
    kubectl get ingressclass \
        --no-headers 2>/dev/null \
        | awk '{print $1}' \
        | head -1
)

if [[ -z "${INGRESS_CLASS}" ]]; then
    warn "No IngressClass found."
    warn "Ingress resource will still be created, but traffic will not work until an Ingress controller is installed."
else
    success "IngressClass detected: ${INGRESS_CLASS}"
fi

CURRENT_STEP="creating ingress"

log "Creating ingress..."

kubectl apply -f ingress.yaml

success "Ingress is created."

CURRENT_STEP="checking final application health"

log "Checking final application health..."

if kubectl wait \
    --for=condition=Ready \
    pods \
    -n "${NAMESPACE}" \
    --all \
    --timeout=180s
then
    success "All application pods are Ready."
else
    fail "Not all application pods became Ready."

    kubectl get pods \
        -n "${NAMESPACE}" \
        -o wide

    echo
    echo "Recent events:"
    kubectl get events \
        -n "${NAMESPACE}" \
        --sort-by='.lastTimestamp' \
        | tail -40 || true

    exit 1
fi

echo
echo "========================================================="
echo "                 DEPLOYMENT COMPLETE"
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
echo "Deployments:"
kubectl get deployments \
    -n "${NAMESPACE}"

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