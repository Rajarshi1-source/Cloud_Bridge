# Observability & Control Plane — Starter Code

## Contents
1. Cell: Prometheus agent config
2. Control plane: receiver config, recording rules, alert rules
3. Alertmanager (Slack + EDA webhook)
4. Blackbox probe through Cloudflare
5. Grafana provisioning (datasources + a panel example)
6. FastAPI control-plane API (capacity, drills, traffic changes)
7. Next.js 16 pages (overview + drills)

---

## 1. Cell — Prometheus agent

```yaml
# gitops/charts/platform-addons/files/prometheus-agent.yml  (mounted into Prometheus run with --agent)
global:
  scrape_interval: 15s
  external_labels:
    cb_cell: ${CB_CELL}          # substituted by the chart (envsubst initContainer) — Prometheus doesn't expand env vars
    cb_cloud: ${CB_CLOUD}
    cb_env: ${CB_ENV}
    cb_profile: ${CB_PROFILE}

scrape_configs:
  - job_name: apps
    kubernetes_sd_configs:
      - role: pod
        namespaces:
          names: [cb-app]
    relabel_configs:
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
        action: keep
        regex: "true"
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
        target_label: __metrics_path__
        regex: (.+)
      - source_labels: [__address__, __meta_kubernetes_pod_annotation_prometheus_io_port]
        regex: ([^:]+)(?::\d+)?;(\d+)
        replacement: $1:$2
        target_label: __address__
      - source_labels: [__meta_kubernetes_pod_label_app]
        target_label: service

  - job_name: kube-state-metrics
    static_configs:
      - targets: ["kube-state-metrics.monitoring:8080"]

  - job_name: opencost
    static_configs:
      - targets: ["opencost.opencost:9003"]

  - job_name: argocd
    static_configs:
      - targets: ["argocd-metrics.argocd:8082", "argocd-server-metrics.argocd:8083"]

remote_write:
  - url: https://metrics.cp.<domain>/api/v1/write
    headers:
      CF-Access-Client-Id: ${CF_ACCESS_CLIENT_ID}
      CF-Access-Client-Secret: ${CF_ACCESS_CLIENT_SECRET}
    queue_config:
      max_samples_per_send: 2000
      capacity: 10000
    write_relabel_configs:
      - source_labels: [__name__]
        regex: "go_.*|process_.*|jvm_gc_pause_seconds_bucket"
        action: drop                # keep the free-tier-sized receiver small
```
Prometheus doesn't expand `${VAR}` in config files; the chart renders this file with an `envsubst` initContainer, or you template the values directly in Helm. Header values come from the ESO-managed secret.

## 2. Control plane — receiver, recording rules, alerts

```yaml
# observability/prometheus/prometheus.yml  (central; started with --web.enable-remote-write-receiver)
global:
  evaluation_interval: 30s
rule_files:
  - /etc/prometheus/rules/*.yml
alerting:
  alertmanagers:
    - static_configs:
        - targets: ["alertmanager:9093"]
scrape_configs:
  - job_name: blackbox-edge
    metrics_path: /probe
    params:
      module: [http_2xx_cell]
    static_configs:
      - targets: ["https://app.<domain>/healthz/cell"]
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - target_label: __address__
        replacement: blackbox:9115
  - job_name: cf-exporter
    static_configs:
      - targets: ["cf-exporter:9105"]
```

