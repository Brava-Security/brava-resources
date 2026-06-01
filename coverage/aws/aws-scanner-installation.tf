# Brava AWS Scanner — customer Terraform (single account or organization)
# Ship this file only: IAM policy and StackSet template are embedded below.
# Set deployment to single_account or organization. Apply in one account (member for single; management account for org).

terraform {
  required_version = ">= 1.3.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "deployment" {
  type        = string
  description = "single_account: one scan role in this account. organization: management account — org list role + StackSet to members (requires Organizations trusted access for StackSets)."
  validation {
    condition     = contains(["single_account", "organization"], var.deployment)
    error_message = "deployment must be single_account or organization."
  }
}

variable "aws_region" {
  type        = string
  description = "AWS region for the provider. IAM is global; us-east-1 is fine. For organization, also used for StackSet instance region."
  default     = "us-east-1"
}

variable "brava_role_arn" {
  type        = string
  description = "Principal ARN in Brava's account allowed to assume the scan role (and org list role when deployment is organization). Provided by Brava during onboarding."
}

variable "external_id" {
  type        = string
  description = "Optional shared secret for sts:ExternalId on trust policies; leave empty to omit."
  default     = ""
  sensitive   = true
}

variable "scan_role_name" {
  type        = string
  description = "IAM role name for the read-only scan role (single account, member accounts via StackSet, and management account when include_management_account is true)."
  default     = "brava-scanner"
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to IAM roles and (for organization) the StackSet."
  default     = {}
}

# --- Organization only ---

variable "org_role_name" {
  type        = string
  description = "IAM role name in the management account for organizations:ListAccounts (organization deployment only)."
  default     = "brava-scanner-org"
}

variable "stack_set_name" {
  type        = string
  description = "CloudFormation StackSet name (organization only; must be unique in the account)."
  default     = "brava-scanner-scan-role"
}

variable "organizational_unit_ids" {
  type        = list(string)
  description = "Target OUs for the StackSet (organization only). Empty = organization root."
  default     = []
}

variable "include_management_account" {
  type        = bool
  description = "Create the scan role directly in the management account (organization only; StackSets skip it by default)."
  default     = true
}

variable "stack_instance_region" {
  type        = string
  description = "Region for the StackSet instance (organization only; IAM is global)."
  default     = "us-east-1"
}

data "aws_caller_identity" "current" {}

data "aws_organizations_organization" "current" {
  count = var.deployment == "organization" && length(var.organizational_unit_ids) == 0 ? 1 : 0
}

