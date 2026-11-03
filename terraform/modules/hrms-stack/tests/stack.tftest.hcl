# Offline tests (no AWS credentials): mock providers + plan.
#   cd infra/modules/hrms-stack && terraform init -backend=false && terraform test
mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = { names = ["ap-south-1a", "ap-south-1b", "ap-south-1c"] }
  }
  mock_data "aws_region" {
    defaults = { region = "ap-south-1" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111111111111" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_resource "aws_db_instance" {
    defaults = {
      address            = "hrms-db.example.ap-south-1.rds.amazonaws.com"
      port               = 5432
      arn                = "arn:aws:rds:ap-south-1:111111111111:db:hrms-db"
      master_user_secret = [{ secret_arn = "arn:aws:secretsmanager:ap-south-1:111111111111:secret:rds-master", kms_key_id = "k", secret_status = "active" }]
    }
  }
  mock_resource "aws_kms_key" {
    defaults = { arn = "arn:aws:kms:ap-south-1:111111111111:key/abc" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111111111111:role/mock" }
  }
  mock_resource "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:ap-south-1:111111111111:secret:hrms" }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:ap-south-1:111111111111:log-group:/hrms/x" }
  }
  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::hrms-mock", bucket = "hrms-mock" }
  }
  mock_resource "aws_ecs_cluster" {
    defaults = { arn = "arn:aws:ecs:ap-south-1:111111111111:cluster/hrms" }
  }
  mock_resource "aws_acm_certificate" {
    defaults = { arn = "arn:aws:acm:ap-south-1:111111111111:certificate/mock" }
  }
  mock_resource "aws_acm_certificate_validation" {
    defaults = { certificate_arn = "arn:aws:acm:ap-south-1:111111111111:certificate/mock" }
  }
  mock_resource "aws_wafv2_web_acl" {
    defaults = { arn = "arn:aws:wafv2:ap-south-1:111111111111:regional/webacl/hrms-waf/mock" }
  }
  mock_resource "aws_lb_target_group" {
    defaults = { arn = "arn:aws:elasticloadbalancing:ap-south-1:111111111111:targetgroup/hrms-api/1", arn_suffix = "targetgroup/hrms-api/1" }
  }
  mock_resource "aws_lb_listener" {
    defaults = { arn = "arn:aws:elasticloadbalancing:ap-south-1:111111111111:listener/app/hrms-alb/1/1" }
  }
  mock_resource "aws_sns_topic" {
    defaults = { arn = "arn:aws:sns:ap-south-1:111111111111:hrms-alarms" }
  }
  mock_resource "aws_backup_vault" {
    defaults = { arn = "arn:aws:backup:ap-south-1:111111111111:backup-vault:hrms" }
  }
  mock_resource "aws_ecs_service" {
    defaults = { id = "arn:aws:ecs:ap-south-1:111111111111:service/hrms/hrms-api" }
  }
  mock_resource "aws_lb" {
    defaults = { arn = "arn:aws:elasticloadbalancing:ap-south-1:111111111111:loadbalancer/app/hrms-alb/1", arn_suffix = "app/hrms-alb/1" }
  }
}

mock_provider "random" {}

variables {
  customer_slug            = "customer-a"
  environment              = "production"
  domains                  = ["hrms.customer-a.example.com", "hr.customer-a.example.com"]
  enabled_modules          = ["default", "attendance.biometric"]
  admin_email              = "it@customer-a.example.com"
  backend_image            = "ghcr.io/example/hrms-backend:v1.2.3"
  frontend_image           = "ghcr.io/example/hrms-frontend:v1.2.3"
  github_oidc_provider_arn = "arn:aws:iam::111111111111:oidc-provider/token.actions.githubusercontent.com"
  github_repository        = "example/hrms-deployment"
  organization = {
    name        = "Customer A Testing Laboratories"
    legal_name  = "Customer A Testing Laboratories Private Limited"
    date_format = "DD-MM-YYYY"
  }
  branding = {
    brand_name    = "Customer A"
    primary_color = "#14532D"
    logo_url      = "https://cdn.customer-a.example.com/logo.svg"
    support_email = "hr@customer-a.example.com"
  }
}