```yaml
# observability/prometheus/rules/sli.yml
groups:
  - name: cb-sli
    rules:
      - record: cb:requests:rate5m
        expr: sum by (cb_cell, service) (rate(http_server_requests_seconds_count{uri!~"/actuator.*|/healthz.*"}[5m]))
      - record: cb:errors:rate5m
        expr: sum by (cb_cell, service) (rate(http_server_requests_seconds_count{uri!~"/actuator.*|/healthz.*", status=~"5.."}[5m]))
      - record: cb:latency_p95:5m
        expr: histogram_quantile(0.95, sum by (cb_cell, service, le) (rate(http_server_requests_seconds_bucket{uri!~"/actuator.*|/healthz.*"}[5m])))
      - record: cb:error_ratio:rate5m
        expr: cb:errors:rate5m{service="api-gateway"} / cb:requests:rate5m{service="api-gateway"}
      - record: cb:error_ratio:rate30m
        expr: sum by (cb_cell) (rate(http_server_requests_seconds_count{service="api-gateway",status=~"5.."}[30m])) / sum by (cb_cell) (rate(http_server_requests_seconds_count{service="api-gateway"}[30m]))
      - record: cb:error_ratio:rate1h
        expr: sum by (cb_cell) (rate(http_server_requests_seconds_count{service="api-gateway",status=~"5.."}[1h])) / sum by (cb_cell) (rate(http_server_requests_seconds_count{service="api-gateway"}[1h]))
      - record: cb:error_ratio:rate6h
        expr: sum by (cb_cell) (rate(http_server_requests_seconds_count{service="api-gateway",status=~"5.."}[6h])) / sum by (cb_cell) (rate(http_server_requests_seconds_count{service="api-gateway"}[6h]))
      - record: cb:availability:ratio_rate1h
        expr: 1 - cb:error_ratio:rate1h
      - record: cb:split:observed
        expr: cb_cf_pool_requests_5m / ignoring(pool) group_left sum(cb_cf_pool_requests_5m)
```

```yaml
# observability/prometheus/rules/alerts.yml   (per-cell SLO 99.5% → error budget 0.005)
groups:
  - name: cb-slo
    rules:
      - alert: CellSLOBurnFast
        expr: |
          (sum by (cb_cell) (cb:error_ratio:rate5m) / 0.005 > 14.4)
          and on (cb_cell)
          (cb:error_ratio:rate1h / 0.005 > 14.4)
        for: 2m
        labels:
          severity: page
        annotations:
          summary: "{{ $labels.cb_cell }} burning error budget at >14.4x"
      - alert: CellSLOBurnSlow
        expr: |
          (cb:error_ratio:rate30m / 0.005 > 6) and on (cb_cell) (cb:error_ratio:rate6h / 0.005 > 6)
        for: 15m
        labels:
          severity: ticket
      - alert: GlobalEdgeDown
        expr: probe_success{job="blackbox-edge"} == 0
        for: 3m
        labels:
          severity: page
      - alert: RemoteWriteSilent
        expr: absent_over_time(up{job="apps"}[10m])
        labels:
          severity: ticket
        annotations:
          summary: "A cell stopped sending metrics (agent down or Access token expired)"
```
`cb_cloud` / `cb_env` labels on `CellSLOBurnFast` come from the series' external labels; keep them in the `by` clauses (`sum by (cb_cell, cb_cloud, cb_env)`) when you extend the rules so the EDA rulebook can route on them. Drill/billing freshness alerts are evaluated by the control-plane API exposing `cb_last_drill_success_timestamp` and `cb_billing_latest_timestamp` gauges.

## 3. Alertmanager

```yaml
# observability/alertmanager/alertmanager.yml
route:
  receiver: slack
  group_by: [alertname, cb_cell]
  routes:
    - matchers: [alertname="CellSLOBurnFast"]
      receiver: slack-and-eda
      continue: false
receivers:
  - name: slack
    slack_configs:
      - api_url_file: /etc/alertmanager/slack_url
        channel: "#cloudbridge-alerts"
        send_resolved: true
  - name: slack-and-eda
    slack_configs:
      - api_url_file: /etc/alertmanager/slack_url
        channel: "#cloudbridge-alerts"
        send_resolved: true
    webhook_configs:
      - url: http://eda:5000/endpoint          # ansible-rulebook alertmanager source
        send_resolved: true
```

## 4. Blackbox probe

```yaml
# observability/blackbox/blackbox.yml
modules:
  http_2xx_cell:
    prober: http
    timeout: 5s
    http:
      method: GET
      valid_status_codes: [200]
      fail_if_header_not_matches:
        - header: X-CB-Cell
          regexp: "^cb-(aws|gcp)-"
```
The probe goes through Cloudflare like a user. A separate external uptime check (not hosted on Cloudflare or either cloud) catches the case where the whole stack, including the control plane's own edge, is down.

## 5. Grafana provisioning

