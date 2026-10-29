#!/usr/bin/env bash
# Usage: ./scripts/02-install-argocd.sh <github-user> <repo-name>
set -euo pipefail
GH_USER="${1:?github user}"; REPO="${2:?repo name}"

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd --server-side -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s

# Point the Application at your repo and apply it
sed -e "s#YOUR_GH_USER/YOUR_REPO#${GH_USER}/${REPO}#" argocd/application.yaml | kubectl apply -f -

echo "ArgoCD admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
echo "UI: kubectl -n argocd port-forward svc/argocd-server 8443:443  ->  https://localhost:8443 (user: admin)"
