terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0"
    }
  }
}

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------

variable "brava_runner_sa_email" {
  type        = string
  description = "Email of the Brava-side GCP runner SA that will impersonate the footprint SA. Output of topologyA/brava-gcp/'s runner_sa_email."
  validation {
    condition     = can(regex("^[^@]+@[^@]+\\.iam\\.gserviceaccount\\.com$", var.brava_runner_sa_email))
    error_message = "brava_runner_sa_email must be a GCP service account email (e.g., runner-foo@brava-gcp.iam.gserviceaccount.com)."
  }
}

variable "project_id" {
  description = "GCP project ID where simulations will run"
  type        = string
}

variable "service_account_name" {
  description = "Name of the footprint service account"
  type        = string
  default     = "brava-footprint"
}

# ---------------------------------------------------------------------------
# Required GCP APIs
# ---------------------------------------------------------------------------

# Most "trigger attack → verify SCC finding" simulations call
# `gcloud scc findings list` in their detection step. The Security Command
# Center API (Standard tier — free) must be enabled for those listings to
# return anything. Without it, every detection-step polls and exits 1 with
# `Security Command Center API has not been used in project ... before or
# it is disabled.`
#
# disable_on_destroy = false keeps the API on if `terraform destroy` runs,
# so unrelated SCC consumers in the project (other tooling, dashboards) are
# not affected by tearing down this footprint.
resource "google_project_service" "securitycenter" {
  project            = var.project_id
  service            = "securitycenter.googleapis.com"
  disable_on_destroy = false
}

# ---------------------------------------------------------------------------
# Footprint Service Account
# ---------------------------------------------------------------------------

resource "google_service_account" "footprint" {
  project      = var.project_id
  account_id   = var.service_account_name
  display_name = "Brava Attack Simulation Footprint"
  description  = "Impersonated by the Brava runner to execute simulations in this project"
}

resource "google_service_account_iam_binding" "brava_runner_can_impersonate_footprint" {
  service_account_id = google_service_account.footprint.name
  role               = "roles/iam.serviceAccountTokenCreator"
  members            = ["serviceAccount:${var.brava_runner_sa_email}"]
}

# ---------------------------------------------------------------------------
# Project IAM — roles required to execute simulations
# ---------------------------------------------------------------------------

resource "google_project_iam_member" "editor" {
  project = var.project_id
  role    = "roles/editor"
  member  = "serviceAccount:${google_service_account.footprint.email}"
}

resource "google_project_iam_member" "service_account_admin" {
  project = var.project_id
  role    = "roles/iam.serviceAccountAdmin"
  member  = "serviceAccount:${google_service_account.footprint.email}"
}

resource "google_project_iam_member" "project_iam_admin" {
  project = var.project_id
  role    = "roles/resourcemanager.projectIamAdmin"
  member  = "serviceAccount:${google_service_account.footprint.email}"
}

resource "google_project_iam_member" "service_account_key_admin" {
  project = var.project_id
  role    = "roles/iam.serviceAccountKeyAdmin"
  member  = "serviceAccount:${google_service_account.footprint.email}"
}

resource "google_project_iam_member" "secret_manager_admin" {
  project = var.project_id
  role    = "roles/secretmanager.admin"
  member  = "serviceAccount:${google_service_account.footprint.email}"
}

resource "google_project_iam_member" "service_usage_admin" {
  project = var.project_id
  role    = "roles/serviceusage.serviceUsageAdmin"
  member  = "serviceAccount:${google_service_account.footprint.email}"
}

# ---------------------------------------------------------------------------
# Outputs — submit both to Brava when registering the environment
# ---------------------------------------------------------------------------

output "service_account_email" {
  description = "Email of the footprint service account. Provide to Brava when registering the GCP environment."
  value       = google_service_account.footprint.email
}

output "project_id" {
  description = "GCP project ID. Provide to Brava when registering the GCP environment."
  value       = var.project_id
}