```yaml
# observability/grafana/provisioning/datasources/ds.yml
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    url: http://prometheus:9090
    isDefault: true
  - name: ControlPlane
    type: grafana-postgresql-datasource
    url: postgres:5432
    user: cp_reader
    jsonData:
      database: controlplane
      sslmode: disable
      postgresVersion: 1800
    secureJsonData:
      password: $__file{/etc/grafana/secrets/cp_reader_password}
```

Configured-vs-observed panel queries:
```sql
-- Grafana (ControlPlane datasource): configured AWS share, as a step series
SELECT applied_at AS "time", (weights->>'aws')::int / 100.0 AS configured_aws
FROM traffic_changes WHERE $__timeFilter(applied_at) ORDER BY 1;
```
```promql
# Prometheus: observed AWS share from Cloudflare analytics
cb:split:observed{pool="cb-aws-prod"}
```

## 6. FastAPI control-plane API

```python
# control-plane/api/main.py
from __future__ import annotations
import os, pathlib
from datetime import datetime, timezone
from typing import Any
import httpx, psycopg, yaml
from fastapi import Depends, FastAPI, Header, HTTPException
from pydantic import BaseModel, Field

app = FastAPI(title="CloudBridge control plane")
DSN = os.environ["DATABASE_URL"]
PROM = os.environ["CB_PROM_URL"]
REPO = pathlib.Path(os.environ.get("CB_REPO_DIR", "/repo"))

def auth(authorization: str = Header(...)) -> None:
    if authorization != f"Bearer {os.environ['CB_CP_TOKEN']}":
        raise HTTPException(401)

def db():
    with psycopg.connect(DSN, autocommit=True) as conn:
        yield conn

def prom(expr: str) -> list[dict]:
    r = httpx.get(f"{PROM}/api/v1/query", params={"query": expr}, timeout=10)
    r.raise_for_status()
    return r.json()["data"]["result"]

# ---------- capacity ----------
@app.get("/capacity/{cell}", dependencies=[Depends(auth)])
def capacity(cell: str) -> dict[str, Any]:
    cap = yaml.safe_load((REPO / "gitops" / "cells" / cell / "capacity.yaml").read_text())
    hpa_max = {r["metric"]["horizontalpodautoscaler"]: float(r["value"][1])
               for r in prom(f'kube_horizontalpodautoscaler_spec_max_replicas{{cb_cell="{cell}",namespace="cb-app"}}')}
    current = {r["metric"]["horizontalpodautoscaler"]: float(r["value"][1])
               for r in prom(f'kube_horizontalpodautoscaler_status_current_replicas{{cb_cell="{cell}",namespace="cb-app"}}')}
    fanout = {"api-gateway": 1, **cap.get("fanout", {})}
    per_service, cap_max, cap_now = [], [], []
    for svc, rps in cap["perPodRps"].items():
        if not rps or svc not in hpa_max:
            raise HTTPException(409, f"capacity for {svc} not measured or HPA missing — refuse to guess")
        c_max = hpa_max[svc] * rps / fanout.get(svc, 1)
        c_now = current.get(svc, 0) * rps / fanout.get(svc, 1)
        per_service.append({"service": svc, "hpa_max": hpa_max[svc], "current": current.get(svc), "capacity_rps": c_max})
        cap_max.append(c_max)
        cap_now.append(c_now)
    peak = prom('max_over_time(sum(cb:requests:rate5m{service="api-gateway"})[7d:5m])')
    peak_rps = float(peak[0]["value"][1]) if peak else 0.0
    if peak_rps == 0:
        raise HTTPException(409, "no traffic history — capacity ratio undefined")
    return {"cell": cell, "peak_rps_7d": peak_rps,
            "capacity_ratio": min(cap_max) / peak_rps,
            "capacity_ratio_at_current_replicas": min(cap_now) / peak_rps,
            "per_service": per_service,
            "measured_at": cap.get("measuredAt")}

@app.get("/capacity/{cell}/evacuation-plan", dependencies=[Depends(auth)])
def evacuation_plan(cell: str, headroom: float = 1.2) -> dict[str, Any]:
    c = capacity(cell)
    cap = yaml.safe_load((REPO / "gitops" / "cells" / cell / "capacity.yaml").read_text())
    fanout = {"api-gateway": 1, **cap.get("fanout", {})}
    need = c["peak_rps_7d"] * headroom
    services = [{"service": s["service"],
                 "min_replicas": min(int(s["hpa_max"]), max(1, -(-int(need * fanout.get(s["service"], 1)) // int(cap["perPodRps"][s["service"]]))))}
                for s in c["per_service"]]
    return {"cell": cell, "target_rps": need, "services": services}

# ---------- drills ----------
class DrillIn(BaseModel):
    from_cell: str
    to_cell: str
    mode: str = Field(pattern="^(drill|real)$")

@app.post("/drills", status_code=201, dependencies=[Depends(auth)])
def open_drill(d: DrillIn, conn=Depends(db)) -> dict[str, Any]:
    weights = (REPO / "infra/live/global/30-traffic/terraform.tfvars.json").read_text()
    row = conn.execute("""INSERT INTO drills (env, from_cell, to_cell, mode, original_weights)
                          VALUES (split_part(%s, '-', 3), %s, %s, %s, (%s::jsonb)->'weights') RETURNING id""",
                       (d.from_cell, d.from_cell, d.to_cell, d.mode, weights)).fetchone()
    return {"id": str(row[0])}

class StepIn(BaseModel):
    seq: int
    weights: dict[str, int]
    burn_rate: float
    p95_ms: float
    decision: str = Field(pattern="^(advance|hold|abort)$")

@app.post("/drills/{drill_id}/steps", status_code=201, dependencies=[Depends(auth)])
def add_step(drill_id: str, s: StepIn, conn=Depends(db)) -> dict[str, str]:
    conn.execute("""INSERT INTO drill_steps (drill_id, seq, weights, burn_rate, p95_ms, decision)
                    VALUES (%s, %s, %s::jsonb, %s, %s, %s)
                    ON CONFLICT (drill_id, seq) DO UPDATE SET burn_rate = EXCLUDED.burn_rate,
                      p95_ms = EXCLUDED.p95_ms, decision = EXCLUDED.decision""",
                 (drill_id, s.seq, __import__("json").dumps(s.weights), s.burn_rate, s.p95_ms, s.decision))
    return {"status": "recorded"}

@app.patch("/drills/{drill_id}", dependencies=[Depends(auth)])
def patch_drill(drill_id: str, body: dict, conn=Depends(db)) -> dict[str, str]:
    if body.get("outcome") not in ("aborted", "rolled_back", "completed"):
        raise HTTPException(422, "outcome must be aborted|rolled_back|completed")
    conn.execute("UPDATE drills SET outcome = %s, finished_at = now() WHERE id = %s", (body["outcome"], drill_id))
    return {"status": "ok"}

@app.post("/drills/{drill_id}/complete", dependencies=[Depends(auth)])
def complete(drill_id: str, conn=Depends(db)) -> dict[str, Any]:
    steps = conn.execute("SELECT seq, at, burn_rate FROM drill_steps WHERE drill_id = %s ORDER BY seq", (drill_id,)).fetchall()
    started = conn.execute("SELECT started_at FROM drills WHERE id = %s", (drill_id,)).fetchone()[0]
    shift_seconds = int((steps[-1][1] - steps[0][1]).total_seconds()) if len(steps) > 1 else 0
    conn.execute("""UPDATE drills SET outcome = 'completed', finished_at = now(),
                      shift_seconds = %s, burn_rate_max = %s WHERE id = %s""",
                 (shift_seconds, max((s[2] or 0) for s in steps) if steps else None, drill_id))
    return {"id": drill_id, "shift_seconds": shift_seconds, "started_at": started.isoformat()}

# ---------- traffic changes ----------
class TrafficIn(BaseModel):
    weights: dict[str, int]
    source: str = Field(pattern="^(manual|recommender|evacuation|failback|drill|break_glass)$")
    pr_url: str | None = None

@app.post("/traffic-changes", status_code=201, dependencies=[Depends(auth)])
def traffic_change(t: TrafficIn, conn=Depends(db)) -> dict[str, str]:
    import json
    try:
        row = conn.execute("INSERT INTO traffic_changes (weights, source, pr_url) VALUES (%s::jsonb, %s, %s) RETURNING id",
                           (json.dumps(t.weights), t.source, t.pr_url)).fetchone()
    except psycopg.errors.RaiseException as e:          # the DB trigger enforces sum=100 and the warm floor
        raise HTTPException(422, str(e).splitlines()[0])
    return {"id": str(row[0])}

@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok", "time": datetime.now(timezone.utc).isoformat()}
```
`capacity()` refuses (409) when a per-pod RPS hasn't been measured — the evacuation playbook then fails safe instead of evacuating on a guessed number. Drill report rendering (`GET /drills/latest/report.md`) is a Jinja template over `drills` + `drill_steps`; keep numbers formatted exactly as stored.

