#!/usr/bin/env bash
#
# aks-bootstrap.sh — install the in-cluster platform on the cluster aks-deploy.sh created.
#
# The whole platform is GitOps: this script only
#   1. installs Argo CD with Helm (the one thing Argo can't install itself), then
#   2. applies the root Application (k8s/argocd/root-application.yaml), which syncs every other
#      Application from k8s/argocd/apps/ - Argo CD itself, External Secrets, Kyverno, the
#      policies, Headlamp, Polaris and Trivy, in sync-wave order - and
#   3. waits for all of it to be Synced + Healthy.
# No secret passes through this script.
#
# Runs only as the expected Azure user (default miquidev), like aks-deploy.sh.
#
# Usage:
#   ./aks-bootstrap.sh [--user <upn>]
#
# Prerequisites: aks-deploy.sh has run; this repo is pushed to GITHUB_REPO's main branch and is
# public (Argo CD reads it anonymously).
set -euo pipefail
trap 'echo "ERROR: failed at line $LINENO (exit $?)" >&2' ERR
cd "$(dirname "$0")"

AZ_USER="${AZ_USER:-miquidev@mmaqhotmail.onmicrosoft.com}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) AZ_USER="${2:?--user needs a value}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-aks-lab}"
CLUSTER="${CLUSTER:-dev-cluster}"
GITHUB_REPO="${GITHUB_REPO:-miqui/aks-operator-lab}"
# Must match k8s/argocd/apps/argocd.yaml, which takes over this release after bootstrap.
ARGOCD_CHART_VERSION="10.9.2"
SYNC_TIMEOUT_MIN="${SYNC_TIMEOUT_MIN:-40}"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

for tool in az kubectl helm git; do
  command -v "$tool" >/dev/null 2>&1 || { echo "$tool not found" >&2; exit 1; }
done

# ---- 0. Preflight -----------------------------------------------------------
log "Preflight"
CURRENT_USER=$(az account show --query user.name -o tsv 2>/dev/null || true)
if [[ "$(tr '[:upper:]' '[:lower:]' <<<"${CURRENT_USER:-none}")" != "$(tr '[:upper:]' '[:lower:]' <<<"$AZ_USER")" ]]; then
  echo "ERROR: signed in as '${CURRENT_USER:-none}', but this script only runs as '$AZ_USER'." >&2; exit 1
fi
echo "    user: $CURRENT_USER"

EXPECTED_CONTEXT="$CLUSTER"
CURRENT_CONTEXT=$(kubectl config current-context 2>/dev/null || true)
if [[ "$CURRENT_CONTEXT" != "$EXPECTED_CONTEXT" ]]; then
  echo "    kubectl context is '${CURRENT_CONTEXT:-none}', switching to $EXPECTED_CONTEXT"
  az aks get-credentials -g "$RESOURCE_GROUP" -n "$CLUSTER" --overwrite-existing
fi
kubectl get --raw /readyz >/dev/null || {
  echo "ERROR: cluster API unreachable - has your public IP changed? (see aks-deploy.sh summary)" >&2; exit 1;
}
echo "    cluster: $EXPECTED_CONTEXT"

git ls-remote --exit-code "https://github.com/${GITHUB_REPO}.git" main >/dev/null 2>&1 || {
  echo "ERROR: https://github.com/${GITHUB_REPO}.git (main) is not publicly readable - Argo CD" >&2
  echo "       syncs from it anonymously. Make the repo public and push first." >&2
  exit 1
}
echo "    git: github.com/${GITHUB_REPO} main is readable"
LOCAL_UNPUSHED=$(git log --oneline origin/main..HEAD 2>/dev/null | wc -l | tr -d ' ' || echo 0)
[[ "${LOCAL_UNPUSHED:-0}" == "0" ]] || \
  echo "    WARNING: $LOCAL_UNPUSHED local commit(s) not on origin/main - Argo CD won't see them"

# ---- 1. Argo CD -----------------------------------------------------------------
log "Installing Argo CD (chart argo/argo-cd $ARGOCD_CHART_VERSION)"
if ! helm repo list 2>/dev/null | grep -q '^argo[[:space:]]'; then
  helm repo add argo https://argoproj.github.io/argo-helm
fi
helm repo update argo >/dev/null
helm upgrade --install argocd argo/argo-cd \
  --version "$ARGOCD_CHART_VERSION" \
  --namespace argocd --create-namespace \
  -f k8s/argocd/argocd-values.yaml \
  --wait --timeout 10m

# ---- 2. Root Application ------------------------------------------------------------
log "Applying root Application (app of apps: k8s/argocd/apps/)"
kubectl apply -f k8s/argocd/root-application.yaml

# ---- 3. Wait for everything -----------------------------------------------------------
log "Waiting for all Applications to be Synced + Healthy (timeout ${SYNC_TIMEOUT_MIN}m)"
deadline=$(( $(date +%s) + SYNC_TIMEOUT_MIN * 60 ))
while :; do
  status=$(kubectl get applications -n argocd \
    -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' \
    --no-headers 2>/dev/null || true)
  total=$(grep -c . <<<"$status" || true)
  done_count=$(grep -cE '\sSynced\s+Healthy$' <<<"$status" || true)
  # root + one per file in k8s/argocd/apps/
  app_files=(k8s/argocd/apps/*.yaml)
  expected=$(( ${#app_files[@]} + 1 ))
  printf '    %s  %s/%s Synced+Healthy\n' "$(date +%H:%M:%S)" "$done_count" "$expected"
  if [[ "$total" -ge "$expected" && "$done_count" -eq "$total" ]]; then
    break
  fi
  if [[ $(date +%s) -ge $deadline ]]; then
    echo "ERROR: timed out. Current state:" >&2
    echo "$status" >&2
    echo "Inspect: kubectl get applications -n argocd" >&2
    exit 1
  fi
  sleep 30
done
echo "$status" | sed 's/^/    /'

cat <<EOF

$(printf '\033[1;32mDone.\033[0m') Platform is synced from github.com/${GITHUB_REPO} (main).

  Tools (port-forward only):  ./aks-port-forward.sh
    Argo CD admin password:
      kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
    Headlamp (read-only) token:
      kubectl create token headlamp -n headlamp --duration=1h
EOF
