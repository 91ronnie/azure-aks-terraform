# FrontRow API (Laravel backend): everything it needs, in one file.
#
#   id-frontrow-dev-api        workload identity for the API pods (Key Vault read)
#   kv-api-dev-<suffix>        its own Key Vault (APP_KEY, DB/Redis/storage
#                              credentials, Passport keys, third-party API keys)
#   mysql-frontrow-dev-<sfx>   MySQL Flexible Server, private; databases
#                              "frontrow" (DB_*) and "frontrow_mqtt" (DB2_*)
#   redis-frontrow-dev-<sfx>   Azure Managed Redis behind a private endpoint
#                              (cache + Laravel queues)
#   st<project>api<env><sfx>   Blob storage; one private container per former
#                              S3 bucket (files, masked-images, telemedicine)
#   acs-/ecs-frontrow-dev      Azure Communication Services Email (SMTP relay)
#
# Terraform writes no secret anywhere: the MySQL admin password is write-only,
# and Redis/storage keys are copied into Key Vault by an operator
# (docs/frontrow-api.md). Toggle the whole app with api_enabled.

locals {
  api_count        = var.api_enabled ? 1 : 0
  api_kv_name      = "kv-api-${var.environment}-${var.unique_suffix}"
  api_mysql_name   = "mysql-${local.name_prefix}-${var.unique_suffix}"
  api_redis_name   = "redis-${local.name_prefix}-${var.unique_suffix}"
  api_storage_name = "st${var.project}api${var.environment}${var.unique_suffix}"

  # One container per S3 bucket the application used (config/filesystems.php).
  api_storage_containers = ["files", "masked-images", "telemedicine"]

  api_databases = ["frontrow", "frontrow_mqtt"]
}

resource "azurerm_user_assigned_identity" "api" {
  count = local.api_count

  name                = "id-${local.name_prefix}-api"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags
}

resource "azurerm_federated_identity_credential" "api" {
  count = local.api_count

  name                      = "fic-api-sa"
  user_assigned_identity_id = azurerm_user_assigned_identity.api[0].id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = module.aks.oidc_issuer_url
  subject                   = "system:serviceaccount:${var.api_namespace}:${var.api_service_account}"
}

module "api_key_vault" {
  source = "../../modules/key-vault"
  count  = local.api_count

  name                       = local.api_kv_name
  location                   = var.location
  resource_group_name        = azurerm_resource_group.main.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  soft_delete_retention_days = var.key_vault_soft_delete_retention_days
  allowed_ip_ranges          = var.operator_ip_ranges
  allowed_subnet_ids         = [module.networking.aks_nodes_subnet_id]
  tags                       = local.tags
}

# --- MySQL ------------------------------------------------------------------

module "api_mysql" {
  source = "../../modules/mysql"
  count  = local.api_count

  name                              = local.api_mysql_name
  location                          = var.location
  resource_group_name               = azurerm_resource_group.main.name
  delegated_subnet_id               = module.networking.mysql_subnet_id
  virtual_network_id                = module.networking.vnet_id
  mysql_version                     = var.mysql_version
  sku_name                          = var.mysql_sku_name
  storage_gb                        = var.mysql_storage_gb
  backup_retention_days             = var.mysql_backup_retention_days
  administrator_password_wo         = var.mysql_admin_password
  administrator_password_wo_version = var.mysql_admin_password_version
  databases                         = local.api_databases
  tags                              = local.tags
}

# --- Redis ------------------------------------------------------------------

module "api_redis" {
  source = "../../modules/managed-redis"
  count  = local.api_count

  name                       = local.api_redis_name
  location                   = var.location
  resource_group_name        = azurerm_resource_group.main.name
  sku_name                   = var.redis_sku_name
  virtual_network_id         = module.networking.vnet_id
  private_endpoint_subnet_id = module.networking.private_endpoints_subnet_id
  tags                       = local.tags
}

# --- Blob storage (replaces S3) ---------------------------------------------

