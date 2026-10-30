# Azure Key Vault (Standard).
#
# - Azure RBAC authorization (no legacy access policies).
# - Soft delete + purge protection: a deleted vault/secret is recoverable for
#   soft_delete_retention_days and CANNOT be purged early. The vault name stays
#   reserved for that period after destroy.
# - Data-plane firewall: deny by default; allow the operator IPs and the
#   cluster's static egress IP (used by the Secrets Store CSI provider).
#
# Terraform creates no secrets. Secret values are written out-of-band
# (az keyvault secret set) so they never enter Terraform state or Git.

resource "azurerm_key_vault" "this" {
  name                = var.name
  location            = var.location
  resource_group_name = var.resource_group_name
  tenant_id           = var.tenant_id
  sku_name            = "standard"

  rbac_authorization_enabled = true
  purge_protection_enabled   = true
  soft_delete_retention_days = var.soft_delete_retention_days

  public_network_access_enabled = true

  network_acls {
    default_action             = "Deny"
    bypass                     = "AzureServices"
    ip_rules                   = var.allowed_ip_ranges
    virtual_network_subnet_ids = var.allowed_subnet_ids
  }

  tags = var.tags
}
