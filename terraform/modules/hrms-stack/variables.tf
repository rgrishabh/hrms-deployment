variable "customer_slug" {
  description = "Organization slug (lowercase, hyphens). Used in names and passed to the bootstrap task."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,40}[a-z0-9]$", var.customer_slug))
    error_message = "customer_slug must be 3-42 lowercase letters, digits or hyphens."
  }
}

variable "organization" {
  description = "Organization identity (public; deployment-controlled). Same meaning as ORGANIZATION_* in Docker Compose."
  type = object({
    name           = string
    legal_name     = optional(string)
    country        = optional(string, "IN")
    timezone       = optional(string, "Asia/Kolkata")
    currency       = optional(string, "INR")
    date_format    = optional(string, "DD/MM/YYYY")
    fy_start_month = optional(number, 4)
  })
  validation {
    condition     = contains(["DD/MM/YYYY", "DD-MM-YYYY", "DD-MMM-YYYY", "YYYY-MM-DD"], var.organization.date_format)
    error_message = "organization.date_format must be DD/MM/YYYY, DD-MM-YYYY, DD-MMM-YYYY or YYYY-MM-DD."
  }
}

variable "branding" {
  description = "White-label branding (public). Same meaning as PRODUCT_NAME / BRAND_* in Docker Compose. Logo and favicon must be https URLs on AWS."
  type = object({
    product_name    = optional(string, "LabHRMS")
    brand_name      = optional(string)
    short_name      = optional(string)
    logo_url        = optional(string)
    favicon_url     = optional(string)
    primary_color   = optional(string, "#1F5F8B")
    secondary_color = optional(string, "#0F172A")
    accent_color    = optional(string, "#2E8B57")
    login_message   = optional(string)
    support_email   = optional(string)
    support_phone   = optional(string)
    help_url        = optional(string)
  })
  default = {}
  validation {
    condition     = alltrue([for c in [var.branding.primary_color, var.branding.secondary_color, var.branding.accent_color] : can(regex("^#[0-9A-Fa-f]{6}$", c))])
    error_message = "Brand colours must be hex values like #14532D."
  }
  validation {
    condition     = alltrue([for u in [var.branding.logo_url, var.branding.favicon_url, var.branding.help_url] : u == null || can(regex("^https://", u))])
    error_message = "logo_url, favicon_url and help_url must be https:// URLs."
  }
}

variable "environment" {
  description = "staging or production."
  type        = string
  validation {
    condition     = contains(["staging", "production"], var.environment)
    error_message = "environment must be staging or production."
  }
}

variable "domains" {
  description = "Hostnames served by this deployment. The first is primary. Example: [\"hrms.acmelabs.in\"]."
  type        = list(string)
  validation {
    condition     = length(var.domains) > 0 && length(var.domains) <= 3
    error_message = "Between one and three domains (ALB rules combine hosts with path patterns; 5 values per rule)."
  }
}

variable "route53_zone_id" {
  description = "Hosted zone (in this account) for the domains. If null, DNS is managed by the customer: give them the ACM validation records and the ALB CNAME from the outputs."
  type        = string
  default     = null
}

variable "mail" {
  description = "Email transport (module notifications.email). The SMTP password is NOT a variable: Terraform creates the empty secret hrms/smtp-password and an operator sets its value (aws secretsmanager put-secret-value) before enabling SMTP with a user."
  type = object({
    transport    = optional(string, "disabled") # disabled | smtp
    smtp_host    = optional(string)
    smtp_port    = optional(number, 587)
    smtp_secure  = optional(bool, false)
    smtp_user    = optional(string)
    from_address = optional(string)
    from_name    = optional(string)
  })
  default = {}
  validation {
    condition     = contains(["disabled", "smtp"], var.mail.transport) && (var.mail.transport != "smtp" || (var.mail.smtp_host != null && var.mail.from_address != null))
    error_message = "mail.transport must be disabled or smtp; smtp needs smtp_host and from_address."
  }
}

variable "enabled_modules" {
  description = "Modules for this installation (ENABLED_MODULES). \"default\" = the standard set; add e.g. \"attendance.biometric\". Validated by the application at startup."
  type        = list(string)
  default     = ["default"]
}

variable "admin_email" {
  description = "First administrator, created by the bootstrap task if no administrator exists. Initial password is generated into Secrets Manager; it must be changed at first sign-in."
  type        = string
}

