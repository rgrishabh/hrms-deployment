output "overlay_values" {
  description = "Read by scripts/new-client-overlay.sh."
  value = {
    tier                     = "high"
    region                   = var.region
    rds_master_secret_name   = module.rds.master_secret_name
    backend_role_arn         = module.iam.backend_role_arn
    worker_role_arn          = module.iam.worker_role_arn
    secrets_role_arn         = module.iam.external_secrets_role_arn
    migrate_role_arn         = module.iam.migrate_role_arn
    freshclam_check_role_arn = module.iam.freshclam_check_role_arn
    certificate_arn          = module.acm.certificate_arn
    alb_security_group_id    = module.eks.alb_security_group_id
    alb_logs_bucket          = module.alb_logs.bucket
  }
}

output "addon_values" {
  description = "Values the Argo CD add-on Applications need."
  value = {
    cluster_name                      = module.eks.cluster_name
    vpc_id                            = module.vpc.vpc_id
    load_balancer_controller_role_arn = module.iam.load_balancer_controller_role_arn
  }
}

output "acm_validation_records" {
  description = "Add these at the client's DNS provider when Route 53 is not used. The same names cover both certificates only if the values match, so check both lists."
  value = {
    regional   = module.acm.validation_records
    cloudfront = module.acm_cloudfront.validation_records
  }
}

output "cloudfront_domain_name" {
  description = "Point the domain here if Route 53 is not used."
  value       = var.origin_alb_dns_name == null ? null : module.cloudfront[0].domain_name
}

output "kms_key_id" {
  value = module.kms.key_id
}

output "release_role_arn" {
  value = module.iam.release_role_arn
}

output "dr_values" {
  description = "For docs/DR.md."
  value = {
    region                   = var.dr_region
    db_identifier            = module.rds_dr.identifier
    db_address               = module.rds_dr.address
    documents_bucket         = module.documents_dr.bucket
    kms_key_id               = module.kms_dr.key_id
    cluster_name             = var.dr_activate ? module.eks_dr[0].cluster_name : null
    backend_role_arn         = var.dr_activate ? module.iam_dr[0].backend_role_arn : null
    worker_role_arn          = var.dr_activate ? module.iam_dr[0].worker_role_arn : null
    secrets_role_arn         = var.dr_activate ? module.iam_dr[0].external_secrets_role_arn : null
    migrate_role_arn         = var.dr_activate ? module.iam_dr[0].migrate_role_arn : null
    freshclam_check_role_arn = var.dr_activate ? module.iam_dr[0].freshclam_check_role_arn : null
    certificate_arn          = var.dr_activate ? module.acm_dr[0].certificate_arn : null
    alb_security_group_id    = var.dr_activate ? module.eks_dr[0].alb_security_group_id : null
  }
}
