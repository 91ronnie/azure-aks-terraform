output "id" {
  value = azurerm_kubernetes_cluster.this.id
}

output "name" {
  value = azurerm_kubernetes_cluster.this.name
}

output "node_resource_group" {
  value = azurerm_kubernetes_cluster.this.node_resource_group
}

output "oidc_issuer_url" {
  value = azurerm_kubernetes_cluster.this.oidc_issuer_url
}

output "kubernetes_version" {
  value = azurerm_kubernetes_cluster.this.current_kubernetes_version
}

output "key_vault_secrets_provider_identity" {
  description = "Add-on identity created by AKS for the CSI driver (not used with workload identity)."
  value       = try(azurerm_kubernetes_cluster.this.key_vault_secrets_provider[0].secret_identity[0].object_id, null)
}
