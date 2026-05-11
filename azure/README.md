# Azure Scanner — Terraform

Provisions an Entra ID app registration (service principal) with read-only access to your Azure environment. Two credential modes:

- **Client secret** (default) — Terraform generates a client secret; you share the credentials JSON with Brava.
- **OIDC / Workload Identity Federation** — no static credentials. The app trusts Brava's AWS Cognito identity. Requires two values from Brava.

## Inputs from Brava

Only needed for **OIDC mode**. Brava will deliver these separately:

| Variable | What Brava sends |
|---|---|
| `brava_cognito_identity_pool_id` | Brava Cognito Identity **Pool** ID for your tenant |
| `brava_cognito_identity_id` | Brava Cognito **Identity** ID for your tenant |

## Run

Replace each `<PLACEHOLDER>`.

### Client secret mode — single subscription

```bash
terraform init
terraform apply \
  -var="tenant_id=<AZURE_TENANT_ID>" \
  -var="subscription_id=<SUBSCRIPTION_ID>"
```

### Client secret mode — management group (organization)

```bash
terraform init
terraform apply \
  -var="tenant_id=<AZURE_TENANT_ID>" \
  -var="management_group_id=<MANAGEMENT_GROUP_ID>" \
  -var="use_mgmt_group=true"
```

### OIDC mode — single subscription

```bash
terraform init
terraform apply \
  -var="tenant_id=<AZURE_TENANT_ID>" \
  -var="subscription_id=<SUBSCRIPTION_ID>" \
  -var="use_oidc=true" \
  -var="brava_cognito_identity_pool_id=<PROVIDED_BY_BRAVA>" \
  -var="brava_cognito_identity_id=<PROVIDED_BY_BRAVA>"
```

### OIDC mode — management group

```bash
terraform init
terraform apply \
  -var="tenant_id=<AZURE_TENANT_ID>" \
  -var="management_group_id=<MANAGEMENT_GROUP_ID>" \
  -var="use_mgmt_group=true" \
  -var="use_oidc=true" \
  -var="brava_cognito_identity_pool_id=<PROVIDED_BY_BRAVA>" \
  -var="brava_cognito_identity_id=<PROVIDED_BY_BRAVA>"
```

## After apply

1. **One-time manual step** — run the command from `terraform output manual_step_entra_id_diagnostics` to grant Monitoring Reader at the Entra ID ARM scope (required for sign-in / audit-log checks).
2. **Client-secret mode** — get the credentials with `terraform output -raw scanner_credentials` and share the JSON with your Brava team.
3. **OIDC mode** — provide the **tenant ID**, **client ID**, and **subscription** (or management group) **ID** to your Brava team. The client ID can be read from `terraform output -raw scanner_credentials`.

> **Warning (client-secret mode only):** `terraform.tfstate` contains the client secret in plaintext. Use a remote backend (e.g. Azure Blob Storage) and do not commit state to git. In OIDC mode the state contains no secrets.

## Optional variables

| Variable | Default | Notes |
|---|---|---|
| `application_name` | `brava-azure-scanner` | Display name of the Entra ID app registration. |
| `client_secret_expiry_days` | `365` | Lifetime of the generated client secret (ignored in OIDC mode). |

## Minimum permissions for the user running Terraform

- **Application Administrator** (Entra) — to create app registrations.
- **Privileged Role Administrator** (Entra) — to assign the Security Reader directory role and grant admin consent for Graph permissions.
- **User Access Administrator** on the target subscription or management group — to assign Reader, Security Reader, and Monitoring Reader.
- The manual post-apply step also requires permission to grant Monitoring Reader at `/providers/microsoft.aadiam`.
