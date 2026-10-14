---
name: cloudbridge-finops-steering
description: Build CloudBridge's cost side - the FOCUS cost ledger in the PostgreSQL 18 control-plane database (AWS Data Exports FOCUS 1.2, GCP BigQuery FOCUS view, idempotent re-ingestion, monthly partitions), OpenCost allocation reconciled against the bill, cost per 1k requests and its fairness rules, Infracost PR framing, and the steering recommender that proposes AWS/GCP traffic weights as a pull request with significance test, SLO veto and a backtest gate. Also owns the whole control-plane schema (cells, deployments, traffic_changes, parity and drill tables) and its queries. Use for cost collectors, FinOps SQL, which cloud is cheaper, cost comparison method, the steering model, or control-plane migrations, even if the user only asks is GCP cheaper or why PostgreSQL not TimescaleDB. MANDATE - per request not totals, exclude credits, show data freshness, never quote unmeasured numbers, recommender only opens PRs. Not for Cloudflare resources (cloudflare-traffic).
---

# CloudBridge — FinOps Ledger & Steering (D3 + D4)

The cost comparison is the claim interviewers will push hardest on, so the rules here are about **honesty first, cleverness second**. Rev 1 quoted "₹18,500 vs ₹14,200 (23% cheaper)" — numbers nobody measured, comparing totals of a cell carrying 70% of traffic against one carrying 30%, on unequal machine shapes. Every rule below exists to make that mistake impossible.

References:
- `references/schema-and-queries.md` — full control-plane DDL (ledger, allocation, volumes, cells, deployments, traffic changes, parity, drills, recommendations, plan-risk), partition management, the dashboard queries.
- `references/starter-code.md` — AWS and GCP FOCUS adapters, normaliser, OpenCost + Prometheus pullers, recommender.
- `references/eval-harness.md` — the steering backtest and its CI gate.

## Database decision (defend it in one breath)

PostgreSQL 18, not TimescaleDB/Mongo/Cassandra/Cosmos: the control plane must be able to move clouds like everything else, and TimescaleDB isn't offered on RDS or Cloud SQL; Cosmos is Azure-only; the ledger is thousands of rows/day, which monthly declarative partitions serve in well under 100 ms; and the data is relational (cell → deployment → service → cost). The honest concession: the ledger *is* time-series-shaped — TimescaleDB is the switch if per-second resource metrics ever land in it.

## Ingestion

| Cloud | Source | Notes |
|---|---|---|
| AWS | Data Exports in **FOCUS 1.2** → Parquet in `s3://cb-billing-aws/focus/` | Read new objects daily with `pyarrow`; `source_file` = object key + ETag |
| GCP | Cloud Billing export to BigQuery + the **FOCUS view** | **Parameterised** query (`@start`, `@end`); the dataset name comes from config validated against `^[\w.-]+$` — never f-string user input into SQL (Rev 1 defect) |

FOCUS spec is at 1.4 (ratified Jun 2026) but providers export 1.2/1.3; ingest what is exported, store FOCUS column names (snake_case) so any FOCUS tool can read the ledger.

Idempotency: one transaction per source file — `DELETE FROM cost_line_items WHERE source_file = $1` then insert, then upsert `cost_ingestions(source_file, checksum, row_count)`. Re-delivered or corrected exports replace their own rows only.

Tag normalisation: `cb-cell`, `cb-service`, `cb-env` are valid as AWS tags and GCP labels; the ledger has generated columns `cb_cell`, `cb_service` from `tags` JSONB. Untagged cost is shown as its own line ("unallocated"), never silently spread.

## Fairness rules (each is an interview sentence)

1. **Unit cost, not totals.** `cost_per_1k_req = allocated_cost / requests × 1000` per service per cell over the same window. Totals mostly measure the traffic split.
2. **Credits excluded.** `charge_category = 'Usage'` only. Free-tier credits (new AWS accounts get a credit-based plan; GCP has trial credits and a GKE management credit) are reported separately.
3. **EffectiveCost and ListCost both shown.** Winning only on negotiated discounts is a procurement story, not an engineering one.
4. **Same shapes, same metro, same window.** Shapes table (terraform-cells), Mumbai on both clouds, identical date ranges.
5. **Allocation is an estimate, labelled.** Node cost is split by OpenCost CPU/memory share; directly tagged costs (DB, cache, LB) attach to their service. The dashboard shows OpenCost-estimate-vs-bill reconciliation error per cell per day.
6. **Freshness on every panel.** Billing exports lag a day or two; panels say "billing data as of …". The recommender refuses to run on data older than 72 h.

