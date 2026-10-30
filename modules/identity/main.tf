# User-assigned managed identities, one per responsibility.
#
#   control_plane  AKS itself (manages LB, public IPs, routes in our VNet)
#   kubelet        Node agent; pulls images from ACR (AcrPull only)
#   workload       FrontRow pods, via workload identity (Key Vault read, if used)
#   argocd         Argo CD repo-server/controller, via workload identity
#                  (optional Azure DevOps Repos access; no Azure RBAC by default)
#
# Role assignments are deliberately NOT made here. They are listed together in
# environments/<env>/rbac.tf so the whole permission model can be read in one file.

resource "azurerm_user_assigned_identity" "control_plane" {
  name                = "id-${var.name_prefix}-aks"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_user_assigned_identity" "kubelet" {
  name                = "id-${var.name_prefix}-kubelet"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_user_assigned_identity" "workload" {
  name                = "id-${var.name_prefix}-frontrow"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_user_assigned_identity" "argocd" {
  name                = "id-${var.name_prefix}-argocd"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

# Federated credentials trust tokens issued by the cluster's OIDC issuer for one
# exact Kubernetes service account. No client secret exists anywhere.

resource "azurerm_federated_identity_credential" "workload" {
  name                      = "fic-frontrow-sa"
  user_assigned_identity_id = azurerm_user_assigned_identity.workload.id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = var.oidc_issuer_url
  subject                   = "system:serviceaccount:${var.workload_namespace}:${var.workload_service_account}"
}

# Entra ID rejects concurrent writes of federated credentials on the same
# identity, so the Argo CD credentials are chained with depends_on.

resource "azurerm_federated_identity_credential" "argocd_repo_server" {
  name                      = "fic-argocd-repo-server"
  user_assigned_identity_id = azurerm_user_assigned_identity.argocd.id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = var.oidc_issuer_url
  subject                   = "system:serviceaccount:${var.argocd_namespace}:argocd-repo-server"
}

resource "azurerm_federated_identity_credential" "argocd_application_controller" {
  name                      = "fic-argocd-application-controller"
  user_assigned_identity_id = azurerm_user_assigned_identity.argocd.id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = var.oidc_issuer_url
  subject                   = "system:serviceaccount:${var.argocd_namespace}:argocd-application-controller"

  depends_on = [azurerm_federated_identity_credential.argocd_repo_server]
}

resource "azurerm_federated_identity_credential" "argocd_server" {
  name                      = "fic-argocd-server"
  user_assigned_identity_id = azurerm_user_assigned_identity.argocd.id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = var.oidc_issuer_url
  subject                   = "system:serviceaccount:${var.argocd_namespace}:argocd-server"

  depends_on = [azurerm_federated_identity_credential.argocd_application_controller]
}
