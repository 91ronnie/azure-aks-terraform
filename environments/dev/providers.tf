# Authentication is taken from the environment, never from this file:
#   - Locally:      az login              (Azure CLI)
#   - In pipelines: ARM_USE_OIDC=true + workload identity federation
#                   (see azure-pipelines.yml)
# ARM_SUBSCRIPTION_ID must be set (or subscription_id in terraform.tfvars).

provider "azurerm" {
  subscription_id = var.subscription_id

  # Only register the resource providers this configuration actually uses.
  resource_provider_registrations = "none"
  resource_providers_to_register = [
    "Microsoft.ContainerService",
    "Microsoft.ContainerRegistry",
    "Microsoft.KeyVault",
    "Microsoft.Network",
    "Microsoft.ManagedIdentity",
    "Microsoft.OperationalInsights",
    "Microsoft.Insights",
    "Microsoft.Consumption",
    "Microsoft.DBforPostgreSQL",
  ]

  # All Azure data-plane calls use Entra ID tokens.
  storage_use_azuread = true

  features {
    key_vault {
      # Never purge soft-deleted secrets or vaults during destroy.
      purge_soft_delete_on_destroy          = false
      purge_soft_deleted_secrets_on_destroy = false
      recover_soft_deleted_key_vaults       = true
      recover_soft_deleted_secrets          = true
    }

    resource_group {
      # Refuse to delete a resource group that still contains resources
      # Terraform does not know about (e.g. something created by hand).
      prevent_deletion_if_contains_resources = true
    }
  }
}
