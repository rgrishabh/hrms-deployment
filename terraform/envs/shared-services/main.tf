# Shared Services account: image registry, Terraform state bucket, CI build role.
# First apply uses local state (the bucket does not exist yet); then migrate:
#   terraform init -migrate-state -backend-config="bucket=<state_bucket output>" \
#     -backend-config="key=accounts/<shared-services-account-id>/shared-services.tfstate" -backend-config="region=ap-south-1"
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
  # backend "s3" { encrypt = true, use_lockfile = true }   # enable after the first apply
}

variable "account_id" {
  type = string
}

variable "region" {
  type    = string
  default = "ap-south-1"
}

variable "organization_id" {
  type = string
}

provider "aws" {
  region              = var.region
  allowed_account_ids = [var.account_id]
  default_tags {
    tags = { Application = "hrms", Account = "shared-services", ManagedBy = "terraform" }
  }
}

module "shared" {
  source          = "../../modules/shared-services"
  organization_id = var.organization_id
}

output "state_bucket" {
  value = module.shared.state_bucket
}
