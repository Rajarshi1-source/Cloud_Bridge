---
name: cloudbridge-cloudflare-traffic
description: Own CloudBridge's global traffic layer - the Cloudflare Load Balancer that splits users 70/30 between the AWS and GCP cells. Use for ANY work on infra/live/global/30-traffic, terraform.tfvars.json weights, pool weights via random_steering, cookie session affinity, the /healthz/cell monitor, check_regions, fallback pool, origin lock-down to Cloudflare IP ranges, configured-vs-observed split, failover timing, the break-glass Cloudflare API path, the Cloudflare-outage runbook, or Cloudflare Terraform provider v5 schema questions - even when the user just says change the traffic split, shift traffic to GCP, why is my split 50/50, or make failover faster. MANDATE - weights live only in terraform.tfvars.json, sum to 100, each cell 0 or at least 10; pool-level weights, never origin weights; every weight change has a recorded source. Not for the step-by-step evacuation saga itself (ansible-ops) or for deciding weights from cost (finops-steering).
---

# CloudBridge — Cloudflare Traffic Layer

Cloudflare is the only component that sees both clouds, so it is also CloudBridge's single point of failure. Treat this stack as the most sensitive one in the repo: small, boring, heavily validated, and changed only through recorded paths.

Full stack files, break-glass script and the observed-split exporter are in `references/starter-code.md`.

## Facts that drive the design

| Fact | Consequence |
|---|---|
| Origin `weight` only distributes **within** a pool | With one origin per pool, origin weights do nothing. Split traffic with **pool** weights: `steering_policy = "random"` + `random_steering.pool_weights` (values 0–1) |
| Load Balancing is a paid Cloudflare add-on (starts around US$5/month for two endpoints) | Not free tier — put it in the cost plan |
| Monitor interval 60 s × retries 2 | A dead cell is marked unhealthy after roughly 2–3 minutes. Never claim "instant failover" |
| Provider v5 (`~> 5.22`) is generated from the API schema, releases every 2–3 weeks | Pin the minor, run `terraform validate` on every Renovate bump, expect nested attribute names to shift |
| `proxied = true` | Steering happens per request at the edge; weight changes take effect in seconds, unlike DNS-only steering with client TTL caching |
| Cloudflare had a multi-hour global outage on 18 Nov 2025 | The edge is the availability ceiling; there's a documented runbook, not a pretend failover |

## The weights contract

The **only** source of truth is `infra/live/global/30-traffic/terraform.tfvars.json`:

```json
{ "weights": { "aws": 70, "gcp": 30 } }
```

JSON (not HCL) because three writers touch it — humans via PR, the steering recommender (cloudbridge-finops-steering) via PR, and the evacuation playbook (cloudbridge-ansible-ops) — and Python/Ansible can parse JSON without an HCL library.

Validation in `variables.tf`:
- sum of values = 100
- each value is `0` (drained) or `>= 10` — the **warm floor**. A cell at 3% has cold caches, un-JITed code and a scaled-in node pool; it fails the moment you send it real traffic. Either it's warm or it's deliberately drained.
- keys ⊆ `{aws, gcp}`

Convert at the resource: `pool_weights = { for k, pct in var.weights : cloudflare_load_balancer_pool.cell[k].id => pct / 100 }`.

Every change is recorded in the control-plane `traffic_changes` table with `source ∈ {manual, recommender, evacuation, failback, drill, break_glass}` — the apply workflow posts it after a successful apply.

## Stack anatomy

- `cloudflare_load_balancer_monitor` — HTTPS GET `/healthz/cell`, expect 200, interval 60, retries 2, timeout 5, `Host` header set. `/healthz/cell` is served by the gateway and means "this cell can take orders" (gateway + order-service ready + cell DB reachable). It deliberately **excludes** the cache: a cold or failed cache degrades performance, it shouldn't drain a cell.
- `cloudflare_load_balancer_pool` × 2 (`for_each` over origins) — one origin each, `minimum_origins = 1`, `check_regions = ["SAS", "SEAS"]` (probe from near the Mumbai origins; probing from North America measures the wrong path).
- `cloudflare_load_balancer` — `proxied = true`, `default_pools` both, `fallback_pool` = the cell you'd rather land on when everything looks unhealthy (GCP by default), `session_affinity = "cookie"`, `session_affinity_attributes.zero_downtime_failover = "sticky"`, `drain_duration = 60`.
- Origins come from the cell stacks: budget profile → static IP from `10-foundation`; GCP managed → reserved global IP from `10-foundation`; **AWS managed → ALB hostname from `20-bootstrap`** (the controller creates the ALB, so the hostname only exists after bootstrap — a documented leaky abstraction).

