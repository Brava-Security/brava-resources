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

---

# Attack Simulation — Azure Footprint

Separately from the read-only scanner above, the **attack-simulation footprint** is the Entra ID app the Brava runner authenticates *as* to execute simulations and collect telemetry in a subscription. It grants broader, write-capable access (`Contributor`, `Role Based Access Control Administrator`, `Security Reader`, `Monitoring Reader`) at subscription scope.

Two equivalent ways to deploy it — pick one:

| File | Tooling | Use when |
|---|---|---|
| `runner_footprint_role_azure.tf` | Terraform | You already manage Azure with Terraform. |
| `runner_footprint_role_azure.sh` | Azure CLI (`az`) | You don't use Terraform. Same result, no state file. |

Both produce the identical footprint and print the same values to submit to Brava.

## Inputs from Brava (WIF mode)

Find both in **Detections → Settings → Runners** on your Azure runner card:

| Value | Purpose |
|---|---|
| Cognito Identity **Pool** ID | Federated credential *audience* |
| Cognito **Identity** ID | Federated credential *subject* |

## Run — Azure CLI script

Log in first (`az login`). The script is idempotent — safe to re-run.

### Workload Identity Federation (recommended, no secret)

```bash
./runner_footprint_role_azure.sh \
  --subscription "<SUBSCRIPTION_NAME_OR_ID>" \
  --cognito-pool-id "<PROVIDED_BY_BRAVA>" \
  --cognito-identity-id "<PROVIDED_BY_BRAVA>"
```

### Client-secret fallback

```bash
./runner_footprint_role_azure.sh \
  --subscription "<SUBSCRIPTION_NAME_OR_ID>" \
  --auth-mode secret
```

`--subscription` accepts either the subscription display name or its ID. Run `./runner_footprint_role_azure.sh --help` for all options (`--tenant-id`, `--application-name`, `--secret-expiry-years`, `--verbose`).

## After it runs

The script prints the **Tenant ID**, **Client ID**, and **Subscription ID** (plus the **Client Secret** in secret mode). Register them in **Detections → Settings → Runners → Add Azure Footprint** — leave the secret blank when using WIF.

## Minimum permissions for the operator running the script

- **Application Administrator** (or Application Developer) in Entra — to create the app registration and service principal.
- **Owner** or **User Access Administrator** on the target subscription — to assign the four roles.
