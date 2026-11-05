# Three tiers per AZ. Public: load balancer and egress only. App: nodes and pods. Data: RDS and
# ElastiCache, with no route to the internet at all.
variable "name" {
  type    = string
  default = "hrms"
}

variable "cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "az_count" {
  type    = number
  default = 2
  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "az_count must be 2 or 3: an ALB and an RDS subnet group each need two zones."
  }
}

variable "egress_mode" {
  description = "nat_gateway (one), nat_gateway_per_az, nat_instance (a small Graviton instance, for tier-low) or none."
  type        = string
  default     = "nat_gateway"
  validation {
    condition     = contains(["nat_gateway", "nat_gateway_per_az", "nat_instance", "none"], var.egress_mode)
    error_message = "egress_mode must be nat_gateway, nat_gateway_per_az, nat_instance or none."
  }
}

variable "nat_instance_type" {
  type    = string
  default = "t4g.nano"
}

variable "cluster_name" {
  description = "Adds the subnet tags the AWS Load Balancer Controller looks for. Null when there is no EKS cluster."
  type        = string
  default     = null
}

variable "kms_key_arn" {
  type = string
}

variable "flow_log_retention_days" {
  type    = number
  default = 365
}

data "aws_region" "this" {}
data "aws_availability_zones" "available" {
  #checkov:skip=CKV_AWS_394:Names sort alphabetically and only the first az_count are used, so a new zone cannot change the selection.
  state = "available"
}

locals {
  azs         = slice(data.aws_availability_zones.available.names, 0, var.az_count)
  nat_gateway = contains(["nat_gateway", "nat_gateway_per_az"], var.egress_mode)
  nat_count   = local.nat_gateway ? (var.egress_mode == "nat_gateway_per_az" ? var.az_count : 1) : 0
  cluster_tag = var.cluster_name == null ? {} : { "kubernetes.io/cluster/${var.cluster_name}" = "shared" }
}

resource "aws_vpc" "this" {
  cidr_block           = var.cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = { Name = "${var.name}-vpc" }
}

# No rules at all: nothing can use the default security group.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-default-locked" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-igw" }
}

resource "aws_subnet" "public" {
  count                   = var.az_count
  vpc_id                  = aws_vpc.this.id
  availability_zone       = local.azs[count.index]
  cidr_block              = cidrsubnet(var.cidr, 8, count.index)
  map_public_ip_on_launch = false
  tags = merge(local.cluster_tag, {
    Name                     = "${var.name}-public-${local.azs[count.index]}"
    Tier                     = "public"
    "kubernetes.io/role/elb" = "1"
  })
}

# /20 per zone: the VPC CNI gives every pod a VPC address, and /24 can run out.
resource "aws_subnet" "app" {
  count             = var.az_count
  vpc_id            = aws_vpc.this.id
  availability_zone = local.azs[count.index]
  cidr_block        = cidrsubnet(var.cidr, 4, 1 + count.index)
  tags = merge(local.cluster_tag, {
    Name                              = "${var.name}-app-${local.azs[count.index]}"
    Tier                              = "app"
    "kubernetes.io/role/internal-elb" = "1"
  })
}

