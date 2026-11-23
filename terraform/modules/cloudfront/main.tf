# CloudFront in front of the Ingress-created ALB, for tier-mid and tier-high. Only /assets/* is cached.
# Everything else (API, health, env.js, index.html, deep links) passes through with Host preserved,
# because the backend matches Host against its configured domains. ACM certificate and web ACL must
# be in us-east-1. Create this after the first sync, when origin_alb_dns_name is known.
variable "aliases" {
  type = list(string)
}

variable "origin_alb_dns_name" {
  type = string
}

variable "certificate_arn" {
  type = string
}

variable "web_acl_arn" {
  type = string
}

variable "log_bucket_domain_name" {
  type = string
}

variable "price_class" {
  description = "PriceClass_200 includes India."
  type        = string
  default     = "PriceClass_200"
}

data "aws_cloudfront_cache_policy" "caching_disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_cache_policy" "caching_optimized" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_origin_request_policy" "all_viewer" {
  name = "Managed-AllViewer"
}

resource "aws_cloudfront_distribution" "this" {
  #checkov:skip=CKV_AWS_310:One regional origin. Failover is the DR runbook's origin change, because origin groups cover only GET.
  #checkov:skip=CKV_AWS_374:An HR system for clients in many countries; access is controlled by sign-in, not geography.
  #checkov:skip=CKV2_AWS_47:Log4j is covered by AWSManagedRulesKnownBadInputsRuleSet in the waf module, which checkov cannot follow.
  #checkov:skip=CKV2_AWS_32:The frontend and the backend set security headers themselves, including CSP, and a second set would conflict.
  enabled         = true
  is_ipv6_enabled = true
  comment         = "HRMS ${var.aliases[0]}"
  aliases         = var.aliases
  price_class     = var.price_class
  web_acl_id      = var.web_acl_arn
  http_version    = "http2and3"
  # Must match the frontend's no-cache entry, so that / is not cached either (default behaviour below).
  default_root_object = "index.html"

  origin {
    origin_id   = "alb"
    domain_name = var.origin_alb_dns_name
    custom_origin_config {
      http_port                = 80
      https_port               = 443
      origin_protocol_policy   = "https-only"
      origin_ssl_protocols     = ["TLSv1.2"]
      origin_read_timeout      = 60
      origin_keepalive_timeout = 30
    }
  }

  default_cache_behavior {
    target_origin_id         = "alb"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer.id
    compress                 = false
  }

  # Hashed file names, served by nginx as immutable: safe to cache, and compressed here.
  ordered_cache_behavior {
    path_pattern           = "/assets/*"
    target_origin_id       = "alb"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = data.aws_cloudfront_cache_policy.caching_optimized.id
    compress               = true
  }

  viewer_certificate {
    acm_certificate_arn      = var.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  logging_config {
    bucket = var.log_bucket_domain_name
    prefix = "cloudfront/"
  }
}

output "domain_name" {
  value = aws_cloudfront_distribution.this.domain_name
}

output "hosted_zone_id" {
  value = aws_cloudfront_distribution.this.hosted_zone_id
}
