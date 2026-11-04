output "overlay_values" {
  description = "Read by scripts/new-client-overlay.sh."
  value = {
    tier                   = "low"
    region                 = var.region
    rds_master_secret_name = module.rds.master_secret_name
    backend_role_arn       = ""
    worker_role_arn        = ""
    secrets_role_arn       = ""
    certificate_arn        = module.acm.certificate_arn
    alb_security_group_id  = ""
    alb_logs_bucket        = module.alb_logs.bucket
  }
}

output "acm_validation_records" {
  value = module.acm.validation_records
}

output "alb_dns_name" {
  description = "Point the domain here if Route 53 is not used."
  value       = module.k3s.alb_dns_name
}

output "kms_key_id" {
  value = module.kms.key_id
}

output "release_role_arn" {
  value = module.iam.release_role_arn
}
