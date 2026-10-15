# Cloudflare Traffic — Starter Code

Cloudflare provider v5 resources are generated from Cloudflare's API schema. The files below are the repo's validated stacks (provider 5.28.0, attribute names checked against the 5.28.0 docs; `terraform validate` + `terraform test` on Terraform 1.15 and OpenTofu 1.12 in CI) — re-run both after every provider bump.

## 1. Stack files (`infra/live/global/30-traffic`)

Besides the load balancer, the stack owns the per-cell **admin hosts** and the **Cloudflare Access** pieces from cloudbridge-cell-services `security-and-api.md` §3: one proxied record per cell (`admin-<cloud>.<domain>`, A for an IP origin, CNAME for an ALB hostname), a service token for the lease allocator, a reusable `non_identity` policy that admits only that token, and one `self_hosted` application covering both admin hosts (one AUD for the services to validate). The domain is read from `gitops/global/values.yaml`, so Ingress hosts and DNS can't disagree.

Lock file: where GitHub release downloads are blocked, `terraform providers lock` can't fetch the Cloudflare provider. The registry's download API still returns each package's SHA-256, which is a valid `zh:` lock hash.

```hcl
# infra/live/global/30-traffic/versions.tf
terraform {
  required_version = ">= 1.15.0, < 2.0.0"
  required_providers {
    # v5 is generated from Cloudflare's API schema and ships every 2–3 weeks: pin the minor, and run
    # `terraform validate` + the stack test on every bump (nested attribute names do move).
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.28.0"
    }
  }
}
```

```hcl
# infra/live/global/30-traffic/backend.tf
terraform {
  # GCS, not S3: AWS is the larger cell and so the likelier evacuation source; this stack must stay
  # applyable while AWS is the cloud that is failing. If GCS is unreachable too: tools/cf_break_glass.py (Week 7).
  backend "gcs" {
    bucket = "cb-tfstate-gcp"
    prefix = "global/traffic"
  }
}
```

```hcl
# infra/live/global/30-traffic/providers.tf
provider "cloudflare" {
  # CLOUDFLARE_API_TOKEN from the traffic GitHub environment. Scope: one zone and one account.
  #   Zone:    Load Balancers Edit, DNS Edit, Zone Settings Edit
  #   Account: Load Balancing: Monitors And Pools Edit, Access: Apps and Policies Edit,
  #            Access: Service Tokens Edit
}
```

```hcl
# infra/live/global/30-traffic/variables.tf
variable "zone_id" {
  type        = string
  description = "Cloudflare zone of the domain in gitops/global/values.yaml."
}

variable "account_id" {
  type = string
}

variable "weights" {
  type        = map(number)
  description = "Percent of traffic per cell. Changed only by PR, the steering recommender's PR, or the evacuation playbook."

  validation {
    condition     = sum(values(var.weights)) == 100
    error_message = "Weights must sum to 100."
  }

  validation {
    condition     = alltrue([for w in values(var.weights) : w == 0 || w >= 10])
    error_message = "Each cell must be 0 (drained) or >= 10 (warm floor): a cell at 3% has cold caches and a scaled-in pool."
  }

  validation {
    condition     = length(setsubtract(keys(var.weights), ["aws", "gcp"])) == 0 && length(var.weights) == 2
    error_message = "Weights need exactly the keys aws and gcp."
  }
}

variable "fallback_cell" {
  type        = string
  default     = "gcp"
  description = "Pool Cloudflare uses when every pool looks unhealthy."

  validation {
    condition     = contains(["aws", "gcp"], var.fallback_cell)
    error_message = "fallback_cell must be aws or gcp."
  }
}

# Where each cell's origin comes from. Budget cells: the VM's static IP from 10-foundation.
# Managed AWS: the ALB hostname from 20-bootstrap (the controller creates the ALB, so it only
# exists after bootstrap — a documented leaky abstraction).
variable "aws_origin_state_key" {
  type    = string
  default = "aws-budget/10-foundation.tfstate"
}

variable "gcp_origin_state_prefix" {
  type    = string
  default = "gcp-budget/10-foundation"
}
```

```json
{
  "zone_id": "00000000000000000000000000000000",
  "account_id": "00000000000000000000000000000000",
  "weights": {
    "aws": 70,
    "gcp": 30
  }
}
```

```hcl
# infra/live/global/30-traffic/main.tf
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
```

