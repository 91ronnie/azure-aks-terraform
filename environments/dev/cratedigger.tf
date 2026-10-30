# CrateDigger: everything the second application needs, in one file.
#
#   id-frontrow-dev-cratedigger   workload identity for the cratedigger pods
#   kv-cd-dev-<suffix>            its own Key Vault (app secrets: session key,
#                                 admin password, Spotify/YouTube credentials)
#   psql-frontrow-dev-<suffix>    PostgreSQL Flexible Server, private access,
#                                 Entra ID auth only; the identity is its admin
#
# A separate Key Vault keeps the blast radius small: the cratedigger identity
# can read its own secrets, not FrontRow's (Key Vault RBAC is vault-scoped here
# because the secrets are created out-of-band, after the vault exists).
# Toggle the whole app with cratedigger_enabled.

locals {
  cratedigger_count     = var.cratedigger_enabled ? 1 : 0
  cratedigger_kv_name   = "kv-cd-${var.environment}-${var.unique_suffix}"
  cratedigger_psql_name = "psql-${local.name_prefix}-${var.unique_suffix}"
}

resource "azurerm_user_assigned_identity" "cratedigger" {
  count = local.cratedigger_count

  name                = "id-${local.name_prefix}-cratedigger"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags
}

resource "azurerm_federated_identity_credential" "cratedigger" {
  count = local.cratedigger_count

  name                      = "fic-cratedigger-sa"
  user_assigned_identity_id = azurerm_user_assigned_identity.cratedigger[0].id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = module.aks.oidc_issuer_url
  subject                   = "system:serviceaccount:${var.cratedigger_namespace}:${var.cratedigger_service_account}"
}

module "cratedigger_key_vault" {
  source = "../../modules/key-vault"
  count  = local.cratedigger_count

  name                       = local.cratedigger_kv_name
  location                   = var.location
  resource_group_name        = azurerm_resource_group.main.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  soft_delete_retention_days = var.key_vault_soft_delete_retention_days
  allowed_ip_ranges          = var.operator_ip_ranges
  allowed_subnet_ids         = [module.networking.aks_nodes_subnet_id]
  tags                       = local.tags
}

module "cratedigger_postgres" {
  source = "../../modules/postgres"
  count  = local.cratedigger_count

  name                  = local.cratedigger_psql_name
  location              = var.location
  resource_group_name   = azurerm_resource_group.main.name
  tenant_id             = data.azurerm_client_config.current.tenant_id
  delegated_subnet_id   = module.networking.postgres_subnet_id
  virtual_network_id    = module.networking.vnet_id
  postgres_version      = var.postgres_version
  sku_name              = var.postgres_sku_name
  storage_mb            = var.postgres_storage_mb
  backup_retention_days = var.postgres_backup_retention_days
  operator_admins       = var.postgres_operator_admins
  tags                  = local.tags

  app_admin = {
    object_id      = azurerm_user_assigned_identity.cratedigger[0].principal_id
    principal_name = azurerm_user_assigned_identity.cratedigger[0].name
  }
}

# --- Role assignments (see rbac.tf for the platform-wide table) --------------

resource "azurerm_role_assignment" "cratedigger_kv_secrets_user" {
  count = local.cratedigger_count

  scope                = module.cratedigger_key_vault[0].id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.cratedigger[0].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "operators_cratedigger_kv_secrets_officer" {
  for_each = var.cratedigger_enabled ? toset(var.cluster_admin_object_ids) : toset([])

  scope                = module.cratedigger_key_vault[0].id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = each.value
}

# --- Outputs ----------------------------------------------------------------

output "cratedigger" {
  description = "Values for gitops/environments/dev/cratedigger/values.yaml."
  value = var.cratedigger_enabled ? {
    workload_identity_client_id = azurerm_user_assigned_identity.cratedigger[0].client_id
    key_vault_name              = module.cratedigger_key_vault[0].name
    postgres_fqdn               = module.cratedigger_postgres[0].fqdn
    postgres_user               = azurerm_user_assigned_identity.cratedigger[0].name
    database_url                = "postgresql+psycopg://${azurerm_user_assigned_identity.cratedigger[0].name}@${module.cratedigger_postgres[0].fqdn}:5432/cratedigger?sslmode=require"
    image_repository            = "${module.acr.login_server}/cratedigger/app"
    app_fqdn                    = var.cratedigger_fqdn
  } : null
}
