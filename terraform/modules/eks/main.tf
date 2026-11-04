# EKS for tier-mid and tier-high. Secrets encrypted with the account key, all control plane logs kept,
# NetworkPolicy enforced by the VPC CNI, nodes in private subnets with IMDS closed to pods.
variable "name" {
  type    = string
  default = "hrms"
}

variable "kubernetes_version" {
  description = "Check the versions EKS offers when you apply."
  type        = string
  default     = "1.35"
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

variable "kms_key_arn" {
  type = string
}

variable "endpoint_public_cidrs" {
  description = "Addresses allowed to reach the API from outside the VPC. Empty keeps it private; open it briefly to install Argo CD."
  type        = list(string)
  default     = []
}

variable "admin_principal_arns" {
  description = "Static map of label to IAM role ARN with cluster-admin."
  type        = map(string)
  default     = {}
}

variable "node_instance_types" {
  type    = list(string)
  default = ["m7g.large"]
}

variable "node_ami_type" {
  description = "AL2023_ARM_64_STANDARD needs images built for linux/arm64 (the platforms input of _app-publish.yml)."
  type        = string
  default     = "AL2023_ARM_64_STANDARD"
}

variable "node_min" {
  type    = number
  default = 2
}

variable "node_desired" {
  type    = number
  default = 2
}

variable "node_max" {
  type    = number
  default = 4
}

variable "node_disk_gb" {
  type    = number
  default = 50
}

variable "log_retention_days" {
  type    = number
  default = 365
}

variable "restrict_alb_to_cloudfront" {
  description = "The ALB security group admits only CloudFront's origin-facing addresses, instead of the internet."
  type        = bool
  default     = false
}

data "aws_partition" "this" {}

locals {
  partition = data.aws_partition.this.partition
}

resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${var.name}/cluster"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
}

resource "aws_iam_role" "cluster" {
  name = "${var.name}-eks-cluster"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "eks.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_eks_cluster" "this" {
  #checkov:skip=CKV_AWS_39:The public endpoint is off by default, and when opened is limited to endpoint_public_cidrs.
  #checkov:skip=CKV_AWS_38:The public endpoint is off by default, and when opened is limited to endpoint_public_cidrs.
  name     = var.name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn
  vpc_config {
    subnet_ids              = var.app_subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = length(var.endpoint_public_cidrs) > 0
    public_access_cidrs     = length(var.endpoint_public_cidrs) > 0 ? var.endpoint_public_cidrs : null
  }
  encryption_config {
    resources = ["secrets"]
    provider {
      key_arn = var.kms_key_arn
    }
  }
  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }
  depends_on = [aws_iam_role_policy_attachment.cluster, aws_cloudwatch_log_group.cluster]
}

resource "aws_iam_openid_connect_provider" "this" {
  url            = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list = ["sts.amazonaws.com"]
}

resource "aws_eks_access_entry" "admin" {
  for_each      = var.admin_principal_arns
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
}

resource "aws_eks_access_policy_association" "admin" {
  for_each      = var.admin_principal_arns
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  policy_arn    = "arn:${local.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope {
    type = "cluster"
  }
  depends_on = [aws_eks_access_entry.admin]
}

# ---------------------------------------------------------------- node network
resource "aws_security_group" "node" {
  name        = "${var.name}-node"
  description = "EKS nodes and pods"
  vpc_id      = var.vpc_id
  tags = {
    Name                                = "${var.name}-node"
    "kubernetes.io/cluster/${var.name}" = "owned" # where the load balancer controller adds target rules
  }
}

resource "aws_vpc_security_group_ingress_rule" "node_self" {
  security_group_id            = aws_security_group.node.id
  referenced_security_group_id = aws_security_group.node.id
  ip_protocol                  = "-1"
  description                  = "Node and pod traffic"
}

resource "aws_vpc_security_group_ingress_rule" "node_from_control_plane" {
  for_each                     = { kubelet = 10250, webhooks = 9443, https = 443 }
  security_group_id            = aws_security_group.node.id
  referenced_security_group_id = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = each.value
  to_port                      = each.value
  description                  = "Control plane to ${each.key}"
}

