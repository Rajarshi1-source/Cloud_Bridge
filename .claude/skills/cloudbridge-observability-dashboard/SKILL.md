---
name: cloudbridge-observability-dashboard
description: Build CloudBridge's observability and control-plane UI - Prometheus 3 agent mode in each cell pushing remote_write to a central receiver behind Cloudflare Access, external labels, SLI recording rules, multi-window burn-rate SLO alerts (CellSLOBurnFast feeding Event-Driven Ansible), Alertmanager, blackbox probes through Cloudflare, the five Grafana 13 dashboards (overview with configured vs observed split, cost per request, parity, drills, delivery), the FastAPI control-plane API (capacity, drills, traffic changes, parity snapshots) and the Next.js 16 dashboard. Use for ANY work on monitoring, alerts, SLOs, Grafana, PromQL, the control-plane API or dashboard pages, or when the user asks how to monitor both clouds, prove the traffic split, or show drill and cost results, even if they only say monitoring dashboard. MANDATE - outbound-only metrics, never cross-cloud federation; every panel states data freshness. Not for cost SQL (finops-steering).
---

# CloudBridge — Observability & Control-Plane Dashboard

The control plane is **off the request path**: if it dies, users are still served; you lose dashboards and the recommender, not traffic. It runs on the GCP budget VM, published through Cloudflare Access (no open ports).

Starter files — Prometheus agent and receiver configs, recording and alert rules, Alertmanager, blackbox, Grafana provisioning, FastAPI routes for capacity/drills/traffic/parity, and Next.js pages — are in `references/starter-code.md`.

## Versions

| Component | Pin |
|---|---|
| Prometheus | 3.14.x — agent mode in cells, `--web.enable-remote-write-receiver` centrally |
| Alertmanager | 0.33.x (API v2) |
| Grafana | 13.2.x, provisioned from files, never `:latest` |
| Control-plane API | Python 3.14 + FastAPI, psycopg 3 |
| Dashboard | Next.js 16.3 App Router, React Server Components, Node 24 LTS |

## Metrics flow (why no federation)

```
cell: Prometheus --agent  ──remote_write (HTTPS, outbound, Access service token)──▶  control plane: Prometheus 3 receiver
      external_labels {cb_cell, cb_cloud, cb_env, cb_profile}                         recording rules · Alertmanager · Grafana
```
Rev 1 federated each cell's Prometheus across the internet, which requires inbound exposure of both cells and couples dashboards to the slowest link. Agent mode + `remote_write` is outbound-only; WAL buffering rides out short control-plane outages. Rollouts canary analysis needs a query endpoint *inside* the cell — run a small query-capable Prometheus (6 h retention) next to the agent for that, or point Rollouts at the central receiver with a `cb_cell` filter; document which.

Scale-out path when one receiver isn't enough (≈1M active series or > 30 days retention): Grafana Mimir or Thanos Receive — same `remote_write` protocol, no cell changes.

### As built (Week 5)

- **Agent:** `gitops/charts/platform-addons/templates/prometheus-agent.yaml`, off until `observability.enabled` (a real cell needs its `metrics-writer` Secret and the central receiver first). 128 MiB limit, `GOMEMLIMIT` 110 MiB, WAL in a 256 MiB emptyDir, Access token headers read from files. It scrapes the apps (`honor_labels`, since they tag `cb_cell` and `service` themselves), Argo CD and Rollouts. No kube-state-metrics: the capacity API brings live HPA data in Week 6.
- **Canary analysis:** points at the central receiver with a `cb_cell` filter. A query-capable Prometheus doesn't fit a 2 GiB cell, and an unreachable receiver fails the analysis, which is the safe way round.
- **Split:** `cb:split:observed` is each cell's share of user requests at the gateway, leaving out health probes and the allocator's admin calls, which reach each cell whatever the weights say (idle, they read as a false 50/50). No user traffic means no data. The Cloudflare analytics exporter is not built, so this says what origins saw, not what Cloudflare counted.
- **Rules:** error ratios use `or 0 *` so a cell with no 5xx reads 0, not no data. `CellMetricsSilent` catches a cell that stops reporting, which a burn-rate rule can't see.
- **Stat panels show numbers only:** a timestamp must go out as epoch milliseconds (`as_of()` in `build_dashboards.py`), or the panel claims "no measurement yet" with data in hand. `twin.sh observe` fails on this.
- **Capacity:** `tools/load/measure_capacity.py` writes a cell's own `capacity.yaml`. Fan-out in that file is what the load mix produced, and a number from the twin says nothing about a budget VM, whose file stays at 0.

## SLIs and SLOs

