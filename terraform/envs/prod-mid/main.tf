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
    Tier        = "mid"
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

# CloudFront's certificate, web ACL and that ACL's logs must be in us-east-1.
provider "aws" {
  alias               = "us_east_1"
  region              = "us-east-1"
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

module "kms_us_east_1" {
  source      = "../../modules/kms"
  description = "HRMS ${var.customer_slug} key for CloudFront's web ACL logs"
  providers   = { aws = aws.us_east_1 }
}

module "vpc" {
  source       = "../../modules/vpc"
  cidr         = var.vpc_cidr
  az_count     = 2
  egress_mode  = "nat_gateway"
  cluster_name = "hrms"
  kms_key_arn  = module.kms.key_arn
}

module "alb_logs" {
  source             = "../../modules/s3"
  name_prefix        = "hrms-alb-logs-"
  log_delivery       = "alb"
  log_retention_days = var.log_retention_days
}

module "cloudfront_logs" {
  source             = "../../modules/s3"
  name_prefix        = "hrms-cloudfront-logs-"
  log_delivery       = "cloudfront"
  kms_key_arn        = module.kms.key_arn
  log_retention_days = var.log_retention_days
  access_log_bucket  = module.alb_logs.bucket
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

module "acm_cloudfront" {
  source          = "../../modules/acm"
  domain          = var.domain
  extra_domains   = var.extra_domains
  route53_zone_id = var.route53_zone_id
  providers       = { aws = aws.us_east_1 }
}

module "eks" {
  source                     = "../../modules/eks"
  vpc_id                     = module.vpc.vpc_id
  vpc_cidr                   = module.vpc.cidr
  app_subnet_ids             = module.vpc.app_subnet_ids
  kms_key_arn                = module.kms.key_arn
  endpoint_public_cidrs      = var.endpoint_public_cidrs
  admin_principal_arns       = var.cluster_admin_role_arns
  node_instance_types        = [var.node_instance_type]
  node_min                   = 2
  node_desired               = 2
  node_max                   = 4
  log_retention_days         = var.log_retention_days
  restrict_alb_to_cloudfront = true
}

module "rds" {
  source                    = "../../modules/rds"
  vpc_id                    = module.vpc.vpc_id
  subnet_ids                = module.vpc.data_subnet_ids
  client_security_group_ids = { node = module.eks.node_security_group_id }
  instance_class            = var.db_instance_class
  allocated_storage_gb      = var.db_allocated_storage_gb
  multi_az                  = true
  read_replica              = false
  backup_retention_days     = var.db_backup_retention_days
  kms_key_arn               = module.kms.key_arn
  deletion_protection       = var.deletion_protection
}

module "elasticache" {
  source                    = "../../modules/elasticache"
  vpc_id                    = module.vpc.vpc_id
  subnet_ids                = module.vpc.data_subnet_ids
  client_security_group_ids = { node = module.eks.node_security_group_id }
  node_type                 = var.cache_node_type
  replica_count             = 1
  kms_key_arn               = module.kms.key_arn
}

module "iam" {
  source                    = "../../modules/iam"
  documents_bucket_arn      = module.documents.bucket_arn
  kms_key_arn               = module.kms.key_arn
  db_instance_arn           = module.rds.arn
  rds_master_secret_arn     = module.rds.master_secret_arn
  irsa_enabled              = true
  oidc_provider_arn         = module.eks.oidc_provider_arn
  oidc_issuer               = module.eks.oidc_issuer
  cluster_arn               = module.eks.cluster_arn
  github_oidc_provider_arn  = module.baseline.github_oidc_provider_arn
  github_repository         = var.github_repository
  github_deploy_environment = "prod-${var.customer_slug}"
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
  redis_enabled = true
  redis_url     = module.elasticache.url
}

module "waf" {
  source             = "../../modules/waf"
  scope              = "CLOUDFRONT"
  kms_key_arn        = module.kms_us_east_1.key_arn
  log_retention_days = var.log_retention_days
  providers          = { aws = aws.us_east_1 }
}

module "cloudfront" {
  count                  = var.origin_alb_dns_name == null ? 0 : 1
  source                 = "../../modules/cloudfront"
  aliases                = local.domains
  origin_alb_dns_name    = var.origin_alb_dns_name
  certificate_arn        = module.acm_cloudfront.certificate_arn
  web_acl_arn            = module.waf.web_acl_arn
  log_bucket_domain_name = module.cloudfront_logs.bucket_domain_name
  providers              = { aws = aws.us_east_1 }
}

module "route53" {
  source        = "../../modules/route53"
  zone_id       = var.route53_zone_id
  names         = local.domains
  alias_name    = var.origin_alb_dns_name == null ? null : module.cloudfront[0].domain_name
  alias_zone_id = var.origin_alb_dns_name == null ? null : module.cloudfront[0].hosted_zone_id
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
  db_max_connections     = var.db_max_connections
  alb_enabled            = var.alb_arn_suffix != null
  alb_arn_suffix         = var.alb_arn_suffix
}
