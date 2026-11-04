# Every secret the workloads read through External Secrets, under stable names (k8s/base/externalsecrets.yaml).
#
# Generated passwords use ephemeral values and write-only attributes, so they never enter Terraform
# state. Each is written once. Bump password_version to generate new ones, then rerun the provision Job
# (docs/RUNBOOK.md, Rotate secrets). Secrets Manager is their only copy, and provision applies them.
variable "kms_key_arn" {
  type = string
}

variable "infra" {
  description = "Non-sensitive Terraform outputs the workloads need: db_host, db_port, db_read_host, s3_bucket, region, kms_key_id, admin_email, admin_name."
  type        = map(string)
}

variable "redis_enabled" {
  description = "Store redis_url. A plain bool, because the value is unknown at plan time."
  type        = bool
  default     = false
}

variable "redis_url" {
  type      = string
  default   = null
  sensitive = true
}

variable "password_version" {
  description = "Bump to generate new role passwords."
  type        = number
  default     = 1
}

variable "replica_region" {
  description = "Replicate every secret to this region, for DR."
  type        = string
  default     = null
}

variable "replica_kms_key_arn" {
  type    = string
  default = null
}

variable "recovery_window_days" {
  type    = number
  default = 30
}

locals {
  generated = {
    db-owner-password        = "hrms_owner password: migrations and bootstrap"
    db-app-password          = "hrms_app password: runtime, restricted by RLS"
    bootstrap-admin-password = "First administrator's temporary password. Hand over securely; it must be changed at first sign-in."
  }
  # Created here and filled in by an operator or script. Terraform never holds the values.
  operator_managed = {
    data-key-ciphertext = "Data key encrypted with the KMS key. Set once by scripts/generate-data-key.sh. Never replace it without re-encrypting the data."
    ghcr-pull           = "Optional GHCR pull credentials, as JSON with username and token. Needed only with k8s/components/private-registry."
    argocd-repo         = "Optional credentials for the client's private overlay repository, as JSON with url and sshPrivateKey."
  }
}

ephemeral "random_password" "generated" {
  for_each = local.generated
  length   = 40
  special  = false
}

resource "aws_secretsmanager_secret" "generated" {
  #checkov:skip=CKV2_AWS_57:Rotation needs the provision Job to apply the new password, so it is a deliberate runbook step.
  for_each                = local.generated
  name                    = "hrms/${each.key}"
  description             = each.value
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = var.recovery_window_days
  dynamic "replica" {
    for_each = var.replica_region == null ? [] : [var.replica_region]
    content {
      region     = replica.value
      kms_key_id = var.replica_kms_key_arn
    }
  }
}

resource "aws_secretsmanager_secret_version" "generated" {
  for_each                 = local.generated
  secret_id                = aws_secretsmanager_secret.generated[each.key].id
  secret_string_wo         = ephemeral.random_password.generated[each.key].result
  secret_string_wo_version = var.password_version
}

resource "aws_secretsmanager_secret" "operator" {
  #checkov:skip=CKV2_AWS_57:Set by an operator. The data key must not rotate without re-encrypting data.
  for_each                = local.operator_managed
  name                    = "hrms/${each.key}"
  description             = each.value
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = var.recovery_window_days
  dynamic "replica" {
    for_each = var.replica_region == null ? [] : [var.replica_region]
    content {
      region     = replica.value
      kms_key_id = var.replica_kms_key_arn
    }
  }
}

# SMTP starts empty so that a client without mail yet can still come up; the app sends nothing until
# credentials are set. The operator's later value is not overwritten.
resource "aws_secretsmanager_secret" "smtp" {
  #checkov:skip=CKV2_AWS_57:SMTP credentials are issued by the mail provider and rotated there.
  name                    = "hrms/smtp-credentials"
  description             = "SMTP credentials as JSON with user and password. Set by an operator."
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = var.recovery_window_days
  dynamic "replica" {
    for_each = var.replica_region == null ? [] : [var.replica_region]
    content {
      region     = replica.value
      kms_key_id = var.replica_kms_key_arn
    }
  }
}

resource "aws_secretsmanager_secret_version" "smtp" {
  secret_id     = aws_secretsmanager_secret.smtp.id
  secret_string = jsonencode({ user = "", password = "" })
  lifecycle {
    ignore_changes = [secret_string, version_stages]
  }
}

# Non-sensitive values, kept here so that External Secrets carries them into pods and no client
# overlay has to copy them by hand.
resource "aws_secretsmanager_secret" "infra" {
  #checkov:skip=CKV2_AWS_57:Holds non-sensitive Terraform outputs and is rewritten on each apply.
  name                    = "hrms/infra"
  description             = "Non-sensitive infrastructure values for the workloads, managed by Terraform."
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = var.recovery_window_days
  dynamic "replica" {
    for_each = var.replica_region == null ? [] : [var.replica_region]
    content {
      region     = replica.value
      kms_key_id = var.replica_kms_key_arn
    }
  }
}

resource "aws_secretsmanager_secret_version" "infra" {
  secret_id     = aws_secretsmanager_secret.infra.id
  secret_string = jsonencode(var.infra)
}

resource "aws_secretsmanager_secret" "redis" {
  #checkov:skip=CKV2_AWS_57:Derived from the ElastiCache AUTH token, which Terraform manages.
  count                   = var.redis_enabled ? 1 : 0
  name                    = "hrms/redis-url"
  description             = "REDIS_URL, including the AUTH token."
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = var.recovery_window_days
}

resource "aws_secretsmanager_secret_version" "redis" {
  count         = var.redis_enabled ? 1 : 0
  secret_id     = aws_secretsmanager_secret.redis[0].id
  secret_string = var.redis_url
}

output "data_key_secret_name" {
  value = aws_secretsmanager_secret.operator["data-key-ciphertext"].name
}
