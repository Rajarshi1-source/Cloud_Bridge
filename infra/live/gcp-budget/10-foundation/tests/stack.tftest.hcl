# Offline proof that this stack plans: GCP is mocked, the aws provider runs with its real
# placeholder configuration (it must not need credentials), and the Cloudflare ranges are overridden.
mock_provider "google" {}

override_data {
  target = data.http.cloudflare_ipv4
  values = {
    status_code   = 200
    response_body = "173.245.48.0/20\n103.21.244.0/22\n"
  }
}

run "gcp_budget_cell_plans_offline" {
  command = plan

  assert {
    condition     = output.cell.cloud == "gcp" && output.cell.profile == "budget"
    error_message = "The GCP budget stack must build a GCP budget cell."
  }
}
