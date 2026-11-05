# Workload identities. On EKS each workload has its own IRSA role. On k3s there is no OIDC issuer, so
# the k3s module attaches app_policy_json and secrets_policy_json to the node role instead.
# The release role keeps its name because scripts/setup-github.sh builds its ARN from it.
variable "documents_bucket_arn" {
  type = string
}

variable "kms_key_arn" {
  type = string
}

variable "db_instance_arn" {
  type = string
}

variable "rds_master_secret_arn" {
  type = string
}

variable "irsa_enabled" {
  description = "Create IRSA roles. False on k3s. A plain bool, because the provider ARN is unknown at plan time."
  type        = bool
  default     = false
}

variable "oidc_provider_arn" {
  type    = string
  default = null
}

variable "oidc_issuer" {
  description = "Issuer URL without https://."
  type        = string
  default     = null
}

variable "role_suffix" {
  description = "Added to role names, so that a DR region's cluster can have its own. IAM names are global."
  type        = string
  default     = ""
}

variable "create_release_role" {
  description = "Only one region needs the release role."
  type        = bool
  default     = true
}

variable "namespace" {
  type    = string
  default = "hrms"
}

variable "cluster_arn" {
  description = "EKS cluster the release role may describe. Null on k3s."
  type        = string
  default     = null
}

variable "github_oidc_provider_arn" {
  type = string
}

variable "github_repository" {
  type = string
}

variable "github_deploy_environment" {
  type = string
}

data "aws_caller_identity" "this" {}
data "aws_region" "this" {}
data "aws_partition" "this" {}

locals {
  partition  = data.aws_partition.this.partition
  secret_arn = "arn:${local.partition}:secretsmanager:${data.aws_region.this.region}:${data.aws_caller_identity.this.account_id}:secret:hrms/*"
}

# Documents in the bucket, and the KMS key for those objects and for decrypting the data key at startup.
data "aws_iam_policy_document" "app" {
  statement {
    sid       = "ListDocuments"
    actions   = ["s3:ListBucket"]
    resources = [var.documents_bucket_arn]
  }
  statement {
    sid       = "ReadWriteDocuments"
    actions   = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload"]
    resources = ["${var.documents_bucket_arn}/*"]
  }
  statement {
    sid       = "UseKey"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [var.kms_key_arn]
  }
}

data "aws_iam_policy_document" "secrets" {
  statement {
    sid       = "ReadSecrets"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [local.secret_arn, var.rds_master_secret_arn]
  }
  statement {
    sid       = "DecryptSecrets"
    actions   = ["kms:Decrypt"]
    resources = [var.kms_key_arn]
  }
}

# Migrate and the operator commands: unwrap the data key, and no access to documents.
data "aws_iam_policy_document" "migrate" {
  statement {
    sid       = "UnwrapDataKey"
    actions   = ["kms:Decrypt"]
    resources = [var.kms_key_arn]
  }
}

# The signature age metric. PutMetricData has no resource-level permissions, so the namespace is the limit.
data "aws_iam_policy_document" "metrics" {
  #checkov:skip=CKV_AWS_356:cloudwatch:PutMetricData supports no resource ARN. The condition limits it to one namespace.
  statement {
    sid       = "PublishHrmsMetrics"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["HRMS"]
    }
  }
}

data "aws_iam_policy_document" "irsa" {
  for_each = var.irsa_enabled ? {
    backend          = "system:serviceaccount:${var.namespace}:hrms-backend"
    worker           = "system:serviceaccount:${var.namespace}:hrms-worker"
    external-secrets = "system:serviceaccount:${var.namespace}:hrms-secrets"
    migrate          = "system:serviceaccount:${var.namespace}:hrms-migrate"
    freshclam-check  = "system:serviceaccount:${var.namespace}:hrms-freshclam-check"
    load-balancer    = "system:serviceaccount:kube-system:aws-load-balancer-controller"
  } : {}
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_issuer}:sub"
      values   = [each.value]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "backend" {
  count              = var.irsa_enabled ? 1 : 0
  name               = "hrms-backend${var.role_suffix}"
  assume_role_policy = data.aws_iam_policy_document.irsa["backend"].json
}

resource "aws_iam_role_policy" "backend" {
  count  = var.irsa_enabled ? 1 : 0
  name   = "documents-and-data-key"
  role   = aws_iam_role.backend[0].id
  policy = data.aws_iam_policy_document.app.json
}

resource "aws_iam_role" "worker" {
  count              = var.irsa_enabled ? 1 : 0
  name               = "hrms-worker${var.role_suffix}"
  assume_role_policy = data.aws_iam_policy_document.irsa["worker"].json
}

resource "aws_iam_role_policy" "worker" {
  count  = var.irsa_enabled ? 1 : 0
  name   = "documents-and-data-key"
  role   = aws_iam_role.worker[0].id
  policy = data.aws_iam_policy_document.app.json
}

resource "aws_iam_role" "external_secrets" {
  count              = var.irsa_enabled ? 1 : 0
  name               = "hrms-external-secrets${var.role_suffix}"
  assume_role_policy = data.aws_iam_policy_document.irsa["external-secrets"].json
}

