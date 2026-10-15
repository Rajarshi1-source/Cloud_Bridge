# Offline proof that the ephemeral GKE stack plans with its real tfvars: GCP is mocked, the aws
# provider runs with its placeholder configuration (it must not need credentials).
mock_provider "google" {
  mock_data "google_project" {
    defaults = {
      number = "123456789012"
    }
  }
}

variables {
  expires_at     = "1792180800"
  admin_cidrs    = ["203.0.113.10/32"]
  gcp_project_id = "cb-test-project" # the tfvars placeholder fails Google's project-ID format on purpose
}

run "gcp_ephemeral_cell_plans_offline" {
  command = plan

  assert {
    condition     = output.cell.profile == "managed" && output.cell.cloud == "gcp" && output.expires_at == "1792180800"
    error_message = "The GCP dev stack must be a managed GKE cell that carries its expiry."
  }
}

run "expiry_is_required" {
  command = plan
  variables {
    expires_at = "soon"
  }
  expect_failures = [var.expires_at]
}
