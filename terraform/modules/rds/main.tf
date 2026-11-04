# RDS PostgreSQL in private data subnets, KMS-encrypted, TLS enforced, PITR on, never public. The master
# password is generated and held by RDS in Secrets Manager, so it never reaches Terraform state.
# With replicate_source_db this creates a replica in another region instead, for DR.
variable "identifier" {
  type    = string
  default = "hrms-db"
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  type = list(string)
}

variable "client_security_group_ids" {
  description = "Static map of label to security group allowed to connect."
  type        = map(string)
  default     = {}
}

variable "engine_version" {
  type    = string
  default = "17"
}

variable "instance_class" {
  type    = string
  default = "db.t4g.medium"
}

variable "allocated_storage_gb" {
  type    = number
  default = 20
}

variable "max_allocated_storage_gb" {
  type    = number
  default = 200
}

variable "multi_az" {
  type    = bool
  default = true
}

variable "read_replica" {
  description = "Add one read replica in this region, for DB_READ_HOST."
  type        = bool
  default     = false
}

variable "read_replica_class" {
  description = "Defaults to instance_class."
  type        = string
  default     = null
}

variable "replicate_source_db" {
  description = "ARN of the primary, in another region. Leave the DR creation switch to the caller."
  type        = string
  default     = null
}

variable "backup_retention_days" {
  type    = number
  default = 14
}

variable "kms_key_arn" {
  type = string
}

variable "deletion_protection" {
  type    = bool
  default = true
}

variable "performance_insights_enabled" {
  type    = bool
  default = true
}

data "aws_partition" "this" {}

locals {
  is_replica = var.replicate_source_db != null
  family     = "postgres${split(".", var.engine_version)[0]}"
}

resource "aws_db_subnet_group" "this" {
  name       = var.identifier
  subnet_ids = var.subnet_ids
}

resource "aws_security_group" "this" {
  name        = var.identifier
  description = "RDS PostgreSQL"
  vpc_id      = var.vpc_id
  tags        = { Name = var.identifier }
}

resource "aws_vpc_security_group_ingress_rule" "clients" {
  for_each                     = var.client_security_group_ids
  security_group_id            = aws_security_group.this.id
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "PostgreSQL from ${each.key}"
}

resource "aws_db_parameter_group" "this" {
  name_prefix = "${var.identifier}-${local.family}-"
  family      = local.family
  description = "HRMS PostgreSQL parameters"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }
  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }
  parameter {
    name  = "log_connections"
    value = "1"
  }
  parameter {
    name  = "log_statement"
    value = "ddl"
  }
  parameter {
    name  = "idle_in_transaction_session_timeout"
    value = "60000"
  }
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_iam_role" "monitoring" {
  name = "${var.identifier}-monitoring"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "monitoring.rds.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "monitoring" {
  role       = aws_iam_role.monitoring.name
  policy_arn = "arn:${data.aws_partition.this.partition}:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

