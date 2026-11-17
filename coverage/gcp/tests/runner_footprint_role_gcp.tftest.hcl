mock_provider "google" {}

variables {
  brava_runner_sa_email = "runner-tenant123@brava-gcp.iam.gserviceaccount.com"
  project_id            = "acme-sec-host"
}

run "single_project_backwards_compatible_default" {
  command = plan

  assert {
    condition     = length(google_project_service.securitycenter) == 1 && google_project_service.securitycenter[0].project == "acme-sec-host" && length(google_project_service.additional_securitycenter) == 0
    error_message = "Default single-project apply must enable securitycenter[0] on var.project_id with zero additional_securitycenter instances"
  }

  assert {
    condition = (
      length(google_project_iam_member.editor) == 1 &&
      length(google_project_iam_member.service_account_admin) == 1 &&
      length(google_project_iam_member.project_iam_admin) == 1 &&
      length(google_project_iam_member.service_account_key_admin) == 1 &&
      length(google_project_iam_member.secret_manager_admin) == 1 &&
      length(google_project_iam_member.service_usage_admin) == 1 &&
      length(google_project_iam_member.simulation_roles) == 0
    )
    error_message = "Default single-project apply must preserve all 6 discrete [0] IAM bindings on var.project_id and create zero additional simulation_roles bindings"
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
    condition = (
      length(google_project_iam_member.editor) == 0 &&
      length(google_project_iam_member.service_account_admin) == 0 &&
      length(google_project_iam_member.project_iam_admin) == 0 &&
      length(google_project_iam_member.service_account_key_admin) == 0 &&
      length(google_project_iam_member.secret_manager_admin) == 0 &&
      length(google_project_iam_member.service_usage_admin) == 0 &&
      length(google_project_iam_member.simulation_roles) == 0
    )
    error_message = "All project-level IAM bindings ([0] and simulation_roles) must be skipped when folder_ids grants inheritance"
  }

  assert {
    condition     = length(google_project_service.securitycenter) == 0 && tolist(keys(google_project_service.additional_securitycenter)) == tolist(["acme-dev-1", "acme-stg-1"]) && output.enabled_securitycenter_projects == toset(["acme-dev-1", "acme-stg-1"])
    error_message = "securitycenter API must be enabled on target_project_ids"
  }
}

run "multi_project_list_excluding_host_project" {
  command = plan

  variables {
    target_project_ids = ["acme-dev-1", "acme-dev-2"]
  }

  assert {
    condition = (
      length(google_project_iam_member.editor) == 0 &&
      length(google_project_iam_member.service_account_admin) == 0 &&
      length(google_project_iam_member.project_iam_admin) == 0 &&
      length(google_project_iam_member.service_account_key_admin) == 0 &&
      length(google_project_iam_member.secret_manager_admin) == 0 &&
      length(google_project_iam_member.service_usage_admin) == 0 &&
      length(google_project_iam_member.simulation_roles) == 12
    )
    error_message = "2 non-host projects x 6 roles must produce 0 [0] host bindings and 12 simulation_roles bindings when folder_ids is empty"
  }

  assert {
    condition     = length(google_project_service.securitycenter) == 0 && tolist(keys(google_project_service.additional_securitycenter)) == tolist(["acme-dev-1", "acme-dev-2"])
    error_message = "additional_securitycenter must enable SCC on both non-host target projects"
  }
}

run "multi_project_list_including_host_project" {
  command = plan

  variables {
    target_project_ids = ["acme-sec-host", "acme-dev-2"]
  }

  assert {
    condition = (
      length(google_project_iam_member.editor) == 1 &&
      length(google_project_iam_member.service_account_admin) == 1 &&
      length(google_project_iam_member.project_iam_admin) == 1 &&
      length(google_project_iam_member.service_account_key_admin) == 1 &&
      length(google_project_iam_member.secret_manager_admin) == 1 &&
      length(google_project_iam_member.service_usage_admin) == 1 &&
      length(google_project_iam_member.simulation_roles) == 6
    )
    error_message = "Including var.project_id in target_project_ids must keep var.project_id on [0] bindings and add 6 simulation_roles bindings only for the additional project"
  }

  assert {
    condition     = length(google_project_service.securitycenter) == 1 && tolist(keys(google_project_service.additional_securitycenter)) == tolist(["acme-dev-2"]) && output.enabled_securitycenter_projects == toset(["acme-sec-host", "acme-dev-2"])
    error_message = "Including var.project_id in target_project_ids must keep securitycenter[0] on var.project_id and enable additional_securitycenter only on acme-dev-2"
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
