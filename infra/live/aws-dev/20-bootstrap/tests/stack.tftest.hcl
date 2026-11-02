# Offline proof that the bootstrap stack plans from a foundation state: nothing is contacted.
mock_provider "helm" {}
mock_provider "aws" {
  mock_data "aws_secretsmanager_secret_version" {
    defaults = {
      secret_string = "{\"certificate\":\"cert\",\"private_key\":\"key\"}"
    }
  }
}

override_data {
  target = data.terraform_remote_state.foundation
  values = {
    outputs = {
      cell = { name = "cb-aws-dev" }
      cluster = {
        name           = "cb-aws-dev"
        endpoint       = "https://203.0.113.1"
        ca_certificate = "ca"
      }
    }
  }
}

run "installs_argo_cd_and_the_root_appset" {
  command = plan

  assert {
    condition     = module.bootstrap.argocd_chart_version == "10.10.5"
    error_message = "The managed cells must run the same Argo CD chart as the budget cells."
  }

  assert {
    condition     = strcontains(module.bootstrap.root_appset, "cb-aws-dev") && strcontains(module.bootstrap.root_appset, "ring-main")
    error_message = "The root ApplicationSet must carry this cell and its ring."
  }
}
