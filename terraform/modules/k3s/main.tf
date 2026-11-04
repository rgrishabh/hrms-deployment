# Tier-low: k3s on one Graviton instance in a private subnet, behind a Terraform-managed ALB. The node
# is disposable: all data is in RDS and S3, and Argo CD rebuilds the workloads from git, so an Auto
# Scaling group of one replaces a failed node by itself. See docs/ARCHITECTURE.md and DECISIONS.md.
variable "name" {
  type    = string
  default = "hrms"
}

variable "vpc_id" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "app_subnet_ids" {
  type = list(string)
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "kms_key_arn" {
  type = string
}

variable "instance_type" {
  type    = string
  default = "t4g.large"
}

variable "disk_gb" {
  type    = number
  default = 40
}

variable "k3s_version" {
  type    = string
  default = "v1.37.2+k3s1"
}

variable "k3s_arm64_sha256" {
  description = "SHA-256 of k3s-arm64 for k3s_version, from that release's sha256sum-arm64.txt."
  type        = string
  default     = "a779ccf1e5e2e33a62f5a29c2f1c0bbf99431e100579d4c10f0aa0742a6aa84b"
}

variable "argocd_chart_version" {
  type    = string
  default = "10.12.1"
}

variable "deployment_ref" {
  description = "Tag of this repository for the add-on manifests."
  type        = string
  default     = "main"
}

variable "gitops_repo_url" {
  description = "Repository holding this client's overlay."
  type        = string
}

variable "gitops_repo_revision" {
  type    = string
  default = "main"
}

variable "gitops_overlay_path" {
  type    = string
  default = "k8s/overlays/prod"
}

variable "domains" {
  description = "Hostnames the ALB forwards. Any other Host gets a 404 from the ALB."
  type        = list(string)
}

variable "certificate_arn" {
  type = string
}

variable "access_log_bucket" {
  type = string
}

variable "app_policy_json" {
  type = string
}

variable "secrets_policy_json" {
  type = string
}

variable "deletion_protection" {
  type    = bool
  default = true
}

locals {
  node_port = 30080
}

data "aws_partition" "this" {}

data "aws_ssm_parameter" "al2023_arm" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

# ---------------------------------------------------------------- network
resource "aws_security_group" "alb" {
  name        = "${var.name}-alb"
  description = "Public entry to the ALB"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name}-alb" }
}

resource "aws_vpc_security_group_ingress_rule" "alb" {
  #checkov:skip=CKV_AWS_260:Port 80 on the public ALB only redirects to HTTPS.
  for_each          = { https = 443, http = 80 }
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = each.value
  to_port           = each.value
  description       = "${each.key} from the internet"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_node" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.node.id
  ip_protocol                  = "tcp"
  from_port                    = local.node_port
  to_port                      = local.node_port
  description                  = "To Traefik"
}

resource "aws_security_group" "node" {
  name        = "${var.name}-node"
  description = "k3s node: no public inbound; ALB to Traefik only"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name}-node" }
}

resource "aws_vpc_security_group_ingress_rule" "node_from_alb" {
  security_group_id            = aws_security_group.node.id
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = local.node_port
  to_port                      = local.node_port
  description                  = "ALB to Traefik"
}

# 587 and 465 matter: the ECS design allowed only 443 and 5432, so SMTP could never have worked.
#trivy:ignore:AWS-0104 Egress is limited to the listed ports. HTTPS, SMTP and image pulls go to addresses that cannot be listed in advance.
resource "aws_vpc_security_group_egress_rule" "node_internet" {
  for_each          = { https = 443, smtp_submission = 587, smtps = 465 }
  security_group_id = aws_security_group.node.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = each.value
  to_port           = each.value
  description       = "Internet ${each.key}"
}

resource "aws_vpc_security_group_egress_rule" "node_vpc" {
  for_each          = { postgres = 5432, redis = 6379 }
  security_group_id = aws_security_group.node.id
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "tcp"
  from_port         = each.value
  to_port           = each.value
  description       = "Data tier ${each.key}"
}

resource "aws_vpc_security_group_egress_rule" "node_dns" {
  for_each          = toset(["udp", "tcp"])
  security_group_id = aws_security_group.node.id
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = each.value
  from_port         = 53
  to_port           = 53
  description       = "VPC DNS"
}

