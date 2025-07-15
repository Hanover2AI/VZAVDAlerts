#==========---------------------------------------------------------------------------------------------==========#
# The code in this file is devided into three main sections:                                                      #
# Rexy, the Dino: The code in this section accomplishes everything related to metric alert rules.                 #
# Rin Tin Tin, the Dog: The code in this section accomplishes everything related to custom log search alert rules.#
# Felix, the Cat: The code in this section accomplishes everything related to service health alert rules.         #
#==========---------------------------------------------------------------------------------------------==========#

#               __
#              / _)
#     _.----._/ /
#    /         /
# __/ (  | (  |
#/__.-'|_|--|_|

# Retrieve the current Azure client configuration.
data "azurerm_client_config" "current" {}

# Retrieve all resource groups in the current subscription.
data "azapi_resource_list" "all_resource_groups" {
  type      = "Microsoft.Resources/resourceGroups@2022-09-01"
  parent_id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}"

  response_export_values = ["*"]
}

# Filter resource groups by name. As per AVD design, resource groups for pooled VMs end with compute in their name, and resource groups for personal VMs end with personal in their name.
locals {
  filtered_rg_names = [
    for rg in data.azapi_resource_list.all_resource_groups.output.value : rg.name
    if can(regex(".*(compute|personal)$", rg.name))
  ]
}

# Dynamically fetch details of matching resource groups.
data "azurerm_resource_group" "selected_rgs" {
  for_each = toset(local.filtered_rg_names)
  name     = each.value
}

# Save resource group IDs in a variable.
locals {
  matching_rg_ids = [
    for rg in data.azurerm_resource_group.selected_rgs : rg.id
  ]
}

# Define local variable with name of the storage accounts (Appattach and FSLogix).
locals {
  sa_name = ["saukspavdappattach", "stpuksavdtfstate"]
}

# Retrieve every storage account in the subscription
data "azurerm_resources" "sas" {
  type = "Microsoft.Storage/storageAccounts"
}

# Filter and retreive storage account resource IDs based on the names defined in local.sa_name.
locals {
  sa_id_map = {
    for sa in data.azurerm_resources.sas.resources :
    sa.name => sa.id
    if contains(local.sa_name, sa.name)
  }
}

# Define local *combined* map of every (storage account related metrics (availability, latency, etc.) and storage account resource IDs) pair.
locals {
  metric_alerts_expanded = merge(
    [
      for alert_name, cfg in local.metric_alerts_storage_account : {
        for sa_name, sa_id in local.sa_id_map :
        "${alert_name}-${sa_name}" => merge(
          cfg,
          {
            alert_name = alert_name
            sa_name    = sa_name
            # if this alert is one of file-service metrics, append "/fileServices/default"
            scope = (
              cfg.target_resource_type == "Microsoft.Storage/storageAccounts/fileServices"
            ) ? "${sa_id}/fileServices/default" : sa_id
          }
        )
      }
    ]...
  )
}

# Refer to a json file containing metric alert definitions.
locals {
  all_alerts = jsondecode(file("${path.module}/metrics.json"))

  metric_alerts_hostpool        = local.all_alerts.metric_alerts_hostpool
  metric_alerts_storage_account = local.all_alerts.metric_alerts_storage_account
}

# Create action group to be used in alert configuration.
resource "azurerm_monitor_action_group" "avd_alerts_ag" {
  name                = var.action_group_name
  short_name          = var.action_group_short_name
  resource_group_name = "rg-p-uks-mon-001"
  enabled             = true
  arm_role_receiver {
    name                    = "armroleaction"
    role_id                 = "8e3af657-a8ff-443c-a75c-2fe8c4bcb635" # Owner role.
    use_common_alert_schema = true
  }
}

# Create metric alert rules for host pool
resource "azurerm_monitor_metric_alert" "metric_hostpool" {
  for_each                 = local.metric_alerts_hostpool
  auto_mitigate            = true
  description              = each.value.description
  enabled                  = true
  frequency                = each.value.frequency
  name                     = each.key
  resource_group_name      = "rg-p-uks-mon-001" # Change this to a resource group where log analytics workspace is. This resource group shall host the alert rules.
  scopes                   = local.matching_rg_ids
  severity                 = each.value.severity
  tags                     = {}
  target_resource_location = each.value.target_resource_location
  target_resource_type     = each.value.target_resource_type
  window_size              = each.value.window_size

  criteria {
    aggregation            = each.value.aggregation
    metric_name            = each.value.metric_name
    metric_namespace       = each.value.target_resource_type
    operator               = each.value.operator
    skip_metric_validation = false
    threshold              = each.value.threshold

    dynamic "dimension" {
      for_each = each.value.dimensions
      content {
        name     = dimension.value.name
        operator = dimension.value.operator
        values   = dimension.value.values
      }
    }
  }

  action {
    action_group_id = azurerm_monitor_action_group.avd_alerts_ag.id
  }
}

