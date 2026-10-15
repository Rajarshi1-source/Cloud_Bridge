# The only component that sees both clouds: small, boring, validated, changed through recorded paths.

locals {
  # One source for the domain: the Ingress hosts (gitops) and these records can't disagree.
  domain   = yamldecode(file("${path.module}/../../../../gitops/global/values.yaml")).domain
  hostname = "app.${local.domain}"

  origins = {
    aws = data.terraform_remote_state.aws.outputs.cell.origin
    gcp = data.terraform_remote_state.gcp.outputs.cell.origin
  }
}

data "terraform_remote_state" "aws" {
  backend = "s3"
  config = {
    bucket = "cb-tfstate-aws"
    key    = var.aws_origin_state_key
    region = "ap-south-1"
  }
}

data "terraform_remote_state" "gcp" {
  backend = "gcs"
  config = {
    bucket = "cb-tfstate-gcp"
    prefix = var.gcp_origin_state_prefix
  }
}

check "origins_known" {
  assert {
    condition     = alltrue([for o in values(local.origins) : o != null && o != ""])
    error_message = "A cell origin is empty. For AWS managed, apply 20-bootstrap first so the ALB exists."
  }
}

# ---- Load balancing: pool weights steer between clouds (origin weights only split inside a pool)

resource "cloudflare_load_balancer_monitor" "cell" {
  account_id     = var.account_id
  type           = "https"
  method         = "GET"
  path           = "/healthz/cell" # gateway + order ready + cell DB; deliberately not the cache
  expected_codes = "200"
  interval       = 60
  retries        = 2
  timeout        = 5
  header         = { "Host" = [local.hostname] }
  description    = "CloudBridge cell health"
}

resource "cloudflare_load_balancer_pool" "cell" {
  for_each   = local.origins
  account_id = var.account_id
  name       = "cb-${each.key}"
  monitor    = cloudflare_load_balancer_monitor.cell.id
  origins = [{
    name    = "${each.key}-ingress"
    address = each.value
    enabled = true
    header  = { host = [local.hostname] }
  }]
  minimum_origins = 1
  check_regions   = ["SAS", "SEAS"] # probe from near the Mumbai origins
}

resource "cloudflare_load_balancer" "app" {
  zone_id         = var.zone_id
  name            = local.hostname
  proxied         = true
  default_pools   = [for k in sort(keys(local.origins)) : cloudflare_load_balancer_pool.cell[k].id]
  fallback_pool   = cloudflare_load_balancer_pool.cell[var.fallback_cell].id
  steering_policy = "random"

  random_steering = {
    default_weight = 0
    pool_weights   = { for k, pct in var.weights : cloudflare_load_balancer_pool.cell[k].id => pct / 100 }
  }

  # Each cell owns its database: affinity keeps a user's reads on the cell that took their writes.
  session_affinity     = "cookie"
  session_affinity_ttl = 82800
  session_affinity_attributes = {
    samesite               = "Lax"
    secure                 = "Always"
    drain_duration         = 60
    zero_downtime_failover = "sticky"
  }
}

# ---- Origin TLS: Cloudflare → origin is HTTPS with the Origin CA certificate (20-origin-tls)

resource "cloudflare_zone_setting" "ssl" {
  zone_id    = var.zone_id
  setting_id = "ssl"
  value      = "strict"
}

# ---- Admin API: one proxied host per cell, straight at that cell's origin, behind Access

resource "cloudflare_dns_record" "admin" {
  for_each = local.origins
  zone_id  = var.zone_id
  name     = "admin-${each.key}.${local.domain}" # one label: covered by Universal SSL
  type     = can(cidrhost("${each.value}/32", 0)) ? "A" : "CNAME"
  content  = each.value
  proxied  = true
  ttl      = 1
  comment  = "CloudBridge lease admin API (Cloudflare Access service auth)"
}

resource "cloudflare_zero_trust_access_service_token" "allocator" {
  account_id = var.account_id
  name       = "cb-lease-allocator"
  duration   = "8760h" # rotate yearly: bump client_secret_version
}

resource "cloudflare_zero_trust_access_policy" "allocator_only" {
  account_id = var.account_id
  name       = "cb-lease-allocator-only"
  decision   = "non_identity" # service auth: a token, not a person
  include = [{
    service_token = { token_id = cloudflare_zero_trust_access_service_token.allocator.id }
  }]
}

resource "cloudflare_zero_trust_access_application" "admin" {
  account_id                = var.account_id
  name                      = "cb-admin"
  type                      = "self_hosted"
  session_duration          = "15m"
  service_auth_401_redirect = true # a blocked machine gets a 401, not a login page
  app_launcher_visible      = false
  destinations = [for k in sort(keys(local.origins)) : {
    type = "public"
    uri  = "admin-${k}.${local.domain}"
  }]
  policies = [{
    id         = cloudflare_zero_trust_access_policy.allocator_only.id
    precedence = 1
  }]
}
