# GitHub Actions → AWS without stored keys. The trust is bound to one repository AND one GitHub
# environment: only a job running inside environment "ephemeral" gets a token with this `sub`.
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

locals {
  ephemeral_sub = "repo:${var.github_repository}:environment:ephemeral"
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
      {
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
      },
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
