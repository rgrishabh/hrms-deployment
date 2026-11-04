# Service control policies for the Customers OU. Applied from the management
# account. They bind every principal in customer accounts — including the
# Terraform role and account administrators.
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

variable "target_ou_ids" {
  description = "Organizational units to attach the guardrails to (e.g. the Customers OU)."
  type        = list(string)
}

variable "allowed_regions" {
  type    = list(string)
  default = ["ap-south-1"]
}

variable "edge_region" {
  description = "CloudFront's certificates, web ACLs and their logs live here, whatever the allowed regions are."
  type        = string
  default     = "us-east-1"
}

variable "break_glass_role_arn_pattern" {
  description = "Role exempt from the key-deletion guardrail (emergency use only)."
  type        = string
  default     = "arn:aws:iam::*:role/hrms-break-glass"
}

locals {
  # Global services that must stay reachable regardless of region restriction.
  global_services = [
    "iam:*", "organizations:*", "sts:*", "support:*", "budgets:*", "ce:*", "cur:*", "account:*",
    "route53:*", "route53domains:*", "cloudfront:*", "waf:*", "health:*", "trustedadvisor:*",
    "acm:*", "kms:*", "s3:GetBucketLocation", "s3:ListAllMyBuckets", "sso:*", "identitystore:*",
  ]
  # AWS WAF for CloudFront is wafv2 in the edge region. waf:* is the old API and does not cover it, so
  # the region lock would deny every CLOUDFRONT web ACL. Its logs and metrics stay in that region too.
  edge_services = ["wafv2:*", "logs:*", "cloudwatch:*"]
  lock_regions  = contains(var.allowed_regions, var.edge_region) ? [] : [var.edge_region]
}

resource "aws_organizations_policy" "guardrails" {
  name        = "hrms-customer-guardrails"
  description = "HRMS customer accounts: region lock, audit and security services protected, no root, no public S3, no key deletion."
  type        = "SERVICE_CONTROL_POLICY"
  content = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyOutsideAllowedRegions"
        Effect    = "Deny"
        NotAction = local.global_services
        Resource  = "*"
        Condition = { StringNotEquals = { "aws:RequestedRegion" = concat(var.allowed_regions, [var.edge_region]) } }
      },
      {
        Sid       = "DenyEdgeRegionExceptEdgeServices"
        Effect    = "Deny"
        NotAction = concat(local.global_services, local.edge_services)
        Resource  = "*"
        Condition = { StringEquals = { "aws:RequestedRegion" = local.lock_regions } }
      },
      { Sid = "DenyLeavingOrg", Effect = "Deny", Action = "organizations:LeaveOrganization", Resource = "*" },
      {
        Sid       = "DenyRootUser"
        Effect    = "Deny"
        Action    = "*"
        Resource  = "*"
        Condition = { StringLike = { "aws:PrincipalArn" = "arn:aws:iam::*:root" } }
      },
      {
        Sid      = "ProtectAuditAndSecurityServices"
        Effect   = "Deny"
        Action   = ["cloudtrail:StopLogging", "cloudtrail:DeleteTrail", "cloudtrail:UpdateTrail", "guardduty:DeleteDetector", "guardduty:DisassociateFromMasterAccount", "guardduty:UpdateDetector", "config:DeleteConfigurationRecorder", "config:StopConfigurationRecorder", "access-analyzer:DeleteAnalyzer"]
        Resource = "*"
      },
      {
        Sid      = "ProtectPublicAccessBlock"
        Effect   = "Deny"
        Action   = ["s3:PutAccountPublicAccessBlock", "s3:DeleteAccountPublicAccessBlock"]
        Resource = "*"
      },
      {
        Sid       = "DenyKeyDeletionExceptBreakGlass"
        Effect    = "Deny"
        Action    = ["kms:ScheduleKeyDeletion", "kms:DisableKey"]
        Resource  = "*"
        Condition = { ArnNotLike = { "aws:PrincipalArn" = var.break_glass_role_arn_pattern } }
      },
      {
        Sid       = "DenyUnencryptedRds"
        Effect    = "Deny"
        Action    = "rds:CreateDBInstance"
        Resource  = "*"
        Condition = { Bool = { "rds:StorageEncrypted" = "false" } }
      },
      {
        Sid       = "DenyIamUserAccessKeys"
        Effect    = "Deny"
        Action    = ["iam:CreateAccessKey", "iam:CreateUser"]
        Resource  = "*"
        Condition = { ArnNotLike = { "aws:PrincipalArn" = var.break_glass_role_arn_pattern } }
      },
    ]
  })
}

resource "aws_organizations_policy_attachment" "guardrails" {
  for_each  = toset(var.target_ou_ids)
  policy_id = aws_organizations_policy.guardrails.id
  target_id = each.value
}

output "policy_id" {
  value = aws_organizations_policy.guardrails.id
}
