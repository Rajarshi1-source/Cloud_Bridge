# GitHub Actions → AWS without stored keys. The trust is bound to one repository AND one GitHub
# environment: only a job running inside environment "ephemeral" gets a token with this `sub`.
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

locals {
  ephemeral_sub = "repo:${var.github_repository}:environment:ephemeral"

  cell_iam_statement = {
    Sid    = "CellRoles"
    Effect = "Allow"
    Action = [
      "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:TagRole", "iam:UntagRole",
      "iam:UpdateAssumeRolePolicy", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies",
      "iam:PutRolePolicy", "iam:GetRolePolicy", "iam:DeleteRolePolicy",
      "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:PassRole",
      "iam:CreateInstanceProfile", "iam:DeleteInstanceProfile", "iam:GetInstanceProfile",
      "iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile",
      "iam:ListInstanceProfilesForRole", "iam:TagInstanceProfile",
    ]
    Resource = [
      "arn:aws:iam::*:role/cb-*",
      "arn:aws:iam::*:instance-profile/cb-*",
    ]
  }
}

resource "aws_iam_role" "ephemeral" {
  name                 = "cb-ephemeral-aws"
  description          = "ephemeral-up.yml and ttl-reaper.yml: create and destroy the aws-dev cell"
  max_session_duration = 7200
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = local.ephemeral_sub
        }
      }
    }]
  })
}

# Read-only plans on PRs and on main (iac-apply's plan job, drift.yml), and read access for the
# traffic stack's apply, which only reads the AWS cell's state. No environment can write with it.
resource "aws_iam_role" "plan" {
  name                 = "cb-plan-aws"
  description          = "iac-pr, iac-apply and drift: read-only terraform plan"
  max_session_duration = 3600
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = [
            "repo:${var.github_repository}:pull_request",
            "repo:${var.github_repository}:ref:refs/heads/main",
            "repo:${var.github_repository}:environment:traffic-prod",
          ]
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "plan_read_only" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_role_policy" "plan_state_lock" {
  name = "cb-state-lock-files"
  role = aws_iam_role.plan.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "LockFilesOnly" # use_lockfile writes a .tflock object even during a plan
      Effect   = "Allow"
      Action   = ["s3:PutObject", "s3:DeleteObject"]
      Resource = "arn:aws:s3:::${var.aws_state_bucket}/*.tflock"
    }]
  })
}

# Applies the budget cell. The trust names one GitHub environment, so the role can only be assumed by
# a job a reviewer has already approved. Its write access covers what that stack creates.
resource "aws_iam_role" "apply_budget" {
  name                 = "cb-apply-aws-budget"
  description          = "iac-apply: apply a reviewed plan of aws-budget"
  max_session_duration = 3600
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_repository}:environment:aws-budget"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "apply_budget_ec2" {
  role       = aws_iam_role.apply_budget.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2FullAccess"
}

resource "aws_iam_role_policy" "apply_budget" {
  name = "cb-iam-transfer-bucket-and-state"
  role = aws_iam_role.apply_budget.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      local.cell_iam_statement,
      {
        Sid      = "SsmTransferBucket"
        Effect   = "Allow"
        Action   = ["s3:CreateBucket", "s3:DeleteBucket", "s3:DeleteBucketPolicy", "s3:Get*", "s3:List*", "s3:Put*", "s3:DeleteObject*"]
        Resource = ["arn:aws:s3:::cb-*-ssm-*", "arn:aws:s3:::cb-*-ssm-*/*"]
      },
      {
        Sid      = "StateBucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = "arn:aws:s3:::${var.aws_state_bucket}"
      },
      {
        Sid      = "BudgetState"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "arn:aws:s3:::${var.aws_state_bucket}/aws-budget/*"
      },
    ]
  })
}

# Everything except IAM; IAM only for cb-* names (the cell's cluster, node and add-on roles).
resource "aws_iam_role_policy_attachment" "ephemeral_power_user" {
  role       = aws_iam_role.ephemeral.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

resource "aws_iam_role_policy" "ephemeral_iam_scoped" {
  name = "cb-iam-and-state"
  role = aws_iam_role.ephemeral.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      local.cell_iam_statement,
      {
        Sid      = "ServiceLinkedRoles"
        Effect   = "Allow"
        Action   = "iam:CreateServiceLinkedRole"
        Resource = "*"
        Condition = {
          StringLike = {
            "iam:AWSServiceName" = ["eks.amazonaws.com", "eks-nodegroup.amazonaws.com", "elasticloadbalancing.amazonaws.com", "autoscaling.amazonaws.com"]
          }
        }
      },
      {
        Sid      = "StateBucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = "arn:aws:s3:::${var.aws_state_bucket}"
      },
      {
        Sid      = "DevState"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "arn:aws:s3:::${var.aws_state_bucket}/aws-dev/*" # dev state and its .tflock only
      },
    ]
  })
}
