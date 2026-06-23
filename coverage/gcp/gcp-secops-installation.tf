terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0"
    }
  }
}

# -------------------------
# Variables
# -------------------------

variable "gcp_project_id" {
  type        = string
  description = "GCP project ID where the Workload Identity Pool will be created and where Google SecOps is located"
}

variable "brava_aws_account_id" {
  type        = string
  description = "Brava Security's AWS account ID (provided by Brava)"
}

variable "brava_aws_role_names" {
  type        = list(string)
  description = "List of Brava Security's AWS IAM role names (provided by Brava during onboarding)"
}

variable "resource_suffix" {
  type        = string
  default     = ""
  description = "Optional suffix appended to resource names (e.g. your name/initials). Use this when running locally to avoid overwriting teammates' resources in the same GCP project."
}

# -------------------------
# Locals
# -------------------------

locals {
  suffix      = var.resource_suffix != "" ? "-${var.resource_suffix}" : ""
  pool_id     = "brava-pool${local.suffix}"
  provider_id = "aws-provider${local.suffix}"
  sa_id       = "brava-secops${local.suffix}"

  # Custom-role IDs allow only [A-Za-z0-9_.] (no hyphens), so the suffix is
  # joined with an underscore and any hyphens are replaced.
  role_suffix = var.resource_suffix != "" ? "_${replace(var.resource_suffix, "-", "_")}" : ""
  role_id     = "bravaSecopsHygieneReader${local.role_suffix}"
}

# -------------------------
# Resources
# -------------------------

# Workload Identity Pool — hosted in the customer's chosen GCP project
resource "google_iam_workload_identity_pool" "brava_secops" {
  project                   = var.gcp_project_id
  workload_identity_pool_id = local.pool_id
  display_name              = "Brava SecOps Pool"
  description               = "Workload Identity Pool for Brava Security Google SecOps Integration (AWS)"
}

# WIF Provider — AWS type, trusts tokens from Brava's AWS account
resource "google_iam_workload_identity_pool_provider" "aws" {
  project                            = var.gcp_project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.brava_secops.workload_identity_pool_id
  workload_identity_pool_provider_id = local.provider_id
  display_name                       = "Brava AWS Provider"
  description                        = "Trusts Brava Security's AWS IAM roles for Google SecOps access"

  # Extract the role ARN (without session suffix) from the full assumed-role ARN.
  # At runtime, aws_role looks like: arn:aws:sts::{account}:assumed-role/{role}/{session}
  # The mapping strips the session suffix so the condition can match on the role name only.
  attribute_mapping = {
    "google.subject" = "assertion.arn"
    "attribute.aws_role" = join("", [
      "assertion.arn.contains('assumed-role') ? ",
      "assertion.arn.extract('{account_arn}assumed-role/') + 'assumed-role/' + assertion.arn.extract('assumed-role/{role_and_session}').split('/')[0]",
      " : assertion.arn"
    ])
  }

  # Restrict access to Brava's specific ECS task roles only.
  # Using the CEL 'in' operator to safely check list membership.
  attribute_condition = format(
    "attribute.aws_role in [%s]",
    join(", ", [for role in var.brava_aws_role_names : "\"arn:aws:sts::${var.brava_aws_account_id}:assumed-role/${role}\""])
  )

  aws {
    account_id = var.brava_aws_account_id
  }
}

# Service Account that Brava will impersonate to query Google SecOps APIs
resource "google_service_account" "brava_secops_viewer" {
  project      = var.gcp_project_id
  account_id   = local.sa_id
  display_name = "Brava SecOps Viewer"
  description  = "Impersonated by Brava Security to retrieve Google SecOps rules and events"
}

# Grant the predefined Chronicle API Viewer role to the Service Account
resource "google_project_iam_member" "brava_chronicle_viewer" {
  project = var.gcp_project_id
  role    = "roles/chronicle.viewer"
  member  = "serviceAccount:${google_service_account.brava_secops_viewer.email}"
}

