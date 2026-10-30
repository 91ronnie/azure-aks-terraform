output "control_plane" {
  description = "AKS control-plane identity."
  value = {
    id           = azurerm_user_assigned_identity.control_plane.id
    client_id    = azurerm_user_assigned_identity.control_plane.client_id
    principal_id = azurerm_user_assigned_identity.control_plane.principal_id
  }
}

output "kubelet" {
  description = "Kubelet identity."
  value = {
    id           = azurerm_user_assigned_identity.kubelet.id
    client_id    = azurerm_user_assigned_identity.kubelet.client_id
    principal_id = azurerm_user_assigned_identity.kubelet.principal_id
  }
}

output "workload" {
  description = "FrontRow workload identity."
  value = {
    id           = azurerm_user_assigned_identity.workload.id
    client_id    = azurerm_user_assigned_identity.workload.client_id
    principal_id = azurerm_user_assigned_identity.workload.principal_id
  }
}

output "argocd" {
  description = "Argo CD identity."
  value = {
    id           = azurerm_user_assigned_identity.argocd.id
    client_id    = azurerm_user_assigned_identity.argocd.client_id
    principal_id = azurerm_user_assigned_identity.argocd.principal_id
  }
}
