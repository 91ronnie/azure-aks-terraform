output "id" {
  value = azurerm_managed_redis.this.id
}

output "name" {
  value = azurerm_managed_redis.this.name
}

output "hostname" {
  description = "Resolves to the private endpoint inside the VNet."
  value       = azurerm_managed_redis.this.hostname
}

output "port" {
  value = azurerm_managed_redis.this.default_database[0].port
}