#trivy:ignore:AWS-0176 The app uses database roles that PostgreSQL RLS depends on; IAM database auth is not used.
resource "aws_db_instance" "this" {
  #checkov:skip=CKV_AWS_161:The app connects with database roles provisioned per installation, and PostgreSQL RLS depends on them; IAM database auth is not used.
  #checkov:skip=CKV2_AWS_30:log_statement=all would write personal data to logs. DDL and slow queries are logged instead.
  #checkov:skip=CKV_AWS_157:Multi-AZ is an input, on for prod-mid and prod-high. prod-low is single-AZ by design and states the trade-off in docs/ARCHITECTURE.md.
  #checkov:skip=CKV_AWS_293:Deletion protection is an input, defaulting to true.
  #checkov:skip=CKV_AWS_354:Performance Insights uses var.kms_key_arn when enabled; checkov cannot follow the conditional.
  identifier          = var.identifier
  engine              = local.is_replica ? null : "postgres"
  engine_version      = local.is_replica ? null : var.engine_version
  instance_class      = var.instance_class
  replicate_source_db = var.replicate_source_db

  allocated_storage     = local.is_replica ? null : var.allocated_storage_gb
  max_allocated_storage = var.max_allocated_storage_gb
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = var.kms_key_arn

  username                      = local.is_replica ? null : "hrmsadmin"
  manage_master_user_password   = local.is_replica ? null : true
  master_user_secret_kms_key_id = local.is_replica ? null : var.kms_key_arn

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.this.id]
  parameter_group_name   = aws_db_parameter_group.this.name
  publicly_accessible    = false
  multi_az               = var.multi_az
  ca_cert_identifier     = "rds-ca-rsa2048-g1"

  backup_retention_period  = var.backup_retention_days
  backup_window            = "20:00-21:00" # 01:30-02:30 IST
  maintenance_window       = "sun:21:30-sun:22:30"
  copy_tags_to_snapshot    = true
  delete_automated_backups = false

  auto_minor_version_upgrade            = true
  performance_insights_enabled          = var.performance_insights_enabled
  performance_insights_kms_key_id       = var.performance_insights_enabled ? var.kms_key_arn : null
  performance_insights_retention_period = var.performance_insights_enabled ? 7 : null
  monitoring_interval                   = 60
  monitoring_role_arn                   = aws_iam_role.monitoring.arn
  enabled_cloudwatch_logs_exports       = ["postgresql", "upgrade"]

  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.identifier}-final"
}

#trivy:ignore:AWS-0176 Inherits the primary's authentication.
resource "aws_db_instance" "read_replica" {
  #checkov:skip=CKV_AWS_161:Read replica inherits the primary's authentication; see above.
  #checkov:skip=CKV2_AWS_30:Read replica; see the primary.
  #checkov:skip=CKV_AWS_157:A read replica for reporting. Failover is the primary's Multi-AZ setting.
  #checkov:skip=CKV_AWS_293:Deletion protection is an input, defaulting to true.
  #checkov:skip=CKV_AWS_354:Performance Insights uses var.kms_key_arn when enabled; checkov cannot follow the conditional.
  #checkov:skip=CKV_AWS_133:Backups are taken on the primary. A read replica has none of its own.
  count               = var.read_replica ? 1 : 0
  identifier          = "${var.identifier}-read"
  instance_class      = coalesce(var.read_replica_class, var.instance_class)
  replicate_source_db = aws_db_instance.this.identifier

  storage_type           = "gp3"
  storage_encrypted      = true
  kms_key_id             = var.kms_key_arn
  vpc_security_group_ids = [aws_security_group.this.id]
  parameter_group_name   = aws_db_parameter_group.this.name
  publicly_accessible    = false
  multi_az               = false
  ca_cert_identifier     = "rds-ca-rsa2048-g1"

  backup_retention_period = 0
  skip_final_snapshot     = true

  auto_minor_version_upgrade            = true
  performance_insights_enabled          = var.performance_insights_enabled
  performance_insights_kms_key_id       = var.performance_insights_enabled ? var.kms_key_arn : null
  performance_insights_retention_period = var.performance_insights_enabled ? 7 : null
  monitoring_interval                   = 60
  monitoring_role_arn                   = aws_iam_role.monitoring.arn
  enabled_cloudwatch_logs_exports       = ["postgresql", "upgrade"]
  deletion_protection                   = var.deletion_protection
}

output "identifier" {
  value = aws_db_instance.this.identifier
}

output "arn" {
  value = aws_db_instance.this.arn
}

output "address" {
  value = aws_db_instance.this.address
}

output "port" {
  value = aws_db_instance.this.port
}

output "read_address" {
  description = "Empty without a read replica, in which case the app reads from the primary."
  value       = var.read_replica ? aws_db_instance.read_replica[0].address : ""
}

output "security_group_id" {
  value = aws_security_group.this.id
}

output "master_secret_arn" {
  value = local.is_replica ? null : aws_db_instance.this.master_user_secret[0].secret_arn
}

output "master_secret_name" {
  description = "The name RDS gave its master secret: the ARN's last part without the six-character suffix."
  value       = local.is_replica ? null : regex("secret:(.+)-[A-Za-z0-9]{6}$", aws_db_instance.this.master_user_secret[0].secret_arn)[0]
}
