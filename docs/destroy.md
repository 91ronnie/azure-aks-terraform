# Teardown, cleanup and recovery

Nothing in this repository destroys infrastructure automatically. Run these steps yourself.

## What is disposable and what is not

| Resource | Disposable? | Notes |
|---|---|---|
| AKS cluster, node pool, node RG, LB | ✔ | Re-created by `terraform apply` + Argo CD bootstrap |
| In-cluster state (Argo CD apps, certificates) | ✔ | All declared in Git; certificates are re-issued |
| VNet, NSG, identities, role assignments | ✔ | Identity client IDs change on re-create → update Helm values/Argo CD |
| Static public IPs | ✔ but **the IP address changes** on re-create → update Cloudflare | Keep them if you want a stable DNS record |
| ACR + images | ⚠ | Images are your rollback history; re-push needed after re-create |
| Key Vault | ⚠ | Soft-deleted for `soft_delete_retention_days` (7) with purge protection: the **name** is blocked and contents are recoverable during that time |
| Log Analytics | ✔ | Logs are lost |
| **Terraform state** (`rg-frontrow-tfstate`) | ✘ **keep** | Separate RG with a delete lock. Without state Terraform cannot manage or destroy what exists |
| Persistent volumes | n/a | FrontRow has none |

## Option 1 – stop paying for compute, keep everything

```bash
az aks stop -g rg-frontrow-dev -n aks-frontrow-dev
```

Still charged: public IPs, ACR, (verify) load balancer. Start again with `az aks start`.

## Option 2 – destroy the lab, keep state backend (and optionally ACR/IPs)

1. Remove the Cloudflare record for `azure-fr` (or it will point at a released IP).
2. Optionally delete Argo CD-managed apps first so cloud resources created by Kubernetes
   (the LB rules on our static IP) are released cleanly:
   ```bash
   kubectl -n argocd delete application root-dev   # cascades to child apps (finalizers)
   kubectl -n traefik get svc                      # wait until traefik service is gone
   ```
3. Plan the destroy and **read it**:
   ```bash
   cd environments/dev
   terraform plan -destroy -out destroy.tfplan
   terraform show destroy.tfplan | less
   ```
   Terraform has no "destroy everything except X" flag. To keep ACR (and its images), take it
   out of state first – `terraform state rm module.acr` – so it becomes unmanaged, and
   re-import it later with `terraform import`. Note that the resource group then cannot be
   deleted (it still contains the registry), which is the intended safety behaviour.
4. Apply: `terraform apply destroy.tfplan`
5. The resource group is deleted only if empty (`prevent_deletion_if_contains_resources`). If
   it fails, list what is left: `az resource list -g rg-frontrow-dev -o table` – usually
   something created by hand.
6. Key Vault is now soft-deleted: `az keyvault list-deleted -o table`. It cannot be purged
   early (purge protection) – this is intended.

## Option 3 – remove everything including state (end of project)

Only after Option 2 succeeded and `terraform state list` is empty:

```bash
az lock delete --name tfstate-no-delete --resource-group rg-frontrow-tfstate
az group delete --name rg-frontrow-tfstate     # interactive confirmation; irreversible
```

## Recreate safely

```bash
cd environments/dev
terraform plan -out tfplan && terraform apply tfplan
$(terraform output -raw get_credentials_command)
./gitops/argocd/install-argocd.sh        # from repo root; re-create the repo credential first
# Update Cloudflare A record if the ingress IP changed
# Re-run the web pipeline (or rely on existing images if ACR was kept)
```

If you destroyed and re-created within the Key Vault retention period, choose a new
`unique_suffix` **or** recover the old vault (`az keyvault recover --name …`) and import it:
`terraform import module.key_vault.azurerm_key_vault.this <vault-resource-id>`.

## Terraform state recovery

| Situation | Action |
|---|---|
| State file corrupted / bad write | Blob versioning: Portal → storage account → container `tfstate` → blob → *Versions* → promote the previous version. CLI: `az storage blob list --include v --container-name tfstate --account-name <sa> --auth-mode login --prefix frontrow/dev` then copy that version over the current blob |
| State blob deleted | Soft delete (30 days): *Show deleted blobs* → Undelete |
| Stuck lock | `terraform force-unlock <LOCK_ID>` – only when you are sure no run is active |
| Resource exists but not in state | `terraform import <address> <azure-id>` (or an `import {}` block) |
| State lost entirely | Re-import every resource, or delete the RG manually and recreate. Avoid: keep the state account |

Before any manual state operation: `terraform state pull > backup-$(date +%F).tfstate` (store
it securely, delete it afterwards – it describes your environment).

## Registry cleanup

```bash
ACR=$(terraform -chdir=environments/dev output -raw acr_name)
az acr repository show-tags -n $ACR --repository frontrow/web --orderby time_desc -o table
# Dry run first: keep the newest 10 tags, delete older than 30 days
az acr run --registry $ACR --cmd "acr purge --filter 'frontrow/web:.*' --ago 30d --keep 10 --untagged --dry-run" /dev/null
```

Never delete the tag currently referenced in `gitops/environments/*/frontrow/values.yaml`.
For a scheduled clean-up set `acr_purge_task_enabled = true`.
