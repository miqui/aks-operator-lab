#!/usr/bin/env bash
#
# aks-teardown.sh — delete the dev AKS cluster.
# Keeps the resource group, role assignment and budget. Runs only as the expected user.
#
# Usage: SUBSCRIPTION_ID=<id> ./aks-teardown.sh [--user <upn>] [--yes]
set -euo pipefail
trap 'echo "ERROR: failed at line $LINENO (exit $?)" >&2' ERR

AZ_USER="${AZ_USER:-miquidev@mmaqhotmail.onmicrosoft.com}"
ASSUME_YES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) AZ_USER="${2:?--user needs a value}"; shift 2 ;;
    --yes)  ASSUME_YES=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

SUBSCRIPTION_ID="${SUBSCRIPTION_ID:?SUBSCRIPTION_ID is required}"
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-aks-lab}"
CLUSTER="${CLUSTER:-dev-cluster}"

CURRENT_USER=$(az account show --query user.name -o tsv 2>/dev/null || true)
if [[ "$(tr '[:upper:]' '[:lower:]' <<<"${CURRENT_USER:-none}")" != "$(tr '[:upper:]' '[:lower:]' <<<"$AZ_USER")" ]]; then
  echo "ERROR: signed in as '${CURRENT_USER:-none}', but this script only runs as '$AZ_USER'." >&2; exit 1
fi
az account set --subscription "$SUBSCRIPTION_ID"

if ! az aks show -g "$RESOURCE_GROUP" -n "$CLUSTER" &>/dev/null; then
  echo "Cluster $CLUSTER not found in $RESOURCE_GROUP; nothing to do."; exit 0
fi
if [[ "$ASSUME_YES" != 1 ]]; then
  read -r -p "Delete AKS cluster $CLUSTER in $RESOURCE_GROUP? [y/N] " ans
  [[ "$ans" == [yY] ]] || { echo "aborted"; exit 1; }
fi
az aks delete -g "$RESOURCE_GROUP" -n "$CLUSTER" --yes
echo "Deleted $CLUSTER."
