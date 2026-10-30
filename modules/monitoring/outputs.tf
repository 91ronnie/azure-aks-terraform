output "log_analytics_workspace_id" {
  value = azurerm_log_analytics_workspace.this.id
}

output "log_analytics_workspace_name" {
  value = azurerm_log_analytics_workspace.this.name
}

output "metric_alert_names" {
  value = [for a in azurerm_monitor_metric_alert.aks : a.name]
}

output "budget_enabled" {
  value = length(azurerm_consumption_budget_resource_group.monthly) == 1
}
