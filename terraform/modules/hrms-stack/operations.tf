# ------------------------------------------------------------------ flow logs
resource "aws_cloudwatch_log_group" "flow" {
  name              = "/hrms/vpc-flow-rejects"
  retention_in_days = 90
  kms_key_id        = aws_kms_key.main.arn
  tags              = local.tags
}

resource "aws_iam_role" "flow_logs" {
  name = "${local.name}-flow-logs"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "vpc-flow-logs.amazonaws.com" } }]
  })
  tags = local.tags
}

resource "aws_iam_role_policy" "flow_logs" {
  name = "write"
  role = aws_iam_role.flow_logs.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
      Resource = "${aws_cloudwatch_log_group.flow.arn}:*"
    }]
  })
}

# ------------------------------------------------------------------ alarms
resource "aws_sns_topic" "alarms" {
  name              = "hrms-alarms"
  kms_master_key_id = aws_kms_key.main.arn
  tags              = local.tags
}

resource "aws_sns_topic_subscription" "alarm_email" {
  for_each  = toset(var.alarm_emails)
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = each.value
}

locals {
  alb_dim = { LoadBalancer = aws_lb.this.arn_suffix }
  alarms = {
    alb-5xx = {
      namespace = "AWS/ApplicationELB", metric = "HTTPCode_ELB_5XX_Count", stat = "Sum", threshold = 10, op = "GreaterThanThreshold", periods = 1,
      dims      = local.alb_dim, desc = "Load balancer returned 5xx errors"
    }
    target-5xx = {
      namespace = "AWS/ApplicationELB", metric = "HTTPCode_Target_5XX_Count", stat = "Sum", threshold = 10, op = "GreaterThanThreshold", periods = 1,
      dims      = local.alb_dim, desc = "Application returned 5xx errors"
    }
    unhealthy-targets = {
      namespace = "AWS/ApplicationELB", metric = "UnHealthyHostCount", stat = "Maximum", threshold = 0, op = "GreaterThanThreshold", periods = 3,
      dims      = merge(local.alb_dim, { TargetGroup = aws_lb_target_group.api.arn_suffix }), desc = "API tasks failing health checks"
    }
    latency-p95 = {
      namespace = "AWS/ApplicationELB", metric = "TargetResponseTime", stat = "p95", threshold = 1.5, op = "GreaterThanThreshold", periods = 3,
      dims      = local.alb_dim, desc = "p95 response time above 1.5 s"
    }
    db-cpu = {
      namespace = "AWS/RDS", metric = "CPUUtilization", stat = "Average", threshold = 80, op = "GreaterThanThreshold", periods = 3,
      dims      = { DBInstanceIdentifier = aws_db_instance.this.identifier }, desc = "Database CPU above 80%"
    }
    db-free-storage = {
      namespace = "AWS/RDS", metric = "FreeStorageSpace", stat = "Minimum", threshold = 10737418240, op = "LessThanThreshold", periods = 1,
      dims      = { DBInstanceIdentifier = aws_db_instance.this.identifier }, desc = "Database free storage below 10 GB"
    }
    db-connections = {
      namespace = "AWS/RDS", metric = "DatabaseConnections", stat = "Maximum", threshold = var.api_max_count * var.db_pool_max, op = "GreaterThanThreshold", periods = 3,
      dims      = { DBInstanceIdentifier = aws_db_instance.this.identifier }, desc = "Database connections above the expected maximum"
    }
    api-running-tasks = {
      namespace = "ECS/ContainerInsights", metric = "RunningTaskCount", stat = "Minimum", threshold = var.api_min_count, op = "LessThanThreshold", periods = 3,
      dims      = { ClusterName = aws_ecs_cluster.this.name, ServiceName = aws_ecs_service.api.name }, desc = "Fewer API tasks running than the minimum"
    }
    waf-blocked-spike = {
      namespace = "AWS/WAFV2", metric = "BlockedRequests", stat = "Sum", threshold = 1000, op = "GreaterThanThreshold", periods = 1,
      dims      = { WebACL = aws_wafv2_web_acl.this.name, Region = local.region, Rule = "ALL" }, desc = "WAF blocking an unusual volume of requests"
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "this" {
  for_each            = local.alarms
  alarm_name          = "hrms-${var.customer_slug}-${each.key}"
  alarm_description   = each.value.desc
  namespace           = each.value.namespace
  metric_name         = each.value.metric
  statistic           = startswith(each.value.stat, "p") ? null : each.value.stat
  extended_statistic  = startswith(each.value.stat, "p") ? each.value.stat : null
  dimensions          = each.value.dims
  period              = 300
  evaluation_periods  = each.value.periods
  threshold           = each.value.threshold
  comparison_operator = each.value.op
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
  tags                = local.tags
}

# ------------------------------------------------------------------ AWS Backup
resource "aws_backup_vault" "this" {
  name        = "hrms"
  kms_key_arn = aws_kms_key.main.arn
  tags        = local.tags
}

resource "aws_backup_plan" "this" {
  name = "hrms-daily"
  rule {
    rule_name         = "daily"
    target_vault_name = aws_backup_vault.this.name
    schedule          = "cron(30 20 * * ? *)" # 02:00 IST
    start_window      = 60
    completion_window = 360
    lifecycle {
      delete_after = var.backup_retention_days
    }
    dynamic "copy_action" {
      for_each = var.backup_copy_vault_arn == null ? [] : [var.backup_copy_vault_arn]
      content {
        destination_vault_arn = copy_action.value
        lifecycle {
          delete_after = var.backup_retention_days
        }
      }
    }
  }
  tags = local.tags
}

resource "aws_iam_role" "backup" {
  name = "${local.name}-backup"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "backup.amazonaws.com" } }]
  })
  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "backup" {
  for_each = toset([
    "arn:${local.partition}:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup",
    "arn:${local.partition}:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores",
    "arn:${local.partition}:iam::aws:policy/AWSBackupServiceRolePolicyForS3Backup",
    "arn:${local.partition}:iam::aws:policy/AWSBackupServiceRolePolicyForS3Restore",
  ])
  role       = aws_iam_role.backup.name
  policy_arn = each.value
}

resource "aws_backup_selection" "this" {
  name         = "hrms-data"
  plan_id      = aws_backup_plan.this.id
  iam_role_arn = aws_iam_role.backup.arn
  resources    = [aws_db_instance.this.arn, aws_s3_bucket.documents.arn]
}

# ------------------------------------------------------------------ budget
resource "aws_budgets_budget" "monthly" {
  count        = var.monthly_budget_usd > 0 ? 1 : 0
  name         = "hrms-${var.customer_slug}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"
  dynamic "notification" {
    for_each = [80, 100]
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = notification.value == 100 ? "FORECASTED" : "ACTUAL"
      subscriber_email_addresses = var.alarm_emails
    }
  }
}
