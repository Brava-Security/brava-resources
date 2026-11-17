terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0"
    }
  }
}

variable "brava_runner_sa_email" {
  type        = string
  description = "Email of the Brava-side GCP runner SA that will impersonate the footprint SA."
  validation {
    condition     = can(regex("^[^@]+@[^@]+\\.iam\\.gserviceaccount\\.com$", var.brava_runner_sa_email))
    error_message = "brava_runner_sa_email must be a GCP service account email (e.g., runner-foo@brava-gcp.iam.gserviceaccount.com)."
  }
}

variable "project_id" {
  description = "Host GCP project ID where the single brava-footprint service account is created (and the default target project when neither folder_ids nor target_project_ids is set)."
  type        = string
}

variable "folder_ids" {
  description = "Optional set of non-prod GCP Folder IDs (e.g. [\"123456789012\"] or [\"folders/123456789012\"]) on which to grant simulation IAM roles so all child projects inherit access."
  type        = set(string)
  default     = []
  validation {
    condition     = alltrue([for f in var.folder_ids : can(regex("^(folders/)?[0-9]+$", trimspace(f)))])
    error_message = "Each entry in folder_ids must be a numeric GCP folder ID or 'folders/<number>'."
  }
}

variable "target_project_ids" {
  description = "Optional set of non-prod GCP project IDs to enable Security Command Center API on (and bind project-level simulation IAM roles on when folder_ids is empty). Defaults to [var.project_id]."
  type        = set(string)
  default     = []
}

variable "service_account_name" {
  description = "Name of the footprint service account"
  type        = string
  default     = "brava-footprint"
}

locals {
  simulation_project_roles = toset([
    "roles/editor",
    "roles/iam.serviceAccountAdmin",
    "roles/resourcemanager.projectIamAdmin",
    "roles/iam.serviceAccountKeyAdmin",
    "roles/secretmanager.admin",
    "roles/serviceusage.serviceUsageAdmin",
  ])

  simulation_folder_roles = setunion(local.simulation_project_roles, [
    "roles/resourcemanager.folderViewer",
  ])

  normalized_folder_ids = toset([
    for f in var.folder_ids :
    startswith(trimspace(f), "folders/") ? trimspace(f) : "folders/${trimspace(f)}"
  ])

  effective_api_projects         = length(var.target_project_ids) > 0 ? var.target_project_ids : toset([var.project_id])
  additional_api_projects        = setsubtract(local.effective_api_projects, toset([var.project_id]))
  project_iam_targets            = length(local.normalized_folder_ids) > 0 ? toset([]) : local.effective_api_projects
  host_project_iam_count         = contains(local.project_iam_targets, var.project_id) ? 1 : 0
  additional_project_iam_targets = setsubtract(local.project_iam_targets, toset([var.project_id]))

  folder_role_bindings = {
    for pair in setproduct(local.normalized_folder_ids, local.simulation_folder_roles) :
    "${pair[0]}::${pair[1]}" => {
      folder = pair[0]
      role   = pair[1]
    }
  }

  project_role_bindings = {
    for pair in setproduct(local.additional_project_iam_targets, local.simulation_project_roles) :
    "${pair[0]}::${pair[1]}" => {
      project = pair[0]
      role    = pair[1]
    }
  }
}

# disable_on_destroy = false keeps SCC enabled if `terraform destroy` runs so
# unrelated SCC consumers in enrolled projects are unaffected.
resource "google_project_service" "securitycenter" {
  count              = contains(local.effective_api_projects, var.project_id) ? 1 : 0
  project            = var.project_id
  service            = "securitycenter.googleapis.com"
  disable_on_destroy = false
}

moved {
  from = google_project_service.securitycenter
  to   = google_project_service.securitycenter[0]
}

resource "google_project_service" "additional_securitycenter" {
  for_each           = local.additional_api_projects
  project            = each.value
  service            = "securitycenter.googleapis.com"
  disable_on_destroy = false
}

