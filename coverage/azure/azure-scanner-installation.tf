terraform {
  required_providers {
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 2.47"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.90"
    }
  }
}

# ── Variables ─────────────────────────────────────────────────────────────────

variable "tenant_id" {
  type        = string
  description = "Azure AD tenant ID"
}

variable "subscription_id" {
  type        = string
  default     = ""
  description = "Target subscription ID (required when use_mgmt_group = false)"
}

variable "management_group_id" {
  type        = string
  default     = ""
  description = "Target management group ID (required when use_mgmt_group = true)"
}

variable "use_mgmt_group" {
  type        = bool
  default     = false
  description = "When true, assigns roles at management group scope instead of subscription scope"
}

variable "application_name" {
  type        = string
  default     = "brava-azure-scanner"
  description = "Display name for the Azure AD app registration"
}

variable "client_secret_expiry_days" {
  type        = number
  default     = 365
  description = "Validity period in days for the generated client secret (ignored when use_oidc = true)"
}

variable "use_oidc" {
  type        = bool
  default     = false
  description = "When true, uses OIDC / Workload Identity Federation via AWS Cognito instead of a client secret"
}

variable "brava_cognito_identity_pool_id" {
  type        = string
  default     = ""
  description = "Brava's Cognito Identity Pool ID (provided by Brava, required when use_oidc = true)"
}

variable "brava_cognito_identity_id" {
  type        = string
  default     = ""
  description = "Brava's Cognito Identity ID for this tenant (provided by Brava, required when use_oidc = true)"
}



# ── Locals ────────────────────────────────────────────────────────────────────

locals {
  # null when management group mode — azurerm provider accepts null and skips
  # subscription-level validation (combined with skip_provider_registration = true)
  azurerm_subscription_id = var.use_mgmt_group ? null : var.subscription_id

  # Role assignment scope: management group path or subscription path
  role_scope = (var.use_mgmt_group
    ? "/providers/Microsoft.Management/managementGroups/${var.management_group_id}"
    : "/subscriptions/${var.subscription_id}")

  # Compute expiry as a number first, then interpolate into the duration string
  secret_expiry_hours = var.client_secret_expiry_days * 24

  # Output JSON matching the credential interface expected by the scanner.
  # subscriptionId holds the management group ID when isMgmtGroup=true —
  # the scanner reads isMgmtGroup to determine how to interpret the value.
  credentials_json = var.use_oidc ? jsonencode({
    clientId            = azuread_application.scanner.client_id
    tenantId            = var.tenant_id
    subscriptionId      = var.use_mgmt_group ? var.management_group_id : var.subscription_id
    isMgmtGroup         = var.use_mgmt_group
    useOidc             = true
    cognitoIdentityId     = var.brava_cognito_identity_id
    cognitoIdentityPoolId = var.brava_cognito_identity_pool_id
  }) : jsonencode({
    clientId       = azuread_application.scanner.client_id
    tenantId       = var.tenant_id
    clientSecret   = azuread_application_password.scanner[0].value
    subscriptionId = var.use_mgmt_group ? var.management_group_id : var.subscription_id
    isMgmtGroup    = var.use_mgmt_group
  })
}

# ── Providers ─────────────────────────────────────────────────────────────────

# azuread: no explicit config needed — uses current Azure CLI session or env vars
provider "azuread" {}

provider "azurerm" {
  features {}
  subscription_id            = local.azurerm_subscription_id
  skip_provider_registration = true
}

# ── Resources ─────────────────────────────────────────────────────────────────

# Microsoft Graph — well-known app ID, same across all tenants
data "azuread_application_published_app_ids" "well_known" {}

data "azuread_service_principal" "msgraph" {
  client_id = data.azuread_application_published_app_ids.well_known.result["MicrosoftGraph"]
}

# 1. Azure AD Application registration
#    Required Graph application permissions:
#      - Policy.Read.All: read Conditional Access policies (P3C53)
resource "azuread_application" "scanner" {
  display_name = var.application_name

  required_resource_access {
    resource_app_id = data.azuread_application_published_app_ids.well_known.result["MicrosoftGraph"]

    resource_access {
      # Policy.Read.All — application permission
      id   = data.azuread_service_principal.msgraph.app_role_ids["Policy.Read.All"]
      type = "Role"
    }
  }
}

