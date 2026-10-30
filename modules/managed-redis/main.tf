# Azure Managed Redis (FrontRow API cache + queues), private endpoint only.
#
# - Azure Managed Redis is the successor of Azure Cache for Redis.
# - EnterpriseCluster policy: one endpoint that behaves like a single Redis
#   node, so Laravel's phpredis client and its multi-key queue scripts work
#   without cluster mode or hash tags.
# - NoEviction: the database holds Laravel queues; dropping keys under memory
#   pressure would silently lose jobs. A full database rejects writes instead.
# - Access-key authentication (phpredis has no Entra ID token support). The key
#   is copied into Key Vault by an operator; it is never written by Terraform.
# - TLS on port 10000; public network access disabled.

resource "azurerm_managed_redis" "this" {
  name                      = var.name
  location                  = var.location
  resource_group_name       = var.resource_group_name
  sku_name                  = var.sku_name
  high_availability_enabled = var.high_availability_enabled
  public_network_access     = "Disabled"

  default_database {
    access_keys_authentication_enabled = true
    client_protocol                    = "Encrypted"
    clustering_policy                  = "EnterpriseCluster"
    eviction_policy                    = "NoEviction"
  }

  tags = var.tags
}

resource "azurerm_private_dns_zone" "this" {
  name                = "privatelink.redis.azure.net"
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

resource "azurerm_private_endpoint" "this" {
  name                = "pe-${var.name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.private_endpoint_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-${var.name}"
    private_connection_resource_id = azurerm_managed_redis.this.id
    subresource_names              = ["redisEnterprise"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.this.id]
  }
}
