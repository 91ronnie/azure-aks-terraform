# Deployment runbook

End-to-end order. Each step says how to verify it before moving on. Nothing here is
automatic: every `apply` is run by you after reading the plan.

| # | Step | Verify |
|---|---|---|
| 0 | Prerequisites | [prerequisites.md](prerequisites.md) checklist done |
| 1 | State backend | `az storage container show` succeeds |
| 2 | Terraform plan/apply | `terraform output` shows IPs and names |
| 3 | Cluster access | `kubectl get nodes` Ready |
| 4 | Pipeline identity → AcrPush | role assignment visible |
| 5 | GitOps placeholders | `grep -r REPLACE_ME gitops` empty (except example file) |
| 6 | Argo CD bootstrap | all Applications Synced/Healthy except `frontrow-dev` (no image yet) |
| 7 | First web pipeline run | image in ACR, values.yaml updated, `frontrow-dev` Healthy |
| 8 | DNS + TLS | [cloudflare-dns-tls.md](cloudflare-dns-tls.md) |
| 9 | Verification | `curl https://azure-fr.frontrow.co.ke/build-info.json` |

## 1. State backend

```bash
LOCATION=northeurope SUFFIX=<your-suffix> ./bootstrap/bootstrap-state.sh
```

Details and recovery: [../bootstrap/README.md](../bootstrap/README.md).

## 2. Provision the Azure foundation

```bash
cd environments/dev
cp terraform.tfvars.example terraform.tfvars    # edit: unique_suffix, owner, operator_ip_ranges, cluster_admin_object_ids
cp backend.hcl.example backend.hcl              # edit: storage_account_name
terraform init -backend-config=backend.hcl
terraform validate
terraform plan -out tfplan
```

Read the plan. Expected on a first run with one operator: **29 to add, 0 to change, 0 to destroy**
(resource group, VNet, subnet, NSG + association, 2 public IPs, 4 identities, 4 federated
credentials, ACR, Key Vault, Log Analytics, DCR + association, AKS, 8 role assignments; +4 alerts, +1 action group, +1 budget if alert_email is set).

```bash
terraform apply tfplan          # AKS creation takes ~8-15 minutes
terraform output
```

