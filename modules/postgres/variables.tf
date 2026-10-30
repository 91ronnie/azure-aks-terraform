variable "name" {
  description = "Globally unique server name (3-63 lowercase letters, digits, hyphens)."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", var.name))
    error_message = "Server names must be 3-63 lowercase letters, digits or hyphens."
  }
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

variable "delegated_subnet_id" {
  description = "Subnet delegated to Microsoft.DBforPostgreSQL/flexibleServers."
  type        = string
}

variable "virtual_network_id" {
  description = "VNet the private DNS zone is linked to."
  type        = string
}

variable "postgres_version" {
  type    = string
  default = "17"
}

variable "sku_name" {
  description = "Compute SKU. B_Standard_B1ms = Burstable, 1 vCore, 2 GiB."
  type        = string
  default     = "B_Standard_B1ms"
}

variable "storage_mb" {
  description = "Provisioned storage (32768 = 32 GiB, the minimum). Auto-grow is on."
  type        = number
  default     = 32768
}

variable "backup_retention_days" {
  type    = number
  default = 7

  validation {
    condition     = var.backup_retention_days >= 7 && var.backup_retention_days <= 35
    error_message = "backup_retention_days must be between 7 and 35."
  }
}

variable "app_admin" {
  description = "Application identity made Entra admin (principal_name = the identity's name)."
  type = object({
    object_id      = string
    principal_name = string
  })
}

variable "operator_admins" {
  description = "Extra Entra admins (human operators or groups). principal_name is the UPN or group display name."
  type = map(object({
    object_id      = string
    principal_name = string
    principal_type = string # User | Group | ServicePrincipal
  }))
  default = {}

  validation {
    condition     = alltrue([for a in values(var.operator_admins) : contains(["User", "Group", "ServicePrincipal"], a.principal_type)])
    error_message = "principal_type must be User, Group or ServicePrincipal."
  }
}

variable "tags" {
  type = map(string)
}