resource "google_service_account" "footprint" {
  project      = var.project_id
  account_id   = var.service_account_name
  display_name = "Brava Attack Simulation Footprint"
  description  = "Impersonated by the Brava runner to execute simulations in enrolled non-prod projects"
}

resource "google_service_account_iam_binding" "brava_runner_can_impersonate_footprint" {
  service_account_id = google_service_account.footprint.name
  role               = "roles/iam.serviceAccountTokenCreator"
  members            = ["serviceAccount:${var.brava_runner_sa_email}"]
}

# Preserve original single-project resource addresses via count + moved blocks
# so existing single-project Terraform states upgrade with zero IAM churn.
resource "google_project_iam_member" "editor" {
  count   = local.host_project_iam_count
  project = var.project_id
  role    = "roles/editor"
  member  = "serviceAccount:${google_service_account.footprint.email}"
}

moved {
  from = google_project_iam_member.editor
  to   = google_project_iam_member.editor[0]
}

resource "google_project_iam_member" "service_account_admin" {
  count   = local.host_project_iam_count
  project = var.project_id
  role    = "roles/iam.serviceAccountAdmin"
  member  = "serviceAccount:${google_service_account.footprint.email}"
}

moved {
  from = google_project_iam_member.service_account_admin
  to   = google_project_iam_member.service_account_admin[0]
}

resource "google_project_iam_member" "project_iam_admin" {
  count   = local.host_project_iam_count
  project = var.project_id
  role    = "roles/resourcemanager.projectIamAdmin"
  member  = "serviceAccount:${google_service_account.footprint.email}"
}

moved {
  from = google_project_iam_member.project_iam_admin
  to   = google_project_iam_member.project_iam_admin[0]
}

resource "google_project_iam_member" "service_account_key_admin" {
  count   = local.host_project_iam_count
  project = var.project_id
  role    = "roles/iam.serviceAccountKeyAdmin"
  member  = "serviceAccount:${google_service_account.footprint.email}"
}

moved {
  from = google_project_iam_member.service_account_key_admin
  to   = google_project_iam_member.service_account_key_admin[0]
}

resource "google_project_iam_member" "secret_manager_admin" {
  count   = local.host_project_iam_count
  project = var.project_id
  role    = "roles/secretmanager.admin"
  member  = "serviceAccount:${google_service_account.footprint.email}"
}

moved {
  from = google_project_iam_member.secret_manager_admin
  to   = google_project_iam_member.secret_manager_admin[0]
}

resource "google_project_iam_member" "service_usage_admin" {
  count   = local.host_project_iam_count
  project = var.project_id
  role    = "roles/serviceusage.serviceUsageAdmin"
  member  = "serviceAccount:${google_service_account.footprint.email}"
}

moved {
  from = google_project_iam_member.service_usage_admin
  to   = google_project_iam_member.service_usage_admin[0]
}

resource "google_folder_iam_member" "simulation_roles" {
  for_each = local.folder_role_bindings
  folder   = each.value.folder
  role     = each.value.role
  member   = "serviceAccount:${google_service_account.footprint.email}"
}

resource "google_project_iam_member" "simulation_roles" {
  for_each = local.project_role_bindings
  project  = each.value.project
  role     = each.value.role
  member   = "serviceAccount:${google_service_account.footprint.email}"
}

output "service_account_email" {
  description = "Email of the footprint service account. Provide to Brava when registering the GCP runner footprint."
  value       = google_service_account.footprint.email
}

output "project_id" {
  description = "Host GCP project ID of the footprint service account. Provide to Brava when registering the GCP runner footprint."
  value       = var.project_id
}

output "enrolled_folder_ids" {
  description = "Normalized GCP folder IDs granted simulation IAM inheritance."
  value       = local.normalized_folder_ids
}

output "enabled_securitycenter_projects" {
  description = "GCP project IDs where securitycenter.googleapis.com was enabled."
  value       = local.effective_api_projects
}
