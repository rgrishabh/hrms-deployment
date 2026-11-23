# A certificate validated by DNS. With a Route 53 zone the records are created here. Otherwise the
# client adds the records from the validation_records output, and validation waits for them.
# For CloudFront, instantiate this with the us-east-1 provider.
variable "domain" {
  type = string
}

variable "extra_domains" {
  type    = list(string)
  default = []
}

variable "route53_zone_id" {
  type    = string
  default = null
}

resource "aws_acm_certificate" "this" {
  domain_name               = var.domain
  subject_alternative_names = var.extra_domains
  validation_method         = "DNS"
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "validation" {
  for_each = var.route53_zone_id == null ? {} : {
    for o in aws_acm_certificate.this.domain_validation_options : o.domain_name => o
  }
  zone_id         = var.route53_zone_id
  name            = each.value.resource_record_name
  type            = each.value.resource_record_type
  records         = [each.value.resource_record_value]
  ttl             = 300
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "this" {
  certificate_arn         = aws_acm_certificate.this.arn
  validation_record_fqdns = var.route53_zone_id == null ? null : [for r in aws_route53_record.validation : r.fqdn]
  timeouts {
    create = "2h"
  }
}

output "certificate_arn" {
  value = aws_acm_certificate_validation.this.certificate_arn
}

output "validation_records" {
  description = "Add these at the client's DNS provider when Route 53 is not used."
  value = [for o in aws_acm_certificate.this.domain_validation_options : {
    name  = o.resource_record_name
    type  = o.resource_record_type
    value = o.resource_record_value
  }]
}
