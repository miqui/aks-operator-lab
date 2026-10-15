#!/usr/bin/env bash
#
# aks-secrets-seed.sh — copy the platform's secrets from 1Password into Azure Key Vault.
#
# Key Vault is what the cluster reads (External Secrets Operator, via Workload Identity - see
# k8s/external-secrets/ and the ExternalSecrets next to each consumer). 1Password stays the
# place humans edit them; run this once, and again after rotating anything in 1Password.
# Secrets live outside the cluster, so they survive aks-teardown.sh / aks-deploy.sh cycles.
# No secret value is ever written to disk or printed; values travel from `op run` through the
# environment straight to `az keyvault secret set`.
#
# Runs only as the expected Azure user (default miquidev), who needs "Key Vault Secrets Officer"
# on the vault. Granting External Secrets read access is a one-time admin step (see AZURE.md).
#
# Usage:
#   VAULT_NAME=<vault> op run --env-file=.env -- ./aks-secrets-seed.sh [--user <upn>]
#
# Idempotent: a new secret version is only added when the value actually changed.
set -euo pipefail
trap 'echo "ERROR: failed at line $LINENO (exit $?)" >&2' ERR

AZ_USER="${AZ_USER:-miquidev@mmaqhotmail.onmicrosoft.com}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) AZ_USER="${2:?--user needs a value}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

VAULT_NAME="${VAULT_NAME:?VAULT_NAME is required}"

# <Key Vault secret name>=<environment variable (resolved by `op run` from .env)>
# Key Vault names allow only letters, digits and hyphens. Keep in sync with .env.example.
SECRETS=(
)

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

command -v az >/dev/null 2>&1 || { echo "az CLI not found" >&2; exit 1; }

if [[ ${#SECRETS[@]} -eq 0 ]]; then
  echo "No secrets defined yet - nothing to seed."
  exit 0
fi

CURRENT_USER=$(az account show --query user.name -o tsv 2>/dev/null || true)
if [[ "$(tr '[:upper:]' '[:lower:]' <<<"${CURRENT_USER:-none}")" != "$(tr '[:upper:]' '[:lower:]' <<<"$AZ_USER")" ]]; then
  echo "ERROR: signed in as '${CURRENT_USER:-none}', but this script only runs as '$AZ_USER'." >&2; exit 1
fi

missing=0
for pair in "${SECRETS[@]}"; do
  var="${pair#*=}"
  value="${!var:-}"
  if [[ -z "$value" || "$value" == op://* ]]; then
    echo "ERROR: $var is empty or unresolved - run through: op run --env-file=.env -- ..." >&2
    missing=1
  fi
done
[[ "$missing" -eq 0 ]] || exit 1

az keyvault show --name "$VAULT_NAME" --query name -o tsv >/dev/null || {
  echo "ERROR: Key Vault $VAULT_NAME not found or not visible to $CURRENT_USER" >&2; exit 1;
}

for pair in "${SECRETS[@]}"; do
  id="${pair%%=*}"
  var="${pair#*=}"
  value="${!var}"
  log "$id  (from \$$var)"

  current=$(az keyvault secret show --vault-name "$VAULT_NAME" --name "$id" --query value -o tsv 2>/dev/null || true)
  if [[ "$current" == "$value" ]]; then
    echo "    unchanged"
  else
    az keyvault secret set --vault-name "$VAULT_NAME" --name "$id" --value "$value" \
      --tags managed-by=aks-secrets-seed --output none
    echo "    new version set"
  fi
done

cat <<EOF

$(printf '\033[1;32mDone.\033[0m') ${#SECRETS[@]} secrets are in Key Vault $VAULT_NAME.
External Secrets refreshes in-cluster copies within its refreshInterval (1h); to pick up a
rotation now: kubectl annotate externalsecret -A --all force-sync=\$(date +%s) --overwrite
(then restart the consuming Deployment - env vars are only read at startup).
EOF
