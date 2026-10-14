# Cloudflare Traffic — Starter Code

Cloudflare provider v5 resources are generated from Cloudflare's API schema. The attribute names below match the v5 `cloudflare_load_balancer*` docs as of provider 5.22 — run `terraform validate` after every provider bump.

## 1. Stack files

```hcl
# infra/live/global/30-traffic/versions.tf
terraform {
  required_version = ">= 1.15.0, < 2.0.0"
  required_providers {
    cloudflare = { source = "cloudflare/cloudflare", version = "~> 5.22" }
  }
  backend "gcs" {
    bucket = "cb-tfstate-gcp"
    prefix = "global/traffic"
  }
}

provider "cloudflare" {
  # CLOUDFLARE_API_TOKEN from the traffic-prod GitHub environment secret.
  # Token scope: Zone > Load Balancers: Edit, Account > Load Balancing: Monitors And Pools: Edit.
}
```

```hcl
# infra/live/global/30-traffic/variables.tf
variable "zone_id" {
  type = string
}

variable "account_id" {
  type = string
}

variable "hostname" {
  type        = string
  description = "Public hostname, e.g. app.example.dev"
}

variable "weights" {
  type        = map(number)
  description = "Percent of traffic per cell. Edited only via PR, recommender PR, or the evacuation playbook."

  validation {
    condition     = sum(values(var.weights)) == 100
    error_message = "Weights must sum to 100."
  }

  validation {
    condition     = alltrue([for w in values(var.weights) : w == 0 || w >= 10])
    error_message = "Each cell must be 0 (drained) or >= 10 (warm floor)."
  }

  validation {
    condition     = length(setsubtract(keys(var.weights), ["aws", "gcp"])) == 0
    error_message = "Unknown cell key; allowed: aws, gcp."
  }
}

variable "fallback_cell" {
  type    = string
  default = "gcp"
}

variable "aws_origin_stack" {
  type        = string
  default     = "aws-prod/20-bootstrap.tfstate"
  description = "Managed AWS origin comes from bootstrap (ALB); budget origin from 10-foundation."
}
```

```json
// infra/live/global/30-traffic/terraform.tfvars.json   (real file has no comments)
{
  "zone_id": "0123456789abcdef0123456789abcdef",
  "account_id": "fedcba9876543210fedcba9876543210",
  "hostname": "app.example.dev",
  "weights": { "aws": 70, "gcp": 30 }
}
```

```hcl
# infra/live/global/30-traffic/main.tf
data "terraform_remote_state" "aws" {
  backend = "s3"
  config = {
    bucket = "cb-tfstate-aws"
    key    = var.aws_origin_stack
    region = "ap-south-1"
  }
}

data "terraform_remote_state" "gcp" {
  backend = "gcs"
  config = {
    bucket = "cb-tfstate-gcp"
    prefix = "gcp-prod/10-foundation"
  }
}

locals {
  origins = {
    aws = data.terraform_remote_state.aws.outputs.cell.origin
    gcp = data.terraform_remote_state.gcp.outputs.cell.origin
  }
}

check "origins_known" {
  assert {
    condition     = alltrue([for o in values(local.origins) : o != null && o != ""])
    error_message = "A cell origin is empty — for AWS managed, apply 20-bootstrap first so the ALB exists."
  }
}

resource "cloudflare_load_balancer_monitor" "cell" {
  account_id     = var.account_id
  type           = "https"
  method         = "GET"
  path           = "/healthz/cell"
  expected_codes = "200"
  interval       = 60
  retries        = 2
  timeout        = 5
  header         = { "Host" = [var.hostname] }
  description    = "CloudBridge cell health"
}

resource "cloudflare_load_balancer_pool" "cell" {
  for_each   = local.origins
  account_id = var.account_id
  name       = "cb-${each.key}-prod"
  monitor    = cloudflare_load_balancer_monitor.cell.id
  origins = [{
    name    = "${each.key}-ingress"
    address = each.value
    enabled = true
    header  = { host = [var.hostname] }
  }]
  minimum_origins = 1
  check_regions   = ["SAS", "SEAS"]
}

resource "cloudflare_load_balancer" "app" {
  zone_id         = var.zone_id
  name            = var.hostname
  proxied         = true
  default_pools   = [for k in sort(keys(local.origins)) : cloudflare_load_balancer_pool.cell[k].id]
  fallback_pool   = cloudflare_load_balancer_pool.cell[var.fallback_cell].id
  steering_policy = "random"

  random_steering = {
    default_weight = 0
    pool_weights   = { for k, pct in var.weights : cloudflare_load_balancer_pool.cell[k].id => pct / 100 }
  }

  session_affinity     = "cookie"
  session_affinity_ttl = 82800
  session_affinity_attributes = {
    samesite               = "Lax"
    secure                 = "Always"
    drain_duration         = 60
    zero_downtime_failover = "sticky"
  }
}

output "pool_ids" {
  value = { for k, p in cloudflare_load_balancer_pool.cell : k => p.id }
}

output "lb_id" {
  value = cloudflare_load_balancer.app.id
}

output "weights" {
  value = var.weights
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
