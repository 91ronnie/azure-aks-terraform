variable "name_prefix" {
  description = "Prefix used in resource names, e.g. frontrow-dev."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group that holds the network resources."
  type        = string
}

variable "vnet_cidr" {
  description = "VNet address space."
  type        = string

  validation {
    condition     = can(cidrhost(var.vnet_cidr, 0))
    error_message = "vnet_cidr must be a valid IPv4 CIDR."
  }
}

variable "aks_nodes_subnet_cidr" {
  description = "Subnet for AKS node NICs. Must be inside vnet_cidr."
  type        = string

  validation {
    condition     = can(cidrhost(var.aks_nodes_subnet_cidr, 0))
    error_message = "aks_nodes_subnet_cidr must be a valid IPv4 CIDR."
  }
}

variable "postgres_subnet_cidr" {
  description = "CIDR for the subnet delegated to PostgreSQL Flexible Server. null = no subnet."
  type        = string
  default     = null

  validation {
    condition     = var.postgres_subnet_cidr == null || can(cidrhost(var.postgres_subnet_cidr, 0))
    error_message = "postgres_subnet_cidr must be a valid IPv4 CIDR (at least /28) or null."
  }
}

variable "mysql_subnet_cidr" {
  description = "CIDR for the subnet delegated to MySQL Flexible Server. null = no subnet."
  type        = string
  default     = null

  validation {
    condition     = var.mysql_subnet_cidr == null || can(cidrhost(var.mysql_subnet_cidr, 0))
    error_message = "mysql_subnet_cidr must be a valid IPv4 CIDR (at least /28) or null."
  }
}

variable "private_endpoints_subnet_cidr" {
  description = "CIDR for the private endpoints subnet. null = no subnet."
  type        = string
  default     = null

  validation {
    condition     = var.private_endpoints_subnet_cidr == null || can(cidrhost(var.private_endpoints_subnet_cidr, 0))
    error_message = "private_endpoints_subnet_cidr must be a valid IPv4 CIDR or null."
  }
}

variable "ingress_allowed_source_prefixes" {
  description = "Source prefixes allowed to reach 80/443. Use [\"Internet\"] initially; switch to Cloudflare's published ranges once proxying is enabled."
  type        = list(string)

  validation {
    condition     = length(var.ingress_allowed_source_prefixes) > 0
    error_message = "Provide at least one source prefix (e.g. \"Internet\")."
  }
}

variable "ingress_domain_name_label" {
  description = "Optional Azure DNS label for the ingress IP (<label>.<region>.cloudapp.azure.com). null disables it."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
}