resource "aws_vpc_security_group_ingress_rule" "control_plane_from_node" {
  security_group_id            = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  referenced_security_group_id = aws_security_group.node.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  description                  = "Nodes to the Kubernetes API"
}

resource "aws_vpc_security_group_egress_rule" "node_self" {
  security_group_id            = aws_security_group.node.id
  referenced_security_group_id = aws_security_group.node.id
  ip_protocol                  = "-1"
  description                  = "Node and pod traffic"
}

resource "aws_vpc_security_group_egress_rule" "node_control_plane" {
  security_group_id            = aws_security_group.node.id
  referenced_security_group_id = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  description                  = "Nodes to the Kubernetes API"
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

# The ALB the controller creates uses this group, through an Ingress annotation.
data "aws_ec2_managed_prefix_list" "cloudfront" {
  count = var.restrict_alb_to_cloudfront ? 1 : 0
  name  = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "aws_security_group" "alb" {
  name        = "${var.name}-alb"
  description = "Public entry to the ALB"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name}-alb" }
}

resource "aws_vpc_security_group_ingress_rule" "alb_cloudfront" {
  count             = var.restrict_alb_to_cloudfront ? 1 : 0
  security_group_id = aws_security_group.alb.id
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront[0].id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "HTTPS from CloudFront"
}

resource "aws_vpc_security_group_ingress_rule" "alb_internet" {
  #checkov:skip=CKV_AWS_260:Port 80 on the public ALB only redirects to HTTPS.
  for_each          = var.restrict_alb_to_cloudfront ? {} : { https = 443, http = 80 }
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = each.value
  to_port           = each.value
  description       = "${each.key} from the internet"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_targets" {
  for_each                     = { backend = 4000, frontend = 8080 }
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.node.id
  ip_protocol                  = "tcp"
  from_port                    = each.value
  to_port                      = each.value
  description                  = "To ${each.key} pods"
}

# ---------------------------------------------------------------- nodes
resource "aws_iam_role" "node" {
  name = "${var.name}-eks-node"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "ec2.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "AmazonEKSWorkerNodePolicy",
    "AmazonEKS_CNI_Policy",
    "AmazonEC2ContainerRegistryPullOnly",
    "AmazonSSMManagedInstanceCore", # shell access without SSH
  ])
  role       = aws_iam_role.node.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/${each.value}"
}

resource "aws_launch_template" "node" {
  name_prefix            = "${var.name}-node-"
  vpc_security_group_ids = [aws_security_group.node.id]
  update_default_version = true
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1 # pods use IRSA, and cannot reach the node role
  }
  monitoring {
    enabled = true
  }
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = var.node_disk_gb
      volume_type           = "gp3"
      encrypted             = true
      kms_key_id            = var.kms_key_arn
      delete_on_termination = true
    }
  }
  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${var.name}-node" }
  }
}

resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.name}-default"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.app_subnet_ids
  ami_type        = var.node_ami_type
  instance_types  = var.node_instance_types
  launch_template {
    id      = aws_launch_template.node.id
    version = aws_launch_template.node.latest_version
  }
  scaling_config {
    min_size     = var.node_min
    desired_size = var.node_desired
    max_size     = var.node_max
  }
  update_config {
    max_unavailable = 1
  }
  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }
  depends_on = [aws_iam_role_policy_attachment.node, aws_eks_addon.vpc_cni]
}

resource "aws_eks_addon" "vpc_cni" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "vpc-cni"
  # Without this, NetworkPolicy objects are accepted and silently not enforced.
  configuration_values        = jsonencode({ enableNetworkPolicy = "true" })
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"
}

resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"
  depends_on                  = [aws_eks_node_group.this]
}

output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "cluster_arn" {
  value = aws_eks_cluster.this.arn
}

output "oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.this.arn
}

output "oidc_issuer" {
  value = replace(aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")
}

output "node_security_group_id" {
  value = aws_security_group.node.id
}

output "alb_security_group_id" {
  value = aws_security_group.alb.id
}