```hcl
# infra/live/global/30-traffic/outputs.tf
output "lb_id" {
  value = cloudflare_load_balancer.app.id
}

# tools/cf_break_glass.py (Week 7) needs these to patch weights when this state is unreachable.
output "pool_ids" {
  value = { for k, p in cloudflare_load_balancer_pool.cell : k => p.id }
}

output "weights" {
  value = var.weights
}

output "hostname" {
  value = local.hostname
}

# The gateway and inventory-service validate Cf-Access-Jwt-Assertion against this audience.
output "admin_access_aud" {
  value = cloudflare_zero_trust_access_application.admin.aud
}

# The lease allocator authenticates with these (stored in GCP Secret Manager, never in Git).
output "allocator_client_id" {
  value = cloudflare_zero_trust_access_service_token.allocator.client_id
}

output "allocator_client_secret" {
  value     = cloudflare_zero_trust_access_service_token.allocator.client_secret
  sensitive = true
}
```

```hcl
# infra/live/global/30-traffic/tests/stack.tftest.hcl
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
    condition     = sort(values(cloudflare_load_balancer.app.random_steering.pool_weights)) == [0.3, 0.7]
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
```

## 1b. Origin certificate (`infra/live/global/20-origin-tls`)

One Cloudflare Origin CA certificate (`origin-ecc`, 15 years, apex + wildcard) stored in **both** clouds' secret managers as `{certificate, private_key}` JSON (`cb/origin-tls`, `cb-origin-tls`). Each cell reads its own cloud's copy (Ansible `origin_tls` on budget cells), so serving TLS never depends on the other cloud. The key is in this stack's state: keep the bucket private and versioned.

```hcl
# infra/live/global/20-origin-tls/main.tf
# One Cloudflare Origin CA certificate for every origin (Full strict TLS), stored in each cloud's
# secret manager. Ansible origin_tls (budget) or External Secrets (managed) reads its own cloud's
# copy, so a cell never depends on the other cloud to serve TLS.

variable "gcp_project_id" {
  type = string
}

locals {
  domain    = yamldecode(file("${path.module}/../../../../gitops/global/values.yaml")).domain
  hostnames = [local.domain, "*.${local.domain}"] # app., admin-aws., admin-gcp., cp.
  pair = jsonencode({
    certificate = cloudflare_origin_ca_certificate.origin.certificate
    private_key = tls_private_key.origin.private_key_pem
  })
}

resource "tls_private_key" "origin" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_cert_request" "origin" {
  private_key_pem = tls_private_key.origin.private_key_pem
  dns_names       = local.hostnames
  subject {
    common_name  = local.domain
    organization = "CloudBridge"
  }
}

resource "cloudflare_origin_ca_certificate" "origin" {
  csr                = tls_cert_request.origin.cert_request_pem
  hostnames          = local.hostnames
  request_type       = "origin-ecc"
  requested_validity = 5475
}

resource "aws_secretsmanager_secret" "origin_tls" {
  name                    = "cb/origin-tls"
  description             = "Cloudflare Origin CA certificate + key for CloudBridge origins"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "origin_tls" {
  secret_id     = aws_secretsmanager_secret.origin_tls.id
  secret_string = local.pair
}

resource "google_secret_manager_secret" "origin_tls" {
  secret_id = "cb-origin-tls"
  labels    = { project = "cloudbridge" }
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "origin_tls" {
  secret      = google_secret_manager_secret.origin_tls.id
  secret_data = local.pair
}

output "certificate_expires_on" {
  value = cloudflare_origin_ca_certificate.origin.expires_on
}

output "hostnames" {
  value = local.hostnames
}
```

## 2. Post-apply recording (GitHub Actions step after `terraform apply tfplan`)

```bash
weights=$(jq -c '.weights' infra/live/global/30-traffic/terraform.tfvars.json)
curl -fsS -X POST "$CB_CP_API/traffic-changes" \
  -H "Authorization: Bearer $CB_CP_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"weights\": $weights, \"source\": \"${CB_TRAFFIC_SOURCE:-manual}\", \"pr_url\": \"$PR_URL\"}"
```
`CB_TRAFFIC_SOURCE` is set from PR labels: `traffic:recommender`, `traffic:evacuation`, `traffic:failback`, default `manual`.

## 3. Break-glass script

