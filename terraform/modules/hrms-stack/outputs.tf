output "app_url" {
  value = "https://${local.primary}"
}

output "alb_dns_name" {
  description = "If DNS is customer-managed: CNAME each domain to this name."
  value       = aws_lb.this.dns_name
}

output "acm_validation_records" {
  description = "If DNS is customer-managed: records the customer must create before the certificate validates."
  value = [for o in aws_acm_certificate.this.domain_validation_options : {
    name  = o.resource_record_name
    type  = o.resource_record_type
    value = o.resource_record_value
  }]
}

output "release_role_arn" {
  description = "Set as the AWS_DEPLOY_ROLE_ARN variable of GitHub Environment prod-<slug>."
  value       = aws_iam_role.release.arn
}

output "registry_credentials_secret_arn" {
  description = "Fill once with scripts/set-registry-credentials.sh (GHCR read:packages token)."
  value       = var.private_registry ? aws_secretsmanager_secret.registry[0].arn : null
}

output "bootstrap_admin_secret_arn" {
  description = "Secret holding the first administrator password (hand over securely)."
  value       = aws_secretsmanager_secret.app["bootstrap_admin"].arn
}

output "alarm_topic_arn" {
  value = aws_sns_topic.alarms.arn
}

output "db_instance_id" {
  value = aws_db_instance.this.identifier
}

output "documents_bucket" {
  value = aws_s3_bucket.documents.bucket
}
