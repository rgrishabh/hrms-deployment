# One customer-managed key per account and region, for RDS, Secrets Manager, S3, EBS, CloudWatch Logs,
# SNS, ElastiCache and AWS Backup. A multi-region primary lets the DR region decrypt the same data key.
variable "alias" {
  description = "Alias, without the alias/ prefix."
  type        = string
  default     = "hrms-main"
}

variable "description" {
  type    = string
  default = "HRMS data key"
}

variable "multi_region" {
  description = "Create a multi-region primary key, required when a DR region is used."
  type        = bool
  default     = false
}

variable "replica_of" {
  description = "ARN of a multi-region primary. Makes this key a replica in the provider's region."
  type        = string
  default     = null
}

variable "deletion_window_days" {
  type    = number
  default = 30
}

data "aws_caller_identity" "this" {}
data "aws_region" "this" {}
data "aws_partition" "this" {}

locals {
  account_id = data.aws_caller_identity.this.account_id
  region     = data.aws_region.this.region
  partition  = data.aws_partition.this.partition
}

data "aws_iam_policy_document" "key" {
  #checkov:skip=CKV_AWS_109:A key policy's Resource "*" means this key only; AWS requires that form.
  #checkov:skip=CKV_AWS_111:A key policy's Resource "*" means this key only; AWS requires that form.
  #checkov:skip=CKV_AWS_356:A key policy's Resource "*" means this key only; AWS requires that form.
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
    sid       = "AlarmsAndBudgetsToSns"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey*"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com", "budgets.amazonaws.com"]
    }
  }
  # CloudFront standard logs are delivered to a KMS-encrypted bucket by this service.
  statement {
    sid       = "LogDelivery"
    actions   = ["kms:GenerateDataKey*", "kms:Decrypt"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }
  }
  # EBS volumes in launch templates are created by this service-linked role. It may not exist yet when
  # the key is created, so it is matched by condition: a named principal would be rejected.
  statement {
    sid = "AutoScalingEbsVolumes"
    actions = [
      "kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey", "kms:CreateGrant",
    ]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    condition {
      test     = "StringEquals"
      variable = "kms:CallerAccount"
      values   = [local.account_id]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:PrincipalArn"
      values   = ["arn:${local.partition}:iam::${local.account_id}:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling"]
    }
  }
}

resource "aws_kms_key" "this" {
  count                   = var.replica_of == null ? 1 : 0
  description             = var.description
  enable_key_rotation     = true
  deletion_window_in_days = var.deletion_window_days
  multi_region            = var.multi_region
  policy                  = data.aws_iam_policy_document.key.json
}

resource "aws_kms_replica_key" "this" {
  count                   = var.replica_of == null ? 0 : 1
  description             = "${var.description} (replica)"
  primary_key_arn         = var.replica_of
  deletion_window_in_days = var.deletion_window_days
  policy                  = data.aws_iam_policy_document.key.json
}

locals {
  key_arn = var.replica_of == null ? aws_kms_key.this[0].arn : aws_kms_replica_key.this[0].arn
  key_id  = var.replica_of == null ? aws_kms_key.this[0].key_id : aws_kms_replica_key.this[0].key_id
}

resource "aws_kms_alias" "this" {
  name          = "alias/${var.alias}"
  target_key_id = local.key_id
}

output "key_arn" {
  value = local.key_arn
}

output "key_id" {
  value = local.key_id
}
