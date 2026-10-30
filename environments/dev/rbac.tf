# Every Azure RBAC role assignment in the platform, in one place.
# docs/security.md#identity-and-access explains each one.
#
# | Principal               | Role                                      | Scope            |
# |-------------------------|-------------------------------------------|------------------|
# | AKS control plane       | Managed Identity Operator                 | kubelet identity |
# | AKS control plane       | Network Contributor                       | node subnet      |
# | AKS control plane       | Network Contributor                       | ingress/egress IP|
# | Kubelet                 | AcrPull                                   | ACR              |
# | FrontRow workload       | Key Vault Secrets User                    | Key Vault        |
# | Pipeline (image push)   | AcrPush                                   | ACR              |
# | Human operators         | Azure Kubernetes Service RBAC Cluster Admin | AKS            |
# | Human operators         | Key Vault Secrets Officer                 | Key Vault        |
# | CrateDigger workload    | Key Vault Secrets User                    | CrateDigger KV   |  (cratedigger.tf)
# | CrateDigger workload    | PostgreSQL Entra administrator            | PostgreSQL server|  (cratedigger.tf)
# | Human operators         | Key Vault Secrets Officer                 | CrateDigger KV   |  (cratedigger.tf)
# | FrontRow API workload   | Key Vault Secrets User                    | API Key Vault    |  (api.tf)
# | Human operators         | Key Vault Secrets Officer                 | API Key Vault    |  (api.tf)
#
# Not granted on purpose: the pipeline has no AKS role at all, Argo CD has no
# Azure role, nothing has Owner/Contributor.

# --- AKS control plane ------------------------------------------------------

# Required when the cluster uses a user-assigned kubelet identity.
resource "azurerm_role_assignment" "control_plane_managed_identity_operator" {
  scope                = module.identity.kubelet.id
  role_definition_name = "Managed Identity Operator"
  principal_id         = module.identity.control_plane.principal_id
  principal_type       = "ServicePrincipal"
}

# Bring-your-own subnet: AKS must join NICs/LB to it.
resource "azurerm_role_assignment" "control_plane_network_subnet" {
  scope                = module.networking.aks_nodes_subnet_id
  role_definition_name = "Network Contributor"
  principal_id         = module.identity.control_plane.principal_id
  principal_type       = "ServicePrincipal"
}

# Static IPs live in our resource group, not the AKS node resource group.
resource "azurerm_role_assignment" "control_plane_network_egress_ip" {
  scope                = module.networking.egress_public_ip_id
  role_definition_name = "Network Contributor"
  principal_id         = module.identity.control_plane.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "control_plane_network_ingress_ip" {
  scope                = module.networking.ingress_public_ip_id
  role_definition_name = "Network Contributor"
  principal_id         = module.identity.control_plane.principal_id
  principal_type       = "ServicePrincipal"
}

# --- Kubelet: pull images ---------------------------------------------------

resource "azurerm_role_assignment" "kubelet_acr_pull" {
  scope                = module.acr.id
  role_definition_name = "AcrPull"
  principal_id         = module.identity.kubelet.principal_id
  principal_type       = "ServicePrincipal"
}

# --- FrontRow workload: read secrets (only used if the chart enables Key Vault) ---

resource "azurerm_role_assignment" "workload_kv_secrets_user" {
  scope                = module.key_vault.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = module.identity.workload.principal_id
  principal_type       = "ServicePrincipal"
}

# --- Azure DevOps pipeline: push images, nothing else -----------------------

resource "azurerm_role_assignment" "pipeline_acr_push" {
  count = var.pipeline_acr_push_principal_id == null ? 0 : 1

  scope                = module.acr.id
  role_definition_name = "AcrPush"
  principal_id         = var.pipeline_acr_push_principal_id
  principal_type       = "ServicePrincipal"
}

# --- Human operators --------------------------------------------------------

resource "azurerm_role_assignment" "operators_aks_cluster_admin" {
  for_each = toset(var.cluster_admin_object_ids)

  scope                = module.aks.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = each.value
}

resource "azurerm_role_assignment" "operators_kv_secrets_officer" {
  for_each = toset(var.cluster_admin_object_ids)

  scope                = module.key_vault.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = each.value
}
