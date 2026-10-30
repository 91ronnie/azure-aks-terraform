#!/usr/bin/env bash
# Create (or verify) the Terraform remote-state backend. Idempotent and
# non-destructive: it never deletes or overwrites anything, and refuses to
# continue if an existing storage account has unsafe settings.
#
# Usage:
#   az login
#   az account set --subscription <SUBSCRIPTION_ID>
#   LOCATION=northeurope SUFFIX=abc01 ./bootstrap/bootstrap-state.sh
#
# Creates:
#   rg-frontrow-tfstate                resource group (separate lifecycle from the lab)
#   stfrontrowtfstate<SUFFIX>          StorageV2, Standard_LRS, TLS1.2, no public blobs,
#                                      shared keys disabled, versioning + soft delete
#   tfstate                            private blob container
#   Storage Blob Data Contributor      for the signed-in user on the account
set -euo pipefail

PROJECT="${PROJECT:-frontrow}"
LOCATION="${LOCATION:?set LOCATION, e.g. northeurope}"
SUFFIX="${SUFFIX:?set SUFFIX (3-6 lowercase chars, same as unique_suffix)}"
RG="${STATE_RG:-rg-${PROJECT}-tfstate}"
SA="${STATE_SA:-st${PROJECT}tfstate${SUFFIX}}"
CONTAINER="${STATE_CONTAINER:-tfstate}"

if [[ ! "$SA" =~ ^[a-z0-9]{3,24}$ ]]; then
  echo "Storage account name '$SA' is invalid (3-24 lowercase alphanumerics)." >&2
  exit 1
fi

SUB_ID="$(az account show --query id -o tsv)"
ME="$(az ad signed-in-user show --query id -o tsv)"
echo "Subscription: $SUB_ID"
echo "State backend: $RG / $SA / $CONTAINER"

az group create --name "$RG" --location "$LOCATION" \
  --tags project="$PROJECT" purpose=terraform-state managed-by=bootstrap-script >/dev/null

if az storage account show --name "$SA" --resource-group "$RG" >/dev/null 2>&1; then
  echo "Storage account exists - verifying settings (no changes will be forced)."
  read -r PUBLIC_BLOB SHARED_KEY TLS <<<"$(az storage account show -n "$SA" -g "$RG" \
    --query '[allowBlobPublicAccess, allowSharedKeyAccess, minimumTlsVersion]' -o tsv)"
  [[ "$PUBLIC_BLOB" == "false" ]] || { echo "allowBlobPublicAccess must be false" >&2; exit 1; }
  [[ "$SHARED_KEY" == "false" ]] || echo "WARNING: shared key access is enabled; consider disabling it."
  [[ "$TLS" == "TLS1_2" || "$TLS" == "TLS1_3" ]] || { echo "minimumTlsVersion must be >= TLS1_2" >&2; exit 1; }
else
  az storage account create \
    --name "$SA" --resource-group "$RG" --location "$LOCATION" \
    --sku Standard_LRS --kind StorageV2 \
    --min-tls-version TLS1_2 \
    --allow-blob-public-access false \
    --allow-shared-key-access false \
    --https-only true \
    --tags project="$PROJECT" purpose=terraform-state >/dev/null
fi

SA_ID="$(az storage account show -n "$SA" -g "$RG" --query id -o tsv)"

# Recovery: versioning keeps every previous state file; soft delete covers accidental deletes.
az storage account blob-service-properties update \
  --account-name "$SA" --resource-group "$RG" \
  --enable-versioning true \
  --enable-delete-retention true --delete-retention-days 30 \
  --enable-container-delete-retention true --container-delete-retention-days 30 >/dev/null

# Data-plane access for the operator (Entra ID, no keys).
if ! az role assignment list --assignee "$ME" --scope "$SA_ID" \
  --role "Storage Blob Data Contributor" --query '[0].id' -o tsv | grep -q .; then
  az role assignment create --assignee-object-id "$ME" --assignee-principal-type User \
    --role "Storage Blob Data Contributor" --scope "$SA_ID" >/dev/null
  echo "Granted Storage Blob Data Contributor to the signed-in user (may take ~1-2 min to propagate)."
fi

# Container creation uses the management plane, so it works with shared keys disabled.
az storage container-rm create --storage-account "$SA" --resource-group "$RG" \
  --name "$CONTAINER" --public-access off >/dev/null

# Optional guard: prevent accidental deletion of the state account.
if ! az lock list --resource-group "$RG" --query "[?name=='tfstate-no-delete'].id" -o tsv | grep -q .; then
  az lock create --name tfstate-no-delete --lock-type CanNotDelete \
    --resource-group "$RG" --notes "Holds Terraform state for ${PROJECT}" >/dev/null
fi

cat <<EOF

Backend ready. Create environments/dev/backend.hcl with:

resource_group_name  = "$RG"
storage_account_name = "$SA"
container_name       = "$CONTAINER"
key                  = "${PROJECT}/dev/terraform.tfstate"
use_azuread_auth     = true

Then: cd environments/dev && terraform init -backend-config=backend.hcl
EOF
