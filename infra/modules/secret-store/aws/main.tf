# What External Secrets reads on AWS: the cell's connection settings, and (when Postgres runs in the
# cluster) its password. The controller's Kubernetes service account gets read access through Pod
# Identity, limited to this cell's secrets and the shared origin certificate.
variable "name" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "region" {
  type = string
}

variable "config" {
  type      = map(string)
  sensitive = true
}

variable "in_cluster_db" {
  type = bool
}

variable "tags" {
  type = map(string)
}

data "aws_caller_identity" "current" {}

locals {
  secret_arn_prefix = "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret"
}

resource "aws_secretsmanager_secret" "config" {
  name                    = "${var.name}-cell-config"
  recovery_window_in_days = 0 # recreated by the next apply, and ephemeral cells reuse the name
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "config" {
  secret_id     = aws_secretsmanager_secret.config.id
  secret_string = jsonencode(var.config)
}

resource "random_password" "in_cluster_db" {
  count   = var.in_cluster_db ? 1 : 0
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "in_cluster_db" {
  count                   = var.in_cluster_db ? 1 : 0
  name                    = "${var.name}-db-admin"
  recovery_window_in_days = 0
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "in_cluster_db" {
  count         = var.in_cluster_db ? 1 : 0
  secret_id     = aws_secretsmanager_secret.in_cluster_db[0].id
  secret_string = jsonencode({ username = "cell", password = random_password.in_cluster_db[0].result })
}

data "aws_iam_policy_document" "pod_identity_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "external_secrets" {
  name               = "${var.name}-external-secrets"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
  tags               = var.tags
}

data "aws_iam_policy_document" "read_secrets" {
  statement {
    actions = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [
      "${local.secret_arn_prefix}:${var.name}-*",
      "${local.secret_arn_prefix}:cb/origin-tls-*",
    ]
  }
}

resource "aws_iam_role_policy" "read_secrets" {
  name   = "read-cell-secrets"
  role   = aws_iam_role.external_secrets.id
  policy = data.aws_iam_policy_document.read_secrets.json
}

resource "aws_eks_pod_identity_association" "external_secrets" {
  cluster_name    = var.cluster_name
  namespace       = "external-secrets"
  service_account = "external-secrets"
  role_arn        = aws_iam_role.external_secrets.arn
}

output "secret_store" {
  value = {
    kind   = "aws"
    prefix = var.name
    reader = aws_iam_role.external_secrets.arn
  }
}
