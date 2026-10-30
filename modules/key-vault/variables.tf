variable "name" {
  description = "Globally unique vault name (3-24 chars, letters, digits, hyphens)."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9-]{1,22}[a-zA-Z0-9]$", var.name))
    error_message = "Key Vault names must be 3-24 characters, start with a letter and contain only letters, digits and hyphens."
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

variable "soft_delete_retention_days" {
  description = "7-90 days. Short for a lab so the name can be reused sooner after destroy."
  type        = number
  default     = 7

  validation {
    condition     = var.soft_delete_retention_days >= 7 && var.soft_delete_retention_days <= 90
    error_message = "soft_delete_retention_days must be between 7 and 90."
  }
}

variable "allowed_ip_ranges" {
  description = "Public IPs/CIDRs allowed through the data-plane firewall."
  type        = list(string)
  default     = []
}

variable "allowed_subnet_ids" {
  description = "Subnets (with the Microsoft.KeyVault service endpoint) allowed through the firewall."
  type        = list(string)
  default     = []
}

variable "tags" {
  type = map(string)
}
