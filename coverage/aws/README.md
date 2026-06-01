# AWS Scanner — Terraform

Provisions the read-only IAM role(s) that the Brava scanner assumes to scan your AWS environment.

Two deployment modes are supported:

- **`single_account`** — creates one scan role in the account where Terraform runs.
- **`organization`** — run from the **management account**. Creates an `organizations:ListAccounts` role plus a CloudFormation StackSet that deploys the scan role into every member account. Requires trusted access for CloudFormation StackSets with AWS Organizations.

## Inputs from Brava

Brava will provide the following values during onboarding (delivered separately — they are **not** committed to this repo):

| Variable | What Brava sends |
|---|---|
| `brava_role_arn` | ARN of the Brava-side principal that assumes your scan role |
| `external_id` *(optional)* | Shared secret for `sts:ExternalId` on the trust policy |

## Run

Replace each `<PLACEHOLDER>` with the value Brava provided.

### Single account

```bash
terraform init
terraform apply \
  -var="deployment=single_account" \
  -var="brava_role_arn=<BRAVA_ROLE_ARN>" \
  -var="external_id=<EXTERNAL_ID_OR_LEAVE_EMPTY>"
```

After apply, share the `scan_role_arn` output with your Brava team.

### Organization (run from the management account)

```bash
terraform init
terraform apply \
  -var="deployment=organization" \
  -var="brava_role_arn=<BRAVA_ROLE_ARN>" \
  -var="external_id=<EXTERNAL_ID_OR_LEAVE_EMPTY>"
```

After apply, share the `organization_role_arn` and `member_role_name` outputs with your Brava team.

## Optional variables

| Variable | Default | Notes |
|---|---|---|
| `aws_region` | `us-east-1` | Region for the provider. IAM is global; only matters for the StackSet. |
| `scan_role_name` | `brava-scanner` | Name of the IAM role created in your account(s). |
| `org_role_name` | `brava-scanner-org` | Name of the org-listing role (organization mode only). |
| `stack_set_name` | `brava-scanner-scan-role` | CloudFormation StackSet name (organization mode only). |
| `organizational_unit_ids` | `[]` (= org root) | Restrict StackSet deployment to specific OUs. |
| `include_management_account` | `true` | Also create the scan role in the management account itself. |
| `stack_instance_region` | `us-east-1` | Region for the StackSet instance. |
| `tags` | `{}` | Tags applied to IAM roles and the StackSet. |

## Minimum permissions for the user running Terraform

| Scope | Required permissions |
|---|---|
| Single account | `iam:CreateRole`, `iam:PutRolePolicy`, `iam:GetRole`, `iam:TagRole`, plus `iam:AttachRolePolicy` for the four AWS-managed policies attached to the role |
| Organization | All of the above, plus `organizations:ListAccounts`, `organizations:DescribeOrganization`, and `cloudformation:*` StackSet permissions |
