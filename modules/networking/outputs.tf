output "vnet_id" {
  value = azurerm_virtual_network.this.id
}

output "aks_nodes_subnet_id" {
  value = azurerm_subnet.aks_nodes.id
}

output "ingress_public_ip_id" {
  value = azurerm_public_ip.ingress.id
}

output "ingress_public_ip_name" {
  value = azurerm_public_ip.ingress.name
}

output "ingress_public_ip_address" {
  value = azurerm_public_ip.ingress.ip_address
}

output "ingress_public_ip_fqdn" {
  value = azurerm_public_ip.ingress.fqdn
}

output "egress_public_ip_id" {
  value = azurerm_public_ip.egress.id
}

output "egress_public_ip_address" {
  value = azurerm_public_ip.egress.ip_address
}

output "vnet_name" {
  value = azurerm_virtual_network.this.name
}

output "postgres_subnet_id" {
  value = try(azurerm_subnet.postgres[0].id, null)
}

output "postgres_subnet_cidr" {
  value = var.postgres_subnet_cidr
}

output "mysql_subnet_id" {
  value = try(azurerm_subnet.mysql[0].id, null)
}

output "mysql_subnet_cidr" {
  value = var.mysql_subnet_cidr
}

output "private_endpoints_subnet_id" {
  value = try(azurerm_subnet.private_endpoints[0].id, null)
}

output "private_endpoints_subnet_cidr" {
  value = var.private_endpoints_subnet_cidr
}