## 7. Next.js 16 pages

```tsx
// control-plane/dashboard/app/page.tsx — overview (Server Component)
import { SplitPanel } from "@/components/split-panel";

type Cell = { cell: string; availability: number | null; p95ms: number | null };
type Overview = { asOf: string; configured: { aws: number; gcp: number }; observed: { aws: number; gcp: number } | null; cells: Cell[] };

async function getOverview(): Promise<Overview> {
  const res = await fetch(`${process.env.CP_API_URL}/overview`, {
    cache: "no-store",
    headers: { Authorization: `Bearer ${process.env.CB_CP_TOKEN}` },
  });
  if (!res.ok) throw new Error(`control plane ${res.status}`);
  return res.json();
}

export default async function Page() {
  const o = await getOverview();
  return (
    <main className="mx-auto max-w-6xl space-y-6 p-6">
      <header className="flex items-baseline justify-between">
        <h1 className="text-2xl font-semibold">CloudBridge — both clouds</h1>
        <p className="text-sm text-muted-foreground">as of {new Date(o.asOf).toLocaleString("en-IN", { timeZone: "Asia/Kolkata" })} IST</p>
      </header>
      <SplitPanel configured={o.configured} observed={o.observed} />
      <section className="grid gap-4 md:grid-cols-2">
        {o.cells.map((c) => (
          <article key={c.cell} className="rounded-lg border p-4">
            <h2 className="font-medium">{c.cell}</h2>
            <dl className="mt-2 grid grid-cols-2 gap-2 text-sm">
              <dt>Availability (1h)</dt>
              <dd>{c.availability === null ? "no measurement yet" : `${(c.availability * 100).toFixed(3)}%`}</dd>
              <dt>p95 latency</dt>
              <dd>{c.p95ms === null ? "no measurement yet" : `${Math.round(c.p95ms)} ms`}</dd>
            </dl>
          </article>
        ))}
      </section>
    </main>
  );
}
```

