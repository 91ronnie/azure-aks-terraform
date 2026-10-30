terraform {
  required_version = ">= 1.11.0, < 2.0.0" # write-only arguments (MySQL admin password)

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.12"
    }
  }

  # Partial configuration: values come from backend.hcl (see backend.hcl.example
  # and bootstrap/README.md). No credentials are ever placed here; access uses
  # Entra ID (use_azuread_auth) and the storage account has shared keys disabled.
  backend "azurerm" {}
}
