variable "name_prefix" {
  type = string
}

variable "location" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "oidc_issuer_url" {
  description = "AKS OIDC issuer URL used by the federated credentials."
  type        = string
}

variable "workload_namespace" {
  description = "Namespace of the FrontRow workload."
  type        = string
}

variable "workload_service_account" {
  description = "Service account used by the FrontRow pods."
  type        = string
}

variable "argocd_namespace" {
  type    = string
  default = "argocd"
}

variable "tags" {
  type = map(string)
}
