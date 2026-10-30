# ---------------------------------------------------------------------------
# Subscription and naming
# ---------------------------------------------------------------------------

variable "subscription_id" {
  description = "Target subscription ID. Leave null to use ARM_SUBSCRIPTION_ID."
  type        = string
  default     = null
}

variable "project" {
  description = "Project name used in resource names and tags."
  type        = string
  default     = "frontrow"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,11}$", var.project))
    error_message = "project must be 2-12 lowercase letters/digits, starting with a letter."
  }
}

variable "environment" {
  description = "Environment name."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be dev, staging or prod."
  }
}

variable "location" {
  description = "Azure region. See docs/cost-estimation.md for the region comparison."
  type        = string
  default     = "northeurope"
}

variable "unique_suffix" {
  description = "Short suffix that makes globally-unique names (ACR, Key Vault) unique, e.g. your initials + 2 digits."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{3,6}$", var.unique_suffix))
    error_message = "unique_suffix must be 3-6 lowercase letters or digits."
  }
}

variable "owner" {
  description = "Value of the owner tag (a name or team, not an email)."
  type        = string
}

variable "cost_center" {
  description = "Value of the cost-center tag."
  type        = string
  default     = "frontrow-lab"
}

# ---------------------------------------------------------------------------
# Access
# ---------------------------------------------------------------------------

variable "operator_ip_ranges" {
  description = "Public CIDRs of the operator (workstation/VPN). Used for the AKS API server and Key Vault firewall."
  type        = list(string)

  validation {
    condition     = length(var.operator_ip_ranges) > 0 && !contains(var.operator_ip_ranges, "0.0.0.0/0")
    error_message = "Provide at least one operator CIDR; 0.0.0.0/0 is not allowed."
  }
}

variable "cluster_admin_object_ids" {
  description = "Entra ID object IDs (users or groups) granted 'Azure Kubernetes Service RBAC Cluster Admin' and 'Key Vault Secrets Officer'."
  type        = list(string)
  default     = []
}

variable "pipeline_acr_push_principal_id" {
  description = "Object ID of the Azure DevOps service connection's service principal/managed identity that pushes images (AcrPush). null skips the assignment."
  type        = string
  default     = null
}

# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------

variable "vnet_cidr" {
  type    = string
  default = "10.40.0.0/16"
}

variable "aks_nodes_subnet_cidr" {
  type    = string
  default = "10.40.0.0/22"
}

variable "pod_cidr" {
  description = "Overlay pod CIDR. Must not overlap the VNet, peered networks or service_cidr."
  type        = string
  default     = "10.244.0.0/16"
}

variable "service_cidr" {
  type    = string
  default = "172.16.0.0/16"
}

variable "dns_service_ip" {
  description = "Must be inside service_cidr."
  type        = string
  default     = "172.16.0.10"
}

variable "ingress_allowed_source_prefixes" {
  description = "Who may reach 80/443. [\"Internet\"] or Cloudflare's ranges once proxied."
  type        = list(string)
  default     = ["Internet"]
}

# ---------------------------------------------------------------------------
# Application hostname (DNS is managed in Cloudflare, not here)
# ---------------------------------------------------------------------------

variable "app_fqdn" {
  description = "Public hostname of the FrontRow application. Used for outputs and DNS instructions."
  type        = string
  default     = "azure-fr.frontrow.co.ke"

  validation {
    condition     = can(regex("^([a-z0-9-]+\\.)+[a-z]{2,}$", var.app_fqdn))
    error_message = "app_fqdn must be a lowercase DNS name."
  }
}

# ---------------------------------------------------------------------------
# AKS
# ---------------------------------------------------------------------------

variable "aks_sku_tier" {
  type    = string
  default = "Free"
}

variable "kubernetes_version" {
  description = "Minor version (e.g. \"1.34\"). null = AKS default at creation; pin it afterwards."
  type        = string
  default     = null
}

variable "node_vm_size" {
  type    = string
  default = "Standard_D2as_v5"
}

variable "node_os_disk_type" {
  type    = string
  default = "Managed"
}

variable "node_os_disk_size_gb" {
  type    = number
  default = 64
}

variable "node_min_count" {
  type    = number
  default = 1
}

variable "node_max_count" {
  type    = number
  default = 2
}

variable "host_encryption_enabled" {
  type    = bool
  default = true
}

variable "azure_policy_enabled" {
  type    = bool
  default = false
}

# ---------------------------------------------------------------------------
# Workload identity
# ---------------------------------------------------------------------------

variable "app_namespace" {
  type    = string
  default = "frontrow"
}

variable "app_service_account" {
  type    = string
  default = "frontrow"
}

# ---------------------------------------------------------------------------
# Registry, Key Vault, monitoring
# ---------------------------------------------------------------------------

variable "acr_sku" {
  type    = string
  default = "Basic"
}

variable "acr_purge_task_enabled" {
  type    = bool
  default = false
}

variable "key_vault_soft_delete_retention_days" {
  type    = number
  default = 7
}

variable "container_insights_enabled" {
  type    = bool
  default = true
}

