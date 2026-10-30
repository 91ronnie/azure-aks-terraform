# Offline plan tests: `terraform test` (from environments/dev).
# The azurerm provider is mocked, so no Azure credentials or resources are
# needed. These tests exercise Terraform logic (counts, for_each, validation,
# wiring between modules), not Azure API behaviour.

mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id       = "00000000-0000-0000-0000-000000000001"
      subscription_id = "00000000-0000-0000-0000-000000000002"
      object_id       = "00000000-0000-0000-0000-000000000003"
    }
  }

  mock_resource "azurerm_resource_group" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000002/resourceGroups/rg-frontrow-dev"
    }
  }
}

variables {
  subscription_id          = "00000000-0000-0000-0000-000000000002"
  unique_suffix            = "test1"
  owner                    = "ci"
  operator_ip_ranges       = ["203.0.113.10/32"]
  cluster_admin_object_ids = ["00000000-0000-0000-0000-0000000000aa"]
  # Test-only value for the write-only, ephemeral MySQL admin password.
  mysql_admin_password = "Test-Only-Passw0rd-NotReal"
}

run "defaults_plan" {
  command = plan

  assert {
    condition     = module.acr.name == "acrfrontrowdevtest1"
    error_message = "ACR name is not derived as expected."
  }

  assert {
    condition     = module.key_vault.name == "kv-frontrow-dev-test1"
    error_message = "Key Vault name is not derived as expected."
  }

  assert {
    condition     = length(azurerm_role_assignment.pipeline_acr_push) == 0
    error_message = "AcrPush must not be granted when no pipeline principal is given."
  }

  assert {
    condition     = length(azurerm_role_assignment.operators_aks_cluster_admin) == 1
    error_message = "Expected one cluster-admin assignment for one operator."
  }

  assert {
    condition     = length(module.monitoring.metric_alert_names) == 0 && !module.monitoring.budget_enabled
    error_message = "No alerts or budget without alert_email."
  }

  assert {
    condition     = output.cloudflare_dns_record.name == "azure-fr.frontrow.co.ke"
    error_message = "app_fqdn default changed unexpectedly."
  }
}

run "pipeline_principal_gets_acr_push_only" {
  command = plan

  variables {
    pipeline_acr_push_principal_id = "00000000-0000-0000-0000-0000000000bb"
  }

  assert {
    condition     = azurerm_role_assignment.pipeline_acr_push[0].role_definition_name == "AcrPush"
    error_message = "Pipeline principal must receive AcrPush."
  }
}

run "alerts_and_budget_enabled" {
  command = plan

  variables {
    alert_email           = "alerts@example.com"
    monthly_budget_amount = 100
  }

  assert {
    condition     = length(module.monitoring.metric_alert_names) == 4
    error_message = "Expected four metric alerts when alert_email is set."
  }

  assert {
    condition     = module.monitoring.budget_enabled
    error_message = "Budget should be created when an email and amount are set."
  }
}

run "rejects_open_api_server" {
  command = plan

  variables {
    operator_ip_ranges = ["0.0.0.0/0"]
  }

  expect_failures = [var.operator_ip_ranges]
}

run "rejects_bad_suffix" {
  command = plan

  variables {
    unique_suffix = "Has-Caps"
  }

  expect_failures = [var.unique_suffix]
}

run "cratedigger_enabled_by_default" {
  command = plan

  assert {
    condition     = length(module.cratedigger_postgres) == 1 && length(module.cratedigger_key_vault) == 1
    error_message = "CrateDigger PostgreSQL and Key Vault should be planned by default."
  }

  assert {
    condition     = module.cratedigger_key_vault[0].name == "kv-cd-dev-test1"
    error_message = "CrateDigger Key Vault name is not derived as expected."
  }

  assert {
    condition     = azurerm_federated_identity_credential.cratedigger[0].subject == "system:serviceaccount:cratedigger:cratedigger"
    error_message = "Federated credential subject must match the cratedigger service account."
  }

  assert {
    condition     = azurerm_role_assignment.cratedigger_kv_secrets_user[0].role_definition_name == "Key Vault Secrets User"
    error_message = "CrateDigger identity must only read secrets."
  }

  assert {
    condition     = module.networking.postgres_subnet_cidr == "10.40.12.0/28"
    error_message = "Delegated PostgreSQL subnet expected."
  }
}

run "cratedigger_disabled_removes_everything" {
  command = plan

  variables {
    cratedigger_enabled = false
  }

  assert {
    condition     = length(module.cratedigger_postgres) == 0 && length(azurerm_user_assigned_identity.cratedigger) == 0
    error_message = "Nothing CrateDigger-related should be planned when disabled."
  }

  assert {
    condition     = module.networking.postgres_subnet_cidr == null && output.cratedigger == null
    error_message = "No PostgreSQL subnet or output when disabled."
  }
}

run "api_enabled_by_default" {
  command = plan

  assert {
    condition     = length(module.api_mysql) == 1 && length(module.api_redis) == 1 && length(module.api_key_vault) == 1
    error_message = "API MySQL, Redis and Key Vault should be planned by default."
  }

  assert {
    condition     = module.api_key_vault[0].name == "kv-api-dev-test1" && azurerm_storage_account.api[0].name == "stfrontrowapidevtest1"
    error_message = "API Key Vault / storage account names are not derived as expected."
  }

  assert {
    condition     = azurerm_federated_identity_credential.api[0].subject == "system:serviceaccount:frontrow-api:frontrow-api"
    error_message = "Federated credential subject must match the frontrow-api service account."
  }

  assert {
    condition     = azurerm_role_assignment.api_kv_secrets_user[0].role_definition_name == "Key Vault Secrets User"
    error_message = "API identity must only read secrets."
  }

  assert {
    condition     = azurerm_storage_account.api[0].allow_nested_items_to_be_public == false && azurerm_storage_account.api[0].min_tls_version == "TLS1_2"
    error_message = "Blob storage must forbid anonymous access and require TLS 1.2."
  }

  assert {
    condition     = length(azurerm_storage_container.api) == 3 && alltrue([for c in azurerm_storage_container.api : c.container_access_type == "private"])
    error_message = "Expected three private containers (files, masked-images, telemedicine)."
  }

  assert {
    condition     = module.networking.mysql_subnet_cidr == "10.40.13.0/28" && module.networking.private_endpoints_subnet_cidr == "10.40.8.0/24"
    error_message = "MySQL delegated subnet and private endpoint subnet expected."
  }

  assert {
    condition     = length(azurerm_communication_service_email_domain_association.api) == 0
    error_message = "The email domain must not be linked before it is verified."
  }
}

run "api_disabled_removes_everything" {
  command = plan

  variables {
    api_enabled          = false
    mysql_admin_password = null
  }

  assert {
    condition     = length(module.api_mysql) == 0 && length(module.api_redis) == 0 && length(azurerm_storage_account.api) == 0 && length(azurerm_user_assigned_identity.api) == 0
    error_message = "Nothing API-related should be planned when disabled."
  }

  assert {
    condition     = module.networking.mysql_subnet_cidr == null && module.networking.private_endpoints_subnet_cidr == null && output.api == null
    error_message = "No API subnets or output when disabled."
  }
}

run "api_requires_mysql_password" {
  command = plan

  variables {
    mysql_admin_password = null
  }

  expect_failures = [var.mysql_admin_password]
}