```tsx
// control-plane/dashboard/components/split-panel.tsx
type Split = { aws: number; gcp: number };

export function SplitPanel({ configured, observed }: { configured: Split; observed: Split | null }) {
  const drift = observed ? Math.abs(observed.aws - configured.aws) : null;
  return (
    <section className="rounded-lg border p-4">
      <h2 className="font-medium">Traffic split — configured vs observed</h2>
      <div className="mt-3 grid grid-cols-2 gap-4 text-sm">
        <div>Configured (Terraform): AWS {configured.aws}% · GCP {configured.gcp}%</div>
        <div>
          Observed (Cloudflare, 5 min):{" "}
          {observed ? `AWS ${observed.aws.toFixed(1)}% · GCP ${observed.gcp.toFixed(1)}%` : "no measurement yet"}
        </div>
      </div>
      {drift !== null && drift > 5 && (
        <p role="alert" className="mt-2 text-sm text-destructive">
          Observed split differs from configured by {drift.toFixed(1)} points — check pool weights vs origin weights and affinity.
        </p>
      )}
    </section>
  );
}
```
Add `/overview` to the FastAPI app: configured = latest `traffic_changes`, observed = `cb:split:observed`, per-cell = `cb:availability:ratio_rate1h` and `cb:latency_p95:5m{service="api-gateway"}`; return `null` for anything not yet measured.
