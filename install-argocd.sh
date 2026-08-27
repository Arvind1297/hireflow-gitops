#!/bin/bash

set -e

NAMESPACE="argocd"

echo "=========================================="
echo "Creating Argo CD namespace"
echo "=========================================="

kubectl create namespace $NAMESPACE

echo ""
echo "=========================================="
echo "Installing Argo CD"
echo "=========================================="

kubectl apply \
  -n $NAMESPACE \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo ""
echo "=========================================="
echo "Waiting for Argo CD components"
echo "=========================================="

kubectl wait \
  --for=condition=Ready pods \
  --all \
  -n $NAMESPACE \
  --timeout=300s

echo ""
echo "=========================================="
echo "Argo CD Pods"
echo "=========================================="

kubectl get pods -n $NAMESPACE

echo ""
echo "=========================================="
echo "Argo CD installation completed"
echo "=========================================="
echo ""
echo "Run this in another terminal:"
echo ""
echo "kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo ""
echo "Then open:"
echo "https://localhost:8080"
echo ""
echo "Get password:"
echo "kubectl -n argocd get secret argocd-initial-admin-secret \\"
echo "-o jsonpath=\"{.data.password}\" | base64 -d"
echo ""
