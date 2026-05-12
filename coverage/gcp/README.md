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
