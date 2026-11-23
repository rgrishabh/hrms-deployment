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

variable "endpoint_public_cidrs" {
  description = "Your address, while installing Argo CD. Return it to empty afterwards."
  type        = list(string)
  default     = []
}

variable "cluster_admin_role_arns" {
  type    = map(string)
  default = {}
}

variable "origin_alb_dns_name" {
  description = "Second apply: the ALB that the Ingress created. Creates CloudFront and DNS."
  type        = string
  default     = null
}

variable "alb_arn_suffix" {
  description = "Second apply: for the ALB alarms."
  type        = string
  default     = null
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "node_instance_type" {
  type    = string
  default = "m7g.xlarge"
}

variable "db_instance_class" {
  type    = string
  default = "db.r7g.large"
}

variable "db_allocated_storage_gb" {
  type    = number
  default = 200
}

variable "db_max_connections" {
  type    = number
  default = 400
}

variable "db_backup_retention_days" {
  type    = number
  default = 35
}

variable "cache_node_type" {
  type    = string
  default = "cache.r7g.large"
}

variable "backup_retention_days" {
  type    = number
  default = 90
}

variable "log_retention_days" {
  type    = number
  default = 365
}

variable "dr_region" {
  description = "Must be in the guardrails' allowed_regions. Hyderabad keeps data in India."
  type        = string
  default     = "ap-south-2"
}

variable "dr_vpc_cidr" {
  type    = string
  default = "10.21.0.0/16"
}

variable "dr_db_instance_class" {
  type    = string
  default = "db.t4g.large"
}

variable "dr_activate" {
  description = "false is the pilot light. true adds NAT, a cluster, roles and a certificate in the DR region."
  type        = bool
  default     = false
}
