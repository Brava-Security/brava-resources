mock_provider "google" {}

variables {
  brava_runner_sa_email = "runner-tenant123@brava-gcp.iam.gserviceaccount.com"
  project_id            = "acme-sec-host"
}

run "single_project_backwards_compatible_default" {
  command = plan

  assert {
    condition     = length(google_project_service.securitycenter) == 1 && contains(keys(google_project_service.securitycenter), "acme-sec-host")
    error_message = "Default single-project apply must enable securitycenter on var.project_id"
  }

  assert {
    condition     = length(google_project_iam_member.simulation_roles) == 6
    error_message = "Default single-project apply must bind all 6 simulation roles on var.project_id"
  }

  assert {
    condition     = length(google_folder_iam_member.simulation_roles) == 0
    error_message = "Default single-project apply must create zero folder IAM bindings"
  }
}

run "folder_mode_normalizes_bare_and_prefixed_ids_and_skips_project_iam" {
  command = plan

  variables {
    folder_ids         = ["123456789012", "folders/987654321098"]
    target_project_ids = ["acme-dev-1", "acme-stg-1"]
  }

  assert {
    condition     = output.enrolled_folder_ids == toset(["folders/123456789012", "folders/987654321098"])
    error_message = "folder_ids must normalize both bare numeric and folders/ prefixed IDs without doubling folders/"
  }

  assert {
    condition     = length(google_folder_iam_member.simulation_roles) == 14
    error_message = "2 folders x 7 roles (6 simulation roles + folderViewer) must produce 14 folder IAM bindings"
  }

  assert {
    condition     = length(google_project_iam_member.simulation_roles) == 0
    error_message = "Project-level IAM bindings must be skipped when folder_ids grants inheritance"
  }

  assert {
    condition     = tolist(keys(google_project_service.securitycenter)) == tolist(["acme-dev-1", "acme-stg-1"]) && output.enabled_securitycenter_projects == toset(["acme-dev-1", "acme-stg-1"])
    error_message = "securitycenter API must be enabled on target_project_ids"
  }
}

run "multi_project_list_without_folders" {
  command = plan

  variables {
    target_project_ids = ["acme-dev-1", "acme-dev-2"]
  }

  assert {
    condition     = length(google_project_iam_member.simulation_roles) == 12
    error_message = "2 projects x 6 roles must produce 12 project IAM bindings when folder_ids is empty"
  }
}

run "rejects_malformed_folder_ids" {
  command = plan

  variables {
    folder_ids = ["folders/folders/123456789012"]
  }

  expect_failures = [
    var.folder_ids,
  ]
}
