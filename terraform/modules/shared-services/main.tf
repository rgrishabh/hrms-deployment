# Shared Services account: the one image registry and the Terraform state
# store for all customer accounts, plus the CI role that builds images.
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

variable "organization_id" {
  description = "AWS Organizations id (o-xxxxxxxx). Only accounts in the organization may pull images / use state."
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

data "aws_caller_identity" "this" {}
data "aws_partition" "this" {}
data "aws_region" "this" {}

locals {
  account_id = data.aws_caller_identity.this.account_id
  partition  = data.aws_partition.this.partition
}

# ------------------------------------------------------------------ KMS
resource "aws_kms_key" "shared" {
  description         = "HRMS shared services (Terraform state)"
  enable_key_rotation = true
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "Admin", Effect = "Allow", Principal = { AWS = "arn:${local.partition}:iam::${local.account_id}:root" }, Action = "kms:*", Resource = "*" },
      {
        # Customer accounts use the key only through S3 (state).
        Sid       = "OrgUseViaServices"
        Effect    = "Allow"
        Principal = { AWS = "*" }
        Action    = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey*", "kms:DescribeKey"]
        Resource  = "*"
        Condition = {
          StringEquals = {
            "aws:PrincipalOrgID" = var.organization_id
            "kms:ViaService"     = ["s3.${data.aws_region.this.region}.amazonaws.com"]
          }
        }
      },
    ]
  })
  tags = var.tags
}

# ------------------------------------------------------------------ Terraform state
# Each account may only read/write state under accounts/<its own account id>/.
resource "aws_s3_bucket" "state" {
  bucket = "hrms-terraform-state-${local.account_id}"
  tags   = var.tags
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.shared.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "TlsOnly"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
      {
        Sid       = "AccountScopedObjects"
        Effect    = "Allow"
        Principal = { AWS = "*" }
        Action    = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource  = "${aws_s3_bucket.state.arn}/accounts/$${aws:PrincipalAccount}/*"
        Condition = { StringEquals = { "aws:PrincipalOrgID" = var.organization_id } }
      },
      {
        Sid       = "AccountScopedList"
        Effect    = "Allow"
        Principal = { AWS = "*" }
        Action    = "s3:ListBucket"
        Resource  = aws_s3_bucket.state.arn
        Condition = {
          StringEquals = { "aws:PrincipalOrgID" = var.organization_id }
          StringLike   = { "s3:prefix" = ["accounts/$${aws:PrincipalAccount}/*"] }
        }
      },
    ]
  })
}

output "state_bucket" {
  value = aws_s3_bucket.state.bucket
}
