variable "name" {
  description = "Globally unique registry name (5-50 lowercase alphanumerics)."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{5,50}$", var.name))
    error_message = "ACR names must be 5-50 lowercase letters or digits."
  }
}

variable "location" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "sku" {
  type    = string
  default = "Basic"

  validation {
    condition     = contains(["Basic", "Standard", "Premium"], var.sku)
    error_message = "sku must be Basic, Standard or Premium."
  }
}

variable "purge_task_enabled" {
  description = "Create a weekly ACR task that purges old images."
  type        = bool
  default     = false
}

variable "purge_repository_filter" {
  description = "acr purge --filter expression (repository:tag-regex)."
  type        = string
  default     = "frontrow/web:.*"
}

variable "purge_older_than" {
  description = "acr purge --ago duration, e.g. 30d."
  type        = string
  default     = "30d"
}

variable "purge_keep_count" {
  description = "Always keep this many of the newest tags."
  type        = number
  default     = 10
}

variable "tags" {
  type = map(string)
}
