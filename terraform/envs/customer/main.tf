# Root configuration for ONE customer account. The same root is used for every
# customer; only the files under infra/customers/ differ:
#
#   terraform -chdir=terraform/envs/customer init -reconfigure -backend-config=../../customers/<name>.backend.hcl
#   terraform -chdir=terraform/envs/customer plan  -var-file=../../customers/<name>.tfvars
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
  # bucket / key / region come from <name>.backend.hcl. Native S3 locking (no DynamoDB).
  backend "s3" {
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region              = var.region
  allowed_account_ids = [var.account_id] # never apply one customer's config to another account
  default_tags {
    tags = {
      Application = "hrms"
      Customer    = var.customer_slug
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

module "baseline" {
  source                   = "../../modules/account-baseline"
  github_repository        = var.github_repository
  github_infra_environment = "infra-${var.customer_slug}"
  enable_guardduty         = var.enable_guardduty
}

module "hrms" {
  source = "../../modules/hrms-stack"

  customer_slug   = var.customer_slug
  environment     = var.environment
  domains         = var.domains
  route53_zone_id = var.route53_zone_id
  enabled_modules = var.enabled_modules
  mail            = var.mail
  organization    = var.organization
  branding        = var.branding
  admin_email     = var.admin_email
  admin_name      = var.admin_name

  backend_image             = var.backend_image
  frontend_image            = var.frontend_image
  private_registry          = var.private_registry
  ecr_repository_arns       = var.ecr_repository_arns
  github_oidc_provider_arn  = module.baseline.github_oidc_provider_arn
  github_repository         = var.github_repository
  github_deploy_environment = "prod-${var.customer_slug}"

  db_instance_class  = var.db_instance_class
  db_multi_az        = var.db_multi_az
  nat_gateway_per_az = var.nat_gateway_per_az
  api_min_count      = var.api_min_count
  api_max_count      = var.api_max_count

  alarm_emails          = var.alarm_emails
  monthly_budget_usd    = var.monthly_budget_usd
  backup_copy_vault_arn = var.backup_copy_vault_arn
  deletion_protection   = var.deletion_protection
}

output "app_url" {
  value = module.hrms.app_url
}

output "alb_dns_name" {
  value = module.hrms.alb_dns_name
}

output "acm_validation_records" {
  value = module.hrms.acm_validation_records
}

output "registry_credentials_secret_arn" {
  value = module.hrms.registry_credentials_secret_arn
}

output "release_role_arn" {
  value = module.hrms.release_role_arn
}

output "terraform_role_arn" {
  value = module.baseline.terraform_role_arn
}

output "bootstrap_admin_secret_arn" {
  value = module.hrms.bootstrap_admin_secret_arn
}
