# A private bucket: public access blocked, TLS only, versioned, encrypted. Log buckets use the same
# module with a log_delivery value, because ALB logs support only SSE-S3 and CloudFront needs ACLs.
# "s3" is for server access logs alone: SSE-S3 too, as delivery to a KMS bucket needs a grant in the key.
variable "name_prefix" {
  description = "Bucket name prefix, for example hrms-documents-."
  type        = string
}

variable "kms_key_arn" {
  type    = string
  default = null
}

variable "log_delivery" {
  description = "none, alb, cloudfront or s3. Anything but none makes this a log bucket, expiring after log_retention_days."
  type        = string
  default     = "none"
  validation {
    condition     = contains(["none", "alb", "cloudfront", "s3"], var.log_delivery)
    error_message = "log_delivery must be none, alb, cloudfront or s3."
  }
}

variable "log_retention_days" {
  type    = number
  default = 365
}

variable "access_log_bucket" {
  description = "Bucket that receives this bucket's server access logs."
  type        = string
  default     = null
}

variable "noncurrent_version_days" {
  type    = number
  default = 90
}

variable "replication_enabled" {
  description = "Replicate to replica_bucket_arn. A plain bool, because the ARN may be unknown at plan time."
  type        = bool
  default     = false
}

variable "replica_bucket_arn" {
  type    = string
  default = null
}

variable "replica_kms_key_arn" {
  type    = string
  default = null
}

variable "force_destroy" {
  type    = bool
  default = false
}

data "aws_caller_identity" "this" {}
data "aws_elb_service_account" "this" {
  count = var.log_delivery == "alb" ? 1 : 0
}

locals {
  is_log_bucket = var.log_delivery != "none"
  sse_s3        = contains(["alb", "s3"], var.log_delivery)
}

resource "aws_s3_bucket" "this" {
  #checkov:skip=CKV2_AWS_62:No consumer for bucket event notifications; the app reads objects directly.
  #checkov:skip=CKV_AWS_144:Cross-region replication is an input, enabled on prod-high. Lower tiers accept single-region durability.
  #checkov:skip=CKV2_AWS_61:Lifecycle is configured in aws_s3_bucket_lifecycle_configuration.this below.
  #checkov:skip=CKV_AWS_18:Access logging is an input; log buckets do not log to themselves.
  #checkov:skip=CKV_AWS_145:Only the log buckets with local.sse_s3 lack KMS, as ALB log delivery supports only SSE-S3. The encryption resource below picks KMS for every other bucket.
  bucket_prefix = var.name_prefix
  force_destroy = var.force_destroy
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket                  = aws_s3_bucket.this.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "this" {
  #checkov:skip=CKV2_AWS_65:ACLs stay on only for log_delivery = "cloudfront", as CloudFront standard logging writes with an ACL. Every other bucket is BucketOwnerEnforced. Public access is blocked on all.
  bucket = aws_s3_bucket.this.id
  rule {
    # CloudFront standard logging writes with an ACL, so that one bucket must allow them.
    object_ownership = var.log_delivery == "cloudfront" ? "BucketOwnerPreferred" : "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  #checkov:skip=CKV2_AWS_67:Key rotation is on in the kms module, which checkov cannot follow through a variable.
  bucket = aws_s3_bucket.this.id
  rule {
    # ALB access logs can be delivered only to SSE-S3 buckets. Everything else uses the KMS key.
    apply_server_side_encryption_by_default {
      sse_algorithm     = local.sse_s3 ? "AES256" : "aws:kms"
      kms_master_key_id = local.sse_s3 ? null : var.kms_key_arn
    }
    bucket_key_enabled = !local.sse_s3
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  bucket = aws_s3_bucket.this.id
  rule {
    id     = "housekeeping"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_days
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
    dynamic "expiration" {
      for_each = local.is_log_bucket ? [var.log_retention_days] : []
      content {
        days = expiration.value
      }
    }
  }
  depends_on = [aws_s3_bucket_versioning.this]
}

resource "aws_s3_bucket_logging" "this" {
  count         = var.access_log_bucket == null ? 0 : 1
  bucket        = aws_s3_bucket.this.id
  target_bucket = var.access_log_bucket
  target_prefix = "s3/${aws_s3_bucket.this.id}/"
}

resource "aws_s3_bucket_policy" "this" {
  bucket = aws_s3_bucket.this.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [{
        Sid       = "TlsOnly"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.this.arn, "${aws_s3_bucket.this.arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      }],
      var.log_delivery == "alb" ? [{
        Sid       = "ElbLogDelivery"
        Effect    = "Allow"
        Principal = { AWS = data.aws_elb_service_account.this[0].arn }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.this.arn}/alb/AWSLogs/${data.aws_caller_identity.this.account_id}/*"
      }] : [],
      var.access_log_bucket == null && local.is_log_bucket ? [{
        Sid       = "S3ServerAccessLogDelivery"
        Effect    = "Allow"
        Principal = { Service = "logging.s3.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.this.arn}/s3/*"
        Condition = { StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.this.account_id } }
      }] : [],
    )
  })
  depends_on = [aws_s3_bucket_public_access_block.this]
}

# ---------------------------------------------------------------- replication (prod-high)
resource "aws_iam_role" "replication" {
  count = var.replication_enabled ? 1 : 0
  name  = "${trimsuffix(var.name_prefix, "-")}-replication"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "s3.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy" "replication" {
  count = var.replication_enabled ? 1 : 0
  name  = "replicate"
  role  = aws_iam_role.replication[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["s3:GetReplicationConfiguration", "s3:ListBucket"], Resource = aws_s3_bucket.this.arn },
      { Effect = "Allow", Action = ["s3:GetObjectVersionForReplication", "s3:GetObjectVersionAcl", "s3:GetObjectVersionTagging"], Resource = "${aws_s3_bucket.this.arn}/*" },
      { Effect = "Allow", Action = ["s3:ReplicateObject", "s3:ReplicateDelete", "s3:ReplicateTags"], Resource = "${var.replica_bucket_arn}/*" },
      { Effect = "Allow", Action = ["kms:Decrypt"], Resource = var.kms_key_arn },
      { Effect = "Allow", Action = ["kms:Encrypt", "kms:GenerateDataKey"], Resource = var.replica_kms_key_arn },
    ]
  })
}

resource "aws_s3_bucket_replication_configuration" "this" {
  count  = var.replication_enabled ? 1 : 0
  bucket = aws_s3_bucket.this.id
  role   = aws_iam_role.replication[0].arn
  rule {
    id     = "dr"
    status = "Enabled"
    filter {}
    delete_marker_replication {
      status = "Enabled"
    }
    source_selection_criteria {
      sse_kms_encrypted_objects {
        status = "Enabled"
      }
    }
    destination {
      bucket = var.replica_bucket_arn
      encryption_configuration {
        replica_kms_key_id = var.replica_kms_key_arn
      }
    }
  }
  depends_on = [aws_s3_bucket_versioning.this]
}

output "bucket" {
  value = aws_s3_bucket.this.bucket
}

output "bucket_arn" {
  value = aws_s3_bucket.this.arn
}

output "bucket_domain_name" {
  value = aws_s3_bucket.this.bucket_domain_name
}
