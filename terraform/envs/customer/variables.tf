variable "account_id" {
  description = "The customer's dedicated AWS account id. Terraform refuses to run against any other account."
  type        = string
}

variable "region" {
  type    = string
  default = "ap-south-1"
}

variable "customer_slug" {
  type = string
}

variable "organization" {
  description = "See modules/hrms-stack: name, legal_name, country, timezone, currency, date_format, fy_start_month."
  type        = any
}

variable "branding" {
  description = "See modules/hrms-stack: product_name, brand_name, short_name, logo_url, favicon_url, colours, login_message, support contacts."
  type        = any
  default     = {}
}

variable "environment" {
  type    = string
  default = "production"
}

variable "domains" {
  type = list(string)
}

variable "route53_zone_id" {
  type    = string
  default = null
}

variable "mail" {
  description = "See modules/hrms-stack: transport, smtp_host, smtp_port, smtp_secure, smtp_user, from_address, from_name."
  type        = any
  default     = {}
}

variable "sms" {
  description = "See modules/hrms-stack: transport, http_url, content_type, body, sender_id, dlt_entity_id."
  type        = any
  default     = {}
}

variable "enabled_modules" {
  type    = list(string)
  default = ["default"]
}

variable "admin_email" {
  type = string
}

variable "admin_name" {
  type    = string
  default = "Administrator"
}

variable "backend_image" {
  description = "Backend image used when the stack is first created; later releases are deployed by deploy-prod."
  type        = string
}

variable "frontend_image" {
  description = "Frontend image used when the stack is first created."
  type        = string
}

variable "private_registry" {
  description = "true for GHCR (pull credentials from Secrets Manager)."
  type        = bool
  default     = true
}

variable "ecr_repository_arns" {
  description = "Optional ECR mirror repositories (alternative to GHCR)."
  type        = list(string)
  default     = []
}

variable "github_repository" {
  description = "Deployment repo whose environments infra-<slug> / prod-<slug> may assume this account's roles."
  type        = string
  default     = "rgrishabh/hrms-deployment"
}

variable "enable_guardduty" {
  type    = bool
  default = true
}

variable "db_instance_class" {
  type    = string
  default = "db.t4g.medium"
}

variable "db_multi_az" {
  type    = bool
  default = true
}

variable "nat_gateway_per_az" {
  type    = bool
  default = false
}

variable "api_min_count" {
  type    = number
  default = 2
}

variable "api_max_count" {
  type    = number
  default = 6
}

variable "alarm_emails" {
  type    = list(string)
  default = []
}

variable "monthly_budget_usd" {
  type    = number
  default = 0
}

variable "backup_copy_vault_arn" {
  type    = string
  default = null
}

variable "deletion_protection" {
  type    = bool
  default = true
}
