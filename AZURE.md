# Azure setup: letting `miquidev` create AKS clusters safely

Admin account `maq` set up a dedicated resource group, a scoped role for `miquidev`, and a budget alert.
Identifiers are replaced with placeholders:

| Placeholder | Meaning |
|---|---|
| `<SUBSCRIPTION_ID>` | Pay-As-You-Go subscription ID |
| `<MIQUIDEV_OBJECT_ID>` | Entra ID object ID of `miquidev` |
| `<ALERT_EMAIL>` | Email address that receives budget alerts |

## 1. Log in (as the admin account, `maq`)

```bash
az login
az account list --query "[].{name:name, id:id, state:state, default:isDefault}" -o table
```

## 2. Verify identities (read-only)

```bash
# Confirm the object ID really belongs to miquidev
az ad user show --id <MIQUIDEV_OBJECT_ID> --query "{name:displayName, upn:userPrincipalName}" -o table

# Confirm who is signed in
az ad signed-in-user show --query "{name:displayName, upn:userPrincipalName}" -o table
```

## 3. Create the dedicated resource group

```bash
az group create --name rg-aks-lab --location eastus --subscription <SUBSCRIPTION_ID>
```

## 4. Grant `miquidev` Contributor on that resource group only

No Owner, User Access Administrator, or subscription-level role is granted.

```bash
az role assignment create \
  --assignee-object-id <MIQUIDEV_OBJECT_ID> \
  --assignee-principal-type User \
  --role "Contributor" \
  --scope /subscriptions/<SUBSCRIPTION_ID>/resourceGroups/rg-aks-lab
```

Verify (read-only):

```bash
az role assignment list --assignee <MIQUIDEV_OBJECT_ID> --all \
  --query "[].{role:roleDefinitionName, scope:scope}" -o table
```

## 5. Check resource provider registration (read-only)

```bash
for p in Microsoft.ContainerService Microsoft.Compute Microsoft.Network \
         Microsoft.Storage Microsoft.OperationsManagement Microsoft.OperationalInsights; do
  echo -n "$p: "; az provider show -n $p --query registrationState -o tsv
done
```

Result: the first four are `Registered`. `OperationsManagement` and `OperationalInsights` are `NotRegistered`.
They are only needed for the Container Insights add-on (`--enable-addons monitoring`).

## 6. $25/month budget with email alerts

An attempt using `--start-date` and `--end-date` failed with `unrecognized arguments`
(this CLI version, 2.91.0, takes `--time-period`). This is the working command:

```bash
az consumption budget create-with-rg -g rg-aks-lab -n aks-lab-25usd \
  --amount 25 --category Cost --time-grain Monthly \
  --time-period "{start-date:2026-10-01,end-date:2027-10-01}" \
  --notifications "{actual80:{enabled:true,operator:GreaterThan,threshold:80,contact-emails:[<ALERT_EMAIL>]},actual100:{enabled:true,operator:GreaterThan,threshold:100,contact-emails:[<ALERT_EMAIL>]}}"
```

Alerts fire at 80% ($20) and 100% ($25) of actual spend on `rg-aks-lab`.
**A budget only sends emails. It does not stop spending.**

## 7. Test as `miquidev` (cheap, then clean up)

The real cluster is created by `aks-deploy.sh` (see section 8). It passes `--no-ssh-key`, so no
SSH key is generated or used.

Stop or delete clusters when not in use: `az aks stop -g rg-aks-lab -n <cluster>`.

## 7b. Cluster identity for the dedicated VNet (admin, one time)

The cluster runs in its own VNet (`dev-vnet`, created by `aks-deploy.sh`). Joining a custom subnet
needs the cluster's identity to hold `Network Contributor`, and `miquidev` cannot create role
assignments, so the admin creates the identity and grants it once. Scope is this resource group only.

```bash
az identity create -g rg-aks-lab -n id-aks-dev -l eastus --query "{name:name, principalId:principalId}" -o table

az role assignment create \
  --assignee-object-id <IDENTITY_PRINCIPAL_ID> \
  --assignee-principal-type ServicePrincipal \
  --role "Network Contributor" \
  --scope /subscriptions/<SUBSCRIPTION_ID>/resourceGroups/rg-aks-lab
```

Verify (read-only):

```bash
az role assignment list --assignee <IDENTITY_PRINCIPAL_ID> --all --query "[].{role:roleDefinitionName, scope:scope}" -o table
```

## 8. Cluster lifecycle (as `miquidev`, in a separate CLI profile)

The cluster is created and deleted by the scripts in this repo, never by the admin account.
The scripts refuse to run unless the signed-in user is `miquidev`.

```bash
export AZURE_CONFIG_DIR=~/.azure-miquidev
az login                                           # sign in as miquidev
export SUBSCRIPTION_ID=<SUBSCRIPTION_ID>

./aks-deploy.sh --dry-run                          # show the az aks create command only
./aks-deploy.sh                                    # create the cluster, fetch credentials
./aks-bootstrap.sh                                 # Argo CD + the GitOps platform
az aks stop  -g rg-aks-lab -n dev-cluster          # pause: stops node billing, keeps the cluster
az aks start -g rg-aks-lab -n dev-cluster
./aks-teardown.sh --yes                            # delete the cluster (VNet kept)
./aks-teardown.sh --yes --purge                    # ...and delete dev-vnet too
```

Quota checks used before choosing the VM size (read-only):

```bash
az vm list-usage -l eastus --query "[].[name.value,currentValue,limit]" -o tsv
az vm list-skus -l eastus --resource-type virtualMachines --size Standard_D2s_v6 -o table
```

Billable-resource check after teardown (read-only, as the admin):

```bash
az resource list --query "[].{name:name, type:type, rg:resourceGroup}" -o table
```

## 9. Key Vault for secrets (planned, admin step)

1Password stays the source of truth; `aks-secrets-seed.sh` copies values into Key Vault and
External Secrets reads them through Workload Identity. Creating the vault, the federated identity
and the role assignments needs rights `miquidev` does not have, so they are admin steps. Nothing
has been created yet.

## Notes

- `az` prints a `SyntaxWarning` from its own Python code. It is harmless.
- Optional follow-ups not done: an Azure Policy restricting VM sizes and regions, and registering the monitoring providers.
