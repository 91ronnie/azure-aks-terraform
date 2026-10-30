# Azure Database for PostgreSQL Flexible Server, private access only.
#
# - VNet integration: the server gets a private IP in a delegated subnet and is
#   resolved through a private DNS zone linked to the VNet. There is no public
#   endpoint, so it is reachable only from inside the VNet (AKS pods).
# - Microsoft Entra ID authentication only; password authentication disabled.
#   No password exists anywhere (state, Key Vault, Git). Applications log in
#   with their workload identity's access token.
# - Burstable compute, 7-day automated backups (included up to the provisioned
#   storage size), no HA / geo-redundant backup (cost).
#
# The application database itself is created by the app's init step
# (`python -m app.scripts.db_init`) as the app's Entra principal, so that role
# owns it. That avoids PostgreSQL 15+'s restricted `public` schema without any
# SQL bootstrapping from Terraform (which could not reach a private server).

resource "azurerm_private_dns_zone" "this" {
  # Must end in .postgres.database.azure.com for VNet-integrated servers.
  name                = "${var.name}.private.postgres.database.azure.com"
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "this" {
  name                 = "link-${var.name}"
  private_dns_zone_id  = azurerm_private_dns_zone.this.id
  virtual_network_id   = var.virtual_network_id
  registration_enabled = false
  tags                 = var.tags
}

resource "azurerm_postgresql_flexible_server" "this" {
  name                = var.name
  location            = var.location
  resource_group_name = var.resource_group_name
  version             = var.postgres_version
  sku_name            = var.sku_name
  storage_mb          = var.storage_mb
  auto_grow_enabled   = true

  delegated_subnet_id           = var.delegated_subnet_id
  private_dns_zone_id           = azurerm_private_dns_zone.this.id
  public_network_access_enabled = false

  authentication {
    active_directory_auth_enabled = true
    password_auth_enabled         = false
    tenant_id                     = var.tenant_id
  }

  backup_retention_days        = var.backup_retention_days
  geo_redundant_backup_enabled = false

  maintenance_window {
    day_of_week  = 0 # Sunday
    start_hour   = 3
    start_minute = 0
  }

  tags = var.tags

  depends_on = [azurerm_private_dns_zone_virtual_network_link.this]

  lifecycle {
    # Azure picks an availability zone when none is requested; don't fight it.
    ignore_changes = [zone]
  }
}

# Server parameters (free). Applied one at a time: the service rejects
# concurrent configuration changes on the same server.
resource "azurerm_postgresql_flexible_server_configuration" "require_secure_transport" {
  name      = "require_secure_transport"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = "on"
}

resource "azurerm_postgresql_flexible_server_configuration" "ssl_min_protocol_version" {
  name      = "ssl_min_protocol_version"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = "TLSv1.2"

  depends_on = [azurerm_postgresql_flexible_server_configuration.require_secure_transport]
}

resource "azurerm_postgresql_flexible_server_configuration" "log_connections" {
  name      = "log_connections"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = "on"

  depends_on = [azurerm_postgresql_flexible_server_configuration.ssl_min_protocol_version]
}

resource "azurerm_postgresql_flexible_server_configuration" "log_checkpoints" {
  name      = "log_checkpoints"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = "on"

  depends_on = [azurerm_postgresql_flexible_server_configuration.log_connections]
}

# Entra ID administrators. The application identity is an admin so it can
# create and own its database (see header). Operators are optional extra admins.
resource "azurerm_postgresql_flexible_server_active_directory_administrator" "app" {
  depends_on = [azurerm_postgresql_flexible_server_configuration.log_checkpoints]

  server_name         = azurerm_postgresql_flexible_server.this.name
  resource_group_name = var.resource_group_name
  tenant_id           = var.tenant_id
  object_id           = var.app_admin.object_id
  principal_name      = var.app_admin.principal_name
  principal_type      = "ServicePrincipal"
}

resource "azurerm_postgresql_flexible_server_active_directory_administrator" "operators" {
  for_each = var.operator_admins

  server_name         = azurerm_postgresql_flexible_server.this.name
  resource_group_name = var.resource_group_name
  tenant_id           = var.tenant_id
  object_id           = each.value.object_id
  principal_name      = each.value.principal_name
  principal_type      = each.value.principal_type

  # One administrator change at a time per server.
  depends_on = [azurerm_postgresql_flexible_server_active_directory_administrator.app]
}
