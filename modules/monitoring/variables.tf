variable "name_prefix" {
  type = string
}

variable "location" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "resource_group_id" {
  type = string
}

variable "aks_cluster_id" {
  description = "Cluster to attach the data collection rule and alerts to."
  type        = string
}

variable "container_insights_enabled" {
  description = "Create the Container Insights data collection rule and association."
  type        = bool
  default     = true
}

variable "log_retention_days" {
  type    = number
  default = 30

  validation {
    condition     = var.log_retention_days >= 30 && var.log_retention_days <= 730
    error_message = "PerGB2018 retention must be between 30 and 730 days."
  }
}

variable "log_daily_quota_gb" {
  description = "Daily ingestion cap in GB (-1 = unlimited)."
  type        = number
  default     = 0.25
}

variable "container_insights_streams" {
  type = list(string)
  default = [
    "Microsoft-ContainerLogV2",
    "Microsoft-KubeEvents",
    "Microsoft-KubePodInventory",
    "Microsoft-KubeNodeInventory",
  ]
}

variable "container_insights_interval" {
  type    = string
  default = "5m"
}

variable "container_insights_excluded_namespaces" {
  type    = list(string)
  default = ["kube-system", "gatekeeper-system"]
}

variable "alert_email" {
  description = "Email for alerts and budget notifications. null disables both."
  type        = string
  default     = null
}

variable "monthly_budget_amount" {
  description = "Monthly budget in the billing currency. 0 disables the budget."
  type        = number
  default     = 0
}

variable "budget_start_date" {
  description = "First day of a month, RFC3339, e.g. 2026-11-01T00:00:00Z."
  type        = string
  default     = "2026-11-01T00:00:00Z"

  validation {
    condition     = can(regex("^\\d{4}-\\d{2}-01T00:00:00Z$", var.budget_start_date))
    error_message = "budget_start_date must be the first day of a month, e.g. 2026-11-01T00:00:00Z."
  }
}

variable "tags" {
  type = map(string)
}
