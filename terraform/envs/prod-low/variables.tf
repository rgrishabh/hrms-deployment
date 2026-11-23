variable "account_id" {
  description = "The client's dedicated AWS account. Terraform refuses to run against any other."
  type        = string
}

variable "region" {
  type    = string
  default = "ap-south-1"
}

variable "customer_slug" {
  description = "Short lower-case name, used in tags and alarm names."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.customer_slug))
    error_message = "customer_slug must be lower-case letters, digits and hyphens."
  }
}

variable "domain" {
  description = "BRAND_DOMAIN of this installation."
  type        = string
}

variable "extra_domains" {
  description = "BRAND_EXTRA_DOMAINS of this installation."
  type        = list(string)
  default     = []
}

variable "route53_zone_id" {
  description = "Null when the client runs DNS elsewhere: add the records from the outputs by hand."
  type        = string
  default     = null
}

variable "admin_email" {
  type = string
}

variable "admin_name" {
  type    = string
  default = "Administrator"
}

variable "alarm_emails" {
  type = list(string)
}

variable "monthly_budget_usd" {
  type    = number
  default = 0
}

variable "github_repository" {
  type    = string
  default = "rgrishabh/hrms-deployment"
}

variable "enable_guardduty" {
  type    = bool
  default = true
}

variable "state_kms_key_arn" {
  description = "Key of the Terraform state bucket, from the shared-services root."
  type        = string
  default     = null
}

variable "deletion_protection" {
  type    = bool
  default = true
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "node_instance_type" {
  type    = string
  default = "t4g.large"
}

variable "db_instance_class" {
  type    = string
  default = "db.t4g.small"
}

variable "backup_retention_days" {
  type    = number
  default = 14
}

variable "log_retention_days" {
  type    = number
  default = 365
}

variable "gitops_repo_url" {
  description = "The client's private repository holding its overlay. See docs/NEW_CLIENT_ONBOARDING.md."
  type        = string
}

variable "gitops_repo_revision" {
  type    = string
  default = "main"
}

variable "gitops_overlay_path" {
  type    = string
  default = "overlay"
}
