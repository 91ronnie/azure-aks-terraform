# AKS cluster for the FrontRow lab.
#
# Key decisions (details in docs/architecture-decisions.md):
#   - Free control-plane tier (no uptime SLA). Standard tier = uptime SLA, paid hourly.
#   - Public API server restricted to authorized_ip_ranges. Private cluster is
#     documented as the production alternative.
#   - Entra ID authentication + Azure RBAC for Kubernetes; local accounts disabled,
#     so there is no static cluster-admin certificate to leak.
#   - Azure CNI Overlay + Cilium: pods don't consume VNet IPs; NetworkPolicy is enforced.
#   - Static, Terraform-owned egress IP on the Standard Load Balancer (no NAT Gateway).
#   - OIDC issuer + workload identity for pods; Key Vault CSI driver add-on.
#   - Automatic patch upgrades and weekly node-image upgrades in a maintenance window.

resource "azurerm_kubernetes_cluster" "this" {
  #checkov:skip=CKV_AZURE_227:Enabled through var.host_encryption_enabled (default true); Checkov cannot resolve the module variable.
  name                = "aks-${var.name_prefix}"
  location            = var.location
  resource_group_name = var.resource_group_name
  dns_prefix          = "aks-${var.name_prefix}"
  node_resource_group = "rg-${var.name_prefix}-aks-nodes"

  sku_tier = var.sku_tier

  # null = AKS picks the current default GA version at creation time.
  # Pin (e.g. "1.34") once created so upgrades are deliberate; see docs/deployment-runbook.md#upgrades.
  kubernetes_version = var.kubernetes_version

  automatic_upgrade_channel = var.automatic_upgrade_channel
  node_os_upgrade_channel   = "NodeImage"

  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  local_account_disabled            = true
  role_based_access_control_enabled = true

  azure_active_directory_role_based_access_control {
    tenant_id          = var.tenant_id
    azure_rbac_enabled = true
  }

  api_server_access_profile {
    authorized_ip_ranges = var.api_server_authorized_ip_ranges
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [var.control_plane_identity_id]
  }

  kubelet_identity {
    client_id                 = var.kubelet_identity.client_id
    object_id                 = var.kubelet_identity.principal_id
    user_assigned_identity_id = var.kubelet_identity.id
  }

  default_node_pool {
    name                        = "system"
    temporary_name_for_rotation = "systemtmp"
    vm_size                     = var.node_vm_size
    vnet_subnet_id              = var.node_subnet_id
    os_sku                      = "AzureLinux"
    os_disk_type                = var.node_os_disk_type
    os_disk_size_gb             = var.node_os_disk_size_gb
    max_pods                    = var.node_max_pods

    # Encrypts temp disks, OS/data disk caches and the VM-to-storage data flow.
    # No extra cost; needs the EncryptionAtHost feature registered once per
    # subscription (docs/prerequisites.md).
    host_encryption_enabled = var.host_encryption_enabled

    auto_scaling_enabled = true
    min_count            = var.node_min_count
    max_count            = var.node_max_count

    # One small pool runs both system add-ons and the FrontRow workload. A
    # dedicated user pool is the production pattern (see docs).
    only_critical_addons_enabled = false

    upgrade_settings {
      max_surge                     = "1"
      drain_timeout_in_minutes      = 30
      node_soak_duration_in_minutes = 0
    }

    tags = var.tags
  }

  # Manual = classic cluster autoscaler on the node pool below. "Auto" would
  # enable Node Auto Provisioning (Karpenter-based); not needed for one pool.
  node_provisioning_profile {
    mode = "Manual"
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_data_plane  = "cilium"
    network_policy      = "cilium"
    pod_cidr            = var.pod_cidr
    service_cidr        = var.service_cidr
    dns_service_ip      = var.dns_service_ip
    load_balancer_sku   = "standard"
    outbound_type       = "loadBalancer"

    load_balancer_profile {
      outbound_ip_address_ids = [var.egress_public_ip_id]
      idle_timeout_in_minutes = 4
    }
  }

  key_vault_secrets_provider {
    secret_rotation_enabled  = true
    secret_rotation_interval = "2m"
  }

  # Azure Policy add-on (Gatekeeper) is free but uses ~0.2 vCPU / 300 MiB on a
  # tiny node. Pod Security Admission labels are used instead by default.
  azure_policy_enabled = var.azure_policy_enabled

  # No persistent storage is needed by FrontRow; keep only the Azure Disk CSI
  # driver for exercises and future use. Files/Blob/snapshots are disabled to
  # save node memory.
  storage_profile {
    disk_driver_enabled         = true
    file_driver_enabled         = false
    blob_driver_enabled         = false
    snapshot_controller_enabled = false
  }

  image_cleaner_enabled        = true
  image_cleaner_interval_hours = 48

  dynamic "oms_agent" {
    for_each = var.container_insights_enabled ? [1] : []
    content {
      log_analytics_workspace_id      = var.log_analytics_workspace_id
      msi_auth_for_monitoring_enabled = true
    }
  }

  maintenance_window_auto_upgrade {
    frequency   = "Weekly"
    interval    = 1
    duration    = 4
    day_of_week = var.maintenance_day_of_week
    start_time  = var.maintenance_start_time
    utc_offset  = var.maintenance_utc_offset
  }

  maintenance_window_node_os {
    frequency   = "Weekly"
    interval    = 1
    duration    = 4
    day_of_week = var.maintenance_day_of_week
    start_time  = var.maintenance_start_time
    utc_offset  = var.maintenance_utc_offset
  }

  tags = var.tags

  lifecycle {
    ignore_changes = [
      # The cluster autoscaler owns the current node count.
      default_node_pool[0].node_count,
    ]
  }
}
