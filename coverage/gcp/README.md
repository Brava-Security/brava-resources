# GCP Scanner — Terraform

Provisions a Workload Identity Federation (WIF) pool, a reader service account, and org-level role bindings so the Brava scanner can read your GCP organization without long-lived keys.

The same module works for single-project and organization environments.

## Inputs from Brava

Brava will deliver these values separately (they are **not** in this repo):

| Variable | What Brava sends |
|---|---|
| `brava_aws_account_id` | Brava's AWS account ID (the WIF provider trusts tokens from this account) |
| `brava_aws_role_name` | Brava's ECS task role name (the WIF provider gates impersonation to this role) |

## Run

Replace each `<PLACEHOLDER>`.

```bash
terraform init
terraform apply \
  -var="gcp_project_id=<GCP_PROJECT_ID>" \
  -var="gcp_org_id=<NUMERIC_GCP_ORG_ID>" \
  -var="brava_aws_account_id=<PROVIDED_BY_BRAVA>" \
  -var="brava_aws_role_name=<PROVIDED_BY_BRAVA>"
```

## After apply

Run `terraform output` and share these values with Brava (they go into the per-tenant connection record):

| Terraform output | Brava field |
|---|---|
| `wif_audience` | `wifAudience` |
| `client_sa_email` | `saEmail` |
| `gcp_org_id` | `orgId` |

For a **single-project** environment, also tell Brava the **project ID** — the same three outputs above are still used for WIF.

## Optional variables

| Variable | Default | Notes |
|---|---|---|
| `resource_suffix` | `""` | Suffix appended to pool/provider/SA names. Use when multiple people run this in the same GCP project so resources don't collide. |

## Minimum permissions for the user running Terraform

- **Project** — create/configure Workload Identity pools and providers, create service accounts, manage IAM policies for those service accounts.
- **Organization** — update org IAM (e.g. `resourcemanager.organizations.setIamPolicy`) so the reader SA receives the org-level role bindings.

Predefined roles or a custom role bundling only the permissions above are both fine.

---

# Attack Simulation — GCP Footprint

Separately from the read-only scanner above, `runner_footprint_role_gcp.tf` provisions a single `brava-footprint` service account in a host project (`project_id`), allows the Brava runner SA (`brava_runner_sa_email`) to impersonate it via `roles/iam.serviceAccountTokenCreator`, enables `securitycenter.googleapis.com`, and binds simulation IAM roles across a single project, an explicit list of non-prod projects (`target_project_ids`), or non-prod GCP folders (`folder_ids`).

Download `runner_footprint_role_gcp.tf` into its own directory before running `terraform init` (each `.tf` file in `coverage/gcp/` is a standalone root module).

## Inputs from Brava

Find this in **Detections → Settings → Runners** on your GCP runner card:

| Variable | What Brava sends |
|---|---|
| `brava_runner_sa_email` | Email of the Brava-managed GCP runner SA (`runner-<tenant>@<brava-project>.iam.gserviceaccount.com`) |

## Run

Replace each `<PLACEHOLDER>`.

### Single project (default)

Creates `brava-footprint` in `<GCP_PROJECT_ID>`, enables `securitycenter.googleapis.com`, and binds simulation roles on `<GCP_PROJECT_ID>`.

```bash
terraform init
terraform apply \
  -var="brava_runner_sa_email=<PROVIDED_BY_BRAVA>" \
  -var="project_id=<GCP_PROJECT_ID>"
```

### Multi-project (without folders)

Creates `brava-footprint` once in `<HOST_PROJECT_ID>` and binds project-level simulation roles + enables `securitycenter.googleapis.com` on each project in `target_project_ids`.

```bash
terraform init
terraform apply \
  -var="brava_runner_sa_email=<PROVIDED_BY_BRAVA>" \
  -var="project_id=<HOST_PROJECT_ID>" \
  -var='target_project_ids=["<NON_PROD_PROJECT_1>","<NON_PROD_PROJECT_2>"]'
```

