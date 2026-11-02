# Runs after 10-foundation, with providers configured from its state: Kubernetes-facing providers can't
# be configured from a cluster created in the same apply.
data "terraform_remote_state" "foundation" {
  backend = "s3"
  config = {
    bucket = "cb-tfstate-aws"
    key    = "aws-dev/10-foundation.tfstate"
    region = "ap-south-1"
  }
}

locals {
  cluster = data.terraform_remote_state.foundation.outputs.cluster
  cell    = data.terraform_remote_state.foundation.outputs.cell.name
}

module "bootstrap" {
  source = "../../../modules/bootstrap"
  cell   = local.cell
  ring   = "ring-main"
}

# The ALB can't read a Kubernetes TLS Secret: the controller finds the certificate in ACM by the
# Ingress hostnames, so the Origin CA pair 20-origin-tls stored goes there.
data "aws_secretsmanager_secret_version" "origin_tls" {
  secret_id = "cb/origin-tls"
}

resource "aws_acm_certificate" "origin" {
  certificate_body = jsondecode(data.aws_secretsmanager_secret_version.origin_tls.secret_string).certificate
  private_key      = jsondecode(data.aws_secretsmanager_secret_version.origin_tls.secret_string).private_key
  tags             = { "cb-cell" = local.cell, "managed-by" = "terraform" }
}

output "argocd_chart_version" {
  value = module.bootstrap.argocd_chart_version
}
