variable "name" {
  description = "Globally unique Managed Redis name."
  type        = string
}

variable "location" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "sku_name" {
  description = "Balanced_B0 is the smallest SKU (0.5 GB)."
  type        = string
  default     = "Balanced_B0"
}

variable "high_availability_enabled" {
  description = "Replicated (HA) deployment. Doubles the price; off for dev."
  type        = bool
  default     = false
}

variable "virtual_network_id" {
  description = "VNet the private DNS zone is linked to."
  type        = string
}

variable "private_endpoint_subnet_id" {
  type = string
}

variable "tags" {
  type = map(string)
}