# ---------------------------------------------------------------- node identity
resource "aws_iam_role" "node" {
  name = "${var.name}-k3s-node"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "ec2.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:${data.aws_partition.this.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# k3s has no IRSA here, so the node role carries what backend, worker and External Secrets need.
# NetworkPolicy keeps IMDS closed to every other pod (k8s/components/tier-low/allow-imds.yaml).
resource "aws_iam_role_policy" "app" {
  name   = "documents-and-data-key"
  role   = aws_iam_role.node.id
  policy = var.app_policy_json
}

resource "aws_iam_role_policy" "secrets" {
  name   = "read-secrets"
  role   = aws_iam_role.node.id
  policy = var.secrets_policy_json
}

resource "aws_iam_instance_profile" "node" {
  name = "${var.name}-k3s-node"
  role = aws_iam_role.node.name
}

# ---------------------------------------------------------------- node
resource "aws_launch_template" "node" {
  #checkov:skip=CKV_AWS_341:Hop limit 2 lets backend, worker and External Secrets use the node role, as k3s has no IRSA here. NetworkPolicy blocks IMDS for all other pods. See DECISIONS.md, ADR-005.
  name_prefix            = "${var.name}-k3s-"
  image_id               = data.aws_ssm_parameter.al2023_arm.value
  instance_type          = var.instance_type
  update_default_version = true
  vpc_security_group_ids = [aws_security_group.node.id]
  iam_instance_profile {
    arn = aws_iam_instance_profile.node.arn
  }
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2 # one hop for the pod network; see the note on the node role above
  }
  monitoring {
    enabled = true
  }
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = var.disk_gb
      volume_type           = "gp3"
      encrypted             = true
      kms_key_id            = var.kms_key_arn
      delete_on_termination = true
    }
  }
  user_data = base64encode(templatefile("${path.module}/user-data.sh.tftpl", {
    k3s_version          = var.k3s_version
    k3s_sha256           = var.k3s_arm64_sha256
    node_port            = local.node_port
    argocd_chart_version = var.argocd_chart_version
    deployment_ref       = var.deployment_ref
    gitops_repo_url      = var.gitops_repo_url
    gitops_repo_revision = var.gitops_repo_revision
    gitops_overlay_path  = var.gitops_overlay_path
  }))
  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${var.name}-k3s" }
  }
  tag_specifications {
    resource_type = "volume"
    tags          = { Name = "${var.name}-k3s" }
  }
}

resource "aws_autoscaling_group" "node" {
  name                = "${var.name}-k3s"
  min_size            = 1
  max_size            = 1
  desired_capacity    = 1
  vpc_zone_identifier = [var.app_subnet_ids[0]]
  target_group_arns   = [aws_lb_target_group.traefik.arn]
  health_check_type   = "EC2"
  launch_template {
    id      = aws_launch_template.node.id
    version = "$Latest"
  }
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 0 # one node: a template change replaces it, with downtime
    }
  }
  tag {
    key                 = "Name"
    value               = "${var.name}-k3s"
    propagate_at_launch = true
  }
}

# ---------------------------------------------------------------- load balancer
#trivy:ignore:AWS-0053 This is the installation's public entry point; nodes stay on private subnets behind it.
resource "aws_lb" "this" {
  name                       = "${var.name}-alb"
  load_balancer_type         = "application"
  internal                   = false
  subnets                    = var.public_subnet_ids
  security_groups            = [aws_security_group.alb.id]
  drop_invalid_header_fields = true
  enable_deletion_protection = var.deletion_protection
  idle_timeout               = 60
  access_logs {
    bucket  = var.access_log_bucket
    prefix  = "alb"
    enabled = true
  }
}

resource "aws_lb_target_group" "traefik" {
  #checkov:skip=CKV_AWS_378:TLS ends at the ALB; the target is on a private subnet. The same holds for ALB to pods on the other tiers.
  name                 = "${var.name}-traefik"
  port                 = local.node_port
  protocol             = "HTTP"
  target_type          = "instance"
  vpc_id               = var.vpc_id
  deregistration_delay = 30
  health_check {
    path                = "/ping"
    matcher             = "200"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
  }
}

resource "aws_lb_listener" "http" {
  #checkov:skip=CKV_AWS_2:This listener only redirects to HTTPS.
  #checkov:skip=CKV_AWS_103:This listener only redirects to HTTPS.
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn
  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Not found"
      status_code  = "404"
    }
  }
}

# Unknown Host headers never reach the cluster.
resource "aws_lb_listener_rule" "known_hosts" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 10
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.traefik.arn
  }
  condition {
    host_header {
      values = var.domains
    }
  }
}

output "alb_arn" {
  value = aws_lb.this.arn
}

output "alb_arn_suffix" {
  value = aws_lb.this.arn_suffix
}

output "alb_dns_name" {
  value = aws_lb.this.dns_name
}

output "alb_zone_id" {
  value = aws_lb.this.zone_id
}

output "node_security_group_id" {
  value = aws_security_group.node.id
}
