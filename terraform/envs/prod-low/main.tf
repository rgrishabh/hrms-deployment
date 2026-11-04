terraform {
  required_version = ">= 1.11"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }
  # bucket, key and region come from a backend file kept with the client's values. Native S3 locking.
  backend "s3" {
    encrypt      = true
    use_lockfile = true
  }
}

locals {
  tags = {
    Application = "hrms"
    Customer    = var.customer_slug
    Tier        = "low"
    ManagedBy   = "terraform"
  }
  domains = concat([var.domain], var.extra_domains)
}

provider "aws" {
  region              = var.region
  allowed_account_ids = [var.account_id]
  default_tags {
    tags = local.tags
  }
}

module "baseline" {
  source                   = "../../modules/account-baseline"
  github_repository        = var.github_repository
  github_infra_environment = "infra-${var.customer_slug}"
  enable_guardduty         = var.enable_guardduty
  state_kms_key_arn        = var.state_kms_key_arn
}

module "kms" {
  source      = "../../modules/kms"
  description = "HRMS ${var.customer_slug} data key"
}

# No NAT gateway: a t4g.nano NAT instance costs a fraction of one, and S3 goes through the free endpoint.
module "vpc" {
  source      = "../../modules/vpc"
  cidr        = var.vpc_cidr
  az_count    = 2
  egress_mode = "nat_instance"
  kms_key_arn = module.kms.key_arn
}

module "alb_logs" {
  source             = "../../modules/s3"
  name_prefix        = "hrms-alb-logs-"
  log_delivery       = "alb"
  log_retention_days = var.log_retention_days
}

module "documents" {
  source            = "../../modules/s3"
  name_prefix       = "hrms-documents-"
  kms_key_arn       = module.kms.key_arn
  access_log_bucket = module.alb_logs.bucket
}

module "acm" {
  source          = "../../modules/acm"
  domain          = var.domain
  extra_domains   = var.extra_domains
  route53_zone_id = var.route53_zone_id
}

# Single-AZ primary plus a read replica, as the tier brief asks. A zone failure means promoting the
# replica or restoring from backup: see docs/DR.md.
module "rds" {
  source                    = "../../modules/rds"
  vpc_id                    = module.vpc.vpc_id
  subnet_ids                = module.vpc.data_subnet_ids
  client_security_group_ids = { node = module.k3s.node_security_group_id }
  instance_class            = var.db_instance_class
  multi_az                  = false
  read_replica              = true
  kms_key_arn               = module.kms.key_arn
  deletion_protection       = var.deletion_protection
}

module "iam" {
  source                    = "../../modules/iam"
  documents_bucket_arn      = module.documents.bucket_arn
  kms_key_arn               = module.kms.key_arn
  db_instance_arn           = module.rds.arn
  rds_master_secret_arn     = module.rds.master_secret_arn
  irsa_enabled              = false
  github_oidc_provider_arn  = module.baseline.github_oidc_provider_arn
  github_repository         = var.github_repository
  github_deploy_environment = "prod-${var.customer_slug}"
}

module "k3s" {
  source               = "../../modules/k3s"
  vpc_id               = module.vpc.vpc_id
  vpc_cidr             = module.vpc.cidr
  app_subnet_ids       = module.vpc.app_subnet_ids
  public_subnet_ids    = module.vpc.public_subnet_ids
  kms_key_arn          = module.kms.key_arn
  instance_type        = var.node_instance_type
  gitops_repo_url      = var.gitops_repo_url
  gitops_repo_revision = var.gitops_repo_revision
  gitops_overlay_path  = var.gitops_overlay_path
  domains              = local.domains
  certificate_arn      = module.acm.certificate_arn
  access_log_bucket    = module.alb_logs.bucket
  app_policy_json      = module.iam.app_policy_json
  secrets_policy_json  = module.iam.secrets_policy_json
  deletion_protection  = var.deletion_protection
}

module "secrets" {
  source      = "../../modules/secrets"
  kms_key_arn = module.kms.key_arn
  infra = {
    db_host      = module.rds.address
    db_port      = tostring(module.rds.port)
    db_read_host = module.rds.read_address
    s3_bucket    = module.documents.bucket
    region       = var.region
    kms_key_id   = module.kms.key_id
    admin_email  = var.admin_email
    admin_name   = var.admin_name
  }
}

module "waf" {
  source             = "../../modules/waf"
  scope              = "REGIONAL"
  kms_key_arn        = module.kms.key_arn
  log_retention_days = var.log_retention_days
  associate_alb      = true
  alb_arn            = module.k3s.alb_arn
}

module "route53" {
  source                 = "../../modules/route53"
  zone_id                = var.route53_zone_id
  names                  = local.domains
  alias_name             = module.k3s.alb_dns_name
  alias_zone_id          = module.k3s.alb_zone_id
  evaluate_target_health = true
}

module "backup" {
  source         = "../../modules/backup"
  kms_key_arn    = module.kms.key_arn
  retention_days = var.backup_retention_days
  resource_arns = {
    database  = module.rds.arn
    documents = module.documents.bucket_arn
  }
}

module "monitoring" {
  source                 = "../../modules/monitoring"
  slug                   = var.customer_slug
  kms_key_arn            = module.kms.key_arn
  alarm_emails           = var.alarm_emails
  monthly_budget_usd     = var.monthly_budget_usd
  db_instance_identifier = module.rds.identifier
  alb_enabled            = true
  alb_arn_suffix         = module.k3s.alb_arn_suffix
  regional_waf_name      = module.waf.web_acl_name
}