# Create metric alert rules for storage account
resource "azurerm_monitor_metric_alert" "metric_storage_account" {
  for_each                 = local.metric_alerts_expanded
  auto_mitigate            = true
  description              = each.value.description
  enabled                  = true
  frequency                = each.value.frequency
  name                     = "${each.value.alert_name} (${each.value.sa_name})"
  resource_group_name      = "rg-p-uks-mon-001" # Change this to a resource group where log analytics workspace is. This resource group shall host the alert rules.
  scopes                   = [each.value.scope]
  severity                 = each.value.severity
  tags                     = {}
  target_resource_location = each.value.target_resource_location
  target_resource_type     = each.value.target_resource_type
  window_size              = each.value.window_size

  criteria {
    aggregation            = each.value.aggregation
    metric_name            = each.value.metric_name
    metric_namespace       = each.value.target_resource_type
    operator               = each.value.operator
    skip_metric_validation = false
    threshold              = each.value.threshold

    dynamic "dimension" {
      for_each = each.value.dimensions
      content {
        name     = dimension.value.name
        operator = dimension.value.operator
        values   = dimension.value.values
      }
    }
  }

  action {
    action_group_id = azurerm_monitor_action_group.avd_alerts_ag.id
  }
}

#   ^
#  / \__
# (    @\___
# /         O
#/   (_____/
#/_____/ U

# Create an automation account that shall be used to execute runbooks for AVD.
resource "azurerm_automation_account" "avd_aaacount" {
  name                         = var.automation_account_name
  location                     = "uksouth"          # Change this to the location where the resource should exist.
  resource_group_name          = "rg-p-uks-mon-001" # Change this to the name of the resource group in which the automation account must be created.
  sku_name                     = "Basic"
  local_authentication_enabled = false
  identity {
    type = "SystemAssigned"
  }
}

# Assign Reader RBAC role to automation account system assigned identity on AVD subscription.
# This is required to allow automation account to read AVD resources. Note: This role assignment is scoped to the entire subscription.
# Ensure that the service principal or the user account that is used to authenticate to Azure has the necessary permissions to create role assignments.
resource "azurerm_role_assignment" "automation_reader" {
  scope                = "/subscriptions/${data.azurerm_client_config.current.subscription_id}"
  role_definition_name = "Reader"
  principal_id         = azurerm_automation_account.avd_aaacount.identity[0].principal_id

  depends_on = [
    azurerm_automation_account.avd_aaacount
  ]
}

# Create automation schedules that will be used to trigger runbooks.
# The schedules are created with a 15 minute offset from the baseline timestamp.
# ----------------------------------------------------------------------------------------
# PLEASE ENSURE THAT THE TIME GAP BETWEEN TERRAFORM PLAN AND APPLY IS LESS THAN 30 MINUTES.
# ----------------------------------------------------------------------------------------
locals {
  baseline = timestamp()
  schedule_start_time = {
    "AVD_Chk-AzFilesStor-0" = 30
    "AVD_Chk-AzFilesStor-1" = 45
    "AVD_Chk-AzFilesStor-2" = 70
    "AVD_Chk-AzFilesStor-3" = 95
    "AVD_Chk-HostPool-0"    = 30
    "AVD_Chk-HostPool-1"    = 45
    "AVD_Chk-HostPool-2"    = 70
    "AVD_Chk-HostPool-3"    = 95
  }
}

resource "azurerm_automation_schedule" "avd_automation_schedule" {
  for_each                = local.schedule_start_time
  name                    = each.key
  resource_group_name     = "rg-p-uks-mon-001" # Change this to the name of the resource group in which the automation schedule must be created.
  automation_account_name = azurerm_automation_account.avd_aaacount.name
  frequency               = "Hour"
  interval                = 1
  start_time              = timeadd(local.baseline, "${each.value}m")
  timezone                = "Europe/Amsterdam"
}

# Create local variable to refer to the PowerShell files.
locals {
  runbooks = {
    "AVDStorageLogData" = {
      path   = "${path.module}/scripts/AVDStorageLogData.ps1"
      prefix = "AVD_Chk-AzFilesStor"
      desc   = "AVD Metrics Runbook for collecting related Azure Files storage statistics to store in Log Analytics for specified Alert Queries"
    }
    "AVDHostPoolLogData" = {
      path   = "${path.module}/scripts/AVDHostPoolLogData.ps1"
      prefix = "AVD_Chk-HostPool"
      desc   = "AVD Metrics Runbook for collecting related Host Pool statistics to store in Log Analytics for specified Alert Queries"
    }
  }
}

