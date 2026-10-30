output "id" {
  value = azurerm_mysql_flexible_server.this.id
}

output "name" {
  value = azurerm_mysql_flexible_server.this.name
}

output "fqdn" {
  description = "Private FQDN (resolvable only inside the VNet)."
  value       = azurerm_mysql_flexible_server.this.fqdn
}

output "administrator_login" {
  value = azurerm_mysql_flexible_server.this.administrator_login
}
