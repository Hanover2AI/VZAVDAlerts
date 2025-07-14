variable "application_name" {
  description = "The name of the application"
  type        = string
}
variable "environment_name" {
  description = "The name of the environment"
  type        = string
}
variable "primary_location_name" {
  description = "The name of primary location"
  type        = string
}
variable "primary_location_short_name" {
  description = "The name of primary location"
  type        = string
}
variable "avd_subscription_id" {
  type        = string
  description = "The ID of the AVD Subscription"
}
variable "action_group_name" {
  description = "The name of the action group."
  type        = string
}
variable "action_group_short_name" {
  description = "The short name of the action group, used for display purposes."
  type        = string
}
variable "automation_account_name" {
  description = "The name of the automation account."
  type        = string
}
