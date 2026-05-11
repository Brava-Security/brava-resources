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
  description = "GCP project ID where the Workload Identity Pool will be created"
}

variable "gcp_org_id" {
  type        = string
  description = "GCP organization ID to grant read access on (numeric, e.g. '123456789012')"
}

variable "brava_aws_account_id" {
  type        = string
  description = "Brava Security's AWS account ID (provided by Brava)"
}

variable "brava_aws_role_name" {
  type        = string
  description = "Brava Security's ECS task IAM role name (provided by Brava, e.g. 'brava-gcp-scanner-task-role')"
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
  suffix       = var.resource_suffix != "" ? "-${var.resource_suffix}" : ""
  pool_id      = "brava-scanner-pool${local.suffix}"
  provider_id  = "aws-provider${local.suffix}"
  sa_id        = "brava-org-reader${local.suffix}"
}

# -------------------------
# Resources
# -------------------------

# Resolve project ID to numeric project number.
# The WIF audience URL requires the numeric project number, not the project ID string.
data "google_project" "wif_project" {
  project_id = var.gcp_project_id
}

# Workload Identity Pool — hosted in the customer's chosen GCP project
resource "google_iam_workload_identity_pool" "brava_scanner" {
  project                   = var.gcp_project_id
  workload_identity_pool_id = local.pool_id
  display_name              = "Brava Scanner Pool"
  description               = "Workload Identity Pool for Brava Security Scanner (AWS ECS)"
}

# WIF Provider — AWS type, trusts tokens from Brava's AWS account
resource "google_iam_workload_identity_pool_provider" "aws" {
  project                            = var.gcp_project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.brava_scanner.workload_identity_pool_id
  workload_identity_pool_provider_id = local.provider_id
  display_name                       = "Brava AWS ECS Provider"
  description                        = "Trusts Brava Security's AWS ECS task role for scanner access"

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

  # Restrict access to Brava's specific ECS task role only.
  # The session suffix is intentionally excluded — ECS tasks produce per-task sessions
  # but we want to gate on the role, not the session name.
  attribute_condition = "attribute.aws_role == \"arn:aws:sts::${var.brava_aws_account_id}:assumed-role/${var.brava_aws_role_name}\""

  aws {
    account_id = var.brava_aws_account_id
  }
}

# Service Account that the scanner will impersonate to read org resources
resource "google_service_account" "brava_org_reader" {
  project      = var.gcp_project_id
  account_id   = local.sa_id
  display_name = "Brava Org Reader"
  description  = "Impersonated by Brava Security scanner to read GCP org resources"
}

# Grant the SA read access at the org level.
# NOTE: roles/viewer is a broad bootstrap grant covering all projects in the org.
# Replace with a least-privilege custom role scoped to the specific GCP APIs
# used by scan checks before GA.
resource "google_organization_iam_member" "brava_org_viewer" {
  org_id = var.gcp_org_id
  role   = "roles/viewer"
  member = "serviceAccount:${google_service_account.brava_org_reader.email}"
}

# roles/viewer covers project resources but not the org resource itself.
# This grants resourcemanager.organizations.get so the scanner can resolve org metadata.
resource "google_organization_iam_member" "brava_org_resource_viewer" {
  org_id = var.gcp_org_id
  role   = "roles/resourcemanager.organizationViewer"
  member = "serviceAccount:${google_service_account.brava_org_reader.email}"
}

# Grants getIamPolicy on projects, folders, and organizations so the scanner
# can read IAM audit configs across the full resource hierarchy.
resource "google_organization_iam_member" "brava_security_reviewer" {
  org_id = var.gcp_org_id
  role   = "roles/iam.securityReviewer"
  member = "serviceAccount:${google_service_account.brava_org_reader.email}"
}

# Grants resourcemanager.folders.get so the scanner can read folder metadata
# (specifically the parent field) to traverse the resource hierarchy.
resource "google_organization_iam_member" "brava_folder_viewer" {
  org_id = var.gcp_org_id
  role   = "roles/resourcemanager.folderViewer"
  member = "serviceAccount:${google_service_account.brava_org_reader.email}"
}

# Allow Brava's ECS task role (via WIF) to impersonate the reader SA.
# Bound to the specific aws_role attribute principal — NOT the entire pool —
# so no future pool provider can impersonate this SA.
resource "google_service_account_iam_member" "wif_binding" {
  service_account_id = google_service_account.brava_org_reader.name
  role               = "roles/iam.workloadIdentityUser"

  # pool.name is: projects/{project_number}/locations/global/workloadIdentityPools/{pool_id}
  # This automatically uses the numeric project number, not the project ID string.
  member = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.brava_scanner.name}/attribute.aws_role/arn:aws:sts::${var.brava_aws_account_id}:assumed-role/${var.brava_aws_role_name}"
}

# Allow the WIF identity to call generateAccessToken on the reader SA.
# Required because the scanner uses service_account_impersonation_url, which calls
# the iamcredentials.googleapis.com generateAccessToken endpoint directly.
resource "google_service_account_iam_member" "wif_token_creator" {
  service_account_id = google_service_account.brava_org_reader.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.brava_scanner.name}/attribute.aws_role/arn:aws:sts::${var.brava_aws_account_id}:assumed-role/${var.brava_aws_role_name}"
}

# -------------------------
# Outputs
# -------------------------

# These three values must be stored in Brava's DB per tenant after the customer runs this module.

output "wif_audience" {
  description = "WIF pool/provider URL — store as wifAudience in Brava's tenant DB record. Uses numeric project number (not project ID) as required by the GCP STS endpoint."
  value       = "//iam.googleapis.com/${google_iam_workload_identity_pool.brava_scanner.name}/providers/${google_iam_workload_identity_pool_provider.aws.workload_identity_pool_provider_id}"
}

output "client_sa_email" {
  description = "Reader SA email — store as clientSaEmail in Brava's tenant DB record."
  value       = google_service_account.brava_org_reader.email
}

output "gcp_org_id" {
  description = "GCP org ID being scanned — store as gcpOrgId in Brava's tenant DB record."
  value       = var.gcp_org_id
}