locals {
  # AWS managed policies attached alongside the inline read-only policy:
  # https://docs.aws.amazon.com/aws-managed-policy/latest/reference/SecurityAudit.html
  # https://docs.aws.amazon.com/aws-managed-policy/latest/reference/AmazonSSMReadOnlyAccess.html
  # https://docs.aws.amazon.com/aws-managed-policy/latest/reference/AWSImageBuilderReadOnlyAccess.html
  # https://docs.aws.amazon.com/aws-managed-policy/latest/reference/AmazonMacieReadOnlyAccess.html
  security_audit_policy_arn         = "arn:aws:iam::aws:policy/SecurityAudit"
  ssm_readonly_policy_arn           = "arn:aws:iam::aws:policy/AmazonSSMReadOnlyAccess"
  image_builder_readonly_policy_arn = "arn:aws:iam::aws:policy/AWSImageBuilderReadOnlyAccess"
  macie_readonly_policy_arn         = "arn:aws:iam::aws:policy/AmazonMacieReadOnlyAccess"

  # Read-only IAM policy for Brava scanner (same document as former iam-role-policy-brava-scanner-readonly.json).
  scanner_policy = jsondecode(<<-JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "STS",
      "Effect": "Allow",
      "Action": [
        "sts:GetCallerIdentity"
      ],
      "Resource": "*"
    },
    {
      "Sid": "EC2",
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeRegions",
        "ec2:DescribeFlowLogs",
        "ec2:DescribeVpcs",
        "ec2:DescribeTransitGateways",
        "ec2:DescribeVpcEndpoints",
        "ec2:DescribeInstances",
        "ec2:DescribeVerifiedAccessInstances",
        "ec2:DescribeVerifiedAccessInstanceLoggingConfigurations"
      ],
      "Resource": "*"
    },
    {
      "Sid": "S3",
      "Effect": "Allow",
      "Action": [
        "s3:ListAllMyBuckets",
        "s3:GetBucketLocation",
        "s3:GetBucketLogging"
      ],
      "Resource": "*"
    },
    {
      "Sid": "CloudFront",
      "Effect": "Allow",
      "Action": [
        "cloudfront:ListDistributions",
        "cloudfront:GetDistributionConfig"
      ],
      "Resource": "*"
    },
    {
      "Sid": "CloudTrail",
      "Effect": "Allow",
      "Action": [
        "cloudtrail:DescribeTrails",
        "cloudtrail:GetTrailStatus",
        "cloudtrail:GetEventSelectors"
      ],
      "Resource": "*"
    },
    {
      "Sid": "SecurityHub",
      "Effect": "Allow",
      "Action": [
        "securityhub:DescribeHub",
        "securityhub:GetEnabledStandards"
      ],
      "Resource": "*"
    },
    {
      "Sid": "WAFv2",
      "Effect": "Allow",
      "Action": [
        "wafv2:ListWebACLs",
        "wafv2:GetLoggingConfiguration"
      ],
      "Resource": "*"
    },
    {
      "Sid": "Lambda",
      "Effect": "Allow",
      "Action": [
        "lambda:ListFunctions",
        "lambda:GetFunctionConfiguration"
      ],
      "Resource": "*"
    },
    {
      "Sid": "CloudWatchLogs",
      "Effect": "Allow",
      "Action": [
        "logs:DescribeLogGroups"
      ],
      "Resource": "*"
    },
    {
      "Sid": "GuardDuty",
      "Effect": "Allow",
      "Action": [
        "guardduty:ListDetectors",
        "guardduty:GetDetector"
      ],
      "Resource": "*"
    },
    {
      "Sid": "Config",
      "Effect": "Allow",
      "Action": [
        "config:DescribeConfigurationRecorders",
        "config:DescribeConfigurationRecorderStatus",
        "config:DescribeDeliveryChannels"
      ],
      "Resource": "*"
    },
    {
      "Sid": "RDS",
      "Effect": "Allow",
      "Action": [
        "rds:DescribeDBClusters",
        "rds:DescribeDBInstances",
        "rds:DescribeDBClusterParameters"
      ],
      "Resource": "*"
    },
    {
      "Sid": "Redshift",
      "Effect": "Allow",
      "Action": [
        "redshift:DescribeClusters",
        "redshift:DescribeLoggingStatus"
      ],
      "Resource": "*"
    },
    {
      "Sid": "OpenSearch",
      "Effect": "Allow",
      "Action": [
        "es:ListDomainNames",
        "es:DescribeDomain"
      ],
      "Resource": "*"
    },
    {
      "Sid": "NetworkFirewall",
      "Effect": "Allow",
      "Action": [
        "network-firewall:ListFirewalls",
        "network-firewall:DescribeLoggingConfiguration"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ELBv2",
      "Effect": "Allow",
      "Action": [
        "elasticloadbalancing:DescribeLoadBalancers",
        "elasticloadbalancing:DescribeLoadBalancerAttributes"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ElastiCache",
      "Effect": "Allow",
      "Action": [
        "elasticache:DescribeReplicationGroups"
      ],
      "Resource": "*"
    },
    {
      "Sid": "DynamoDB",
      "Effect": "Allow",
      "Action": [
        "dynamodb:ListTables",
        "dynamodb:DescribeTable"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ECS",
      "Effect": "Allow",
      "Action": [
        "ecs:ListClusters",
        "ecs:ListServices",
        "ecs:DescribeServices",
        "ecs:DescribeTaskDefinition"
      ],
      "Resource": "*"
    },
    {
      "Sid": "EKS",
      "Effect": "Allow",
      "Action": [
        "eks:ListClusters",
        "eks:DescribeCluster"
      ],
      "Resource": "*"
    },
    {
      "Sid": "EMR",
      "Effect": "Allow",
      "Action": [
        "elasticmapreduce:ListClusters",
        "elasticmapreduce:DescribeCluster"
      ],
      "Resource": "*"
    },
    {
      "Sid": "APIGateway",
      "Effect": "Allow",
      "Action": [
        "apigateway:GET"
      ],
      "Resource": "*"
    },
    {
      "Sid": "Cognito",
      "Effect": "Allow",
      "Action": [
        "cognito-idp:ListUserPools",
        "cognito-idp:DescribeUserPool",
        "cognito-identity:ListIdentityPools"
      ],
      "Resource": "*"
    },
    {
      "Sid": "CodeBuild",
      "Effect": "Allow",
      "Action": [
        "codebuild:ListProjects",
        "codebuild:BatchGetProjects"
      ],
      "Resource": "*"
    },
    {
      "Sid": "Route53Resolver",
      "Effect": "Allow",
      "Action": [
        "route53resolver:ListResolverQueryLogConfigs"
      ],
      "Resource": "*"
    },
    {
      "Sid": "Shield",
      "Effect": "Allow",
      "Action": [
        "shield:GetSubscriptionState"
      ],
      "Resource": "*"
    },
    {
      "Sid": "SSM",
      "Effect": "Allow",
      "Action": [
        "ssm:GetDocument"
      ],
      "Resource": "*"
    },
    {
      "Sid": "Macie",
      "Effect": "Allow",
      "Action": [
        "macie2:GetMacieSession",
        "macie2:GetAutomatedDiscoveryConfiguration"
      ],
      "Resource": "*"
    },
    {
      "Sid": "Inspector2",
      "Effect": "Allow",
      "Action": [
        "inspector2:BatchGetAccountStatus"
      ],
      "Resource": "*"
    },
    {
      "Sid": "AccessAnalyzer",
      "Effect": "Allow",
      "Action": [
        "access-analyzer:ListAnalyzers"
      ],
      "Resource": "*"
    },
    {
      "Sid": "EFS",
      "Effect": "Allow",
      "Action": [
        "elasticfilesystem:DescribeFileSystems"
      ],
      "Resource": "*"
    },
    {
      "Sid": "Kinesis",
      "Effect": "Allow",
      "Action": [
        "kinesis:ListStreams",
        "kinesis:DescribeStreamSummary"
      ],
      "Resource": "*"
    },
    {
      "Sid": "MSK",
      "Effect": "Allow",
      "Action": [
        "kafka:ListClustersV2",
        "kafka:DescribeClusterV2"
      ],
      "Resource": "*"
    },
    {
      "Sid": "EventBridge",
      "Effect": "Allow",
      "Action": [
        "events:ListEventBuses",
        "events:DescribeEventBus"
      ],
      "Resource": "*"
    }
  ]
}
JSON
  )

  policy_compact = jsonencode(local.scanner_policy)

  # CloudFormation template for StackSet member-account scan role (__POLICY_COMPACT__ = inlined IAM policy JSON).
  _cfn_scan_role_stack_yaml = <<-YAML