# Grant admin consent for the Graph application permissions
resource "azuread_app_role_assignment" "graph_policy_read" {
  app_role_id         = data.azuread_service_principal.msgraph.app_role_ids["Policy.Read.All"]
  principal_object_id = azuread_service_principal.scanner.object_id
  resource_object_id  = data.azuread_service_principal.msgraph.object_id
}

# 2. Service principal bound to the application
#    In azuread ~> 2.47, use client_id (the application UUID), not the object ID
resource "azuread_service_principal" "scanner" {
  client_id = azuread_application.scanner.client_id
}

# 3a. Client secret — only when NOT using OIDC
resource "azuread_application_password" "scanner" {
  count             = var.use_oidc ? 0 : 1
  application_id    = azuread_application.scanner.id
  end_date_relative = "${local.secret_expiry_hours}h"
}

# 3b. Federated identity credential — only when using OIDC
#     Trusts JWTs from Brava's AWS Cognito Identity Pool, eliminating client secrets.
resource "azuread_application_federated_identity_credential" "aws_cognito" {
  count          = var.use_oidc ? 1 : 0
  application_id = azuread_application.scanner.id
  display_name   = "brava-aws-cognito-oidc"
  description    = "Trusts Brava Security scanner via AWS Cognito Workload Identity Federation"
  issuer         = "https://cognito-identity.amazonaws.com"
  subject        = var.brava_cognito_identity_id
  audiences      = [var.brava_cognito_identity_pool_id]
}

# 4. Reader — read all resources across the scope
resource "azurerm_role_assignment" "role_reader" {
  scope                = local.role_scope
  role_definition_name = "Reader"
  principal_id         = azuread_service_principal.scanner.object_id
  principal_type       = "ServicePrincipal"
}

# 5. Security Reader — read Defender for Cloud, security alerts, policies
resource "azurerm_role_assignment" "role_security_reader" {
  scope                = local.role_scope
  role_definition_name = "Security Reader"
  principal_id         = azuread_service_principal.scanner.object_id
  principal_type       = "ServicePrincipal"
}

# 6. Monitoring Reader — read diagnostic settings and monitor data
resource "azurerm_role_assignment" "role_monitoring_reader" {
  scope                = local.role_scope
  role_definition_name = "Monitoring Reader"
  principal_id         = azuread_service_principal.scanner.object_id
  principal_type       = "ServicePrincipal"
}

# 7. Entra ID — Security Reader directory role
#    Read-only security info in Microsoft Entra ID (sign-in reports, audit logs, etc.).
#    Template ID 5d6b6bb7-de71-4623-b4af-96380a352509 is the well-known ID for
#    Security Reader across all tenants (Microsoft Entra permissions reference).
resource "azuread_directory_role" "entra_security_reader" {
  template_id = "5d6b6bb7-de71-4623-b4af-96380a352509"
}

resource "azuread_directory_role_assignment" "entra_security_reader" {
  role_id             = azuread_directory_role.entra_security_reader.template_id
  principal_object_id = azuread_service_principal.scanner.object_id
}

# ── Outputs ───────────────────────────────────────────────────────────────────

# The azurerm provider (~> 3.90) rejects /providers/Microsoft.aadiam as an invalid scope,
# so Monitoring Reader at the Entra ID ARM scope cannot be assigned via Terraform.
# Run the command below once after terraform apply to enable Entra ID diagnostic settings
# checks (P3C11–P3C15, P3C53). Requires Global Admin or User Access Administrator.
output "manual_step_entra_id_diagnostics" {
  description = "One-time manual step: grant Monitoring Reader at the Entra ID ARM scope"
  value       = <<-EOT
    az role assignment create \
      --role "Monitoring Reader" \
      --assignee-object-id "${azuread_service_principal.scanner.object_id}" \
      --assignee-principal-type ServicePrincipal \
      --scope "/providers/microsoft.aadiam"
  EOT
}

# Client-secret mode: retrieve with `terraform output -raw scanner_credentials`
# and paste the JSON into AWS Secrets Manager.
#
# OIDC mode: the customer does NOT paste this into Secrets Manager.
# Instead, enter tenantId, clientId, subscriptionId in the Brava UI.
# The backend stores the merged credential JSON automatically.
#
# WARNING (client-secret mode only): terraform.tfstate contains clientSecret in plaintext.
# Use a remote backend (e.g. Azure Blob Storage) and do not commit state to git.
# In OIDC mode the state contains no secrets.
output "scanner_credentials" {
  value       = local.credentials_json
  sensitive   = true
  description = "Credentials JSON for the Brava scanner"
}