# Create two runbooks of type PowerShell.
resource "azurerm_automation_runbook" "runbooks" {
  for_each                 = local.runbooks
  name                     = each.key
  resource_group_name      = "rg-p-uks-mon-001" # Change this to the name of the resource group in which runbooks must be created.
  automation_account_name  = azurerm_automation_account.avd_aaacount.name
  location                 = "uksouth" # Change this to the location where the resource should exist.
  runbook_type             = "PowerShell"
  description              = each.value.desc
  log_activity_trace_level = 0
  log_progress             = false
  log_verbose              = false
  tags                     = {}
  content                  = file(each.value.path)

  dynamic "job_schedule" {
    for_each = [
      for sched in azurerm_automation_schedule.avd_automation_schedule :
      sched
      if startswith(sched.name, each.value.prefix)
    ]
    content {
      schedule_name = job_schedule.value.name
      run_on        = ""
      parameters = {
        cloudenvironment = "AzureCloud"
        subscriptionid   = var.avd_subscription_id
      }
    }
  }
}

# Refer to a json file containing custom log search alert definitions.
locals {
  log_search_alerts = jsondecode(file("${path.module}/logsearch.json"))
}

# Retrieve the Log Analytics workspace that is used to store AVD logs.
data "azurerm_log_analytics_workspace" "law" {
  name                = "law-p-uks-avd-001" # Change this to the name of the Log Analytics workspace that is used to store AVD logs.
  resource_group_name = "rg-p-uks-mon-001"  # Change this to the name of the resource group in which the Log Analytics workspace is created.
}

# Create custom log search alert rules.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "custom_log_search" {
  for_each = {
    for rule in local.log_search_alerts :
    rule.index => rule
  }
  auto_mitigation_enabled          = true
  description                      = each.value.description
  display_name                     = "${each.value.display_name} (${each.value.hostpool_name})"
  enabled                          = true
  evaluation_frequency             = each.value.evaluation_frequency
  location                         = "uksouth" #Change this to azure region where the custom log search rule should exist.
  name                             = "${each.value.name}${each.value.hostpool_name}"
  resource_group_name              = "rg-p-uks-mon-001" # Change this to a resource group where log analytics workspace is. This resource group shall host the alert rules.
  scopes                           = [data.azurerm_log_analytics_workspace.law.id]
  severity                         = each.value.severity
  skip_query_validation            = false
  tags                             = {}
  target_resource_types            = []
  window_duration                  = each.value.window_duration
  workspace_alerts_storage_enabled = false
  action {
    action_groups = [azurerm_monitor_action_group.avd_alerts_ag.id]
  }
  criteria {
    operator                = each.value.operator
    query                   = each.value.query
    resource_id_column      = length(each.value.resource_id_column) > 0 ? each.value.resource_id_column : null # Not all alert rules need resource ID column to split by resource ID.
    threshold               = each.value.threshold
    time_aggregation_method = each.value.time_aggregation_method

    dynamic "dimension" {
      for_each = each.value.dimensions
      content {
        name     = dimension.value.name
        operator = dimension.value.operator
        values   = dimension.value.values
      }
    }

    failing_periods {
      minimum_failing_periods_to_trigger_alert = each.value.minimum_failing_periods_to_trigger_alert
      number_of_evaluation_periods             = each.value.number_of_evaluation_periods
    }
  }
}

#  /\_/\  
# ( o.o ) 
#  > ^ <

# Create service health alert rules.
resource "azurerm_monitor_activity_log_alert" "avd_service_health_ala" {
  name                = "AVD-Service-Health-Alert"
  resource_group_name = "rg-p-uks-mon-001" # Change this to a resource group where log analytics workspace is. This resource group shall host the alert rules.
  location            = "global"           # Activity Log Alerts are global
  enabled             = true
  scopes              = ["/subscriptions/${var.avd_subscription_id}"]
  description         = "This alert will monitor AVD Service issues, incidents and planned maintenance"

  criteria {
    category = "ServiceHealth"
    service_health {
      events    = ["Incident", "Maintenance", "Security", "ActionRequired"]
      locations = ["uksouth"] # Change this to the location where the service health alert should be created.
      services  = ["Windows Virtual Desktop"]
    }
  }
  action {
    action_group_id = azurerm_monitor_action_group.avd_alerts_ag.id
  }
}