AWSTemplateFormatVersion: "2010-09-09"
Description: Brava AWS Scanner scan role (inline read-only policy plus AWS managed SecurityAudit, AmazonSSMReadOnlyAccess, AWSImageBuilderReadOnlyAccess, and AmazonMacieReadOnlyAccess)

Parameters:
  BravaRoleArn:
    Type: String
    Description: IAM role ARN in Brava's account allowed to assume the scan role
  ExternalId:
    Type: String
    NoEcho: true
    Default: ""
    Description: Optional sts:ExternalId; leave empty to omit from trust policy
  RoleName:
    Type: String
    Default: brava-scanner
    Description: IAM role name to create

Conditions:
  HasExternalId: !Not [!Equals [!Ref ExternalId, ""]]

Resources:
  ScanRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: !Ref RoleName
      ManagedPolicyArns:
        - arn:aws:iam::aws:policy/SecurityAudit
        - arn:aws:iam::aws:policy/AmazonSSMReadOnlyAccess
        - arn:aws:iam::aws:policy/AWSImageBuilderReadOnlyAccess
        - arn:aws:iam::aws:policy/AmazonMacieReadOnlyAccess
      MaxSessionDuration: 43200
      AssumeRolePolicyDocument:
        Fn::If:
          - HasExternalId
          - Version: "2012-10-17"
            Statement:
              - Effect: Allow
                Principal:
                  AWS: !Ref BravaRoleArn
                Action: sts:AssumeRole
                Condition:
                  StringEquals:
                    sts:ExternalId: !Ref ExternalId
          - Version: "2012-10-17"
            Statement:
              - Effect: Allow
                Principal:
                  AWS: !Ref BravaRoleArn
                Action: sts:AssumeRole
      Policies:
        - PolicyName: BravaScannerReadOnly
          PolicyDocument: __POLICY_COMPACT__