variable "log_retention_days" {
  type    = number
  default = 30
}

variable "log_daily_quota_gb" {
  type    = number
  default = 0.25
}

variable "alert_email" {
  description = "Alert/budget email. null disables alerts and the budget."
  type        = string
  default     = null
  sensitive   = false
}

variable "monthly_budget_amount" {
  type    = number
  default = 0
}

variable "budget_start_date" {
  type    = string
  default = "2026-11-01T00:00:00Z"
}

# ---------------------------------------------------------------------------
# CrateDigger (second application, see cratedigger.tf)
# ---------------------------------------------------------------------------

variable "cratedigger_enabled" {
  description = "Provision CrateDigger's identity, Key Vault and PostgreSQL server."
  type        = bool
  default     = true
}

variable "cratedigger_fqdn" {
  description = "Public hostname of CrateDigger (Cloudflare DNS)."
  type        = string
  default     = "azure-cd.frontrow.co.ke"
}

variable "cratedigger_namespace" {
  type    = string
  default = "cratedigger"
}

variable "cratedigger_service_account" {
  type    = string
  default = "cratedigger"
}

variable "postgres_subnet_cidr" {
  description = "Subnet delegated to PostgreSQL Flexible Server. Must be inside vnet_cidr."
  type        = string
  default     = "10.40.12.0/28"
}

variable "postgres_version" {
  type    = string
  default = "17"
}

variable "postgres_sku_name" {
  type    = string
  default = "B_Standard_B1ms"
}

variable "postgres_storage_mb" {
  type    = number
  default = 32768
}

variable "postgres_backup_retention_days" {
  type    = number
  default = 7
}

variable "postgres_operator_admins" {
  description = "Extra Entra admins on the PostgreSQL server, e.g. { me = { object_id = \"...\", principal_name = \"me@contoso.com\", principal_type = \"User\" } }."
  type = map(object({
    object_id      = string
    principal_name = string
    principal_type = string
  }))
  default = {}
}

# ---------------------------------------------------------------------------
# FrontRow API (Laravel backend, see api.tf)
# ---------------------------------------------------------------------------

variable "api_enabled" {
  description = "Provision the FrontRow API's identity, Key Vault, MySQL, Redis, Blob storage and email."
  type        = bool
  default     = true
}

variable "api_fqdn" {
  description = "Public hostname of the FrontRow API (Cloudflare DNS)."
  type        = string
  default     = "azure-api.frontrow.co.ke"

  validation {
    condition     = can(regex("^([a-z0-9-]+\\.)+[a-z]{2,}$", var.api_fqdn))
    error_message = "api_fqdn must be a lowercase DNS name."
  }
}

variable "api_namespace" {
  type    = string
  default = "frontrow-api"
}

variable "api_service_account" {
  type    = string
  default = "frontrow-api"
}

variable "mysql_subnet_cidr" {
  description = "Subnet delegated to MySQL Flexible Server. Must be inside vnet_cidr."
  type        = string
  default     = "10.40.13.0/28"
}

variable "private_endpoints_subnet_cidr" {
  description = "Subnet for private endpoints (Managed Redis). Must be inside vnet_cidr."
  type        = string
  default     = "10.40.8.0/24"
}

variable "mysql_version" {
  type    = string
  default = "8.4"
}

variable "mysql_sku_name" {
  type    = string
  default = "B_Standard_B1ms"
}

variable "mysql_storage_gb" {
  type    = number
  default = 20
}

variable "mysql_backup_retention_days" {
  type    = number
  default = 7
}

variable "mysql_admin_password" {
  description = "MySQL administrator password (TF_VAR_mysql_admin_password, a secret pipeline variable). Write-only and ephemeral: never stored in state; Azure only receives it on create and when mysql_admin_password_version changes. Required when api_enabled."
  type        = string
  default     = null
  sensitive   = true
  ephemeral   = true

  validation {
    condition     = !var.api_enabled || try(length(var.mysql_admin_password) >= 16, false)
    error_message = "Set TF_VAR_mysql_admin_password (16+ characters) when api_enabled = true."
  }
}

variable "mysql_admin_password_version" {
  description = "Increment together with a new mysql_admin_password to rotate it."
  type        = number
  default     = 1
}

variable "redis_sku_name" {
  type    = string
  default = "Balanced_B0"
}

variable "api_storage_soft_delete_days" {
  description = "Soft-delete retention for blobs and containers."
  type        = number
  default     = 14
}

variable "api_email_domain" {
  description = "Sender domain for Azure Communication Services Email (customer-managed, DNS in Cloudflare)."
  type        = string
  default     = "frontrow.co.ke"
}

variable "api_email_sender_username" {
  description = "Local part of the From address (<username>@<api_email_domain>)."
  type        = string
  default     = "noreply"
}

variable "api_email_data_location" {
  description = "Where Communication Services stores data at rest (e.g. Europe, Africa, United States)."
  type        = string
  default     = "Europe"
}

variable "api_email_domain_verified" {
  description = "Set to true after the domain's DNS records are verified, to link it to the Communication Service."
  type        = bool
  default     = false
}
