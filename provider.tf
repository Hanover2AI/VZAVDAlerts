terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "4.31.0"
    }
    random = {
      source = "hashicorp/random"
    }
    local = {
      source = "hashicorp/local"
    }
    azapi = {
      source = "Azure/azapi"
    }
    time = {
      source  = "hashicorp/time"
      version = "~>0.13"
    }
  }
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_deleted_secrets_on_destroy      = false
      purge_soft_deleted_certificates_on_destroy = false
      purge_soft_deleted_keys_on_destroy         = false
      recover_soft_deleted_key_vaults            = true
      recover_soft_deleted_secrets               = true
      recover_soft_deleted_certificates          = true
      recover_soft_deleted_keys                  = true
    }
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
  resource_provider_registrations = "none"
  subscription_id                 = var.avd_subscription_id
  use_msi                         = true
  client_id                       = "dbfb1459-6bee-40c3-8c32-d31021af99fa"
  client_secret                   = "CLIENT_SECRET_HERE" # If using az login or environment variable(s), then use_msi, client_id, and client_secret are not required.
  tenant_id                       = "e5b8949f-5fc8-4315-8cc0-21933b6e1406"
}

terraform {
  backend "azurerm" {
    resource_group_name  = "rg-p-uks-tfstate-001"
    storage_account_name = "stpuksavdtfstate"
    container_name       = "avd-alerts-tfstate"
    key                  = "key-p-uks-avd-alerts"
  }
}
