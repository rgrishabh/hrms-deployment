# Management account: guardrail SCPs on the Customers OU.
# Account creation itself is done with AWS Control Tower Account Factory (or
# aws_organizations_account) — see infra/README.md.
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
  backend "s3" {
    encrypt      = true
    use_lockfile = true
  }
}

variable "management_account_id" {
  type = string
}

variable "customers_ou_id" {
  description = "OU containing all customer (and staging) accounts."
  type        = string
}

variable "allowed_regions" {
  type    = list(string)
  default = ["ap-south-1"]
}

provider "aws" {
  region              = "ap-south-1"
  allowed_account_ids = [var.management_account_id]
}

module "guardrails" {
  source          = "../../modules/org-guardrails"
  target_ou_ids   = [var.customers_ou_id]
  allowed_regions = var.allowed_regions
}