resource "aws_iam_role_policy" "external_secrets" {
  count  = var.irsa_enabled ? 1 : 0
  name   = "read-secrets"
  role   = aws_iam_role.external_secrets[0].id
  policy = data.aws_iam_policy_document.secrets.json
}

resource "aws_iam_role" "migrate" {
  count              = var.irsa_enabled ? 1 : 0
  name               = "hrms-migrate${var.role_suffix}"
  assume_role_policy = data.aws_iam_policy_document.irsa["migrate"].json
}

resource "aws_iam_role_policy" "migrate" {
  count  = var.irsa_enabled ? 1 : 0
  name   = "unwrap-data-key"
  role   = aws_iam_role.migrate[0].id
  policy = data.aws_iam_policy_document.migrate.json
}

resource "aws_iam_role" "freshclam_check" {
  count              = var.irsa_enabled ? 1 : 0
  name               = "hrms-freshclam-check${var.role_suffix}"
  assume_role_policy = data.aws_iam_policy_document.irsa["freshclam-check"].json
}

resource "aws_iam_role_policy" "freshclam_check" {
  count  = var.irsa_enabled ? 1 : 0
  name   = "publish-metric"
  role   = aws_iam_role.freshclam_check[0].id
  policy = data.aws_iam_policy_document.metrics.json
}

# AWS Load Balancer Controller. The JSON is the project's published policy for chart 3.6.2, unchanged.
resource "aws_iam_role" "load_balancer_controller" {
  count              = var.irsa_enabled ? 1 : 0
  name               = "hrms-aws-load-balancer-controller${var.role_suffix}"
  assume_role_policy = data.aws_iam_policy_document.irsa["load-balancer"].json
}

resource "aws_iam_policy" "load_balancer_controller" {
  #checkov:skip=CKV_AWS_355:The controller's published policy; resources it creates are not known in advance.
  #checkov:skip=CKV_AWS_290:The controller's published policy; resources it creates are not known in advance.
  #checkov:skip=CKV_AWS_289:The controller's published policy; resources it creates are not known in advance.
  count  = var.irsa_enabled ? 1 : 0
  name   = "hrms-aws-load-balancer-controller${var.role_suffix}"
  policy = file("${path.module}/policies/aws-load-balancer-controller.json")
}

resource "aws_iam_role_policy_attachment" "load_balancer_controller" {
  count      = var.irsa_enabled ? 1 : 0
  role       = aws_iam_role.load_balancer_controller[0].name
  policy_arn = aws_iam_policy.load_balancer_controller[0].arn
}

# The release pipeline: snapshot before migrating, and describe the cluster. It holds no secrets and
# no data access; Argo CD applies the manifests from inside the cluster.
resource "aws_iam_role" "release" {
  count                = var.create_release_role ? 1 : 0
  name                 = "hrms-release"
  max_session_duration = 3600
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = var.github_oidc_provider_arn }
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_repository}:environment:${var.github_deploy_environment}"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "release" {
  count = var.create_release_role ? 1 : 0
  name  = "snapshot-and-describe"
  role  = aws_iam_role.release[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid      = "SnapshotBeforeMigrating"
          Effect   = "Allow"
          Action   = ["rds:CreateDBSnapshot", "rds:AddTagsToResource"]
          Resource = [var.db_instance_arn, "arn:${local.partition}:rds:${data.aws_region.this.region}:${data.aws_caller_identity.this.account_id}:snapshot:hrms-pre-*"]
        },
        {
          Sid      = "ReadSnapshotState"
          Effect   = "Allow"
          Action   = ["rds:DescribeDBSnapshots", "rds:DescribeDBInstances"]
          Resource = "*"
        },
      ],
      var.cluster_arn == null ? [] : [{
        Sid      = "DescribeCluster"
        Effect   = "Allow"
        Action   = ["eks:DescribeCluster"]
        Resource = var.cluster_arn
      }],
    )
  })
}

output "app_policy_json" {
  value = data.aws_iam_policy_document.app.json
}

output "secrets_policy_json" {
  value = data.aws_iam_policy_document.secrets.json
}

output "metrics_policy_json" {
  value = data.aws_iam_policy_document.metrics.json
}

output "migrate_role_arn" {
  value = var.irsa_enabled ? aws_iam_role.migrate[0].arn : ""
}

output "freshclam_check_role_arn" {
  value = var.irsa_enabled ? aws_iam_role.freshclam_check[0].arn : ""
}

output "backend_role_arn" {
  value = var.irsa_enabled ? aws_iam_role.backend[0].arn : ""
}

output "worker_role_arn" {
  value = var.irsa_enabled ? aws_iam_role.worker[0].arn : ""
}

output "external_secrets_role_arn" {
  value = var.irsa_enabled ? aws_iam_role.external_secrets[0].arn : ""
}

output "load_balancer_controller_role_arn" {
  value = var.irsa_enabled ? aws_iam_role.load_balancer_controller[0].arn : ""
}

output "release_role_arn" {
  value = var.create_release_role ? aws_iam_role.release[0].arn : ""
}