variable "admin_name" {
  type    = string
  default = "Administrator"
}

variable "backend_image" {
  description = "Initial backend image (ghcr.io/<owner>/hrms-backend:<tag>). Releases register new task definition revisions outside Terraform (deploy-prod workflow)."
  type        = string
  validation {
    condition     = !endswith(var.backend_image, ":latest")
    error_message = "Use an immutable tag (vX.Y.Z or sha-<short>), never latest."
  }
}

variable "frontend_image" {
  description = "Initial frontend image (ghcr.io/<owner>/hrms-frontend:<tag>)."
  type        = string
  validation {
    condition     = !endswith(var.frontend_image, ":latest")
    error_message = "Use an immutable tag (vX.Y.Z or sha-<short>), never latest."
  }
}

variable "private_registry" {
  description = "Images are in a private registry that needs credentials (GHCR). Creates the Secrets Manager secret hrms/registry-credentials ({\"username\",\"password\"}), filled once by scripts/set-registry-credentials.sh."
  type        = bool
  default     = true
}

variable "ecr_repository_arns" {
  description = "Optional ECR mirror: repositories the tasks may pull from (alternative to GHCR; see docs/RUNBOOK.md)."
  type        = list(string)
  default     = []
}

variable "github_oidc_provider_arn" {
  description = "IAM OIDC provider for GitHub Actions in this account (from account-baseline)."
  type        = string
}

variable "github_repository" {
  description = "owner/repo allowed to deploy releases (the deployment repo)."
  type        = string
  default     = "rgrishabh/hrms-deployment"
}

variable "github_deploy_environment" {
  description = "GitHub environment whose jobs may assume the release role. Default: prod-<customer_slug>."
  type        = string
  default     = null
}

# ---- sizing (start small; resize from load tests)
variable "vpc_cidr" {
  type    = string
  default = "10.40.0.0/16"
}

variable "az_count" {
  type    = number
  default = 2
  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "az_count must be 2 or 3."
  }
}

variable "nat_gateway_per_az" {
  description = "One NAT gateway per AZ (resilient) instead of one shared (cheaper)."
  type        = bool
  default     = false
}

variable "db_instance_class" {
  type    = string
  default = "db.t4g.medium"
}

variable "db_engine_version" {
  type    = string
  default = "17"
}

variable "db_allocated_storage_gb" {
  type    = number
  default = 50
}

variable "db_max_allocated_storage_gb" {
  type    = number
  default = 500
}

variable "db_multi_az" {
  type    = bool
  default = true
}

variable "db_backup_retention_days" {
  type    = number
  default = 14
}

variable "api_cpu" {
  type    = number
  default = 512
}

variable "api_memory" {
  type    = number
  default = 1024
}

variable "api_min_count" {
  type    = number
  default = 2
}

variable "api_max_count" {
  type    = number
  default = 6
}

variable "web_cpu" {
  type    = number
  default = 256
}

variable "web_memory" {
  type    = number
  default = 512
}

variable "web_min_count" {
  type    = number
  default = 2
}

variable "web_max_count" {
  type    = number
  default = 4
}

variable "api_requests_per_target" {
  description = "Target ALB requests per API task per minute for request-count autoscaling."
  type        = number
  default     = 1000
}

variable "db_pool_max" {
  description = "Connections per API task. Keep api_max_count * db_pool_max well below the RDS max_connections."
  type        = number
  default     = 10
}

# ---- operations
variable "log_retention_days" {
  type    = number
  default = 365
}

variable "alarm_emails" {
  description = "Recipients for operational alarms and budget alerts."
  type        = list(string)
  default     = []
}

variable "monthly_budget_usd" {
  description = "Monthly cost budget for this account (alerts at 80% and 100%). 0 disables the budget."
  type        = number
  default     = 0
}

variable "backup_retention_days" {
  description = "AWS Backup retention for daily recovery points."
  type        = number
  default     = 35
}

variable "backup_copy_vault_arn" {
  description = "Optional vault in another account/region to copy recovery points to (ransomware protection)."
  type        = string
  default     = null
}

variable "waf_rate_limit_per_5min" {
  description = "Requests per client IP per 5 minutes before WAF blocks."
  type        = number
  default     = 2000
}

variable "deletion_protection" {
  description = "Protect RDS and the ALB from deletion. Only disable deliberately when decommissioning."
  type        = bool
  default     = true
}

variable "tags" {
  type    = map(string)
  default = {}
}