# apply against mock providers: computes every value, creates nothing real.
run "app_container_gets_same_configuration_as_compose" {
  command = apply

  assert {
    condition = alltrue([
      for kv in [
        ["APP_URL", "https://hrms.customer-a.example.com"],
        ["APP_EXTRA_DOMAINS", "hr.customer-a.example.com"],
        ["ENABLED_MODULES", "default,attendance.biometric"],
        ["ORGANIZATION_NAME", "Customer A Testing Laboratories"],
        ["ORGANIZATION_DATE_FORMAT", "DD-MM-YYYY"],
        ["ORGANIZATION_CURRENCY", "INR"],
        ["BRAND_NAME", "Customer A"],
        ["BRAND_PRIMARY_COLOR", "#14532D"],
        ["BRAND_LOGO_URL", "https://cdn.customer-a.example.com/logo.svg"],
        ["DATABASE_SSL", "verify-full"],
      ] : contains([for e in jsondecode(aws_ecs_task_definition.api.container_definitions)[0].environment : "${e.name}=${e.value}"], "${kv[0]}=${kv[1]}")
    ])
    error_message = "API container environment does not carry the expected installation configuration."
  }

  assert {
    # Unset optional values are omitted, not passed as empty strings.
    condition     = !contains([for e in jsondecode(aws_ecs_task_definition.api.container_definitions)[0].environment : e.name], "BRAND_FAVICON_URL")
    error_message = "Unset optional branding must not be passed to the container."
  }

  assert {
    # Secrets arrive only via Secrets Manager references, never as plain environment values.
    condition = alltrue([
      for e in jsondecode(aws_ecs_task_definition.api.container_definitions)[0].environment :
      !contains(["DATABASE_URL", "DATA_ENCRYPTION_KEY", "DB_APP_PASSWORD", "DB_OWNER_PASSWORD"], e.name)
    ]) && length(jsondecode(aws_ecs_task_definition.api.container_definitions)[0].secrets) == 2
    error_message = "Secrets must be injected from Secrets Manager only."
  }

  assert {
    condition     = contains([for e in jsondecode(aws_ecs_task_definition.ops.container_definitions)[0].environment : "${e.name}=${e.value}"], "BOOTSTRAP_MODE=password")
    error_message = "Bootstrap on AWS must use password mode (temporary password from Secrets Manager)."
  }

  assert {
    condition     = !strcontains(aws_ecs_task_definition.api.container_definitions, "username::") && !strcontains(aws_ecs_task_definition.ops.container_definitions, "username::")
    error_message = "Only the dbadmin task may receive the RDS master credentials."
  }

  assert {
    condition     = aws_db_instance.this.publicly_accessible == false && aws_db_instance.this.storage_encrypted == true
    error_message = "Database must be private and encrypted."
  }

  assert {
    condition     = toset(flatten([for c in aws_lb_listener_rule.api["api"].condition : [for h in c.host_header : h.values]])) == toset(["hrms.customer-a.example.com", "hr.customer-a.example.com"])
    error_message = "ALB must forward only the configured domains."
  }
}

run "rejects_invalid_brand_colour" {
  command = plan
  variables {
    branding = { primary_color = "green" }
  }
  expect_failures = [var.branding]
}

run "rejects_non_https_logo" {
  command = plan
  variables {
    branding = { logo_url = "http://insecure.example.com/logo.png" }
  }
  expect_failures = [var.branding]
}

run "rejects_unknown_date_format" {
  command = plan
  variables {
    organization = { name = "X", date_format = "MM/DD/YYYY" }
  }
  expect_failures = [var.organization]
}

