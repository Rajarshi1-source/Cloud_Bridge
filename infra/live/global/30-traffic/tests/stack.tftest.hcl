# Offline: Cloudflare is mocked and both cell states are overridden, so this proves the weights
# contract and the wiring without a token, a zone or any state bucket.
mock_provider "cloudflare" {}

override_data {
  target = data.terraform_remote_state.aws
  values = { outputs = { cell = { origin = "203.0.113.10" } } }
}

override_data {
  target = data.terraform_remote_state.gcp
  values = { outputs = { cell = { origin = "198.51.100.20" } } }
}

run "pool_weights_carry_the_split" {
  command = apply

  assert {
    condition     = toset(values(cloudflare_load_balancer.app.random_steering.pool_weights)) == toset([0.3, 0.7]) # sort() would stringify
    error_message = "70/30 must become pool weights 0.7/0.3 (pool level, never origin weights)."
  }
  assert {
    condition     = cloudflare_load_balancer.app.random_steering.pool_weights[cloudflare_load_balancer_pool.cell["aws"].id] == 0.7
    error_message = "The AWS pool must carry the AWS weight."
  }
  assert {
    condition     = cloudflare_load_balancer.app.steering_policy == "random" && cloudflare_load_balancer.app.proxied
    error_message = "Steering must be proxied random steering."
  }
  assert {
    condition     = cloudflare_load_balancer.app.session_affinity == "cookie"
    error_message = "Cookie affinity is required: each cell owns its database (read-your-writes)."
  }
  assert {
    condition     = cloudflare_load_balancer.app.fallback_pool == cloudflare_load_balancer_pool.cell["gcp"].id
    error_message = "GCP is the default fallback pool."
  }
  assert {
    condition     = cloudflare_load_balancer_monitor.cell.path == "/healthz/cell" && cloudflare_load_balancer_monitor.cell.interval == 60
    error_message = "The monitor must probe /healthz/cell every 60 s."
  }
  assert {
    condition     = alltrue([for r in cloudflare_dns_record.admin : r.type == "A" && r.proxied])
    error_message = "Budget origins are IPs: proxied A records for the admin hosts."
  }
  assert {
    condition     = cloudflare_zone_setting.ssl.value == "strict"
    error_message = "Origins use the Origin CA certificate: SSL must be Full (strict)."
  }
}

run "managed_aws_origin_is_a_hostname" {
  command = apply

  override_data {
    target = data.terraform_remote_state.aws
    values = { outputs = { cell = { origin = "k8s-cbapp-0123456789.ap-south-1.elb.amazonaws.com" } } }
  }

  assert {
    condition     = cloudflare_dns_record.admin["aws"].type == "CNAME" && cloudflare_dns_record.admin["gcp"].type == "A"
    error_message = "An ALB hostname origin needs a CNAME admin record."
  }
}

run "drain_one_cell" {
  command = plan
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
