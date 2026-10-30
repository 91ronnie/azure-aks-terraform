# Azure Container Registry.
#
# Basic SKU is enough for one small repository (10 GiB included storage).
# Basic does NOT support: private endpoints, retention policies, geo-replication,
# content trust. Images are scanned by Trivy in the pipeline instead of the paid
# Defender for Containers plan. See docs/security.md#registry.

resource "azurerm_container_registry" "this" {
  name                = var.name
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = var.sku

  # Pulls and pushes use Entra ID identities (AcrPull / AcrPush), never the
  # shared admin user.
  admin_enabled = false

  # Basic/Standard registries only support public network access. Access is
  # still authenticated; anonymous pull is off.
  public_network_access_enabled = true
  anonymous_pull_enabled        = false

  tags = var.tags
}

# Optional scheduled clean-up. Off by default because deleting images removes
# rollback targets. "--keep" always preserves the newest N tags.
resource "azurerm_container_registry_task" "purge" {
  count = var.purge_task_enabled ? 1 : 0

  name                  = "purge-old-images"
  container_registry_id = azurerm_container_registry.this.id
  tags                  = var.tags

  platform {
    os = "Linux"
  }

  encoded_step {
    task_content = base64encode(<<-YAML
      version: v1.1.0
      steps:
        - cmd: acr purge --filter '${var.purge_repository_filter}' --ago ${var.purge_older_than} --keep ${var.purge_keep_count} --untagged
          disableWorkingDirectoryOverride: true
          timeout: 3600
    YAML
    )
  }

  timer_trigger {
    name     = "weekly"
    schedule = "0 3 * * 0"
    enabled  = true
  }
}
