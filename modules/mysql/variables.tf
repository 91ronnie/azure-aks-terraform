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

variable "delegated_subnet_id" {
  description = "Subnet delegated to Microsoft.DBforMySQL/flexibleServers."
  type        = string
}

variable "virtual_network_id" {
  description = "VNet the private DNS zone is linked to."
  type        = string
}

variable "mysql_version" {
  description = "MySQL major version (8.0.21 or 8.4)."
  type        = string
  default     = "8.4"
}

variable "sku_name" {
  description = "Compute SKU. B_Standard_B1ms = Burstable, 1 vCore, 2 GiB."
  type        = string
  default     = "B_Standard_B1ms"
}

variable "storage_gb" {
  description = "Provisioned storage in GiB (minimum 20). Auto-grow is on."
  type        = number
  default     = 20
}

variable "backup_retention_days" {
  type    = number
  default = 7

  validation {
    condition     = var.backup_retention_days >= 1 && var.backup_retention_days <= 35
    error_message = "backup_retention_days must be between 1 and 35."
  }
}

variable "administrator_login" {
  type    = string
  default = "frontrowadmin"
}

variable "administrator_password_wo" {
  description = "Administrator password, write-only (never stored in state). Sent to Azure only on create and when administrator_password_wo_version changes."
  type        = string
  sensitive   = true
  ephemeral   = true
}

variable "administrator_password_wo_version" {
  description = "Bump to send a new administrator_password_wo to Azure (rotation)."
  type        = number
  default     = 1
}

variable "databases" {
  description = "Databases to create on the server."
  type        = list(string)
}

variable "tags" {
  type = map(string)
}
