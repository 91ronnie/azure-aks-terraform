#!/usr/bin/env bash
# Install or upgrade Argo CD, then hand everything else to GitOps.
#
# Prerequisites:
#   - kubectl context points at the AKS cluster (terraform output get_credentials_command)
#   - You hold "Azure Kubernetes Service RBAC Cluster Admin" (granted by Terraform)
#   - The Argo CD repository credential secret exists (see repository.example.yaml)
#   - REPLACE_ME placeholders in gitops/ have been replaced (repo URL, ACME email)
#
# Usage: ./gitops/argocd/install-argocd.sh            (from the repo root)
#        ARGOCD_WI_CLIENT_ID=<id> ./gitops/argocd/install-argocd.sh   (workload identity)
set -euo pipefail

CHART_VERSION="10.11.6"   # Argo CD v3.5.6 - bump deliberately, see docs/argocd-gitops.md#upgrades
NAMESPACE="argocd"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GITOPS_DIR="$(dirname "$HERE")"

PLACEHOLDER_GREP=(grep -rIn "REPLACE_ME" "$GITOPS_DIR" --include='*.yaml'
  --exclude=repository.example.yaml)
if "${PLACEHOLDER_GREP[@]}" >/dev/null 2>&1; then
  echo "ERROR: replace the REPLACE_ME placeholders (repo URL, ACME email) first:" >&2
  "${PLACEHOLDER_GREP[@]}" >&2
  exit 1
fi

echo "Current context: $(kubectl config current-context)"
kubectl get nodes -o wide

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace "$NAMESPACE" pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/warn=restricted --overwrite

EXTRA_ARGS=()
if [[ -n "${ARGOCD_WI_CLIENT_ID:-}" ]]; then
  echo "Enabling Azure workload identity for Argo CD (client id ${ARGOCD_WI_CLIENT_ID})"
  for c in controller repoServer server; do
    EXTRA_ARGS+=(--set "${c}.serviceAccount.annotations.azure\.workload\.identity/client-id=${ARGOCD_WI_CLIENT_ID}")
    EXTRA_ARGS+=(--set-string "${c}.podLabels.azure\.workload\.identity/use=true")
  done
fi

helm upgrade --install argocd argo-cd \
  --repo https://argoproj.github.io/argo-helm \
  --version "$CHART_VERSION" \
  --namespace "$NAMESPACE" \
  --values "$HERE/values.yaml" \
  "${EXTRA_ARGS[@]}" \
  --wait --timeout 10m

kubectl apply -n "$NAMESPACE" -f "$HERE/projects.yaml"
kubectl apply -n "$NAMESPACE" -f "$HERE/root-app.yaml"

cat <<'EOF'

Argo CD is installed and the root application is registered.

  kubectl -n argocd get applications
  kubectl -n argocd port-forward svc/argocd-server 8080:443
  # https://localhost:8080  user: admin
  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
  # Change the password, then: kubectl -n argocd delete secret argocd-initial-admin-secret
EOF
