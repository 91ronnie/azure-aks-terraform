# Troubleshooting

Work from the outside in: **DNS → TLS → Load balancer/NSG → Traefik → Ingress → Service →
Endpoints → Pod → Image → Argo CD → Git**.

## Quick triage

```bash
dig +short azure-fr.frontrow.co.ke
curl -skv https://azure-fr.frontrow.co.ke/healthz 2>&1 | tail -5
kubectl -n traefik get svc,pods
kubectl -n frontrow get ingress,svc,endpoints,pods -o wide
kubectl -n frontrow describe pod -l app.kubernetes.io/name=frontrow | sed -n '/Events/,$p'
kubectl -n frontrow logs -l app.kubernetes.io/name=frontrow --tail=50
kubectl -n argocd get applications
kubectl get events -A --field-selector type=Warning --sort-by=.lastTimestamp | tail -20
```

## Terraform

| Error | Cause → fix |
|---|---|
| `AuthorizationFailed … roleAssignments/write` | Deployer lacks RBAC Administrator → see prerequisites |
| `SkuNotAvailable` / `QuotaExceeded` | VM size not offered or vCPU quota → `az vm list-skus`, `az vm list-usage`; pick another size/region or request quota |
| `EncryptionAtHost feature is not enabled` | Register the feature or set `host_encryption_enabled = false` |
| `The vault name … is already in use` | Soft-deleted vault with that name exists (purge protection) → choose another `unique_suffix` or wait `soft_delete_retention_days` |
| `CustomKubeletIdentityMissingPermission` | Managed Identity Operator assignment not yet propagated → re-run apply |
| `Error acquiring the state lock` | Another run holds the blob lease → wait; if a crashed run left it: `terraform force-unlock <ID>` after confirming nothing is running |
| `Saved plan is stale` | State changed after planning → plan again |
| `403 … state` | Missing Storage Blob Data Contributor on the state container, or `use_azuread_auth` not set |
| AKS API: `connection refused / i/o timeout` from your laptop | Your public IP changed → update `operator_ip_ranges` (use Cloud Shell or the portal: AKS → Networking → authorized IP ranges) |

## Kubernetes access

```bash
kubelogin convert-kubeconfig -l azurecli   # after az login
kubectl auth whoami
kubectl auth can-i get pods -n frontrow
```

`Forbidden` → role assignment missing/propagating (`az role assignment list --assignee <you> --scope $(az aks show -g rg-frontrow-dev -n aks-frontrow-dev --query id -o tsv)`).

## Pods

| Status | Look at | Typical cause |
|---|---|---|
| `Pending` | `kubectl describe pod` events | Insufficient CPU/memory → autoscaler should add a node (`kubectl get events -n kube-system \| grep -i scale`); max_count reached |
| `ImagePullBackOff` | events | Tag not in ACR (`az acr repository show-tags -n <acr> --repository frontrow/web`), kubelet AcrPull missing, wrong login server |
| `CrashLoopBackOff` | `kubectl logs --previous` | nginx config error; read-only FS write outside `/tmp` |
| `Running` but not `Ready` | readiness probe | `/healthz` not served (old image), wrong `containerPort` |
| Rejected by PodSecurity | events on the ReplicaSet | A security setting removed from the chart |

```bash
az aks check-acr -g rg-frontrow-dev -n aks-frontrow-dev --acr <acr>.azurecr.io   # end-to-end pull test
```

## Ingress / Traefik

```bash
kubectl -n traefik logs deploy/traefik --tail=100     # access log lines show router + status
kubectl -n traefik get svc traefik -o yaml | yq '.metadata.annotations, .status'
```

* `EXTERNAL-IP <pending>`: the control-plane identity lacks Network Contributor on
  `pip-frontrow-dev-ingress`, or the annotation names a different IP/RG →
  `kubectl -n traefik describe svc traefik` shows the Azure cloud-provider error.
* Health probe failures: the LB uses a TCP probe on the node port (annotation
  `azure-load-balancer-health-probe-protocol: tcp`).

## Network policy

If Traefik returns 504/502 but the pod is Ready, test from the Traefik namespace:

```bash
kubectl -n traefik run t --rm -it --image=busybox:1.37 --restart=Never -- wget -qO- http://frontrow.frontrow.svc/healthz
```

A Pod Security restricted namespace may reject that debug pod; use `kubectl debug` on the Traefik
pod instead or a namespace without `restricted` enforcement.

## Argo CD

See [argocd-gitops.md](argocd-gitops.md#drift-and-reconciliation-troubleshooting).

## Key Vault CSI (only when enabled)

```bash
kubectl -n frontrow describe pod <pod> | grep -A5 -i "MountVolume"
kubectl -n kube-system logs -l app=secrets-store-provider-azure --tail=50
```

| Error | Cause |
|---|---|
| `AADSTS70021: No matching federated identity record` | SA name/namespace differs from the federated credential subject (`system:serviceaccount:frontrow:frontrow`) |
| `403 Forbidden … ForbiddenByFirewall` | Node traffic not via the subnet service endpoint, or the vault firewall changed |
| `403 … does not have secrets get permission` | Key Vault Secrets User missing / propagating |
| `SecretNotFound` | Object name in values differs from the vault |

## Monitoring

```kusto
// Log Analytics: FrontRow container logs, last hour
ContainerLogV2
| where TimeGenerated > ago(1h) and PodNamespace == "frontrow"
| project TimeGenerated, PodName, LogMessage
| order by TimeGenerated desc

// Pod restarts
KubePodInventory
| where TimeGenerated > ago(1d) and Namespace == "frontrow"
| summarize restarts = max(PodRestartCount) by Name
```

If nothing arrives: daily cap reached (`Usage` table, workspace *Usage and estimated costs*), or
`container_insights_enabled = false`.