If the apply fails half-way, re-run `terraform plan`/`apply`: Terraform knows what was
created. Typical first-run failures and fixes are in [troubleshooting.md](troubleshooting.md#terraform).

## 3. Cluster access

```bash
$(terraform output -raw get_credentials_command)
kubectl get nodes -o wide
kubectl auth can-i '*' '*' --all-namespaces      # yes (Cluster Admin role)
```

Role assignments can take a few minutes to propagate; `Forbidden` right after apply usually
resolves itself.

## 4. Grant the web pipeline AcrPush

Create the `sc-frontrow-acr-push` service connection (prerequisites.md), find its principal:

```bash
az ad sp show --id <application-(client)-id-of-the-connection> --query id -o tsv
```

Put that object ID in `pipeline_acr_push_principal_id`, then `terraform plan -out tfplan` →
expect **1 to add** (`azurerm_role_assignment.pipeline_acr_push[0]`) → `terraform apply tfplan`.

## 5. Fill in GitOps placeholders

```bash
cd ../..    # repo root
grep -rn REPLACE_ME gitops
ORG=<org> PROJECT=<project> REPO=<infra-repo-name> EMAIL=<acme-email>
grep -rl REPLACE_ME_ORG gitops | xargs sed -i '' "s#REPLACE_ME_ORG#$ORG#g; s#REPLACE_ME_PROJECT#$PROJECT#g; s#REPLACE_ME_REPO#$REPO#g"
sed -i '' "s#REPLACE_ME_ACME_EMAIL#$EMAIL#g" gitops/platform/dev/cluster-issuers.yaml
```

Check that `gitops/apps/dev/traefik.yaml` annotations match
`terraform output ingress_public_ip_name` and `resource_group_name` (they do with the default
naming). Commit and push to `main` – Argo CD reads from the remote repository, not your disk.

## 6. Bootstrap Argo CD

Create the repository credential first (no secret in Git):
[../gitops/argocd/repository.example.yaml](../gitops/argocd/repository.example.yaml).

```bash
# Option A - workload identity
ARGOCD_WI_CLIENT_ID=$(terraform -chdir=environments/dev output -raw argocd_identity_client_id) \
  ./gitops/argocd/install-argocd.sh
# Option B - PAT secret created beforehand
./gitops/argocd/install-argocd.sh

kubectl -n argocd get applications
# cert-manager, platform-config, root-dev, traefik  -> Synced / Healthy
# frontrow-dev -> error "image.repository is required" until the first pipeline run (expected)

kubectl -n traefik get svc traefik   # EXTERNAL-IP must equal terraform output ingress_public_ip_address
```

## 7. First application deployment

Run the web pipeline on `main` (see `web/docs/deployment.md`). Afterwards:

```bash
git pull     # the pipeline committed gitops/environments/dev/frontrow/values.yaml
kubectl -n argocd get app frontrow-dev
kubectl -n frontrow get deploy,pods,svc,ingress,certificate
kubectl -n frontrow port-forward svc/frontrow 8080:80 &
curl -s localhost:8080/build-info.json
```

## 8–9. DNS, TLS and public verification

Follow [cloudflare-dns-tls.md](cloudflare-dns-tls.md). Do not consider the platform live until
its final verification step passes.

## Infrastructure changes via the pipeline

1. Branch → change Terraform → PR. Build validation runs **Validate + Plan** (no apply).
2. Review: pipeline run → *Plan* stage → artifact `tfplan-dev` → `plan.txt`; check
   `destroys.txt` and the warning annotation for anything destroyed/replaced.
3. Merge to `main`.
4. *Run pipeline* on `main` with **runApply = true** → Plan runs again against current state →
   Apply waits for the `frontrow-infra-dev` approval → approve after reading the new plan.
5. Apply uses that exact plan file; if state changed in between, Terraform refuses ("Saved plan
   is stale") and you re-run.

## Upgrades

### Kubernetes version

```bash
az aks get-upgrades -g rg-frontrow-dev -n aks-frontrow-dev -o table
```

1. Read the AKS release notes / removed APIs for the target minor version.
2. Check add-on compatibility: Argo CD, Traefik, cert-manager support matrices.
3. Set `kubernetes_version = "1.xx"` (one minor at a time) → plan → expect an **in-place update**
   of `module.aks.azurerm_kubernetes_cluster.this` (not a replacement) → apply.
4. Nodes are surged one at a time (`max_surge = "1"`); the FrontRow PDB keeps one pod running.
5. Patch versions are applied automatically (`automatic_upgrade_channel = "patch"`) in the
   Sunday 02:00 (+03:00) window; node OS images weekly (`NodeImage`).

### Node size / disk

Changing `node_vm_size` or `node_os_disk_*` rotates the default pool through
`temporary_name_for_rotation`: the plan shows an in-place update of the cluster; AKS creates
the temporary pool, drains, rebuilds. See exercise 1 in [exercises.md](exercises.md).

### Add-ons

Bump `targetRevision` in `gitops/apps/dev/*.yaml` (Traefik, cert-manager) by PR; Argo CD rolls
it out. For Argo CD itself change `CHART_VERSION` in `install-argocd.sh` and re-run it. Read
each project's upgrade notes first (CRD changes).

### Container patching

Base images are pinned in `web/Dockerfile` (`NODE_IMAGE`, `NGINX_IMAGE`). Monthly, or when
Trivy reports a fixable CRITICAL: bump the tag and run the pipeline, which rebuilds, scans and
promotes.

## Routine checks (weekly, 5 minutes)

```bash
kubectl get nodes; kubectl get pods -A | grep -vE 'Running|Completed'
kubectl -n argocd get applications
kubectl get events -A --field-selector type=Warning --sort-by=.lastTimestamp | tail -20
kubectl -n frontrow get certificate
# Cost Management -> Cost analysis, filter tag project = frontrow
```
