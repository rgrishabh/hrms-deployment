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

variable "github_repository" {
  type = string
}

variable "github_build_ref" {
  description = "Git ref allowed to push images."
  type        = string
  default     = "refs/heads/main"
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
  description         = "HRMS shared services (ECR images, Terraform state)"
  enable_key_rotation = true
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "Admin", Effect = "Allow", Principal = { AWS = "arn:${local.partition}:iam::${local.account_id}:root" }, Action = "kms:*", Resource = "*" },
      {
        # Customer accounts use the key only through S3 (state) or ECR (image pulls).
        Sid       = "OrgUseViaServices"
        Effect    = "Allow"
        Principal = { AWS = "*" }
        Action    = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey*", "kms:DescribeKey"]
        Resource  = "*"
        Condition = {
          StringEquals = {
            "aws:PrincipalOrgID" = var.organization_id
            "kms:ViaService"     = ["s3.${data.aws_region.this.region}.amazonaws.com", "ecr.${data.aws_region.this.region}.amazonaws.com"]
          }
        }
      },
    ]
  })
  tags = var.tags
}

# ------------------------------------------------------------------ ECR
resource "aws_ecr_repository" "api" {
  name                 = "hrms-api"
  image_tag_mutability = "IMMUTABLE"
  image_scanning_configuration {
    scan_on_push = true
  }
  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.shared.arn
  }
  tags = var.tags
}

resource "aws_ecr_lifecycle_policy" "api" {
  repository = aws_ecr_repository.api.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the most recent 100 release images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 100 }
      action       = { type = "expire" }
    }]
  })
}

resource "aws_ecr_repository_policy" "api" {
  repository = aws_ecr_repository.api.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "OrgPull"
      Effect    = "Allow"
      Principal = { AWS = "*" }
      Action    = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
      Condition = { StringEquals = { "aws:PrincipalOrgID" = var.organization_id } }
    }]
  })
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

# ------------------------------------------------------------------ CI build role
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  tags           = var.tags
}

resource "aws_iam_role" "build" {
  name = "hrms-image-build"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_repository}:ref:${var.github_build_ref}"
        }
      }
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy" "build" {
  name = "push"
  role = aws_iam_role.build.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = "ecr:GetAuthorizationToken", Resource = "*" },
      {
        Effect = "Allow"
        Action = ["ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload",
        "ecr:PutImage", "ecr:BatchGetImage", "ecr:DescribeImages", "ecr:DescribeImageScanFindings"]
        Resource = aws_ecr_repository.api.arn
      },
      { Effect = "Allow", Action = ["kms:GenerateDataKey", "kms:Decrypt"], Resource = aws_kms_key.shared.arn },
    ]
  })
}

output "ecr_repository_url" {
  value = aws_ecr_repository.api.repository_url
}

output "ecr_repository_arn" {
  value = aws_ecr_repository.api.arn
}

output "state_bucket" {
  value = aws_s3_bucket.state.bucket
}

output "build_role_arn" {
  value = aws_iam_role.build.arn
}
