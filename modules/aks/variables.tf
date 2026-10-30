variable "name_prefix" {
  type = string
}

variable "location" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "tenant_id" {
  type = string
}

variable "sku_tier" {
  description = "Free (no SLA) or Standard (uptime SLA, billed per cluster-hour)."
  type        = string
  default     = "Free"

  validation {
    condition     = contains(["Free", "Standard"], var.sku_tier)
    error_message = "sku_tier must be Free or Standard."
  }
}

variable "kubernetes_version" {
  description = "Kubernetes minor version, e.g. \"1.34\". null = AKS default at creation."
  type        = string
  default     = null
}

variable "automatic_upgrade_channel" {
  description = "patch keeps the pinned minor version patched; none disables auto-upgrade."
  type        = string
  default     = "patch"

  validation {
    condition     = contains(["none", "patch", "stable", "rapid", "node-image"], var.automatic_upgrade_channel)
    error_message = "Invalid automatic_upgrade_channel."
  }
}

variable "api_server_authorized_ip_ranges" {
  description = "CIDRs allowed to reach the public API server (your workstation/VPN egress)."
  type        = list(string)

  validation {
    condition     = length(var.api_server_authorized_ip_ranges) > 0 && !contains(var.api_server_authorized_ip_ranges, "0.0.0.0/0")
    error_message = "Provide at least one CIDR and do not use 0.0.0.0/0."
  }
}

variable "control_plane_identity_id" {
  type = string
}

variable "kubelet_identity" {
  type = object({
    id           = string
    client_id    = string
    principal_id = string
  })
}

variable "node_subnet_id" {
  type = string
}

variable "node_vm_size" {
  description = "Node VM size. Must have >= 2 vCPU and >= 4 GiB for a system pool."
  type        = string
  default     = "Standard_D2as_v5"
}

variable "node_os_disk_type" {
  description = "Managed or Ephemeral. Ephemeral needs a VM size with a large enough cache/temp disk (e.g. Standard_D2ads_v5)."
  type        = string
  default     = "Managed"

  validation {
    condition     = contains(["Managed", "Ephemeral"], var.node_os_disk_type)
    error_message = "node_os_disk_type must be Managed or Ephemeral."
  }
}

variable "node_os_disk_size_gb" {
  type    = number
  default = 64
}

variable "host_encryption_enabled" {
  description = "Encryption at host for node disks/caches (requires the Microsoft.Compute/EncryptionAtHost feature)."
  type        = bool
  default     = true
}

variable "node_max_pods" {
  type    = number
  default = 110
}

variable "node_min_count" {
  type    = number
  default = 1
}

variable "node_max_count" {
  type    = number
  default = 2

  validation {
    condition     = var.node_max_count >= 1 && var.node_max_count <= 10
    error_message = "node_max_count must be between 1 and 10 for this lab."
  }
}

variable "pod_cidr" {
  type = string
}

variable "service_cidr" {
  type = string
}

variable "dns_service_ip" {
  type = string
}

variable "egress_public_ip_id" {
  type = string
}

variable "azure_policy_enabled" {
  type    = bool
  default = false
}

variable "container_insights_enabled" {
  description = "Enable the monitoring (Container Insights) add-on."
  type        = bool
  default     = true
}

variable "log_analytics_workspace_id" {
  description = "Workspace for Container Insights."
  type        = string
}

variable "maintenance_day_of_week" {
  type    = string
  default = "Sunday"
}

variable "maintenance_start_time" {
  type    = string
  default = "02:00"
}

variable "maintenance_utc_offset" {
  type    = string
  default = "+03:00"
}

variable "tags" {
  type = map(string)
}