run "smtp_password_only_from_secrets_manager" {
  command = apply
  variables {
    enabled_modules = ["default", "notifications.email"]
    mail            = { transport = "smtp", smtp_host = "email-smtp.ap-south-1.amazonaws.com", smtp_user = "AKIAEXAMPLE", from_address = "hrms@customer-a.example.com" }
  }
  assert {
    condition     = contains([for s in jsondecode(aws_ecs_task_definition.api.container_definitions)[0].secrets : s.name], "SMTP_PASSWORD")
    error_message = "SMTP_PASSWORD must come from Secrets Manager."
  }
  assert {
    condition     = !contains([for e in jsondecode(aws_ecs_task_definition.api.container_definitions)[0].environment : e.name], "SMTP_PASSWORD")
    error_message = "SMTP_PASSWORD must never be a plain environment value."
  }
  assert {
    condition     = contains([for e in jsondecode(aws_ecs_task_definition.api.container_definitions)[0].environment : "${e.name}=${e.value}"], "MAIL_TRANSPORT=smtp")
    error_message = "MAIL_TRANSPORT not passed to the container."
  }
}

run "rejects_incomplete_smtp" {
  command = plan
  variables {
    mail = { transport = "smtp" }
  }
  expect_failures = [var.mail]
}

run "frontend_is_a_separate_service_on_the_same_origin" {
  command = apply
  assert {
    condition     = toset(flatten([for c in aws_lb_listener_rule.api["api"].condition : [for p in c.path_pattern : p.values]])) == toset(["/api/*", "/branding/*"])
    error_message = "API and branding paths must go to the backend"
  }
  assert {
    condition     = toset(flatten([for c in aws_lb_listener_rule.api["health"].condition : [for p in c.path_pattern : p.values]])) == toset(["/health*", "/ready"])
    error_message = "Health and readiness must go to the backend"
  }
  assert {
    condition     = aws_lb_listener_rule.web.priority > aws_lb_listener_rule.api["api"].priority && aws_lb_listener_rule.web.priority > aws_lb_listener_rule.api["health"].priority
    error_message = "Frontend catch-all must be evaluated after the backend path rules"
  }
  assert {
    condition     = toset(flatten([for c in aws_lb_listener_rule.web.condition : [for h in c.host_header : h.values]])) == toset(["hrms.customer-a.example.com", "hr.customer-a.example.com"])
    error_message = "Frontend rule must be limited to the installation's hosts"
  }
  assert {
    condition     = jsondecode(aws_ecs_task_definition.web.container_definitions)[0].image == "ghcr.io/example/hrms-frontend:v1.2.3" && jsondecode(aws_ecs_task_definition.web.container_definitions)[0].readonlyRootFilesystem
    error_message = "Frontend task must run the frontend image with a read-only root filesystem"
  }
  assert {
    condition     = aws_ecs_service.web.deployment_circuit_breaker[0].rollback && aws_ecs_service.api.deployment_circuit_breaker[0].rollback
    error_message = "Both services must roll back automatically on a failed deployment"
  }
}

run "pulls_from_ghcr_with_registry_credentials" {
  command = apply
  assert {
    condition = alltrue([for td in [aws_ecs_task_definition.api, aws_ecs_task_definition.ops, aws_ecs_task_definition.web] :
    jsondecode(td.container_definitions)[0].repositoryCredentials.credentialsParameter == aws_secretsmanager_secret.registry[0].arn])
    error_message = "Every task must pull with the registry credentials secret"
  }
  assert {
    condition     = contains(flatten([for c in data.aws_iam_policy_document.release_assume.statement[0].condition : c.values]), "repo:example/hrms-deployment:environment:prod-customer-a")
    error_message = "Only the prod-<slug> environment of the deployment repo may assume the release role"
  }
}

run "rejects_latest_tag" {
  command = plan
  variables {
    backend_image = "ghcr.io/example/hrms-backend:latest"
  }
  expect_failures = [var.backend_image]
}

run "rejects_too_many_domains_for_alb_rules" {
  command = plan
  variables {
    domains = ["a.example.com", "b.example.com", "c.example.com", "d.example.com"]
  }
  expect_failures = [var.domains]
}
