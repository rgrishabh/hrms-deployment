resource "aws_ecs_cluster" "this" {
  name = local.name
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
  tags = local.tags
}

resource "aws_cloudwatch_log_group" "app" {
  for_each          = toset(["api", "ops"])
  name              = "/hrms/${each.key}"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.main.arn
  tags              = local.tags
}

# ------------------------------------------------------------------ IAM
data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

# Execution role: pulls the image (cross-account ECR), writes logs, injects secrets.
resource "aws_iam_role" "execution" {
  name               = "${local.name}-ecs-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "execution" {
  name = "secrets-and-ecr"
  role = aws_iam_role.execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = concat([for s in aws_secretsmanager_secret.app : s.arn], [aws_db_instance.this.master_user_secret[0].secret_arn, aws_secretsmanager_secret.smtp_password.arn])
      },
      { Effect = "Allow", Action = ["kms:Decrypt"], Resource = [aws_kms_key.main.arn] },
      { Effect = "Allow", Action = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"], Resource = [var.ecr_repository_arn] },
    ]
  })
}

# API task role: only the documents bucket.
resource "aws_iam_role" "api_task" {
  name               = "${local.name}-api-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
  tags               = local.tags
}

resource "aws_iam_role_policy" "api_task" {
  name = "documents"
  role = aws_iam_role.api_task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"], Resource = ["${aws_s3_bucket.documents.arn}/*"] },
      { Effect = "Allow", Action = ["s3:ListBucket"], Resource = [aws_s3_bucket.documents.arn] },
      { Effect = "Allow", Action = ["kms:Decrypt", "kms:GenerateDataKey"], Resource = [aws_kms_key.main.arn] },
    ]
  })
}

# One-off task role: needs no AWS API access at all.
resource "aws_iam_role" "ops_task" {
  name               = "${local.name}-ops-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
  tags               = local.tags
}

# ------------------------------------------------------------------ task definitions
locals {
  secret = { for k, s in aws_secretsmanager_secret.app : k => s.arn }
  master = aws_db_instance.this.master_user_secret[0].secret_arn
  log = { for k in ["api", "ops"] : k => {
    logDriver = "awslogs"
    options = {
      "awslogs-group"         = aws_cloudwatch_log_group.app[k].name
      "awslogs-region"        = local.region
      "awslogs-stream-prefix" = k
    }
  } }
  common_env = [
    { name = "AWS_REGION", value = local.region },
    { name = "LOG_LEVEL", value = "info" },
  ]
  # Installation identity + white-label configuration: identical names and meaning to Docker Compose.
  identity_env = {
    APP_URL               = "https://${local.primary}"
    APP_EXTRA_DOMAINS     = join(",", slice(var.domains, 1, length(var.domains)))
    ORGANIZATION_NAME     = var.organization.name
    ORGANIZATION_TIMEZONE = var.organization.timezone
  }
  branding_env = {
    ENABLED_MODULES             = join(",", var.enabled_modules)
    PRODUCT_NAME                = var.branding.product_name
    BRAND_NAME                  = var.branding.brand_name
    BRAND_SHORT_NAME            = var.branding.short_name
    BRAND_LOGO_URL              = var.branding.logo_url
    BRAND_FAVICON_URL           = var.branding.favicon_url
    BRAND_PRIMARY_COLOR         = var.branding.primary_color
    BRAND_SECONDARY_COLOR       = var.branding.secondary_color
    BRAND_ACCENT_COLOR          = var.branding.accent_color
    BRAND_LOGIN_MESSAGE         = var.branding.login_message
    BRAND_SUPPORT_EMAIL         = var.branding.support_email
    BRAND_SUPPORT_PHONE         = var.branding.support_phone
    BRAND_HELP_URL              = var.branding.help_url
    ORGANIZATION_LEGAL_NAME     = var.organization.legal_name
    ORGANIZATION_COUNTRY        = var.organization.country
    ORGANIZATION_CURRENCY       = var.organization.currency
    ORGANIZATION_DATE_FORMAT    = var.organization.date_format
    ORGANIZATION_FY_START_MONTH = tostring(var.organization.fy_start_month)
  }
  mail_env = {
    MAIL_TRANSPORT    = var.mail.transport
    SMTP_HOST         = var.mail.smtp_host
    SMTP_PORT         = tostring(var.mail.smtp_port)
    SMTP_SECURE       = tostring(var.mail.smtp_secure)
    SMTP_USER         = var.mail.smtp_user
    MAIL_FROM_ADDRESS = var.mail.from_address
    MAIL_FROM_NAME    = var.mail.from_name
  }
  mail_env_list     = [for k, v in local.mail_env : { name = k, value = v } if v != null && v != ""]
  smtp_secret       = var.mail.transport == "smtp" && var.mail.smtp_user != null ? [{ name = "SMTP_PASSWORD", valueFrom = aws_secretsmanager_secret.smtp_password.arn }] : []
  identity_env_list = [for k, v in local.identity_env : { name = k, value = v } if v != null && v != ""]
  branding_env_list = [for k, v in local.branding_env : { name = k, value = v } if v != null && v != ""]
  container_base = {
    name                   = "app"
    image                  = var.container_image
    essential              = true
    readonlyRootFilesystem = true
    user                   = "node"
    linuxParameters        = { initProcessEnabled = true }
  }
}

resource "aws_ecs_task_definition" "api" {
  family                   = "hrms-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.api_cpu
  memory                   = var.api_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.api_task.arn
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
  container_definitions = jsonencode([merge(local.container_base, {
    portMappings     = [{ containerPort = 4000, protocol = "tcp" }]
    logConfiguration = local.log.api
    environment = concat(local.common_env, local.identity_env_list, local.branding_env_list, local.mail_env_list, [
      { name = "DATABASE_SSL", value = "verify-full" },
      { name = "TRUST_PROXY", value = "true" },
      { name = "COOKIE_SECURE", value = "true" },
      { name = "DATABASE_POOL_MAX", value = tostring(var.db_pool_max) },
      { name = "AWS_S3_BUCKET", value = aws_s3_bucket.documents.bucket },
      { name = "STORAGE_DRIVER", value = "s3" },
    ])
    secrets = concat([
      { name = "DATABASE_URL", valueFrom = local.secret.database_url },
      { name = "DATA_ENCRYPTION_KEY", valueFrom = local.secret.data_encryption_key },
    ], local.smtp_secret)
    healthCheck = {
      command     = ["CMD-SHELL", "wget -qO- http://127.0.0.1:4000/health/live || exit 1"]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 20
    }
  })])
  tags = local.tags
}

# migrate + bootstrap (owner credentials, no master credentials).
resource "aws_ecs_task_definition" "ops" {
  family                   = "hrms-ops"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.ops_task.arn
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
  container_definitions = jsonencode([merge(local.container_base, {
    command          = ["node", "dist/src/db/migrate.js"]
    logConfiguration = local.log.ops
    environment = concat(local.common_env, local.identity_env_list, [
      { name = "DATABASE_SSL", value = "verify-full" },
      { name = "BOOTSTRAP_ADMIN_EMAIL", value = var.admin_email },
      { name = "BOOTSTRAP_ADMIN_NAME", value = var.admin_name },
      # Password from Secrets Manager (never in logs or outputs); changed by the admin at first sign-in.
      { name = "BOOTSTRAP_MODE", value = "password" },
    ])
    secrets = [
      { name = "DATABASE_MIGRATION_URL", valueFrom = local.secret.database_migration_url },
      { name = "BOOTSTRAP_ADMIN_PASSWORD", valueFrom = local.secret.bootstrap_admin },
    ]
  })])
  tags = local.tags
}

# Provisioning (RDS master credentials). Kept separate so no other task can read them.
resource "aws_ecs_task_definition" "dbadmin" {
  family                   = "hrms-dbadmin"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.ops_task.arn
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
  container_definitions = jsonencode([merge(local.container_base, {
    command          = ["node", "dist/src/db/provision.js"]
    logConfiguration = local.log.ops
    environment = concat(local.common_env, [
      { name = "DATABASE_SSL", value = "verify-full" },
      { name = "DB_HOST", value = local.db_host },
      { name = "DB_PORT", value = tostring(local.db_port) },
      { name = "DB_NAME", value = local.db_name },
    ])
    secrets = [
      { name = "DB_ADMIN_USER", valueFrom = "${local.master}:username::" },
      { name = "DB_ADMIN_PASSWORD", valueFrom = "${local.master}:password::" },
      { name = "DB_OWNER_PASSWORD", valueFrom = local.secret.db_owner_password },
      { name = "DB_APP_PASSWORD", valueFrom = local.secret.db_app_password },
    ]
  })])
  tags = local.tags
}

# ------------------------------------------------------------------ service
resource "aws_ecs_service" "api" {
  name                              = "hrms-api"
  cluster                           = aws_ecs_cluster.this.id
  task_definition                   = aws_ecs_task_definition.api.arn
  desired_count                     = var.api_min_count
  launch_type                       = "FARGATE"
  platform_version                  = "LATEST"
  health_check_grace_period_seconds = 30
  enable_execute_command            = false
  propagate_tags                    = "SERVICE"

  network_configuration {
    subnets          = aws_subnet.app[*].id
    security_groups  = [aws_security_group.api.id]
    assign_public_ip = false
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.api.arn
    container_name   = "app"
    container_port   = 4000
  }
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  # Releases register new task definition revisions (scripts/deploy/release.sh);
  # autoscaling owns desired_count.
  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }
  depends_on = [aws_lb_listener_rule.api]
  tags       = local.tags
}

resource "aws_appautoscaling_target" "api" {
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.api.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.api_min_count
  max_capacity       = var.api_max_count
}

resource "aws_appautoscaling_policy" "api_cpu" {
  name               = "cpu-target"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.api.service_namespace
  resource_id        = aws_appautoscaling_target.api.resource_id
  scalable_dimension = aws_appautoscaling_target.api.scalable_dimension
  target_tracking_scaling_policy_configuration {
    target_value       = 60
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}

# ------------------------------------------------------------------ release metadata
# Read by scripts/deploy/release.sh so the pipeline needs no Terraform state access.
resource "aws_ssm_parameter" "release" {
  for_each = {
    cluster        = aws_ecs_cluster.this.name
    service        = aws_ecs_service.api.name
    subnets        = join(",", aws_subnet.app[*].id)
    ops_sg         = aws_security_group.ops.id
    domain         = local.primary
    db_instance_id = aws_db_instance.this.identifier
    ops_log_group  = aws_cloudwatch_log_group.app["ops"].name
    customer_slug  = var.customer_slug
  }
  name  = "/hrms/release/${each.key}"
  type  = "String"
  value = each.value
  tags  = local.tags
}

# ------------------------------------------------------------------ GitHub release role
# Assumed by the release workflow (OIDC, this repo + environment only). Can
# register task definitions, run the one-off tasks, update the service and snapshot RDS.
data "aws_iam_policy_document" "release_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.github_oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repository}:environment:${var.github_deploy_environment}"]
    }
  }
}

resource "aws_iam_role" "release" {
  name                 = "hrms-release"
  assume_role_policy   = data.aws_iam_policy_document.release_assume.json
  max_session_duration = 3600
  tags                 = local.tags
}

resource "aws_iam_role_policy" "release" {
  name = "release"
  role = aws_iam_role.release.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["ssm:GetParameter", "ssm:GetParametersByPath"], Resource = "arn:${local.partition}:ssm:${local.region}:${local.account_id}:parameter/hrms/release*" },
      { Effect = "Allow", Action = ["ecs:DescribeTaskDefinition", "ecs:RegisterTaskDefinition", "ecs:DescribeServices", "ecs:DescribeTasks", "ecs:ListTasks", "ecs:TagResource"], Resource = "*" },
      {
        Effect    = "Allow", Action = ["ecs:RunTask"], Resource = "arn:${local.partition}:ecs:${local.region}:${local.account_id}:task-definition/hrms-*"
        Condition = { ArnEquals = { "ecs:cluster" = aws_ecs_cluster.this.arn } }
      },
      { Effect = "Allow", Action = ["ecs:UpdateService"], Resource = aws_ecs_service.api.id },
      {
        Effect    = "Allow", Action = ["iam:PassRole"], Resource = [aws_iam_role.execution.arn, aws_iam_role.api_task.arn, aws_iam_role.ops_task.arn]
        Condition = { StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" } }
      },
      { Effect = "Allow", Action = ["rds:CreateDBSnapshot", "rds:DescribeDBSnapshots", "rds:AddTagsToResource"], Resource = "*" },
      { Effect = "Allow", Action = ["rds:DescribeDBInstances"], Resource = aws_db_instance.this.arn },
      { Effect = "Allow", Action = ["logs:GetLogEvents", "logs:FilterLogEvents"], Resource = "${aws_cloudwatch_log_group.app["ops"].arn}:*" },
    ]
  })
}
