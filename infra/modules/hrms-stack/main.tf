terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

data "aws_caller_identity" "this" {}
data "aws_region" "this" {}
data "aws_partition" "this" {}
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  name       = "hrms"
  account_id = data.aws_caller_identity.this.account_id
  region     = data.aws_region.this.region
  partition  = data.aws_partition.this.partition
  azs        = slice(data.aws_availability_zones.available.names, 0, var.az_count)
  primary    = var.domains[0]
  tags = merge(var.tags, {
    Application = "hrms"
    Customer    = var.customer_slug
    Environment = var.environment
    ManagedBy   = "terraform"
  })
}

# ------------------------------------------------------------------ KMS
# One customer-managed key per account: RDS, Secrets Manager, S3 documents,
# CloudWatch Logs, SNS and AWS Backup. Rotated yearly.
data "aws_iam_policy_document" "kms" {
  statement {
    sid       = "AccountAdministration"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
  }
  statement {
    sid       = "CloudWatchLogs"
    actions   = ["kms:Encrypt*", "kms:Decrypt*", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:Describe*"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["logs.${local.region}.amazonaws.com"]
    }
    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:${local.partition}:logs:${local.region}:${local.account_id}:*"]
    }
  }
  statement {
    sid       = "CloudWatchAlarmsToSNS"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey*"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com", "budgets.amazonaws.com"]
    }
  }
}

resource "aws_kms_key" "main" {
  description             = "HRMS ${var.customer_slug} data key"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.kms.json
  tags                    = local.tags
}

resource "aws_kms_alias" "main" {
  name          = "alias/hrms-main"
  target_key_id = aws_kms_key.main.key_id
}
