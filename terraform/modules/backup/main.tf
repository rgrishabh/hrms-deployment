# AWS Backup for RDS and S3 (PITR is in the rds module; this is the longer, separately held copy).
# With copy_vault_arn, every recovery point is also copied to the DR region's vault.
variable "vault_name" {
  type    = string
  default = "hrms"
}

variable "kms_key_arn" {
  type = string
}

variable "create_plan" {
  description = "false creates only the vault, for use as a copy destination in the DR region."
  type        = bool
  default     = true
}

variable "resource_arns" {
  description = "Static map of label to ARN, so that for_each and plans work before the ARNs are known."
  type        = map(string)
  default     = {}
}

variable "retention_days" {
  type    = number
  default = 35
}

variable "schedule" {
  type    = string
  default = "cron(30 20 * * ? *)" # 02:00 IST
}

variable "copy_enabled" {
  description = "Copy recovery points to copy_vault_arn. A plain bool, because the ARN may be unknown at plan time."
  type        = bool
  default     = false
}

variable "copy_vault_arn" {
  type    = string
  default = null
}

data "aws_partition" "this" {}

resource "aws_backup_vault" "this" {
  name        = var.vault_name
  kms_key_arn = var.kms_key_arn
}

resource "aws_backup_plan" "this" {
  count = var.create_plan ? 1 : 0
  name  = "${var.vault_name}-daily"
  rule {
    rule_name         = "daily"
    target_vault_name = aws_backup_vault.this.name
    schedule          = var.schedule
    start_window      = 60
    completion_window = 360
    lifecycle {
      delete_after = var.retention_days
    }
    dynamic "copy_action" {
      for_each = var.copy_enabled ? [var.copy_vault_arn] : []
      content {
        destination_vault_arn = copy_action.value
        lifecycle {
          delete_after = var.retention_days
        }
      }
    }
  }
}

resource "aws_iam_role" "backup" {
  count = var.create_plan ? 1 : 0
  name  = "${var.vault_name}-backup"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "backup.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "backup" {
  for_each = var.create_plan ? toset([
    "service-role/AWSBackupServiceRolePolicyForBackup",
    "service-role/AWSBackupServiceRolePolicyForRestores",
    "AWSBackupServiceRolePolicyForS3Backup",
    "AWSBackupServiceRolePolicyForS3Restore",
  ]) : toset([])
  role       = aws_iam_role.backup[0].name
  policy_arn = "arn:${data.aws_partition.this.partition}:iam::aws:policy/${each.value}"
}

resource "aws_backup_selection" "this" {
  count        = var.create_plan ? 1 : 0
  name         = "${var.vault_name}-data"
  plan_id      = aws_backup_plan.this[0].id
  iam_role_arn = aws_iam_role.backup[0].arn
  resources    = values(var.resource_arns)
}

output "vault_arn" {
  value = aws_backup_vault.this.arn
}