```python
#!/usr/bin/env python3
"""tools/cf_break_glass.py — change pool weights via the Cloudflare API when IaC is unavailable.

Usage: CF_API_TOKEN=... CB_CP_API=... CB_CP_TOKEN=... \
       python3 tools/cf_break_glass.py --weights aws=0,gcp=100 --reason "GCS state backend unreachable"
"""
import argparse, json, os, sys, urllib.request

API = "https://api.cloudflare.com/client/v4"

def call(method: str, url: str, token: str, body: dict | None = None) -> dict:
    req = urllib.request.Request(url, method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=15) as r:
        out = json.load(r)
    if not out.get("success", True):
        raise SystemExit(f"Cloudflare API error: {out.get('errors')}")
    return out

def parse_weights(s: str) -> dict[str, int]:
    w = {k: int(v) for k, v in (p.split("=") for p in s.split(","))}
    if sum(w.values()) != 100 or any(v not in (0,) and v < 10 for v in w.values()):
        raise SystemExit("weights must sum to 100 and each be 0 or >= 10")
    return w

def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--weights", required=True)
    ap.add_argument("--reason", required=True)
    ap.add_argument("--zone-id", default=os.environ.get("CF_ZONE_ID"))
    ap.add_argument("--lb-id", default=os.environ.get("CF_LB_ID"))
    ap.add_argument("--pool-ids", default=os.environ.get("CF_POOL_IDS"),
                    help='JSON map {"aws": "<pool id>", "gcp": "<pool id>"} (from terraform output pool_ids)')
    a = ap.parse_args()
    token = os.environ["CF_API_TOKEN"]
    weights = parse_weights(a.weights)
    pools = json.loads(a.pool_ids)

    lb_url = f"{API}/zones/{a.zone_id}/load_balancers/{a.lb_id}"
    current = call("GET", lb_url, token)["result"]
    print("current random_steering:", current.get("random_steering"), file=sys.stderr)

    body = {"random_steering": {"default_weight": 0,
                                "pool_weights": {pools[k]: v / 100 for k, v in weights.items()}}}
    call("PATCH", lb_url, token, body)
    print("applied:", weights, file=sys.stderr)

    rec = {"weights": weights, "source": "break_glass", "pr_url": None}
    req = urllib.request.Request(f"{os.environ['CB_CP_API']}/traffic-changes", method="POST",
                                 data=json.dumps(rec).encode(),
                                 headers={"Authorization": f"Bearer {os.environ['CB_CP_TOKEN']}",
                                          "Content-Type": "application/json"})
    try:
        urllib.request.urlopen(req, timeout=10)
    except Exception as e:  # recording must not block the incident action
        print(f"WARNING: could not record traffic change ({e}); record it manually", file=sys.stderr)
    print("NEXT: commit the same weights to terraform.tfvars.json and open an issue:", a.reason)

if __name__ == "__main__":
    main()
```
(The PATCH body sends only `random_steering`; the load balancer PATCH endpoint updates the supplied fields. If your API version requires the full object for PUT, use the GET result, modify `random_steering`, and PUT it back.)

## 4. Observed-split exporter (control plane)

```python
# control-plane/cf-exporter/exporter.py — exposes cb_cf_pool_requests_total from Cloudflare's GraphQL Analytics API
import os, time, json, urllib.request
from prometheus_client import Gauge, start_http_server

GQL = "https://api.cloudflare.com/client/v4/graphql"
QUERY = """
query ($zone: String!, $since: Time!, $until: Time!) {
  viewer { zones(filter: {zoneTag: $zone}) {
    loadBalancingRequestsAdaptiveGroups(limit: 100,
      filter: {datetime_geq: $since, datetime_lt: $until}) {
      count
      dimensions { lbName selectedPoolName }
    } } }
}"""
POOL_REQS = Gauge("cb_cf_pool_requests_5m", "LB requests per pool over the last 5 minutes", ["pool"])

def scrape() -> None:
    until = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    since = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 300))
    body = json.dumps({"query": QUERY, "variables": {"zone": os.environ["CF_ZONE_ID"], "since": since, "until": until}})
    req = urllib.request.Request(GQL, data=body.encode(), headers={
        "Authorization": f"Bearer {os.environ['CF_ANALYTICS_TOKEN']}", "Content-Type": "application/json"})
    data = json.load(urllib.request.urlopen(req, timeout=15))
    groups = data["data"]["viewer"]["zones"][0]["loadBalancingRequestsAdaptiveGroups"]
    seen = {}
    for g in groups:
        pool = g["dimensions"]["selectedPoolName"]
        seen[pool] = seen.get(pool, 0) + g["count"]
    for pool, n in seen.items():
        POOL_REQS.labels(pool=pool).set(n)

if __name__ == "__main__":
    start_http_server(9105)
    while True:
        try:
            scrape()
        except Exception as e:
            print("scrape failed:", e)
        time.sleep(60)
```
Dataset and field names in Cloudflare's GraphQL schema change occasionally — explore with the GraphiQL explorer first and adjust. PromQL for the panel: `cb_cf_pool_requests_5m / ignoring(pool) group_left sum(cb_cf_pool_requests_5m)`.

## 5. Origin lock-down (consumed by cell stacks)

```hcl
data "cloudflare_ip_ranges" "cf" {}
# module "cell" { cloudflare_ipv4 = data.cloudflare_ip_ranges.cf.ipv4_cidrs }
```
Refresh happens on every plan, so new Cloudflare ranges appear as a normal diff in the cell stack.
