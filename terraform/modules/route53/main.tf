# Alias records for the installation's hostnames. Does nothing until both a zone and a target exist:
# an Ingress-created ALB is known only after the first sync, so it arrives on the second apply.
variable "zone_id" {
  type    = string
  default = null
}

variable "names" {
  type = list(string)
}

variable "alias_name" {
  type    = string
  default = null
}

variable "alias_zone_id" {
  type    = string
  default = null
}

variable "evaluate_target_health" {
  type    = bool
  default = false
}

locals {
  enabled = var.zone_id != null && var.alias_name != null
}

resource "aws_route53_record" "a" {
  for_each = local.enabled ? toset(var.names) : toset([])
  zone_id  = var.zone_id
  name     = each.value
  type     = "A"
  alias {
    name                   = var.alias_name
    zone_id                = var.alias_zone_id
    evaluate_target_health = var.evaluate_target_health
  }
}

resource "aws_route53_record" "aaaa" {
  for_each = local.enabled ? toset(var.names) : toset([])
  zone_id  = var.zone_id
  name     = each.value
  type     = "AAAA"
  alias {
    name                   = var.alias_name
    zone_id                = var.alias_zone_id
    evaluate_target_health = var.evaluate_target_health
  }
}
