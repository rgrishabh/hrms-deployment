# The region lock must not deny wafv2 in us-east-1, or CloudFront's web ACL cannot be created.
mock_provider "aws" {}

variables {
  target_ou_ids   = ["ou-test"]
  allowed_regions = ["ap-south-1", "ap-south-2"]
}

run "edge_region_allows_only_edge_services" {
  command = apply
  assert {
    condition     = contains(jsondecode(aws_organizations_policy.guardrails.content).Statement[0].Condition.StringNotEquals["aws:RequestedRegion"], "us-east-1")
    error_message = "us-east-1 must be excluded from the general region deny."
  }
  assert {
    condition     = contains(jsondecode(aws_organizations_policy.guardrails.content).Statement[1].NotAction, "wafv2:*")
    error_message = "wafv2 must stay allowed in us-east-1."
  }
  assert {
    condition     = !contains(jsondecode(aws_organizations_policy.guardrails.content).Statement[1].NotAction, "ec2:*")
    error_message = "Other services must stay denied in us-east-1."
  }
  assert {
    condition     = jsondecode(aws_organizations_policy.guardrails.content).Statement[1].Condition.StringEquals["aws:RequestedRegion"] == ["us-east-1"]
    error_message = "The second statement must apply to us-east-1."
  }
  assert {
    condition     = length(aws_organizations_policy.guardrails.content) < 5120
    error_message = "An SCP cannot exceed 5120 characters."
  }
}