## Why session affinity is not optional

Each cell owns its own database. Without affinity a user creates an order on AWS, refreshes, lands on GCP and the order is "gone". Cookie affinity pins the session to a **home cell**; `zero_downtime_failover = "sticky"` moves it only if the home pool is unhealthy. If someone proposes removing affinity "to balance better", explain read-your-writes and point them at cloudbridge-cell-services.

## Origin lock-down

Origins accept 443 only from Cloudflare: `data "cloudflare_ip_ranges" "cf" {}` is passed into every cell stack as `cloudflare_ipv4` and used in the AWS security group / GCP firewall. TLS is Full (strict) with a Cloudflare Origin CA certificate on the ingress. Anyone hitting the origin IP directly gets nothing — this also means the observed split can't be skewed by direct-to-origin traffic.

## State placement

The traffic stack's state lives in **GCS** (`cb-tfstate-gcp/global/traffic`). Reasoning: the stack must be applyable when AWS is the failing cloud (it's the larger cell, so the more likely evacuation source). If GCS is unreachable, use break-glass.

## Break-glass (the one sanctioned bypass of IaC)

`tools/cf_break_glass.py --weights aws=0,gcp=100 --reason "..."`:
1. `PATCH /zones/{zone_id}/load_balancers/{lb_id}` with new `random_steering.pool_weights` using a token scoped to Load Balancing on one zone.
2. Records `traffic_changes.source = break_glass` and opens a priority issue.
3. Next `terraform plan` on the traffic stack shows drift; you commit the same weights to `terraform.tfvars.json` so code matches reality.

Use it only when the state backend or CI is unavailable during an incident. Logged, reconciled, rare.

## If Cloudflare itself is down

The LB is down with it. Runbook (`docs/runbooks/cloudflare-outage.md`): if Cloudflare DNS still answers, switch `app` to a DNS-only record pointing at the healthier cell's origin (origins must then accept non-Cloudflare traffic — temporary firewall rule, logged); otherwise accept the outage. A secondary authoritative DNS provider is the real fix and is listed as out of scope with its cost. In interviews, naming this SPOF is the senior answer.

## Proving the split

Dashboard panel "configured vs observed": configured = latest `traffic_changes.weights`; observed = Cloudflare analytics per pool (cf-exporter → Prometheus `cb_cf_pool_requests_total{pool=...}`), plus `X-CB-Cell` headers sampled by the blackbox prober. Expect a few points of deviation at low traffic (random steering + affinity); a persistent 50/50 means weights are on origins, not pools.

## Common requests → what to do

| Request | Action |
|---|---|
| "Shift to 50/50" | PR editing `terraform.tfvars.json`; plan shows only `random_steering` changing |
| "Move everything to GCP now" | That's an evacuation — use `ansible/playbooks/evacuate.yml` (capacity check + steps). A direct 0/100 apply skips the capacity check that prevents a cascade |
| "Faster failover" | Shorter monitor interval is a paid-tier option; explain detection math (interval × retries + drain) and that drills measure it |
| "Add Azure" | New pool in `for_each`, new key in validation, new origin output from the Azure cell |
| "Why is my split 50/50?" | Check that weights are in `random_steering.pool_weights`, not origin `weight`; check `steering_policy = "random"`; then **verify** with the configured-vs-observed panel (`traffic_changes` vs `cb:split:observed`) — name that panel in the answer rather than suggesting an ad-hoc comparison; every split fix ends with proof, not a claim |

## Interview soundbites

- "My first version put 0.7 on the single origin inside each pool — which splits nothing. Pool weights are what steer between clouds."
- "Weights are 0 or at least 10%: a cell is either warm or deliberately drained."
- "Adding a second cloud moved my availability ceiling to Cloudflare, so I wrote the runbook for Cloudflare failing instead of pretending it can't."