Outputs:
  ScanRoleArn:
    Description: ARN of the scan role
    Value: !GetAtt ScanRole.Arn
YAML

  stack_template_body = replace(local._cfn_scan_role_stack_yaml, "__POLICY_COMPACT__", local.policy_compact)

  deployment_ou_ids = var.deployment != "organization" ? [] : (
    length(var.organizational_unit_ids) > 0 ? var.organizational_unit_ids : [
      data.aws_organizations_organization.current[0].roots[0].id
    ]
  )
}

data "aws_iam_policy_document" "assume_brava" {
  statement {
    sid     = "AssumeBrava"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = [var.brava_role_arn]
    }

    dynamic "condition" {
      for_each = trimspace(var.external_id) != "" ? [1] : []
      content {
        test     = "StringEquals"
        variable = "sts:ExternalId"
        values   = [var.external_id]
      }
    }
  }
}

# -----------------------------------------------------------------------------
# Single account
# -----------------------------------------------------------------------------

resource "aws_iam_role" "scan" {
  count                = var.deployment == "single_account" ? 1 : 0
  name                 = var.scan_role_name
  assume_role_policy   = data.aws_iam_policy_document.assume_brava.json
  max_session_duration = 43200
  tags                 = var.tags
}

resource "aws_iam_role_policy" "scan" {
  count  = var.deployment == "single_account" ? 1 : 0
  name   = "brava-scanner-readonly"
  role   = aws_iam_role.scan[0].id
  policy = local.policy_compact
}

resource "aws_iam_role_policy_attachment" "scan_security_audit" {
  count      = var.deployment == "single_account" ? 1 : 0
  role       = aws_iam_role.scan[0].name
  policy_arn = local.security_audit_policy_arn
}

resource "aws_iam_role_policy_attachment" "scan_ssm_readonly" {
  count      = var.deployment == "single_account" ? 1 : 0
  role       = aws_iam_role.scan[0].name
  policy_arn = local.ssm_readonly_policy_arn
}

resource "aws_iam_role_policy_attachment" "scan_image_builder_readonly" {
  count      = var.deployment == "single_account" ? 1 : 0
  role       = aws_iam_role.scan[0].name
  policy_arn = local.image_builder_readonly_policy_arn
}

resource "aws_iam_role_policy_attachment" "scan_macie_readonly" {
  count      = var.deployment == "single_account" ? 1 : 0
  role       = aws_iam_role.scan[0].name
  policy_arn = local.macie_readonly_policy_arn
}

# -----------------------------------------------------------------------------
# Organization (management account)
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "org_list_accounts" {
  count = var.deployment == "organization" ? 1 : 0

  statement {
    sid       = "ListOrganizationAccounts"
    effect    = "Allow"
    actions   = ["organizations:ListAccounts"]
    resources = ["*"]
  }
}

resource "aws_iam_role" "org" {
  count                = var.deployment == "organization" ? 1 : 0
  name                 = var.org_role_name
  assume_role_policy   = data.aws_iam_policy_document.assume_brava.json
  max_session_duration = 43200
  tags                 = var.tags
}

resource "aws_iam_role_policy" "org" {
  count  = var.deployment == "organization" ? 1 : 0
  name   = "list-accounts"
  role   = aws_iam_role.org[0].id
  policy = data.aws_iam_policy_document.org_list_accounts[0].json
}

resource "aws_cloudformation_stack_set" "scan_role" {
  count = var.deployment == "organization" ? 1 : 0

  name             = var.stack_set_name
  permission_model = "SERVICE_MANAGED"
  capabilities     = ["CAPABILITY_NAMED_IAM", "CAPABILITY_IAM"]
  call_as          = "SELF"

  template_body = local.stack_template_body

  parameters = {
    BravaRoleArn = var.brava_role_arn
    ExternalId   = var.external_id
    RoleName     = var.scan_role_name
  }

  auto_deployment {
    enabled                          = true
    retain_stacks_on_account_removal = false
  }

  tags = var.tags
}

