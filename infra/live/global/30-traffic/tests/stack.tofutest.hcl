# OpenTofu runs this file instead of stack.tftest.hcl (a .tofutest.hcl takes precedence).
# OpenTofu's mock provider gives every instance of a resource the same generated id, and overrides
# can't target a single for_each instance, so the load balancer's pool-id-keyed weight map would
# get duplicate keys. This variant targets everything except the load balancer; the weights
# contract (variable validation) is engine-independent and tested in full. Terraform runs the
# complete stack.tftest.hcl, including the pool-weight assertions.
mock_provider "cloudflare" {}

override_data {
  target = data.terraform_remote_state.aws
  values = { outputs = { cell = { origin = "203.0.113.10" } } }
}

override_data {
  target = data.terraform_remote_state.gcp
  values = { outputs = { cell = { origin = "198.51.100.20" } } }
}

run "wiring_except_load_balancer" {
  command = apply
  plan_options {
    target = [
      cloudflare_load_balancer_monitor.cell,
      cloudflare_load_balancer_pool.cell,
      cloudflare_zone_setting.ssl,
      cloudflare_dns_record.admin,
      cloudflare_zero_trust_access_application.admin,
    ]
  }

  assert {
    condition     = cloudflare_load_balancer_monitor.cell.path == "/healthz/cell" && cloudflare_load_balancer_monitor.cell.interval == 60
    error_message = "The monitor must probe /healthz/cell every 60 s."
  }
  assert {
    condition     = length(cloudflare_load_balancer_pool.cell) == 2 && cloudflare_load_balancer_pool.cell["aws"].origins[0].address == "203.0.113.10"
    error_message = "One pool per cell, each pointing at that cell's origin."
  }
  assert {
    condition     = alltrue([for r in cloudflare_dns_record.admin : r.type == "A" && r.proxied])
    error_message = "Budget origins are IPs: proxied A records for the admin hosts."
  }
  assert {
    condition     = cloudflare_zone_setting.ssl.value == "strict"
    error_message = "Origins use the Origin CA certificate: SSL must be Full (strict)."
  }
  assert {
    condition     = length(cloudflare_zero_trust_access_application.admin.destinations) == 2
    error_message = "Access must cover both admin hosts."
  }
}

run "drain_one_cell" {
  command = plan
  plan_options {
    target = [cloudflare_load_balancer_monitor.cell]
  }
  variables {
    weights = { aws = 0, gcp = 100 }
  }
}

run "rejects_weights_not_summing_to_100" {
  command = plan
  variables {
    weights = { aws = 60, gcp = 30 }
  }
  expect_failures = [var.weights]
}

run "rejects_below_warm_floor" {
  command = plan
  variables {
    weights = { aws = 95, gcp = 5 }
  }
  expect_failures = [var.weights]
}

run "rejects_unknown_cell" {
  command = plan
  variables {
    weights = { aws = 70, azure = 30 }
  }
  expect_failures = [var.weights]
}
