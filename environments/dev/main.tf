data "azurerm_client_config" "current" {}

locals {
  name_prefix = "${var.project}-${var.environment}"

  # Globally unique names cannot contain hyphens (ACR) or exceed 24 chars (Key Vault).
  acr_name       = "acr${var.project}${var.environment}${var.unique_suffix}"
  key_vault_name = "kv-${var.project}-${var.environment}-${var.unique_suffix}"

  tags = {
    project     = var.project
    environment = var.environment
    owner       = var.owner
    cost-center = var.cost_center
    managed-by  = "terraform"
    repository  = "azure-aks-terraform"
  }
}

resource "azurerm_resource_group" "main" {
  name     = "rg-${local.name_prefix}"
  location = var.location
  tags     = local.tags
}

module "networking" {
  source = "../../modules/networking"

  name_prefix                     = local.name_prefix
  location                        = var.location
  resource_group_name             = azurerm_resource_group.main.name
  vnet_cidr                       = var.vnet_cidr
  aks_nodes_subnet_cidr           = var.aks_nodes_subnet_cidr
  ingress_allowed_source_prefixes = var.ingress_allowed_source_prefixes
  ingress_domain_name_label       = "${local.name_prefix}-${var.unique_suffix}"
  postgres_subnet_cidr            = var.cratedigger_enabled ? var.postgres_subnet_cidr : null
  mysql_subnet_cidr               = var.api_enabled ? var.mysql_subnet_cidr : null
  private_endpoints_subnet_cidr   = var.api_enabled ? var.private_endpoints_subnet_cidr : null
  tags                            = local.tags
}

module "identity" {
  source = "../../modules/identity"

  name_prefix              = local.name_prefix
  location                 = var.location
  resource_group_name      = azurerm_resource_group.main.name
  oidc_issuer_url          = module.aks.oidc_issuer_url
  workload_namespace       = var.app_namespace
  workload_service_account = var.app_service_account
  tags                     = local.tags
}

module "monitoring" {
  source = "../../modules/monitoring"

  name_prefix                = local.name_prefix
  location                   = var.location
  resource_group_name        = azurerm_resource_group.main.name
  resource_group_id          = azurerm_resource_group.main.id
  aks_cluster_id             = module.aks.id
  container_insights_enabled = var.container_insights_enabled
  log_retention_days         = var.log_retention_days
  log_daily_quota_gb         = var.log_daily_quota_gb
  alert_email                = var.alert_email
  monthly_budget_amount      = var.monthly_budget_amount
  budget_start_date          = var.budget_start_date
  tags                       = local.tags
}

module "acr" {
  source = "../../modules/acr"

  name                = local.acr_name
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = var.acr_sku
  purge_task_enabled  = var.acr_purge_task_enabled
  tags                = local.tags
}

module "key_vault" {
  source = "../../modules/key-vault"

  name                       = local.key_vault_name
  location                   = var.location
  resource_group_name        = azurerm_resource_group.main.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  soft_delete_retention_days = var.key_vault_soft_delete_retention_days
  allowed_ip_ranges          = var.operator_ip_ranges
  allowed_subnet_ids         = [module.networking.aks_nodes_subnet_id]
  tags                       = local.tags
}

module "aks" {
  source = "../../modules/aks"

  name_prefix                     = local.name_prefix
  location                        = var.location
  resource_group_name             = azurerm_resource_group.main.name
  tenant_id                       = data.azurerm_client_config.current.tenant_id
  sku_tier                        = var.aks_sku_tier
  kubernetes_version              = var.kubernetes_version
  api_server_authorized_ip_ranges = var.operator_ip_ranges
  control_plane_identity_id       = module.identity.control_plane.id
  kubelet_identity                = module.identity.kubelet
  node_subnet_id                  = module.networking.aks_nodes_subnet_id
  node_vm_size                    = var.node_vm_size
  node_os_disk_type               = var.node_os_disk_type
  node_os_disk_size_gb            = var.node_os_disk_size_gb
  node_min_count                  = var.node_min_count
  node_max_count                  = var.node_max_count
  host_encryption_enabled         = var.host_encryption_enabled
  pod_cidr                        = var.pod_cidr
  service_cidr                    = var.service_cidr
  dns_service_ip                  = var.dns_service_ip
  egress_public_ip_id             = module.networking.egress_public_ip_id
  azure_policy_enabled            = var.azure_policy_enabled
  container_insights_enabled      = var.container_insights_enabled
  log_analytics_workspace_id      = module.monitoring.log_analytics_workspace_id
  tags                            = local.tags

  # AKS validates these permissions while creating the cluster.
  depends_on = [
    azurerm_role_assignment.control_plane_managed_identity_operator,
    azurerm_role_assignment.control_plane_network_subnet,
    azurerm_role_assignment.control_plane_network_egress_ip,
  ]
}
