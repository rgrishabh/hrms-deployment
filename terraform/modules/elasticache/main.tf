# Redis for config and lookup caching. TLS in transit, KMS at rest, AUTH token. The app works without
# it, more slowly, so this is left out of tier-low. The token is in Terraform state, because the
# provider has no write-only form of auth_token; the state bucket is KMS-encrypted and restricted.
variable "name" {
  type    = string
  default = "hrms-redis"
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  type = list(string)
}

variable "client_security_group_ids" {
  description = "Static map of label to security group allowed to connect."
  type        = map(string)
}

variable "node_type" {
  type    = string
  default = "cache.t4g.small"
}

variable "replica_count" {
  description = "0 is one node. 1 or more adds automatic failover across zones."
  type        = number
  default     = 1
}

variable "engine_version" {
  type    = string
  default = "7.1"
}

variable "kms_key_arn" {
  type = string
}

variable "snapshot_retention_days" {
  type    = number
  default = 1
}

resource "aws_elasticache_subnet_group" "this" {
  name       = var.name
  subnet_ids = var.subnet_ids
}

resource "aws_security_group" "this" {
  name        = var.name
  description = "ElastiCache Redis"
  vpc_id      = var.vpc_id
  tags        = { Name = var.name }
}

resource "aws_vpc_security_group_ingress_rule" "clients" {
  for_each                     = var.client_security_group_ids
  security_group_id            = aws_security_group.this.id
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6379
  description                  = "Redis from ${each.key}"
}

resource "random_password" "auth" {
  length  = 48
  special = false
}

resource "aws_elasticache_parameter_group" "this" {
  name   = var.name
  family = "redis${split(".", var.engine_version)[0]}"
}

resource "aws_elasticache_replication_group" "this" {
  replication_group_id       = var.name
  description                = "HRMS config and lookup cache"
  engine                     = "redis"
  engine_version             = var.engine_version
  node_type                  = var.node_type
  num_cache_clusters         = 1 + var.replica_count
  automatic_failover_enabled = var.replica_count > 0
  multi_az_enabled           = var.replica_count > 0
  subnet_group_name          = aws_elasticache_subnet_group.this.name
  security_group_ids         = [aws_security_group.this.id]
  parameter_group_name       = aws_elasticache_parameter_group.this.name
  port                       = 6379
  at_rest_encryption_enabled = true
  kms_key_id                 = var.kms_key_arn
  transit_encryption_enabled = true
  auth_token                 = random_password.auth.result
  auto_minor_version_upgrade = true
  snapshot_retention_limit   = var.snapshot_retention_days
  snapshot_window            = "19:00-20:00"
  maintenance_window         = "sun:22:30-sun:23:30"
  apply_immediately          = false
}

output "url" {
  description = "REDIS_URL for the app."
  value       = "rediss://:${random_password.auth.result}@${aws_elasticache_replication_group.this.primary_endpoint_address}:6379/0"
  sensitive   = true
}
