output "id" {
  value = azurerm_postgresql_flexible_server.this.id
}

output "name" {
  value = azurerm_postgresql_flexible_server.this.name
}

output "fqdn" {
  description = "Private FQDN (resolvable only inside the VNet)."
  value       = azurerm_postgresql_flexible_server.this.fqdn
}
