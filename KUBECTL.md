# kubectl Commands — Cluster Access and Platform Status

Everyday `kubectl` for the AKS dev cluster. Argo CD specifics are in [ARGOCD.md](ARGOCD.md),
Kyverno in [KYVERNO.md](KYVERNO.md), Trivy in [TRIVY.md](TRIVY.md).

## Cluster access and platform status (AKS)

```bash
az aks get-credentials -g rg-aks-lab -n dev-cluster      # as miquidev
kubectl config current-context          # dev-cluster
kubectl get nodes -o wide

# Everything is an Argo CD Application (see ARGOCD.md)
kubectl get applications -n argocd -o custom-columns='NAME:.metadata.name,WAVE:.metadata.annotations.argocd\.argoproj\.io/sync-wave,SYNC:.status.sync.status,HEALTH:.status.health.status'

# Secrets from Azure Key Vault (no stores or secrets configured yet)
kubectl get externalsecrets -A                          # STATUS should be SecretSynced
kubectl get clustersecretstores

# Workloads
kubectl get pods -A -o wide
kubectl get networkpolicy -A
```

## Tools (port-forward only)

```bash
./aks-port-forward.sh                   # all of them; or e.g. ./aks-port-forward.sh argocd
kubectl port-forward -n headlamp svc/headlamp 4466:80   # the same, by hand
```

## Diagnosing `argocd-repo-server` liveness probe failures

Symptom: `Liveness probe failed: Get "http://<ip>:8084/healthz?full=true": context deadline exceeded`
and a few restarts (exit code 0). The pod was otherwise healthy (about 2m CPU / 38Mi, no resource limits).

```bash
kubectl get pod -n argocd -l app.kubernetes.io/name=argocd-repo-server -o wide   # RESTARTS column
kubectl describe pod -n argocd -l app.kubernetes.io/name=argocd-repo-server       # probe settings, Last State, Events
kubectl get events -n argocd --sort-by=.lastTimestamp
kubectl top pod -n argocd
```

Reading the repo-server logs (JSON; address the Deployment so it survives pod renames):

```bash
kubectl logs -n argocd deploy/argocd-repo-server
kubectl logs -n argocd deploy/argocd-repo-server -f --tail=50
kubectl logs -n argocd deploy/argocd-repo-server --previous                       # before a liveness restart
kubectl logs -n argocd deploy/argocd-repo-server --since=1h
kubectl logs -n argocd deploy/argocd-repo-server | grep '"level":"error"'
kubectl logs -n argocd deploy/argocd-repo-server | grep -v 'grpc.health.v1.Health' # drop health-check noise
kubectl logs -n argocd deploy/argocd-repo-server | grep healthcheck               # the probe-side failures
kubectl logs -n argocd deploy/argocd-repo-server --since=1h | jq -r '[.time,.level,.msg] | @tsv'
```

The tell-tale line is `Error serving health check request ... context canceled` with
`"duration":5004874461`: the health check normally answers in about 1ms, and here it ran into the
probe's `timeoutSeconds: 5`. That points at a stall around the process (CPU or memory contention on
the node), not at repo-server being slow. This was seen on an earlier, heavily packed local cluster;
on AKS check node pressure first:

```bash
kubectl top nodes
kubectl describe node <node> | grep -A8 'Allocated resources'
```

If it recurs, give `argocd-repo-server` a CPU/memory request (and, if needed, a looser liveness
probe) through `repoServer.resources` / `repoServer.livenessProbe` in `k8s/argocd/argocd-values.yaml`
- Argo CD manages its own chart, so a hand `kubectl patch` would just be reverted.
