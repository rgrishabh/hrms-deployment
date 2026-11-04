# Per-customer-account baseline. Applied once by an administrator (AWS SSO)
# when the account is created; afterwards the pipeline uses the roles it creates.
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

variable "github_repository" {
  description = "owner/repo whose workflows may deploy to this account."
  type        = string
}

variable "github_infra_environment" {
  description = "GitHub environment allowed to run Terraform in this account (e.g. infra-acme)."
  type        = string
}

variable "enable_guardduty" {
  description = "Create a GuardDuty detector here. Set false if GuardDuty is managed by an organization delegated admin."
  type        = bool
  default     = true
}

variable "state_kms_key_arn" {
  description = "Key of the Terraform state bucket. The plan role needs it: ReadOnlyAccess has no kms:Decrypt, so plans could not read an encrypted state."
  type        = string
  default     = null
}

variable "tags" {
  type    = map(string)
  default = {}
}

data "aws_partition" "this" {}

# Account-wide protections.
resource "aws_ebs_encryption_by_default" "this" {
  enabled = true
}

resource "aws_s3_account_public_access_block" "this" {
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_iam_account_password_policy" "this" {
  minimum_password_length        = 16
  require_lowercase_characters   = true
  require_uppercase_characters   = true
  require_numbers                = true
  require_symbols                = true
  allow_users_to_change_password = true
  password_reuse_prevention      = 24
  max_password_age               = 90
}

resource "aws_guardduty_detector" "this" {
  count  = var.enable_guardduty ? 1 : 0
  enable = true
  tags   = var.tags
}

resource "aws_accessanalyzer_analyzer" "this" {
  analyzer_name = "hrms-account"
  type          = "ACCOUNT"
  tags          = var.tags
}

# GitHub Actions OIDC — no long-lived AWS keys in CI.
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  tags           = var.tags
}

# Terraform role for the infra pipeline (one GitHub environment, which should
# require reviewer approval). Broad by necessity; constrained by org SCPs.
resource "aws_iam_role" "terraform" {
  name                 = "hrms-terraform"
  max_session_duration = 3600
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_repository}:environment:${var.github_infra_environment}"
        }
      }
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "terraform" {
  role       = aws_iam_role.terraform.name
  policy_arn = "arn:${data.aws_partition.this.partition}:iam::aws:policy/AdministratorAccess"
}

# Read-only plan role for pull requests. Plans run with -refresh=false and
# -lock=false, so it never needs secret values or the state lock.
resource "aws_iam_role" "terraform_plan" {
  name                 = "hrms-terraform-plan"
  max_session_duration = 3600
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_repository}:pull_request"
        }
      }
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "terraform_plan" {
  role       = aws_iam_role.terraform_plan.name
  policy_arn = "arn:${data.aws_partition.this.partition}:iam::aws:policy/ReadOnlyAccess"
}

# ReadOnlyAccess includes some data-plane reads; explicitly keep secret values and S3 objects out of reach.
resource "aws_iam_role_policy" "terraform_plan_deny" {
  name = "deny-data"
  role = aws_iam_role.terraform_plan.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect      = "Deny"
      Action      = ["secretsmanager:GetSecretValue", "s3:GetObject*", "logs:GetLogEvents", "logs:FilterLogEvents", "rds:DownloadDBLogFilePortion"]
      NotResource = ["arn:${data.aws_partition.this.partition}:s3:::hrms-terraform-state-*/*"]
    }]
  })
}

resource "aws_iam_role_policy" "terraform_plan_state_key" {
  count = var.state_kms_key_arn == null ? 0 : 1
  name  = "decrypt-state"
  role  = aws_iam_role.terraform_plan.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "kms:Decrypt"
      Resource = var.state_kms_key_arn
    }]
  })
}

output "github_oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.github.arn
}

output "terraform_role_arn" {
  value = aws_iam_role.terraform.arn
}