# Custom read-only role: the ingestion/parsing reads NOT included in
# roles/chronicle.viewer (feeds, parsers, parser extensions, parsing/validation
# errors, log-type config, alert grouping). Every permission is read-only
# (.get/.list) — no write/modify — and scoped to the Google SecOps domain.
resource "google_project_iam_custom_role" "brava_secops_hygiene_reader" {
  project     = var.gcp_project_id
  role_id     = local.role_id
  title       = "Brava SecOps Hygiene Reader${local.suffix}"
  description = "Read-only ingestion/parsing permissions for Brava hygiene-service, on top of roles/chronicle.viewer."
  stage       = "GA"

  permissions = [
    # Feeds (ingestion sources)
    "chronicle.feeds.list",
    "chronicle.feeds.get",
    "chronicle.feedSourceTypeSchemas.list",

    # Parsers, extensions & validation (normalization quality)
    "chronicle.parsers.list",
    "chronicle.parsers.get",
    "chronicle.parserExtensions.list",
    "chronicle.parserExtensions.get",
    "chronicle.parsingErrors.list",
    "chronicle.validationReports.get",
    "chronicle.validationErrors.list",
    "chronicle.extensionValidationReports.list",
    "chronicle.extensionValidationReports.get",

    # Log types & per-log-type config
    "chronicle.logTypes.list",
    "chronicle.logTypes.get",
    "chronicle.logTypeSettings.list",
    "chronicle.logTypeSettings.get",

    # Detection tuning
    "chronicle.alertGroupingRules.get",
  ]
}

# Grant the custom hygiene-reader role to the same Brava SA.
resource "google_project_iam_member" "brava_secops_hygiene_reader" {
  project = var.gcp_project_id
  role    = google_project_iam_custom_role.brava_secops_hygiene_reader.id
  member  = "serviceAccount:${google_service_account.brava_secops_viewer.email}"
}

# Allow Brava's ECS task roles (via WIF) to impersonate the viewer SA.
# Bound to the specific aws_role attribute principal — NOT the entire pool —
# so no future pool provider can impersonate this SA.
resource "google_service_account_iam_member" "wif_binding" {
  for_each = toset(var.brava_aws_role_names)

  service_account_id = google_service_account.brava_secops_viewer.name
  role               = "roles/iam.workloadIdentityUser"

  # pool.name is: projects/{project_number}/locations/global/workloadIdentityPools/{pool_id}
  # This automatically uses the numeric project number, not the project ID string.
  member = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.brava_secops.name}/attribute.aws_role/arn:aws:sts::${var.brava_aws_account_id}:assumed-role/${each.key}"
}

# Allow the WIF identity to call generateAccessToken on the viewer SA.
# Required because the integration client uses service_account_impersonation_url, which calls
# the iamcredentials.googleapis.com generateAccessToken endpoint directly.
resource "google_service_account_iam_member" "wif_token_creator" {
  for_each = toset(var.brava_aws_role_names)

  service_account_id = google_service_account.brava_secops_viewer.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.brava_secops.name}/attribute.aws_role/arn:aws:sts::${var.brava_aws_account_id}:assumed-role/${each.key}"
}

# -------------------------
# Outputs
# -------------------------

output "wif_audience" {
  description = "WIF pool/provider URL — store as wifAudience in Brava's integration settings. Uses numeric project number (not project ID) as required by the GCP STS endpoint."
  value       = "//iam.googleapis.com/${google_iam_workload_identity_pool.brava_secops.name}/providers/${google_iam_workload_identity_pool_provider.aws.workload_identity_pool_provider_id}"
}

output "client_sa_email" {
  description = "Viewer SA email — store as clientSaEmail in Brava's integration settings."
  value       = google_service_account.brava_secops_viewer.email
}

output "gcp_project_id" {
  description = "GCP Project ID — store as projectId in Brava's integration settings."
  value       = var.gcp_project_id
}
