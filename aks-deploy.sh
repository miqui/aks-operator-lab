#!/usr/bin/env bash
#
# aks-deploy.sh — create the dev AKS cluster.
#
# Zonal, 2 vCPU / 8 GB nodes, 30 GB OS disk, autoscaling, NetworkPolicy enforcement (Cilium
# dataplane), Workload Identity, API server locked to the operator's IP, nodes without public IPs.
#
# Safety: this script changes Azure ONLY when the signed-in CLI user is the expected user
# (default miquidev). Anyone else, including the admin account, is refused.
#
# Usage:
#   az login                                  # as miquidev; see AZURE.md for a separate profile
#   SUBSCRIPTION_ID=<id> ./aks-deploy.sh [--user <upn>] [--dry-run]
#
# Overridable env vars: AZ_USER, SUBSCRIPTION_ID, RESOURCE_GROUP, LOCATION, CLUSTER, VM_SIZE,
#                       MIN_NODES, MAX_NODES, NODE_DISK_SIZE_GB, ZONE
set -euo pipefail
trap 'echo "ERROR: failed at line $LINENO (exit $?)" >&2' ERR
cd "$(dirname "$0")"

AZ_USER="${AZ_USER:-miquidev@mmaqhotmail.onmicrosoft.com}"
DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)    AZ_USER="${2:?--user needs a value}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

SUBSCRIPTION_ID="${SUBSCRIPTION_ID:?SUBSCRIPTION_ID is required}"
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-aks-lab}"
LOCATION="${LOCATION:-eastus}"
CLUSTER="${CLUSTER:-dev-cluster}"
VM_SIZE="${VM_SIZE:-Standard_D2s_v6}"   # 2 vCPU / 8 GB
MIN_NODES="${MIN_NODES:-3}"
# The default regional quota is 10 vCPUs: 4 nodes x 2 vCPU + 1 upgrade surge node = 10.
MAX_NODES="${MAX_NODES:-4}"
NODE_DISK_SIZE_GB="${NODE_DISK_SIZE_GB:-30}"
ZONE="${ZONE:-1}"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

for tool in az kubectl curl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "$tool not found" >&2; exit 1; }
done

# ---- 0. Preflight -----------------------------------------------------------
log "Preflight"
CURRENT_USER=$(az account show --query user.name -o tsv 2>/dev/null || true)
if [[ -z "$CURRENT_USER" ]]; then
  echo "ERROR: not logged in. Run: az login (as $AZ_USER)" >&2; exit 1
fi
if [[ "$(tr '[:upper:]' '[:lower:]' <<<"$CURRENT_USER")" != "$(tr '[:upper:]' '[:lower:]' <<<"$AZ_USER")" ]]; then
  echo "ERROR: signed in as '$CURRENT_USER', but this script only runs as '$AZ_USER'." >&2
  echo "       Log in as the expected user (az login), or pass --user." >&2
  exit 1
fi
echo "    user: $CURRENT_USER"
az account set --subscription "$SUBSCRIPTION_ID"

az group show -n "$RESOURCE_GROUP" --query name -o tsv >/dev/null || {
  echo "ERROR: resource group $RESOURCE_GROUP not found or not visible to $CURRENT_USER" >&2; exit 1;
}

log "Detecting operator public IP for API server authorized ranges"
MY_IP=$(curl -4 -s --max-time 10 ifconfig.me || true)
[[ "$MY_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "ERROR: could not detect public IP (got: '${MY_IP:-empty}')" >&2; exit 1;
}
echo "    operator IP: $MY_IP"

CMD=(az aks create
  --resource-group "$RESOURCE_GROUP" --name "$CLUSTER" --location "$LOCATION"
  --tier free
  --zones "$ZONE"
  --node-vm-size "$VM_SIZE"
  --node-osdisk-type Managed --node-osdisk-size "$NODE_DISK_SIZE_GB"
  --node-count "$MIN_NODES"
  --enable-cluster-autoscaler --min-count "$MIN_NODES" --max-count "$MAX_NODES"
  --network-plugin azure --network-plugin-mode overlay
  --network-dataplane cilium --network-policy cilium
  --enable-oidc-issuer --enable-workload-identity
  --enable-managed-identity
  --api-server-authorized-ip-ranges "$MY_IP/32"
  --auto-upgrade-channel stable
  --no-ssh-key)

if [[ "$DRY_RUN" == 1 ]]; then
  log "Dry run: would execute"
  printf '    %q' "${CMD[@]}"; echo
  exit 0
fi

# ---- 1. Cluster -----------------------------------------------------------------
log "Creating cluster: $CLUSTER (zone $ZONE, $VM_SIZE, ${NODE_DISK_SIZE_GB}GB, autoscaling $MIN_NODES..$MAX_NODES)"
if az aks show -g "$RESOURCE_GROUP" -n "$CLUSTER" &>/dev/null; then
  echo "    exists, skipping (cluster-level settings are creation-time; recreate to change them)"
else
  "${CMD[@]}"
fi

# ---- 2. Credentials ---------------------------------------------------------
az aks get-credentials -g "$RESOURCE_GROUP" -n "$CLUSTER" --overwrite-existing
kubectl get nodes -o wide

cat <<EOF

Done. Cluster $CLUSTER is up in $RESOURCE_GROUP ($LOCATION).
  If your public IP changes:
    az aks update -g $RESOURCE_GROUP -n $CLUSTER --api-server-authorized-ip-ranges <new-ip>/32
  Cost: nodes bill while running. Stop or delete when idle: ./aks-teardown.sh
EOF
