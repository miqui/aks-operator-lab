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

```bash
az aks create -g rg-aks-lab -n aks-test --node-count 1 --node-vm-size Standard_B2s --generate-ssh-keys
az aks delete -g rg-aks-lab -n aks-test --yes
```

Stop or delete clusters when not in use: `az aks stop -g rg-aks-lab -n <cluster>`.

## Notes

- `az` prints a `SyntaxWarning` from its own Python code. It is harmless.
- Optional follow-ups not done: an Azure Policy restricting VM sizes and regions, and registering the monitoring providers.
