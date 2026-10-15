# aks-operator-lab

An environment for developing custom Kubernetes operators and testing third-party operators on a
dev [AKS](https://learn.microsoft.com/azure/aks/) cluster in Azure. Argo CD deploys the platform
from this repo.

> **Status:** the platform layer is in place. Operator development tooling and repeatable test
> scenarios are not implemented yet. The architecture diagram is [az-arch.drawio](az-arch.drawio).

The cluster is meant to be **short-lived**: create it for an experiment, tear it down after a few
hours, recreate it for the next one. Secrets and the resource group live outside it and are reused.

## Stack URLs

Nothing is public: there is no Ingress, Gateway or LoadBalancer. Every UI is reached through
`./aks-port-forward.sh`. It tunnels through the AKS API server, which only accepts your IP plus
valid cluster credentials, and binds on `127.0.0.1` only.

| Component | URL | Login |
| --- | --- | --- |
| Argo CD | `https://localhost:8081` (self-signed cert) | `admin` / `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' \| base64 -d`. Change it in the UI, then delete that Secret. |
| Headlamp | `http://localhost:4466` | `kubectl create token headlamp -n headlamp --duration=1h \| tr -d '\n' \| pbcopy` (read-only) |
| Polaris | `http://localhost:8082` | none (read-only report) |

## Architecture

- **Access model**: the Azure setup is split between an admin account and a least-privilege
  cluster user. The admin creates the resource group, grants the cluster user `Contributor` on
  that resource group only, and sets a $25/month budget alert; see [AZURE.md](AZURE.md). Every
  `aks-*.sh` script refuses to change anything unless the signed-in user is the expected one
  (`miquidev@mmaqhotmail.onmicrosoft.com` by default, or `--user <upn>` / `AZ_USER`).
- **Cluster** (`aks-deploy.sh`): zonal AKS cluster `dev-cluster` in `rg-aks-lab` (`eastus`),
  free tier, `stable` auto-upgrade channel.

  | Setting | Value |
  | --- | --- |
  | Nodes | `Standard_D2s_v6` (2 vCPU / 8 GB), 30 GB managed OS disk, autoscaling 3-4, zone 1 |
  | Network | Dedicated VNet `dev-vnet` (`10.10.0.0/16`) with subnet `dev-subnet` (`10.10.0.0/20`) in `rg-aks-lab`; Azure CNI Overlay with the Cilium dataplane and network policy (enforces NetworkPolicies) |
  | Identity | User-assigned managed identity `id-aks-dev` (Network Contributor on the resource group, granted by an admin); OIDC issuer and Workload Identity |
  | API access | API server accepts only the operator's public IP (`/32`); nodes have no public IPs |
  | SSH | none (`--no-ssh-key`) |

  Max nodes is 4, not 5: the default regional quota is 10 vCPUs, and AKS needs a surge node during
  upgrades. Every image is public (ghcr.io, Docker Hub, quay.io, ...), so no registry is needed.
- **GitOps**: Argo CD syncs the whole platform from this repo's `main` branch; see
  [Continuous Deployment with Argo CD](#continuous-deployment-with-argo-cd).
- **Secrets**: nothing secret is committed, or passed through a script into the cluster.
  - Values live in 1Password. `aks-secrets-seed.sh` copies them into **Azure Key Vault**.
  - The **External Secrets Operator** builds Kubernetes Secrets from `ExternalSecret` manifests.
    It will authenticate through Workload Identity and read exactly the seeded secrets.
  - No vault, secret store or secrets are defined yet. Before adding an `ExternalSecret`, create
    the vault and a federated identity for `external-secrets/external-secrets` (an admin step),
    then add a `ClusterSecretStore` in `k8s/` with namespace-scoped access conditions. Each secret
    is an entry in `aks-secrets-seed.sh` and `.env.example`.
- **Tools**:
  - **[Headlamp](https://headlamp.dev/)** is a Kubernetes web UI, bound to the read-only `view`
    ClusterRole.
  - **[Polaris](https://polaris.docs.fairwinds.com/)** is a best-practice dashboard with read-only
    RBAC.
  - **[Trivy Operator](https://github.com/aquasecurity/trivy-operator)** does continuous CVE and
    misconfiguration scanning ([TRIVY.md](TRIVY.md)).

## Continuous Deployment with Argo CD

`aks-bootstrap.sh` does two things by hand: it Helm-installs Argo CD and applies one **root**
Application (`k8s/argocd/root-application.yaml`). The root Application syncs every other
Application from `k8s/argocd/apps/` ("app of apps"), Argo CD itself included. From then on, a
version bump, a values change or a new manifest is a merged commit to
`https://github.com/miqui/aks-operator-lab.git`. The repo must be public, because Argo CD clones it
anonymously.

| Wave | Application | Source |
| --- | --- | --- |
| -4 | `argocd` (self-managed), `external-secrets` | upstream charts + values in `k8s/argocd/`, `k8s/external-secrets/` |
| -3 | `kyverno` | Kyverno chart |
| -2 | `kyverno-policies` | `k8s/policies/`: enforce rules exist before any workload syncs |
| -1 | `headlamp`, `polaris`, `trivy-operator` | charts + values |

A wave only starts once the previous one is Healthy. That depends on the Application health check
in `k8s/argocd/argocd-values.yaml`. Every Application runs `automated: {prune: true, selfHeal:
true}`, except Argo CD's own, which doesn't prune. Day-to-day commands are in
[ARGOCD.md](ARGOCD.md), and chart versions in [HELM.md](HELM.md).

## Policy as Code with Kyverno

[Kyverno](https://kyverno.io/) runs admission control in the cluster. The *same* policies are
checked in CI (`.github/workflows/policy-check.yml` → `check-policies.sh`). They use the CEL-based
`policies.kyverno.io/v1` types.

- `k8s/policies/rules/` holds each rule once:
  - `disallow-host-access`
  - `require-secure-container-context`
  - `require-resources`
  - `restrict-image-repositories`, an exact-repository allowlist
- Overlays turn the rules into a **Deny** copy for `default` and an **Audit** copy for `headlamp`
  and `polaris`. `audit-only/` holds `disallow-latest-tag` and `restrict-cluster-admin-bindings`.
- **A new image** needs its repository in `restrict-image-repositories.yaml`.
- **A new namespace** goes into the overlays' `namespaceSelector`.
- `check-policies.sh` evaluates the enforce and audit sets against this repo's own workload
  manifests (`WORKLOAD_DIRS`, empty for now). It also requires the enforce set to reject a
  known-bad fixture. `polaris-audit.sh` runs the Polaris checks against the same manifests,
  report-only.

Debugging commands are in [KYVERNO.md](KYVERNO.md).

## Deployment to AKS

Requirements:
- `az` (Azure CLI), `kubectl` and `helm`
- the cluster user's Azure login (see [AZURE.md](AZURE.md) for the admin-side setup, including the
  one-time `id-aks-dev` identity)
- the [1Password CLI](https://developer.1password.com/docs/cli/) (`op`), once secrets exist

```bash
# Log in as the cluster user, in a separate CLI profile so an admin session is untouched
export AZURE_CONFIG_DIR=~/.azure-miquidev
az login                                        # sign in as miquidev
export SUBSCRIPTION_ID=<subscription-id>

# 1. Cluster (~5-10 min). --dry-run prints the az aks create command and changes nothing.
./aks-deploy.sh --dry-run
./aks-deploy.sh

# 2. Secrets -> Key Vault (first time, and after rotating anything in 1Password)
VAULT_NAME=<key-vault> op run --env-file=.env -- ./aks-secrets-seed.sh

# 3. Argo CD + everything else via GitOps (~5 min)
./aks-bootstrap.sh

# 4. Tools
./aks-port-forward.sh
```

**Before the first run:** the repo must be pushed to `github.com/miqui/aks-operator-lab` (public),
branch `main`. Argo CD syncs from there, not from your working copy. `aks-bootstrap.sh` checks
that the repo is readable and warns about unpushed commits.

**What each script does:**

- `aks-deploy.sh` checks the signed-in user, the resource group and the `id-aks-dev` identity,
  finds your public IP, creates the VNet if missing, and runs `az aks create`. It skips creation if the cluster already exists (cluster-level settings are
  creation-time; recreate to change them). Overridable env vars: `AZ_USER`, `RESOURCE_GROUP`,
  `LOCATION`, `CLUSTER`, `VM_SIZE`, `MIN_NODES`, `MAX_NODES`, `NODE_DISK_SIZE_GB`, `ZONE`,
  `VNET_NAME`, `VNET_CIDR`, `SUBNET_NAME`, `SUBNET_CIDR`, `IDENTITY_NAME`.
- `aks-secrets-seed.sh` creates or updates the Key Vault secrets listed in its `SECRETS` array. It
  adds a version only when the value changed.
- `aks-bootstrap.sh` runs a preflight (user, kubectl context, public repo). It then Helm-installs
  Argo CD, applies the root Application and waits until every Application is Synced + Healthy.
  Safe to re-run.
- `aks-teardown.sh` deletes the cluster (`--yes` skips the prompt). The resource group, VNet,
  identity, role assignments, budget and Key Vault are kept; `--purge` also deletes the VNet.
- `aks-port-forward.sh` opens the local tunnels to the tools.

**Cost.** Nodes bill while running: three `D2s_v6` cost roughly $0.29/hour (about $210/month), so
the $25 budget lasts only a few days of continuous running. The budget sends emails and does not
stop spending. Stop the cluster with `az aks stop` or delete it when idle.

**If your public IP changes**, `kubectl` times out. Re-authorize it:

```bash
az aks update -g rg-aks-lab -n dev-cluster --api-server-authorized-ip-ranges <new-ip>/32
```

**Validate a teardown** (nothing should be listed):

```bash
az aks list -g rg-aks-lab -o table
az group list --query "[?starts_with(name,'MC_')].name" -o tsv      # the node resource group
```

Operational notes on events that look alarming but aren't are in [AKS-OPS.md](AKS-OPS.md);
everyday `kubectl` is in [KUBECTL.md](KUBECTL.md).

### Headlamp

Headlamp can show everything in the cluster, so it gets the least access that is still useful.
`./aks-port-forward.sh headlamp` serves it at `http://localhost:4466`. Log in with a short-lived
token for its `view`-bound ServiceAccount (see [Stack URLs](#stack-urls)).

For anything that needs more access (editing, exec), use `kubectl` with your own cluster
credentials. Don't widen the `headlamp` binding: every Headlamp login would become an admin login.

### Polaris

`./aks-port-forward.sh polaris` serves it at `http://localhost:8082`. It shows an overall score
and, per workload, which built-in checks fail at `warning`/`danger`.
- Platform-managed namespaces are exempt (`config.exemptions` in `k8s/polaris/polaris-values.yaml`).
- Findings are advice. Anything that must be blocked belongs in a Kyverno policy.
