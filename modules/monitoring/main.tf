# Cost-aware monitoring.
#
# - Log Analytics workspace with 30-day retention and a daily ingestion cap.
#   When the cap is hit, collection stops until the next UTC day (cost safety
#   net, at the expense of missing logs).
# - Container Insights data collection rule using the cost-optimised settings:
#   5-minute interval, ContainerLogV2, kube-system logs excluded.
# - A handful of platform-metric alerts (cheap, no log queries).
# - A monthly budget on the resource group.
#
# Alerts and the budget are only created when alert_email is set.

resource "azurerm_log_analytics_workspace" "this" {
  name                = "log-${var.name_prefix}"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "PerGB2018"
  retention_in_days   = var.log_retention_days
  daily_quota_gb      = var.log_daily_quota_gb
  tags                = var.tags
}

locals {
  alerts_enabled = var.alert_email != null
}

resource "azurerm_monitor_data_collection_rule" "container_insights" {
  count = var.container_insights_enabled ? 1 : 0

  name                = "dcr-${var.name_prefix}-ci"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  destinations {
    log_analytics {
      name                  = "ciworkspace"
      workspace_resource_id = azurerm_log_analytics_workspace.this.id
    }
  }

  data_flow {
    streams      = var.container_insights_streams
    destinations = ["ciworkspace"]
  }

  data_sources {
    extension {
      name           = "ContainerInsightsExtension"
      extension_name = "ContainerInsights"
      streams        = var.container_insights_streams
      extension_json = jsonencode({
        dataCollectionSettings = {
          interval               = var.container_insights_interval
          namespaceFilteringMode = "Exclude"
          namespaces             = var.container_insights_excluded_namespaces
          enableContainerLogV2   = true
        }
      })
    }
  }
}

resource "azurerm_monitor_data_collection_rule_association" "container_insights" {
  count = var.container_insights_enabled ? 1 : 0

  name                    = "ContainerInsightsExtension"
  target_resource_id      = var.aks_cluster_id
  data_collection_rule_id = azurerm_monitor_data_collection_rule.container_insights[0].id
}

resource "azurerm_monitor_action_group" "email" {
  count = local.alerts_enabled ? 1 : 0

  name                = "ag-${var.name_prefix}-email"
  resource_group_name = var.resource_group_name
  short_name          = "frontrow"
  tags                = var.tags

  email_receiver {
    name                    = "operator"
    email_address           = var.alert_email
    use_common_alert_schema = true
  }
}

locals {
  # Every entry has the same shape so the map is homogeneous. dimension = ""
  # means "no dimension filter"; dim_values is a comma-separated list.
  metric_alerts = {
    node-cpu-high = {
      description = "Average node CPU above 80% for 15 minutes."
      metric      = "node_cpu_usage_percentage"
      aggregation = "Average"
      operator    = "GreaterThan"
      threshold   = 80
      severity    = 2
      dimension   = ""
      dim_values  = ""
    }
    node-memory-high = {
      description = "Average node working-set memory above 85% for 15 minutes."
      metric      = "node_memory_working_set_percentage"
      aggregation = "Average"
      operator    = "GreaterThan"
      threshold   = 85
      severity    = 2
      dimension   = ""
      dim_values  = ""
    }
    node-not-ready = {
      description = "At least one node reports NotReady."
      metric      = "kube_node_status_condition"
      aggregation = "Average"
      operator    = "GreaterThan"
      threshold   = 0
      severity    = 1
      dimension   = "status2"
      dim_values  = "NotReady"
    }
    pods-failed = {
      description = "Pods in Failed phase."
      metric      = "kube_pod_status_phase"
      aggregation = "Average"
      operator    = "GreaterThan"
      threshold   = 0
      severity    = 2
      dimension   = "phase"
      dim_values  = "Failed"
    }
  }
}

resource "azurerm_monitor_metric_alert" "aks" {
  for_each = local.alerts_enabled ? local.metric_alerts : {}

  name                = "alert-${var.name_prefix}-${each.key}"
  resource_group_name = var.resource_group_name
  scopes              = [var.aks_cluster_id]
  description         = each.value.description
  severity            = each.value.severity
  frequency           = "PT5M"
  window_size         = "PT15M"
  tags                = var.tags

  criteria {
    metric_namespace = "Microsoft.ContainerService/managedClusters"
    metric_name      = each.value.metric
    aggregation      = each.value.aggregation
    operator         = each.value.operator
    threshold        = each.value.threshold

    dynamic "dimension" {
      for_each = each.value.dimension == "" ? [] : [1]
      content {
        name     = each.value.dimension
        operator = "Include"
        values   = split(",", each.value.dim_values)
      }
    }
  }

  action {
    action_group_id = azurerm_monitor_action_group.email[0].id
  }
}

resource "azurerm_consumption_budget_resource_group" "monthly" {
  count = var.alert_email != null && var.monthly_budget_amount > 0 ? 1 : 0

  name              = "budget-${var.name_prefix}"
  resource_group_id = var.resource_group_id
  amount            = var.monthly_budget_amount
  time_grain        = "Monthly"

  time_period {
    start_date = var.budget_start_date
  }

  notification {
    enabled        = true
    operator       = "GreaterThan"
    threshold      = 80
    threshold_type = "Forecasted"
    contact_emails = [var.alert_email]
  }

  notification {
    enabled        = true
    operator       = "GreaterThan"
    threshold      = 100
    threshold_type = "Actual"
    contact_emails = [var.alert_email]
  }

  lifecycle {
    ignore_changes = [time_period]
  }
}
