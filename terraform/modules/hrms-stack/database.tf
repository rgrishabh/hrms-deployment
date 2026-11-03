# RDS PostgreSQL: private data subnets, encrypted with the account CMK, TLS
# enforced, Multi-AZ by default, PITR via automated backups. The master
# password is generated and stored by RDS in Secrets Manager (never in state).
resource "aws_db_subnet_group" "this" {
  name       = "${local.name}-db"
  subnet_ids = aws_subnet.data[*].id
  tags       = local.tags
}

resource "aws_db_parameter_group" "this" {
  name_prefix = "${local.name}-pg${split(".", var.db_engine_version)[0]}-"
  family      = "postgres${split(".", var.db_engine_version)[0]}"
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
    name  = "idle_in_transaction_session_timeout"
    value = "60000"
  }
  lifecycle {
    create_before_destroy = true
  }
  tags = local.tags
}

resource "aws_iam_role" "rds_monitoring" {
  name = "${local.name}-rds-monitoring"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "monitoring.rds.amazonaws.com" } }]
  })
  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

resource "aws_db_instance" "this" {
  identifier     = "${local.name}-db"
  engine         = "postgres"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  allocated_storage     = var.db_allocated_storage_gb
  max_allocated_storage = var.db_max_allocated_storage_gb
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.main.arn

  username                      = "hrmsadmin"
  manage_master_user_password   = true
  master_user_secret_kms_key_id = aws_kms_key.main.arn

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]
  parameter_group_name   = aws_db_parameter_group.this.name
  publicly_accessible    = false
  multi_az               = var.db_multi_az
  ca_cert_identifier     = "rds-ca-rsa2048-g1"

  backup_retention_period  = var.db_backup_retention_days
  backup_window            = "20:00-21:00" # 01:30-02:30 IST
  maintenance_window       = "sun:21:30-sun:22:30"
  copy_tags_to_snapshot    = true
  delete_automated_backups = false

  auto_minor_version_upgrade            = true
  performance_insights_enabled          = true
  performance_insights_kms_key_id       = aws_kms_key.main.arn
  performance_insights_retention_period = 7
  monitoring_interval                   = 60
  monitoring_role_arn                   = aws_iam_role.rds_monitoring.arn
  enabled_cloudwatch_logs_exports       = ["postgresql", "upgrade"]

  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = false
  final_snapshot_identifier = "${local.name}-db-final"

  tags = local.tags
}

# ------------------------------------------------------------------ application secrets
# Role passwords are generated here (alphanumeric so they are URL-safe) and
# stored as full connection URLs. They exist in Terraform state, so the state
# bucket is KMS-encrypted and access-restricted (shared-services module).
resource "random_password" "db_owner" {
  length  = 40
  special = false
}

resource "random_password" "db_app" {
  length  = 40
  special = false
}

resource "random_password" "admin" {
  length  = 24
  special = true
}

resource "random_bytes" "data_key" {
  length = 32
}

locals {
  db_host = aws_db_instance.this.address
  db_port = aws_db_instance.this.port
  db_name = "hrms"
}

resource "aws_secretsmanager_secret" "app" {
  for_each = {
    database_url           = "Runtime DB URL (hrms_app, RLS-restricted)"
    database_migration_url = "Owner DB URL (migrations, bootstrap)"
    db_owner_password      = "hrms_owner password (provisioning)"
    db_app_password        = "hrms_app password (provisioning)"
    data_encryption_key    = "Field-level encryption key (bank details). Never rotate without the re-encryption job."
    bootstrap_admin        = "Initial tenant administrator password. Hand over securely, then the admin should change it."
  }
  name                    = "hrms/${replace(each.key, "_", "-")}"
  description             = each.value
  kms_key_id              = aws_kms_key.main.arn
  recovery_window_in_days = 30
  tags                    = local.tags
}

# SMTP password: container only — the value is set by an operator, never by Terraform.
resource "aws_secretsmanager_secret" "smtp_password" {
  name                    = "hrms/smtp-password"
  description             = "SMTP password for MAIL_TRANSPORT=smtp. Set the value manually; Terraform never stores it."
  kms_key_id              = aws_kms_key.main.arn
  recovery_window_in_days = 30
  tags                    = local.tags
}

resource "aws_secretsmanager_secret_version" "app" {
  for_each = {
    database_url           = "postgres://hrms_app:${random_password.db_app.result}@${local.db_host}:${local.db_port}/${local.db_name}"
    database_migration_url = "postgres://hrms_owner:${random_password.db_owner.result}@${local.db_host}:${local.db_port}/${local.db_name}"
    db_owner_password      = random_password.db_owner.result
    db_app_password        = random_password.db_app.result
    data_encryption_key    = random_bytes.data_key.base64
    bootstrap_admin        = random_password.admin.result
  }
  secret_id     = aws_secretsmanager_secret.app[each.key].id
  secret_string = each.value
}