resource "aws_subnet" "data" {
  count             = var.az_count
  vpc_id            = aws_vpc.this.id
  availability_zone = local.azs[count.index]
  cidr_block        = cidrsubnet(var.cidr, 8, 240 + count.index)
  tags = {
    Name = "${var.name}-data-${local.azs[count.index]}"
    Tier = "data"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = { Name = "${var.name}-public" }
}

resource "aws_route_table_association" "public" {
  count          = var.az_count
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat" {
  count  = local.nat_count
  domain = "vpc"
  tags   = { Name = "${var.name}-nat-${count.index}" }
}

resource "aws_nat_gateway" "this" {
  count         = local.nat_count
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  tags          = { Name = "${var.name}-nat-${count.index}" }
  depends_on    = [aws_internet_gateway.this]
}

# ---------------------------------------------------------------- NAT instance (tier-low)
data "aws_ssm_parameter" "al2023_arm" {
  count = var.egress_mode == "nat_instance" ? 1 : 0
  name  = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

resource "aws_security_group" "nat" {
  count       = var.egress_mode == "nat_instance" ? 1 : 0
  name        = "${var.name}-nat"
  description = "NAT instance: forwards VPC traffic to the internet, accepts nothing from outside"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${var.name}-nat" }
}

resource "aws_vpc_security_group_ingress_rule" "nat_from_vpc" {
  count             = var.egress_mode == "nat_instance" ? 1 : 0
  security_group_id = aws_security_group.nat[0].id
  cidr_ipv4         = var.cidr
  ip_protocol       = "-1"
  description       = "All traffic from inside the VPC"
}

#trivy:ignore:AWS-0104 Egress is limited to the listed ports. HTTPS, SMTP and image pulls go to addresses that cannot be listed in advance.
resource "aws_vpc_security_group_egress_rule" "nat_out" {
  for_each          = var.egress_mode == "nat_instance" ? { https = 443, smtp_submission = 587, smtps = 465, http = 80 } : {}
  security_group_id = aws_security_group.nat[0].id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = each.value
  to_port           = each.value
  description       = "Forwarded ${each.key}"
}

resource "aws_network_interface" "nat" {
  count             = var.egress_mode == "nat_instance" ? 1 : 0
  subnet_id         = aws_subnet.public[0].id
  security_groups   = [aws_security_group.nat[0].id]
  source_dest_check = false
  tags              = { Name = "${var.name}-nat" }
}

resource "aws_eip" "nat_instance" {
  #checkov:skip=CKV2_AWS_19:Attached through network_interface to the NAT instance's ENI; the check recognizes an instance or an association, not an ENI.
  count             = var.egress_mode == "nat_instance" ? 1 : 0
  domain            = "vpc"
  network_interface = aws_network_interface.nat[0].id
  tags              = { Name = "${var.name}-nat-instance" }
  depends_on        = [aws_internet_gateway.this]
}

resource "aws_instance" "nat" {
  #checkov:skip=CKV2_AWS_41:The NAT instance calls no AWS APIs, so it has no IAM role.
  count         = var.egress_mode == "nat_instance" ? 1 : 0
  ami           = data.aws_ssm_parameter.al2023_arm[0].value
  instance_type = var.nat_instance_type
  ebs_optimized = true
  monitoring    = true
  primary_network_interface {
    network_interface_id = aws_network_interface.nat[0].id
  }
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }
  root_block_device {
    volume_size           = 8
    volume_type           = "gp3"
    encrypted             = true
    kms_key_id            = var.kms_key_arn
    delete_on_termination = true
  }
  user_data = <<-SCRIPT
    #!/bin/bash
    set -euo pipefail
    dnf install -y iptables-services
    systemctl enable --now iptables
    echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/90-nat.conf
    sysctl -p /etc/sysctl.d/90-nat.conf
    interface=$(ip -o route get 1.1.1.1 | sed -E 's/.* dev ([^ ]+).*/\1/')
    iptables -t nat -A POSTROUTING -o "$interface" -j MASQUERADE
    iptables -F FORWARD
    service iptables save
  SCRIPT
  lifecycle {
    ignore_changes = [ami, user_data] # a new AMI must not replace the egress path on its own
  }
  tags = { Name = "${var.name}-nat" }
}

# ---------------------------------------------------------------- app and data routing
resource "aws_route_table" "app" {
  count  = var.az_count
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-app-${local.azs[count.index]}" }
}

resource "aws_route" "app_nat_gateway" {
  count                  = local.nat_gateway ? var.az_count : 0
  route_table_id         = aws_route_table.app[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[var.egress_mode == "nat_gateway_per_az" ? count.index : 0].id
}

resource "aws_route" "app_nat_instance" {
  count                  = var.egress_mode == "nat_instance" ? var.az_count : 0
  route_table_id         = aws_route_table.app[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_network_interface.nat[0].id
}

resource "aws_route_table_association" "app" {
  count          = var.az_count
  subnet_id      = aws_subnet.app[count.index].id
  route_table_id = aws_route_table.app[count.index].id
}

resource "aws_route_table" "data" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-data" }
}

resource "aws_route_table_association" "data" {
  count          = var.az_count
  subnet_id      = aws_subnet.data[count.index].id
  route_table_id = aws_route_table.data.id
}

# Free, and keeps document and image-layer traffic off the NAT.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.this.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.app[*].id
  tags              = { Name = "${var.name}-s3" }
}

# ---------------------------------------------------------------- flow logs
resource "aws_cloudwatch_log_group" "flow" {
  name              = "/hrms/vpc-flow-rejects"
  retention_in_days = var.flow_log_retention_days
  kms_key_id        = var.kms_key_arn
}

resource "aws_iam_role" "flow_logs" {
  name = "${var.name}-flow-logs"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "vpc-flow-logs.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy" "flow_logs" {
  name = "write"
  role = aws_iam_role.flow_logs.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
      Resource = "${aws_cloudwatch_log_group.flow.arn}:*"
    }]
  })
}

resource "aws_flow_log" "this" {
  vpc_id               = aws_vpc.this.id
  traffic_type         = "REJECT"
  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.flow.arn
  iam_role_arn         = aws_iam_role.flow_logs.arn
}

output "vpc_id" {
  value = aws_vpc.this.id
}

output "cidr" {
  value = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "app_subnet_ids" {
  value = aws_subnet.app[*].id
}

output "data_subnet_ids" {
  value = aws_subnet.data[*].id
}