resource "azurerm_storage_account" "api" {
  count = local.api_count

  #checkov:skip=CKV_AZURE_59:Browsers download files through SAS links (temporaryUrl), so the endpoint must be public; containers are private and anonymous access is off.
  #checkov:skip=CKV2_AZURE_33:No private endpoint for the same reason (SAS links are opened by browsers on the Internet).
  #checkov:skip=CKV2_AZURE_40:Shared key is required: the PHP SDK signs SAS URLs only with the account key (no user-delegation SAS).
  #checkov:skip=CKV2_AZURE_1:Microsoft-managed keys are sufficient for the dev environment.
  #checkov:skip=CKV_AZURE_206:LRS is a deliberate cost choice for dev; soft delete covers accidental deletion.
  #checkov:skip=CKV_AZURE_33:Queue service is not used, so queue logging does not apply.
  name                     = local.api_storage_name
  location                 = var.location
  resource_group_name      = azurerm_resource_group.main.name
  account_kind             = "StorageV2"
  account_tier             = "Standard"
  account_replication_type = "LRS"
  access_tier              = "Hot"

  https_traffic_only_enabled       = true
  min_tls_version                  = "TLS1_2"
  allow_nested_items_to_be_public  = false
  shared_access_key_enabled        = true
  public_network_access            = "Enabled"
  cross_tenant_replication_enabled = false
  local_user_enabled               = false
  sftp_enabled                     = false

  sas_policy {
    # SAS links issued by the app live 1 hour to 1 day; refuse anything longer.
    expiration_period = "1.00:00:00"
    expiration_action = "Log"
  }

  blob_properties {
    versioning_enabled = true

    delete_retention_policy {
      days = var.api_storage_soft_delete_days
    }

    container_delete_retention_policy {
      days = var.api_storage_soft_delete_days
    }

    # Lets the web app fetch() a SAS URL (images/PDF previews). Read-only.
    cors_rule {
      allowed_origins    = ["https://${var.app_fqdn}"]
      allowed_methods    = ["GET", "HEAD"]
      allowed_headers    = ["*"]
      exposed_headers    = ["Content-Length", "Content-Type", "ETag"]
      max_age_in_seconds = 3600
    }
  }

  tags = local.tags
}

resource "azurerm_storage_container" "api" {
  for_each = var.api_enabled ? toset(local.api_storage_containers) : toset([])

  #checkov:skip=CKV2_AZURE_21:Blob read logging is configured with diagnostic settings, not per container.
  name                  = each.value
  storage_account_id    = azurerm_storage_account.api[0].id
  container_access_type = "private"
}

# --- Email (replaces SES) ---------------------------------------------------

resource "azurerm_email_communication_service" "api" {
  count = local.api_count

  name                = "ecs-${local.name_prefix}"
  resource_group_name = azurerm_resource_group.main.name
  data_location       = var.api_email_data_location
  tags                = local.tags
}

# Customer-managed domain: Azure shows TXT/SPF/DKIM records to add in
# Cloudflare (output api.email_verification_records), then verify in the portal.
resource "azurerm_email_communication_service_domain" "api" {
  count = local.api_count

  name                             = var.api_email_domain
  email_service_id                 = azurerm_email_communication_service.api[0].id
  domain_management                = "CustomerManaged"
  user_engagement_tracking_enabled = false
  tags                             = local.tags
}

resource "azurerm_email_communication_service_domain_sender_username" "api" {
  count = local.api_count

  name                    = var.api_email_sender_username
  email_service_domain_id = azurerm_email_communication_service_domain.api[0].id
  display_name            = "FrontRow"
}

resource "azurerm_communication_service" "api" {
  count = local.api_count

  name                = "acs-${local.name_prefix}"
  resource_group_name = azurerm_resource_group.main.name
  data_location       = var.api_email_data_location
  tags                = local.tags
}

# Linking succeeds only after the domain is verified (DNS records in place).
resource "azurerm_communication_service_email_domain_association" "api" {
  count = var.api_enabled && var.api_email_domain_verified ? 1 : 0

  communication_service_id = azurerm_communication_service.api[0].id
  email_service_domain_id  = azurerm_email_communication_service_domain.api[0].id
}

# --- Role assignments (see rbac.tf for the platform-wide table) --------------

resource "azurerm_role_assignment" "api_kv_secrets_user" {
  count = local.api_count

  scope                = module.api_key_vault[0].id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.api[0].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "operators_api_kv_secrets_officer" {
  for_each = var.api_enabled ? toset(var.cluster_admin_object_ids) : toset([])

  scope                = module.api_key_vault[0].id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = each.value
}

# --- Outputs ----------------------------------------------------------------

output "api" {
  description = "Values for gitops/environments/dev/frontrow-api/values.yaml and docs/frontrow-api.md."
  value = var.api_enabled ? {
    workload_identity_client_id = azurerm_user_assigned_identity.api[0].client_id
    key_vault_name              = module.api_key_vault[0].name
    mysql_server_name           = module.api_mysql[0].name
    mysql_fqdn                  = module.api_mysql[0].fqdn
    mysql_admin_login           = module.api_mysql[0].administrator_login
    mysql_databases             = local.api_databases
    redis_name                  = module.api_redis[0].name
    redis_hostname              = module.api_redis[0].hostname
    redis_port                  = module.api_redis[0].port
    storage_account_name        = azurerm_storage_account.api[0].name
    storage_containers          = local.api_storage_containers
    communication_service_name  = azurerm_communication_service.api[0].name
    email_from_address          = "${var.api_email_sender_username}@${var.api_email_domain}"
    email_verification_records  = azurerm_email_communication_service_domain.api[0].verification_records
    image_repository            = "${module.acr.login_server}/frontrow/api"
    web_image_repository        = "${module.acr.login_server}/frontrow/api-web"
    app_fqdn                    = var.api_fqdn
  } : null
}
