# Alarms and a budget. Inputs may be null: an Ingress-created ALB is known only after the first sync,
# and its alarms appear on the next apply.
variable "slug" {
  type = string
}

variable "kms_key_arn" {
  type = string
}

variable "alarm_emails" {
  description = "At least one address: with none, alarms and budget notifications reach nobody."
  type        = list(string)
  validation {
    condition     = length(var.alarm_emails) > 0
    error_message = "Set at least one alarm_emails address."
  }
}

variable "monthly_budget_usd" {
  type    = number
  default = 0
}

variable "db_instance_identifier" {
  type = string
}

variable "db_max_connections" {
  type    = number
  default = 100
}

variable "db_replica_enabled" {
  description = "Alarm on replication lag. A plain bool, because the identifier may be unknown at plan time."
  type        = bool
  default     = false
}

variable "db_replica_identifier" {
  type    = string
  default = ""
}

variable "db_replica_lag_seconds" {
  description = "Reports read from the replica, so this is how stale a report may be before someone is told."
  type        = number
  default     = 300
}

variable "clamav_signature_max_age_hours" {
  description = "ClamAV publishes several updates a day, so this much age means freshclam has stopped."
  type        = number
  default     = 48
}

variable "alb_enabled" {
  description = "Create the ALB alarms. A plain bool, because the suffix may be unknown at plan time."
  type        = bool
  default     = false
}

variable "alb_arn_suffix" {
  type    = string
  default = null
}

variable "regional_waf_name" {
  description = "Regional web ACL to alarm on. A CLOUDFRONT ACL reports in us-east-1, so leave this null there."
  type        = string
  default     = null
}

data "aws_region" "this" {}

resource "aws_sns_topic" "alarms" {
  name              = "hrms-alarms"
  kms_master_key_id = var.kms_key_arn
}

resource "aws_sns_topic_subscription" "email" {
  for_each  = toset(var.alarm_emails)
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = each.value
}

locals {
  db_dim = { DBInstanceIdentifier = var.db_instance_identifier }
  db_alarms = {
    db-cpu = {
      namespace = "AWS/RDS", metric = "CPUUtilization", stat = "Average", threshold = 80, op = "GreaterThanThreshold", periods = 3,
      dims      = local.db_dim, desc = "Database CPU above 80%"
    }
    db-free-storage = {
      namespace = "AWS/RDS", metric = "FreeStorageSpace", stat = "Minimum", threshold = 5368709120, op = "LessThanThreshold", periods = 1,
      dims      = local.db_dim, desc = "Database free storage below 5 GB"
    }
    db-connections = {
      namespace = "AWS/RDS", metric = "DatabaseConnections", stat = "Maximum", threshold = var.db_max_connections, op = "GreaterThanThreshold", periods = 3,
      dims      = local.db_dim, desc = "Database connections above the expected maximum"
    }
  }
  replica_alarms = var.db_replica_enabled ? {
    db-replica-lag = {
      namespace = "AWS/RDS", metric = "ReplicaLag", stat = "Maximum", threshold = var.db_replica_lag_seconds, op = "GreaterThanThreshold", periods = 3,
      dims      = { DBInstanceIdentifier = var.db_replica_identifier }, desc = "Read replica is behind the primary; reports are stale"
    }
  } : {}
  alb_dim = { LoadBalancer = var.alb_arn_suffix }
  alb_alarms = var.alb_enabled ? {
    alb-5xx = {
      namespace = "AWS/ApplicationELB", metric = "HTTPCode_ELB_5XX_Count", stat = "Sum", threshold = 10, op = "GreaterThanThreshold", periods = 1,
      dims      = local.alb_dim, desc = "Load balancer returned 5xx errors"
    }
    target-5xx = {
      namespace = "AWS/ApplicationELB", metric = "HTTPCode_Target_5XX_Count", stat = "Sum", threshold = 10, op = "GreaterThanThreshold", periods = 1,
      dims      = local.alb_dim, desc = "Application returned 5xx errors"
    }
    latency-p95 = {
      namespace = "AWS/ApplicationELB", metric = "TargetResponseTime", stat = "p95", threshold = 1.5, op = "GreaterThanThreshold", periods = 3,
      dims      = local.alb_dim, desc = "p95 response time above 1.5 s"
    }
  } : {}
  waf_alarms = var.regional_waf_name == null ? {} : {
    waf-blocked-spike = {
      namespace = "AWS/WAFV2", metric = "BlockedRequests", stat = "Sum", threshold = 1000, op = "GreaterThanThreshold", periods = 1,
      dims      = { WebACL = var.regional_waf_name, Region = data.aws_region.this.region, Rule = "ALL" }, desc = "WAF blocking an unusual volume of requests"
    }
  }
  alarms = merge(local.db_alarms, local.replica_alarms, local.alb_alarms, local.waf_alarms)
}

resource "aws_cloudwatch_metric_alarm" "this" {
  for_each            = local.alarms
  alarm_name          = "hrms-${var.slug}-${each.key}"
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
}

# Published hourly by the CronJob in k8s/base/freshclam-check.yaml. No data also alarms, because it means
# that job has stopped, so this reads as an alarm until the first sync has run.
resource "aws_cloudwatch_metric_alarm" "freshclam" {
  alarm_name          = "hrms-${var.slug}-freshclam"
  alarm_description   = "ClamAV signatures are old, or their age is not being reported: uploads are scanned against stale signatures"
  namespace           = "HRMS"
  metric_name         = "ClamavSignatureAgeHours"
  statistic           = "Maximum"
  period              = 3600
  evaluation_periods  = 2
  threshold           = var.clamav_signature_max_age_hours
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
}

resource "aws_budgets_budget" "monthly" {
  count        = var.monthly_budget_usd > 0 ? 1 : 0
  name         = "hrms-${var.slug}-monthly"
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

output "alarm_topic_arn" {
  value = aws_sns_topic.alarms.arn
}