When asked "which cloud is cheaper?": answer with the method and the ledger's numbers *with their date range*, or say there isn't enough data yet. Predicting which line items will differ (NAT processing, LB hourly + capacity units, EKS control-plane fee vs GKE's management credit for one zonal cluster, egress to Cloudflare) is fine; predicting the winner is not.

## Request volumes

Prometheus recording rule `cb:requests:rate5m` → daily job sums to `request_volume_daily(day, cell, service, requests, errors, p95_ms)`. Use `increase()` over the day (`sum by (cb_cell, service) (increase(http_server_requests_seconds_count{uri!~"/actuator.*"}[1d]))`) at 00:05 IST for yesterday; never average rates.

## Steering recommender (D3)

Average cost per request misleads because each cell has fixed cost (control plane, NAT, minimum nodes) that doesn't move with traffic. Fit per cell over 28 days:

```
daily_cost_c = F_c + v_c × requests_c          (least squares; clamp F, v ≥ 0)
```

Search `w_aws ∈ {0.10, 0.11, …, 0.90}` (two cells → 1-D grid, no solver, fully explainable) minimising `R × (w·v_aws + (1−w)·v_gcp)` subject to:

| Constraint | Value | Why |
|---|---|---|
| safety first | if today's weight already violates a constraint, move to the nearest feasible weight, ignoring cost | a cost optimiser must never hold an unsafe split |
| significance | act only if `|v_aws − v_gcp| > 2σ` (σ from the regression's standard errors) | marginal cost is weakly identified; without this the model chases noise |
| warm floor | each cell 0 or ≥ 10% | same rule as Terraform validation |
| headroom | `w × peak_rps ≤ capacity_rps / 1.2` per cell | capacity.yaml (k6-measured at p95 < 300 ms) + HPA max |
| latency | predicted p95 ≤ 300 ms, using a **pessimistic** fit: mean per distinct share, forced non-decreasing, 1.5× slope beyond data | latency cliffs are convex; optimism here causes outages |
| no extrapolation | share ≤ highest observed share in the window + 0.10 | never trust the latency model far from data |
| step | `|w − w_now| ≤ 0.20` per week | no whiplash |
| hysteresis | saving ≥ max(₹500/month, 2% of variable cost) | don't churn for pennies |
| freshness | billing ≤ 72 h old, ≥ 21 days of history | refuse otherwise |

"Not significant" will be the most common answer early on — that is the correct output when the data can't distinguish the clouds, and it's a strong interview line.

Output: a PR editing `infra/live/global/30-traffic/terraform.tfvars.json`, label `traffic:recommender`, body with proposed weights, estimated monthly saving on **variable** cost, the binding constraint, the marginal ₹/1k-request per cell, and the backtest result. Its GitHub App can open PRs on that one file and nothing else. A row goes to `steering_recommendations`.

## Backtest gate

`evals/steering/` replays 90 days (synthetic until real history accrues, then real) with the recommender's policy vs static 70/30, grading against **ground-truth** latency and capacity curves rather than the model's own predictions. CI fails on **any** SLO/capacity violation, on a scenario moving the wrong way (including moving at all under pure noise), or on a saving regression > 20% vs the last merged model. Details and code in `references/eval-harness.md`.

The first runs of this backtest caught three real bugs in a naive recommender — acting on noise when costs were equal, a negative latency slope from duplicate-share noise, and holding an already-unsafe weight because "the saving wasn't significant". Each is now a scenario. That story is worth telling in an interview.

## Infracost framing

Infracost estimates the list-price delta of a plan; CloudBridge adds one line to the PR comment translating it to per-request terms at the current weight using measured volumes: "+₹1,900/month on the AWS cell ≈ +₹0.004 per 1k requests at today's 70%". Never rebuild what Infracost already does.

## Interview soundbites

- "Totals measure the traffic split; cost per request measures the cloud."
- "My ledger uses FOCUS column names, excludes credits, and every panel says how old the billing data is."
- "It's a recommender with a backtest, not an autopilot — the model writes the PR, a human merges it."