### Folder-scoped inheritance (recommended for tenant-wide non-prod)

Creates `brava-footprint` once in `<HOST_PROJECT_ID>` and grants simulation roles + `roles/resourcemanager.folderViewer` on each folder in `folder_ids` (accepts bare numeric IDs like `"123456789012"` or `"folders/123456789012"`). Duplicate project-level IAM bindings are skipped automatically because child projects inherit folder IAM. Optionally pass `target_project_ids` to enable `securitycenter.googleapis.com` across child projects.

```bash
terraform init
terraform apply \
  -var="brava_runner_sa_email=<PROVIDED_BY_BRAVA>" \
  -var="project_id=<HOST_PROJECT_ID>" \
  -var='folder_ids=["123456789012"]' \
  -var='target_project_ids=["<NON_PROD_PROJECT_1>","<NON_PROD_PROJECT_2>"]'
```

## After apply

Run `terraform output` and register the footprint in **Detections → Settings → Runners**:

| Terraform output | Purpose |
|---|---|
| `service_account_email` | Email of the `brava-footprint` service account |
| `project_id` | Host GCP project ID where `brava-footprint` lives |
| `enrolled_folder_ids` | Normalized `folders/<id>` set granted simulation IAM inheritance |
| `enabled_securitycenter_projects` | Projects where `securitycenter.googleapis.com` was enabled |

## Optional variables

| Variable | Default | Notes |
|---|---|---|
| `folder_ids` | `[]` | Set of non-prod GCP folder IDs (`"123456789012"` or `"folders/123456789012"`). When non-empty, project-level IAM bindings are skipped in favor of folder inheritance. |
| `target_project_ids` | `[]` (`[var.project_id]`) | Set of non-prod project IDs to enable `securitycenter.googleapis.com` on (and bind project IAM roles on when `folder_ids` is empty). |
| `service_account_name` | `"brava-footprint"` | Account ID of the footprint service account created in `project_id`. |

## Minimum permissions for the user running Terraform

- **Host project (`project_id`)** — `roles/iam.serviceAccountAdmin` to create the footprint service account and bind `roles/iam.serviceAccountTokenCreator`.
- **Target projects (`target_project_ids` or `project_id`)** — `roles/serviceusage.serviceUsageAdmin` to enable `securitycenter.googleapis.com`, plus `roles/resourcemanager.projectIamAdmin` when `folder_ids` is empty.
- **Target folders (`folder_ids`)** — `roles/resourcemanager.folderIamAdmin` on each enrolled non-prod folder.

## Upgrading Existing Single-Project Deployments

- **Staying single-project or adding `target_project_ids`:** Built-in `moved` blocks migrate existing `google_project_service.securitycenter` and the six `google_project_iam_member.*` state addresses in-place to `[0]` with zero IAM destroys/recreates. Including `project_id` in `target_project_ids` keeps `project_id` on `[0]` and adds bindings only for the new projects.
- **Migrating an existing single-project state to `folder_ids`:** Setting `folder_ids` grants folder-level IAM inheritance and removes the redundant project-level bindings on `project_id`. Ensure `project_id` is already inside an enrolled folder before applying; if GCP IAM eventual consistency briefly delays folder propagation, re-run `terraform apply` (or verify inherited bindings with `gcloud projects get-ancestors-iam-policy`).

## Offline validation

Because `coverage/gcp/` stores multiple standalone single-file root modules side-by-side, run `terraform test` in a clean staging directory:

```bash
TMP_DIR=$(mktemp -d) && cp coverage/gcp/runner_footprint_role_gcp.tf "$TMP_DIR/" && cp -R coverage/gcp/tests "$TMP_DIR/tests" && terraform -chdir="$TMP_DIR" init -backend=false && terraform -chdir="$TMP_DIR" test && rm -rf "$TMP_DIR"
```