resource "aws_cloudformation_stack_set_instance" "scan_role" {
  count = var.deployment == "organization" ? 1 : 0

  stack_set_name            = aws_cloudformation_stack_set.scan_role[0].name
  stack_set_instance_region = var.stack_instance_region

  deployment_targets {
    organizational_unit_ids = local.deployment_ou_ids
  }

  operation_preferences {
    failure_tolerance_percentage = 100
    max_concurrent_percentage    = 100
  }
}

resource "aws_iam_role" "management_scan" {
  count                = var.deployment == "organization" && var.include_management_account ? 1 : 0
  name                 = var.scan_role_name
  assume_role_policy   = data.aws_iam_policy_document.assume_brava.json
  max_session_duration = 43200
  tags                 = var.tags
}

resource "aws_iam_role_policy" "management_scan" {
  count  = var.deployment == "organization" && var.include_management_account ? 1 : 0
  name   = "brava-scanner-readonly"
  role   = aws_iam_role.management_scan[0].id
  policy = local.policy_compact
}

resource "aws_iam_role_policy_attachment" "management_scan_security_audit" {
  count      = var.deployment == "organization" && var.include_management_account ? 1 : 0
  role       = aws_iam_role.management_scan[0].name
  policy_arn = local.security_audit_policy_arn
}

resource "aws_iam_role_policy_attachment" "management_scan_ssm_readonly" {
  count      = var.deployment == "organization" && var.include_management_account ? 1 : 0
  role       = aws_iam_role.management_scan[0].name
  policy_arn = local.ssm_readonly_policy_arn
}

resource "aws_iam_role_policy_attachment" "management_scan_image_builder_readonly" {
  count      = var.deployment == "organization" && var.include_management_account ? 1 : 0
  role       = aws_iam_role.management_scan[0].name
  policy_arn = local.image_builder_readonly_policy_arn
}

resource "aws_iam_role_policy_attachment" "management_scan_macie_readonly" {
  count      = var.deployment == "organization" && var.include_management_account ? 1 : 0
  role       = aws_iam_role.management_scan[0].name
  policy_arn = local.macie_readonly_policy_arn
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------

output "scan_role_arn" {
  description = "Single account: scan role ARN for Brava. Null when deployment is organization."
  value       = var.deployment == "single_account" ? aws_iam_role.scan[0].arn : null
}

output "scan_role_name" {
  description = "Single account: scan IAM role name. Null when deployment is organization."
  value       = var.deployment == "single_account" ? aws_iam_role.scan[0].name : null
}

output "organization_role_arn" {
  description = "Organization: ARN for organizations:ListAccounts. Null when deployment is single_account."
  value       = var.deployment == "organization" ? aws_iam_role.org[0].arn : null
}

output "member_role_name" {
  description = "Organization: IAM role name for the member accounts. Null when deployment is single_account."
  value       = var.deployment == "organization" ? var.scan_role_name : null
}

output "caller_account_id" {
  description = "AWS account ID where Terraform ran (for organization, should be the management account)."
  value       = var.deployment == "organization" ? data.aws_caller_identity.current.account_id : null
}

# Upgrade path from pre-unified modules (single-account/ and organization/ main.tf without count indices).
moved {
  from = aws_iam_role.scan
  to   = aws_iam_role.scan[0]
}

moved {
  from = aws_iam_role_policy.scan
  to   = aws_iam_role_policy.scan[0]
}

moved {
  from = aws_iam_role.org
  to   = aws_iam_role.org[0]
}

moved {
  from = aws_iam_role_policy.org
  to   = aws_iam_role_policy.org[0]
}

moved {
  from = aws_cloudformation_stack_set.scan_role
  to   = aws_cloudformation_stack_set.scan_role[0]
}

moved {
  from = aws_cloudformation_stack_set_instance.scan_role
  to   = aws_cloudformation_stack_set_instance.scan_role[0]
}

moved {
  from = aws_iam_role.management_scan
  to   = aws_iam_role.management_scan[0]
}

moved {
  from = aws_iam_role_policy.management_scan
  to   = aws_iam_role_policy.management_scan[0]
}
