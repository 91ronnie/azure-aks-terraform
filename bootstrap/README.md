# Remote state bootstrap

Terraform needs somewhere to keep state **before** it can create anything, so the backend is
created once, outside the main configuration, by `bootstrap-state.sh` (Azure CLI). It has its
own resource group and lifecycle: destroying the lab never touches it.

## What it creates

| Resource | Setting | Why |
|---|---|---|
| `rg-frontrow-tfstate` | `CanNotDelete` lock | Accidental `az group delete` protection |
| `stfrontrowtfstate<suffix>` | StorageV2, Standard_LRS, HTTPS only, TLS ≥ 1.2 | Cheap, durable enough for a lab (use ZRS/GRS for production) |
| | `allowBlobPublicAccess=false`, **`allowSharedKeyAccess=false`** | No anonymous access; no account keys or SAS – Entra ID only |
| | blob versioning, 30-day blob and container soft delete | Recover a corrupted or deleted state file |
| `tfstate` container | private | |
| Role assignment | *Storage Blob Data Contributor* for you | Data-plane access without keys |

## Run it

```bash
az login
az account set --subscription "<SUBSCRIPTION_ID>"
LOCATION=northeurope SUFFIX=abc01 ./bootstrap/bootstrap-state.sh
```

The script is idempotent: re-running it verifies settings and never overwrites or deletes.
It prints the `backend.hcl` contents at the end.

```bash
cd environments/dev
cp backend.hcl.example backend.hcl   # paste the printed values
terraform init -backend-config=backend.hcl
```

## Permissions

* To run the script: Contributor + User Access Administrator (or Owner) on the subscription or
  on a pre-created `rg-frontrow-tfstate`.
* To use the backend: **Storage Blob Data Contributor** on the container/account for every
  identity that runs Terraform (you, and the `sc-frontrow-infra-dev` pipeline identity):
  ```bash
  SA_ID=$(az storage account show -n stfrontrowtfstate<suffix> -g rg-frontrow-tfstate --query id -o tsv)
  az role assignment create --assignee-object-id <pipeline-principal-object-id> \
    --assignee-principal-type ServicePrincipal --role "Storage Blob Data Contributor" \
    --scope "$SA_ID/blobServices/default/containers/tfstate"
  ```

## Locking

The azurerm backend takes a blob **lease** on the state blob for the duration of
plan/apply. A second run waits (`-lock-timeout`) or fails with "state blob is already locked".
`terraform force-unlock <ID>` breaks a stale lease – only use it when no run is active.

## Recovery and migration

* Restore a previous state version: see [../docs/destroy.md](../docs/destroy.md#terraform-state-recovery).
* Moving state to another account/key: `terraform init -migrate-state -backend-config=new.hcl`
  **after** `terraform state pull > backup.tfstate`. Validate with `terraform plan` (expect no
  changes) before deleting anything old. Never migrate automatically from a pipeline.
* There was no previous Azure state: the old AWS stacks used Terraform Cloud and have nothing
  to do with this backend. Nothing was migrated or overwritten.
