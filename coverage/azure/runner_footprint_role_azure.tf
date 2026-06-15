terraform {
  required_version = ">= 1.5"
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

# ---------------------------------------------------------------------------
# Brava Attack Simulation — Azure Footprint
#
# Creates the Entra ID app registration the Brava runner authenticates AS to
# execute attack simulations and collect telemetry in this subscription.
#
# Authentication footprint model - our identity, your grant, no customer secret
# the runner runs in Brava's scope and federates into
# this tenant via Workload Identity Federation. A federated identity credential
# on this app trusts Brava's AWS Cognito Identity Pool — no secret ever leaves
# your environment. A client-secret fallback (use_oidc = false) is available for
# environments that cannot federate.
#
# Submit the outputs (tenantId, clientId, subscriptionId) to Brava when
# registering the Azure environment.
# ---------------------------------------------------------------------------

# ── Variables ──────────────────────────────────────────────────────────────

variable "tenant_id" {
  type        = string
  description = "Azure AD (Entra ID) tenant ID."
}

variable "subscription_id" {
  type        = string
  description = "Target subscription ID where simulations will run."
}

variable "application_name" {
  type        = string
  default     = "brava-attack-simulation-footprint"
  description = "Display name for the footprint Entra ID app registration."
}

variable "use_oidc" {
  type        = bool
  default     = true
  description = "When true (default), trust Brava's AWS Cognito via Workload Identity Federation — no secret. When false, generate a client secret to share with Brava."
}

variable "brava_cognito_identity_pool_id" {
  type        = string
  default     = ""
  description = "Brava's Cognito Identity Pool ID (provided by Brava; required when use_oidc = true)."
}

variable "brava_cognito_identity_id" {
  type        = string
  default     = ""
  description = "Brava's Cognito Identity ID for this tenant (provided by Brava; required when use_oidc = true)."
}

variable "client_secret_expiry_days" {
  type        = number
  default     = 365
  description = "Validity period in days for the generated client secret (ignored when use_oidc = true)."
}

# ── Locals ─────────────────────────────────────────────────────────────────

locals {
  role_scope          = "/subscriptions/${var.subscription_id}"
  secret_expiry_hours = var.client_secret_expiry_days * 24
}

# ── Providers ──────────────────────────────────────────────────────────────

provider "azuread" {}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

# ── App registration + service principal ───────────────────────────────────

# The footprint app. The runner federates into this tenant as this app and acts
# with the RBAC roles assigned below.
resource "azuread_application" "footprint" {
  display_name = var.application_name
}

resource "azuread_service_principal" "footprint" {
  client_id = azuread_application.footprint.client_id
}

# WIF (default): federated identity credential trusting Brava's AWS Cognito.
# Both EC2 and EKS runner hosts assume the same Brava AWS role, mint a Cognito
# OpenID token, and exchange it here — so this trust is host-independent.
resource "azuread_application_federated_identity_credential" "aws_cognito" {
  count          = var.use_oidc ? 1 : 0
  application_id = azuread_application.footprint.id
  display_name   = "brava-aws-cognito-oidc"
  description    = "Trusts the Brava attack-simulation runner via AWS Cognito Workload Identity Federation."
  issuer         = "https://cognito-identity.amazonaws.com"
  subject        = var.brava_cognito_identity_id
  audiences      = [var.brava_cognito_identity_pool_id]
}

# Client-secret fallback (use_oidc = false): share the secret with Brava.
resource "azuread_application_password" "footprint" {
  count             = var.use_oidc ? 0 : 1
  application_id    = azuread_application.footprint.id
  end_date_relative = "${local.secret_expiry_hours}h"
}

# ── Subscription RBAC — execute simulations + collect telemetry ─────────────
#
# Attack simulations create, modify, and delete resources, so the footprint
# needs broad write access (Contributor) plus the ability to manipulate RBAC
# for identity-tactic simulations (Role Based Access Control Administrator) —
# the Azure analogue of the GCP footprint's editor + projectIamAdmin grants.
# Security Reader / Monitoring Reader cover telemetry collection (Defender for
# Cloud alerts, Activity Logs, Azure Monitor).

resource "azurerm_role_assignment" "contributor" {
  scope                = local.role_scope
  role_definition_name = "Contributor"
  principal_id         = azuread_service_principal.footprint.object_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "rbac_administrator" {
  scope                = local.role_scope
  role_definition_name = "Role Based Access Control Administrator"
  principal_id         = azuread_service_principal.footprint.object_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "security_reader" {
  scope                = local.role_scope
  role_definition_name = "Security Reader"
  principal_id         = azuread_service_principal.footprint.object_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "monitoring_reader" {
  scope                = local.role_scope
  role_definition_name = "Monitoring Reader"
  principal_id         = azuread_service_principal.footprint.object_id
  principal_type       = "ServicePrincipal"
}

# ── Outputs — submit to Brava when registering the environment ──────────────

output "tenant_id" {
  description = "Entra ID tenant ID. Provide to Brava when registering the Azure environment."
  value       = var.tenant_id
}

output "client_id" {
  description = "Footprint app (client) ID. Provide to Brava when registering the Azure environment."
  value       = azuread_application.footprint.client_id
}

output "subscription_id" {
  description = "Target subscription ID. Provide to Brava when registering the Azure environment."
  value       = var.subscription_id
}

# Only populated in client-secret fallback mode (use_oidc = false).
# WARNING: terraform.tfstate stores this in plaintext — use a remote backend
# and do not commit state. In WIF mode (default) the state contains no secrets.
output "client_secret" {
  description = "Footprint client secret (client-secret fallback only). Empty in WIF mode."
  value       = var.use_oidc ? "" : azuread_application_password.footprint[0].value
  sensitive   = true
}