Recording rules (names used everywhere — evacuation playbook, ring promotion, recommender):
- `cb:requests:rate5m`, `cb:errors:rate5m`, `cb:latency_p95:5m` by `cb_cell, service`
- `cb:availability:ratio_rate1h` (gateway, by cell)

| SLO | Target | Alert |
|---|---|---|
| Per-cell availability (gateway 5xx) | 99.5% / 28 d | `CellSLOBurnFast`: burn > 14.4 over 1 h **and** 5 m → page + EDA webhook; `CellSLOBurnSlow`: > 6 over 6 h and 30 m → ticket |
| Global availability (blackbox through Cloudflare) | 99.9% / 28 d | `GlobalSLOBurnFast` |
| Edge latency p95 (Mumbai probe) | < 400 ms | ticket |
| Parity | score 1.0 | issue (parity workflow) |
| Drill freshness | last successful drill < 14 days | `ExitPlanEvidenceStale` |
| Billing freshness | < 72 h | `CostDataStale` |

Every alert carries labels `cb_cell`, `cb_cloud`, `cb_env` — the EDA rulebook routes on them (prod → proposal only, non-prod → drill).

## Dashboards (each answers one question)

| Dashboard | Question | Panels |
|---|---|---|
| Multi-cloud overview | Are both cells healthy, and is the split what I configured? | configured (latest `traffic_changes`) vs observed (`cb_cf_pool_requests_5m` share); golden signals per cell; pool health; blackbox `X-CB-Cell` distribution |
| Cost per request | Which cloud is cheaper per unit of work? | Q1 from the ledger (finops-steering); unallocated cost; OpenCost-vs-bill error; **"billing data as of"** stat |
| Parity | Are the cells still interchangeable? | score trend; current divergences; exceptions expiring in 7 days |
| Drills | Can the smaller cell take everything, how fast? | per-drill step timeline (weights, burn, p95); RTO trend; capacity ratio before/after pre-warm |
| Delivery | Is delivery healthy? | deploy frequency per cell; lead time commit → canary → main; change-failure rate (rollbacks); open drift issues |

Grafana reads Prometheus for metrics and the control-plane Postgres (read-only `cp_reader`) for ledger, parity and drills — no copying data into Prometheus that isn't a time series.

## Control-plane API (FastAPI) — contract used by other components

| Endpoint | Caller | Purpose |
|---|---|---|
| `GET /capacity/{cell}` | evacuation playbook | `{capacity_ratio, capacity_ratio_at_current_replicas, peak_rps_7d, per_service: [...]}` |
| `GET /capacity/{cell}/evacuation-plan` | pre-warm | `{services: [{service, min_replicas}]}` |
| `POST /drills`, `PATCH /drills/{id}`, `POST /drills/{id}/steps`, `POST /drills/{id}/complete`, `GET /drills/{id}/original-weights`, `GET /drills/latest/report.md` | Ansible | drill lifecycle + report rendering |
| `POST /traffic-changes` | apply workflow, break-glass | audit every weight change |
| `POST /parity/snapshots` | parity workflow | store findings |
| `GET /evacuation-proposal` | EDA prod path | proposed weights + capacity |

Auth: Cloudflare Access service tokens at the edge **and** a bearer token checked by the API (defence in depth). Writes are idempotent where callers retry (drill steps keyed by `(drill_id, seq)`).

Capacity math lives in one place (the API) so the playbook, the recommender and the dashboard agree:
`capacity_rps(cell) = min over services( hpa_max × per_pod_rps / fanout )` from `gitops/cells/<cell>/capacity.yaml` + live HPA max; `peak_rps_7d = max_over_time(sum by (cb_cell)(cb:requests:rate5m{service="api-gateway"})[7d:5m])` summed across cells; ratio = capacity / total peak.

## Next.js dashboard rules

- Server Components fetch from the control-plane API (`cache: 'no-store'` for live panels, `revalidate: 300` for cost); client components only for interactive charts.
- Every number renders with its **as-of timestamp** and source (ledger window, drill id, snapshot time). A panel without data shows "no measurement yet" — never a placeholder number. This is the dashboard-level version of the "never quote an unmeasured number" rule.
- Pages: `/` overview, `/cost`, `/parity`, `/drills`, `/drills/[id]`, `/traffic` (weight history with source badges: manual / recommender / evacuation / break-glass).

## Interview soundbites

- "Metrics flow outbound only — cells push, nothing reaches into a cell."
- "My overview dashboard shows the split I configured next to the split Cloudflare actually delivered."
- "Every panel tells you how old its data is; billing data is a day behind and I say so."
