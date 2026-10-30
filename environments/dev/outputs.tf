# Outputs contain identifiers only. Nothing here is a secret: client IDs of
# managed identities are public identifiers (possession grants nothing without
# a federated token), and no kubeconfig or key is exported.

output "resource_group_name" {
  value = azurerm_resource_group.main.name
}

output "aks_cluster_name" {
  value = module.aks.name
}

output "aks_node_resource_group" {
  value = module.aks.node_resource_group
}

output "aks_oidc_issuer_url" {
  value = module.aks.oidc_issuer_url
}

output "aks_kubernetes_version" {
  value = module.aks.kubernetes_version
}

output "get_credentials_command" {
  description = "Fetch a kubeconfig that uses Entra ID (kubelogin) - no static credentials."
  value       = "az aks get-credentials --resource-group ${azurerm_resource_group.main.name} --name ${module.aks.name} && kubelogin convert-kubeconfig -l azurecli"
}

output "acr_name" {
  value = module.acr.name
}

output "acr_login_server" {
  value = module.acr.login_server
}

output "frontrow_image_repository" {
  value = "${module.acr.login_server}/frontrow/web"
}

output "key_vault_name" {
  value = module.key_vault.name
}

output "key_vault_uri" {
  value = module.key_vault.vault_uri
}

output "workload_identity_client_id" {
  description = "Put in the Helm values: serviceAccount.workloadIdentityClientId."
  value       = module.identity.workload.client_id
}

output "argocd_identity_client_id" {
  description = "Put in gitops/argocd/values.yaml if Argo CD uses workload identity for Azure Repos."
  value       = module.identity.argocd.client_id
}

output "tenant_id" {
  value = data.azurerm_client_config.current.tenant_id
}

output "ingress_public_ip_name" {
  description = "Referenced by the Traefik service annotation azure-pip-name."
  value       = module.networking.ingress_public_ip_name
}

output "ingress_public_ip_address" {
  value = module.networking.ingress_public_ip_address
}

output "ingress_public_ip_fqdn" {
  value = module.networking.ingress_public_ip_fqdn
}

output "egress_public_ip_address" {
  description = "All outbound traffic from the cluster uses this address (allow-list it where needed)."
  value       = module.networking.egress_public_ip_address
}

output "log_analytics_workspace_name" {
  value = module.monitoring.log_analytics_workspace_name
}

output "cloudflare_dns_record" {
  description = "The record to create in Cloudflare once the ingress is serving."
  value = {
    type    = "A"
    name    = var.app_fqdn
    content = module.networking.ingress_public_ip_address
    proxied = "false initially (DNS only); enable after HTTPS works at the origin"
  }
}
