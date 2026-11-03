# State lives in the Shared Services bucket under the customer's own account id
# (the bucket policy only lets an account touch accounts/<its-id>/*).
bucket = "hrms-terraform-state-<shared-account-id>"
key    = "accounts/<12-digit-staging-account-id>/hrms.tfstate"
region = "ap-south-1"
