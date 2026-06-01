terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------

variable "brava_runner_role_arn" {
  description = "ARN of Brava's runner instance role (Role A) — output from the brava-side Terraform module"
  type        = string
}

locals {
  role_name  = "brava-footprint-role"
  account_id = data.aws_caller_identity.current.account_id
}

# ---------------------------------------------------------------------------
# Data sources
# ---------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# Footprint role (Role B)
#
# The Runner (Role A, in Brava's account) assumes this role to operate in the
# client account. It has full action permissions scoped to resources within
# this account only — the trust policy restricts who can assume it.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "footprint" {
  name = local.role_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = var.brava_runner_role_arn }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Name = local.role_name
  }
}

resource "aws_iam_role_policy" "footprint" {
  name = "${local.role_name}-policy"
  role = aws_iam_role.footprint.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Chain into simulation profile roles within this account
        Sid      = "AssumeProfileRoles"
        Effect   = "Allow"
        Action   = ["sts:AssumeRole"]
        Resource = "arn:aws:iam::${local.account_id}:role/*"
      },
      {
        # Full access required to execute attack simulations in the client account.
        # AWS does not support resource-level restrictions for most of these actions,
        # so Resource = "*" is required. The trust policy on this role restricts
        # who can assume it to Brava's runner role only.
        Sid    = "SimulationFullAccess"
        Effect = "Allow"
        Action = [
          "ec2:*",
          "iam:*",
          "s3:*",
          "eks:*",
          "ecs:*",
          "rds:*",
          "lambda:*",
          "logs:*",
          "cloudwatch:*",
          "cloudtrail:*",
          "guardduty:*",
          "ssm:*",
          "secretsmanager:*",
          "autoscaling:*",
          "elasticloadbalancing:*",
          "route53:*",
          "acm:*",
          "ecr:*",
          "apigateway:*",
          "dynamodb:*",
          "sns:*",
          "sqs:*",
          "cognito-idp:*",
          "cognito-identity:*",
          "glue:*",
          "codebuild:*",
          "cloudformation:*",
          "transfer:*",
          "mq:*",
          "lightsail:*",
          "waf:*",
          "waf-regional:*",
          "wafv2:*",
          "route53resolver:*",
          "bedrock:*",
          "organizations:*",
          "ses:*",
          "sts:*",
          "ebs:*",
          "RolesAnywhere:*",
          "ec2-instance-connect:SendSSHPublicKey",
        ]
        Resource = "*"
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

output "footprint_role_arn" {
  description = "ARN of the footprint role (Role B). Provide this to Brava when registering the environment."
  value       = aws_iam_role.footprint.arn
}
