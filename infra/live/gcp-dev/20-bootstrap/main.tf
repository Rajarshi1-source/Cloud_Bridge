# Runs after 10-foundation, with providers configured from its state: Kubernetes-facing providers can't
# be configured from a cluster created in the same apply.
data "terraform_remote_state" "foundation" {
  backend = "gcs"
  config = {
    bucket = "cb-tfstate-gcp"
    prefix = "gcp-dev/10-foundation"
  }
}

locals {
  cluster = data.terraform_remote_state.foundation.outputs.cluster
  cell    = data.terraform_remote_state.foundation.outputs.cell.name
}

module "bootstrap" {
  source = "../../../modules/bootstrap"
  cell   = local.cell
  ring   = "ring-canary"
}

output "argocd_chart_version" {
  value = module.bootstrap.argocd_chart_version
}
