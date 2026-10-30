# Azure Database for MySQL Flexible Server, private access only (FrontRow API).
#
# - VNet integration: private IP in a delegated subnet, resolved through a
#   private DNS zone linked to the VNet. No public endpoint.
# - Password authentication: the Laravel application connects with a MySQL
#   user and password (PDO cannot refresh Entra ID tokens). The administrator
#   password is WRITE-ONLY: it is sent to Azure on create/rotation and never
#   stored in Terraform state (administrator_password_wo, Terraform >= 1.11).
# - TLS required (TLS 1.2+). The application user and its grants are created
#   once by an operator (docs/frontrow-api.md#database-user).
# - Burstable compute, 7-day backups, no HA / geo-redundant backup (cost).

resource "azurerm_private_dns_zone" "this" {
  # Must end in .mysql.database.azure.com for VNet-integrated servers.
  name                = "${var.name}.private.mysql.database.azure.com"
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

resource "azurerm_mysql_flexible_server" "this" {
  #checkov:skip=CKV_AZURE_53:Checks the Single Server attribute public_network_access_enabled; this Flexible Server sets public_network_access = "Disabled" and is VNet-integrated.
  name                = var.name
  location            = var.location
  resource_group_name = var.resource_group_name
  version             = var.mysql_version
  sku_name            = var.sku_name

  administrator_login               = var.administrator_login
  administrator_password_wo         = var.administrator_password_wo
  administrator_password_wo_version = var.administrator_password_wo_version

  delegated_subnet_id   = var.delegated_subnet_id
  private_dns_zone_id   = azurerm_private_dns_zone.this.id
  public_network_access = "Disabled"

  storage {
    size_gb           = var.storage_gb
    auto_grow_enabled = true
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

resource "azurerm_mysql_flexible_server_configuration" "require_secure_transport" {
  name                = "require_secure_transport"
  resource_group_name = var.resource_group_name
  server_name         = azurerm_mysql_flexible_server.this.name
  value               = "ON"
}

resource "azurerm_mysql_flexible_server_configuration" "tls_version" {
  name                = "tls_version"
  resource_group_name = var.resource_group_name
  server_name         = azurerm_mysql_flexible_server.this.name
  value               = "TLSv1.2,TLSv1.3"

  depends_on = [azurerm_mysql_flexible_server_configuration.require_secure_transport]
}

resource "azurerm_mysql_flexible_database" "this" {
  for_each = toset(var.databases)

  name                = each.value
  resource_group_name = var.resource_group_name
  server_name         = azurerm_mysql_flexible_server.this.name
  charset             = "utf8mb4"
  collation           = "utf8mb4_unicode_ci"
}
