# FinOps Ledger & Steering — Starter Code

Python 3.14 package `control-plane/cost-collector/` and `control-plane/steering/`. Dependencies (pin in `pyproject.toml`): `psycopg[binary]`, `pyarrow`, `boto3`, `google-cloud-bigquery`, `numpy`, `httpx`.

## Contents
1. Row model + Strategy interface
2. AWS FOCUS adapter (S3 Parquet)
3. GCP FOCUS adapter (BigQuery, parameterised)
4. Idempotent writer
5. OpenCost allocation + Prometheus volume pullers
6. Recommender (fit, constraints, search, PR body)
7. Daily job entrypoint

---

## 1. Row model + interface

```python
# collector/model.py
from __future__ import annotations
from dataclasses import dataclass
from datetime import datetime
from decimal import Decimal
from typing import Iterable, Protocol

@dataclass(frozen=True)
class FocusRow:
    provider_name: str
    billing_account_id: str
    charge_period_start: datetime
    charge_period_end: datetime
    charge_category: str
    service_category: str | None
    service_name: str | None
    resource_id: str | None
    region_id: str | None
    billed_cost: Decimal
    effective_cost: Decimal
    list_cost: Decimal | None
    billing_currency: str
    tags: dict[str, str]

@dataclass(frozen=True)
class Batch:
    source_file: str          # lineage: S3 key@etag or BigQuery job id
    checksum: str
    rows: list[FocusRow]

class CostSource(Protocol):
    """Strategy: one implementation per provider; callers never branch on cloud."""
    provider: str
    def batches(self, since: datetime, until: datetime) -> Iterable[Batch]: ...

TAG_KEYS = ("cb-cell", "cb-service", "cb-env", "cb-cloud")

def normalise_tags(raw: dict | list | None) -> dict[str, str]:
    """AWS exports tags as a map; GCP labels arrive as [{key, value}]. Keep only cb-* keys, lowercase."""
    if raw is None:
        return {}
    items = raw.items() if isinstance(raw, dict) else ((t.get("key"), t.get("value")) for t in raw)
    out = {}
    for k, v in items:
        if not k:
            continue
        k2 = k.lower().replace("_", "-").removeprefix("user:")
        if k2 in TAG_KEYS and v is not None:
            out[k2] = str(v)
    return out
```

## 2. AWS adapter

```python
# collector/aws.py
from __future__ import annotations
import hashlib, io
from datetime import datetime
from decimal import Decimal
import boto3, pyarrow.parquet as pq
from .model import Batch, FocusRow, normalise_tags

class AwsFocusSource:
    provider = "aws"

    def __init__(self, bucket: str, prefix: str, region: str = "ap-south-1"):
        self.s3 = boto3.client("s3", region_name=region)
        self.bucket, self.prefix = bucket, prefix

    def batches(self, since: datetime, until: datetime):
        paginator = self.s3.get_paginator("list_objects_v2")
        for page in paginator.paginate(Bucket=self.bucket, Prefix=self.prefix):
            for obj in page.get("Contents", []):
                if not obj["Key"].endswith(".parquet"):
                    continue
                body = self.s3.get_object(Bucket=self.bucket, Key=obj["Key"])["Body"].read()
                table = pq.read_table(io.BytesIO(body))
                rows = [self._row(r) for r in table.to_pylist()]
                rows = [r for r in rows if since <= r.charge_period_start < until]
                if rows:
                    yield Batch(source_file=f"s3://{self.bucket}/{obj['Key']}@{obj['ETag'].strip('\"')}",
                                checksum=hashlib.sha256(body).hexdigest(), rows=rows)

    @staticmethod
    def _row(r: dict) -> FocusRow:
        # FOCUS column names as exported by AWS Data Exports (FOCUS 1.2 table)
        return FocusRow(
            provider_name=r.get("ProviderName") or "AWS",
            billing_account_id=r["BillingAccountId"],
            charge_period_start=r["ChargePeriodStart"],
            charge_period_end=r["ChargePeriodEnd"],
            charge_category=r["ChargeCategory"],
            service_category=r.get("ServiceCategory"),
            service_name=r.get("ServiceName"),
            resource_id=r.get("ResourceId"),
            region_id=r.get("RegionId"),
            billed_cost=Decimal(str(r["BilledCost"])),
            effective_cost=Decimal(str(r["EffectiveCost"])),
            list_cost=Decimal(str(r["ListCost"])) if r.get("ListCost") is not None else None,
            billing_currency=r["BillingCurrency"],
            tags=normalise_tags(r.get("Tags")),
        )
```
Export files are rewritten during the month as AWS restates charges; the ETag in `source_file` makes each version a distinct batch, and the writer deletes the previous version's rows by key prefix (see §4).

## 3. GCP adapter

```python
# collector/gcp.py
from __future__ import annotations
import hashlib, json, re
from datetime import datetime
from decimal import Decimal
from google.cloud import bigquery
from .model import Batch, FocusRow, normalise_tags

DATASET_RE = re.compile(r"^[\w.-]+$")

FOCUS_SQL = """
SELECT ProviderName, BillingAccountId, ChargePeriodStart, ChargePeriodEnd, ChargeCategory,
       ServiceCategory, ServiceName, ResourceId, RegionId,
       BilledCost, EffectiveCost, ListCost, BillingCurrency, Tags
FROM `{view}`
WHERE ChargePeriodStart >= @start AND ChargePeriodStart < @end
"""

class GcpFocusSource:
    provider = "gcp"

    def __init__(self, project: str, focus_view: str):
        if not DATASET_RE.match(focus_view):
            raise ValueError("focus_view must be project.dataset.view with no special characters")
        self.client, self.view = bigquery.Client(project=project), focus_view

    def batches(self, since: datetime, until: datetime):
        cfg = bigquery.QueryJobConfig(query_parameters=[
            bigquery.ScalarQueryParameter("start", "TIMESTAMP", since),
            bigquery.ScalarQueryParameter("end", "TIMESTAMP", until),
        ])
        job = self.client.query(FOCUS_SQL.format(view=self.view), job_config=cfg)
        rows = [self._row(dict(r)) for r in job.result()]
        digest = hashlib.sha256(json.dumps([r.__dict__ for r in rows], default=str, sort_keys=True).encode()).hexdigest()
        yield Batch(source_file=f"bq://{self.view}/{since:%Y-%m-%d}..{until:%Y-%m-%d}", checksum=digest, rows=rows)

    @staticmethod
    def _row(r: dict) -> FocusRow:
        return FocusRow(
            provider_name=r.get("ProviderName") or "Google Cloud",
            billing_account_id=r["BillingAccountId"],
            charge_period_start=r["ChargePeriodStart"],
            charge_period_end=r["ChargePeriodEnd"],
            charge_category=r["ChargeCategory"],
            service_category=r.get("ServiceCategory"),
            service_name=r.get("ServiceName"),
            resource_id=r.get("ResourceId"),
            region_id=r.get("RegionId"),
            billed_cost=Decimal(str(r["BilledCost"])),
            effective_cost=Decimal(str(r["EffectiveCost"])),
            list_cost=Decimal(str(r["ListCost"])) if r.get("ListCost") is not None else None,
            billing_currency=r["BillingCurrency"],
            tags=normalise_tags(r.get("Tags")),
        )
```
The view name is configuration (validated), the dates are bound parameters — the fix for Rev 1's f-string query. GCP's `source_file` is keyed by date window, so re-running a window replaces it.

## 4. Idempotent writer

```python
# collector/writer.py
import json
import psycopg
from .model import Batch

INSERT = """
INSERT INTO cost_line_items (provider_name, billing_account_id, charge_period_start, charge_period_end,
  charge_category, service_category, service_name, resource_id, region_id, billed_cost, effective_cost,
  list_cost, billing_currency, tags, source_file)
VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s::jsonb,%s)
"""

def write(conn: psycopg.Connection, provider: str, batch: Batch) -> str:
    with conn.transaction():
        prev = conn.execute("SELECT checksum FROM cost_ingestions WHERE source_file = %s", (batch.source_file,)).fetchone()
        if prev and prev[0] == batch.checksum:
            return "unchanged"
        conn.execute("SELECT ensure_cost_partitions()")
        base_key = batch.source_file.split("@", 1)[0]                     # all versions of the same export file
        conn.execute("DELETE FROM cost_line_items WHERE source_file = %s OR source_file LIKE %s",
                     (batch.source_file, base_key + "@%"))
        with conn.cursor() as cur:
            cur.executemany(INSERT, [
                (r.provider_name, r.billing_account_id, r.charge_period_start, r.charge_period_end,
                 r.charge_category, r.service_category, r.service_name, r.resource_id, r.region_id,
                 r.billed_cost, r.effective_cost, r.list_cost, r.billing_currency, json.dumps(r.tags),
                 batch.source_file) for r in batch.rows])
        conn.execute("""
            INSERT INTO cost_ingestions (source_file, provider_name, period_start, row_count, checksum)
            VALUES (%s, %s, %s, %s, %s)
            ON CONFLICT (source_file) DO UPDATE
              SET row_count = EXCLUDED.row_count, checksum = EXCLUDED.checksum, ingested_at = now()
        """, (batch.source_file, provider, min(r.charge_period_start for r in batch.rows).date(),
              len(batch.rows), batch.checksum))
    return "replaced" if prev else "inserted"
```

## 5. Allocation + volumes

```python
# collector/pullers.py
from datetime import date
import httpx

def opencost_allocation(opencost_url: str, cell_id: str, day: date) -> list[tuple]:
    """Namespace/label allocation for one day from a cell's OpenCost API (exposed to the control plane via Cloudflare Access)."""
    r = httpx.get(f"{opencost_url}/allocation/compute", timeout=30, params={
        "window": f"{day.isoformat()}T00:00:00Z,{day.isoformat()}T23:59:59Z",
        "aggregate": "label:app", "accumulate": "true"})
    r.raise_for_status()
    sets = r.json()["data"][0]
    total_cpu = sum(v.get("cpuCoreHours", 0) for v in sets.values()) or 1
    total_mem = sum(v.get("ramByteHours", 0) for v in sets.values()) or 1
    rows = []
    for app, v in sets.items():
        if app.startswith("__") or app not in ("api-gateway", "order-service", "inventory-service"):
            continue
        rows.append((day, cell_id, app, v.get("cpuCoreHours", 0) / total_cpu, v.get("ramByteHours", 0) / total_mem,
                     v.get("totalCost")))
    return rows

def request_volumes(prom_url: str, token: str, day: date) -> list[tuple]:
    """Yesterday's totals per cell/service via increase() at day end — never average rates."""
    end = f"{day.isoformat()}T23:59:59Z"
    def q(expr: str) -> dict:
        r = httpx.get(f"{prom_url}/api/v1/query", params={"query": expr, "time": end},
                      headers={"Authorization": f"Bearer {token}"}, timeout=30)
        r.raise_for_status()
        return {(s["metric"]["cb_cell"], s["metric"]["service"]): float(s["value"][1]) for s in r.json()["data"]["result"]}
    req = q('sum by (cb_cell, service) (increase(http_server_requests_seconds_count{uri!~"/actuator.*"}[1d]))')
    err = q('sum by (cb_cell, service) (increase(http_server_requests_seconds_count{uri!~"/actuator.*",status=~"5.."}[1d]))')
    p95 = q('histogram_quantile(0.95, sum by (cb_cell, service, le) (increase(http_server_requests_seconds_bucket{uri!~"/actuator.*"}[1d]))) * 1000')
    return [(day, cell, svc, int(n), int(err.get((cell, svc), 0)), p95.get((cell, svc))) for (cell, svc), n in req.items()]
```

## 6. Recommender

```python
# steering/recommender.py
from __future__ import annotations
from dataclasses import dataclass, field
from typing import Callable
import numpy as np

@dataclass(frozen=True)
class CellModel:
    name: str
    fixed_inr_day: float
    marginal_inr_per_req: float
    capacity_rps: float
    p95_at: Callable[[float], float]            # traffic share (0..1) → predicted p95 ms
    marginal_se: float = 0.0                    # standard error of the marginal-cost estimate
    observed_max_share: float = 1.0             # highest share this cell carried in the training window
    distinct_shares: int = 1                    # how many different weights the latency fit has actually seen

@dataclass
class Recommendation:
    w_aws: float
    saving_inr_month: float
    binding: str
    reasons: list[str] = field(default_factory=list)

def fit_cost(requests: np.ndarray, cost: np.ndarray) -> tuple[float, float, float]:
    """daily_cost = F + v × requests. Returns (F, v, se_v); F and v clamped to ≥ 0.
    se_v matters: day-to-day traffic variation is what identifies v — with flat traffic the
    estimate is noise, and the recommender must not act on noise."""
    x, y = requests.astype(float), cost.astype(float)
    A = np.vstack([np.ones_like(x), x]).T
    coef, *_ = np.linalg.lstsq(A, y, rcond=None)
    resid = y - A @ coef
    dof = max(len(y) - 2, 1)
    s2 = float(resid @ resid) / dof
    cov = s2 * np.linalg.pinv(A.T @ A)
    return max(float(coef[0]), 0.0), max(float(coef[1]), 0.0), float(np.sqrt(max(cov[1, 1], 0.0)))

def fit_p95(shares: np.ndarray, p95: np.ndarray) -> Callable[[float], float]:
    """Pessimistic latency model over traffic share.
    - average p95 per distinct share (days at the same weight are repeats, not new points)
    - force it non-decreasing (more load never makes latency better) — removes noise-driven negative slopes
    - beyond the highest observed share, extrapolate with 1.5 × the last non-negative slope."""
    uniq = np.unique(np.round(shares, 3))
    xs = uniq
    ys = np.maximum.accumulate(np.array([p95[np.isclose(np.round(shares, 3), u)].mean() for u in uniq]))
    slope = max((ys[-1] - ys[-2]) / (xs[-1] - xs[-2]), 0.0) if len(xs) > 1 else 0.0
    def f(s: float) -> float:
        if s <= xs[-1]:
            return float(np.interp(s, xs, ys))
        return float(ys[-1] + 1.5 * slope * (s - xs[-1]))
    return f

def recommend(aws: CellModel, gcp: CellModel, total_req_day: float, peak_rps: float, current_aws: float,
              floor: float = 0.10, max_step: float = 0.20, p95_slo_ms: float = 300.0, headroom: float = 1.2,
              min_saving_inr_month: float = 500.0, min_saving_pct: float = 0.02,
              max_extrapolation: float = 0.10, z: float = 2.0,
              last_direction: int = 0, reversal_factor: float = 2.0) -> Recommendation:
    """last_direction: +1 if the previous accepted change raised w_aws, -1 if it lowered it, 0 if none."""
    # Big steps only once the latency fit covers >= 3 distinct shares per cell — big jumps on a thin fit cause whiplash.
    if min(aws.distinct_shares, gcp.distinct_shares) < 3:
        max_step = min(max_step, 0.10)
    def var_cost(w: float) -> float:
        return total_req_day * (w * aws.marginal_inr_per_req + (1 - w) * gcp.marginal_inr_per_req)

    def violation(w: float) -> str | None:
        if w < floor - 1e-9 or w > 1 - floor + 1e-9:
            return "warm floor"
        if abs(w - current_aws) > max_step + 1e-9:
            return "max weekly step"
        if w * peak_rps > aws.capacity_rps / headroom or (1 - w) * peak_rps > gcp.capacity_rps / headroom:
            return "capacity headroom"
        if w > aws.observed_max_share + max_extrapolation or (1 - w) > gcp.observed_max_share + max_extrapolation:
            return "outside observed range"           # never trust the latency model far from data
        if aws.p95_at(w) > p95_slo_ms or gcp.p95_at(1 - w) > p95_slo_ms:
            return "latency SLO"
        return None

    grid = [float(w) for w in np.round(np.arange(floor, 1 - floor + 1e-9, 0.01), 2)]

    # Safety first: if today's weight already breaks a constraint (e.g. latency observed above SLO),
    # move to the nearest feasible weight regardless of cost, significance or hysteresis.
    now_violation = violation(current_aws) if abs(current_aws - round(current_aws, 2)) < 1e-9 else None
    if now_violation and now_violation != "max weekly step":
        safe = [w for w in grid if violation(w) is None]
        if not safe:
            return Recommendation(current_aws, 0.0, "infeasible", ["no weight satisfies all constraints — investigate capacity"])
        w_safe = min(safe, key=lambda w: abs(w - current_aws))
        return Recommendation(w_safe, 0.0, f"safety: current weight violates {now_violation}", ["moved for safety, not cost"])

    # Act only on a statistically meaningful cost difference — otherwise noise moves traffic.
    diff = abs(aws.marginal_inr_per_req - gcp.marginal_inr_per_req)
    se = float(np.hypot(aws.marginal_se, gcp.marginal_se))
    if diff <= z * se:
        return Recommendation(current_aws, 0.0, "not significant",
                              [f"marginal-cost difference {diff * 1000:.4f} ₹/1k req is within {z}σ ({z * se * 1000:.4f})"])

    base = var_cost(current_aws)
    feasible = [w for w in grid if violation(w) is None]
    if not feasible:
        return Recommendation(current_aws, 0.0, "infeasible", ["no weight satisfies all constraints — investigate capacity"])
    best = min(feasible, key=lambda w: (var_cost(w), abs(w - current_aws)))   # tie → smallest move

    # The binding constraint is whatever stops one more step in the cheaper direction.
    direction = 1 if aws.marginal_inr_per_req < gcp.marginal_inr_per_req else -1
    binding = violation(round(best + 0.01 * direction, 2)) or "none (cost-optimal)"

    saving = (base - var_cost(best)) * 30
    reasons = [f"marginal ₹/1k req — aws {aws.marginal_inr_per_req * 1000:.4f}, gcp {gcp.marginal_inr_per_req * 1000:.4f}"]
    threshold = max(min_saving_inr_month, min_saving_pct * base * 30)
    direction_now = (best > current_aws) - (best < current_aws)
    if last_direction and direction_now == -last_direction:
        threshold *= reversal_factor                   # reversing last week's move must clear a higher bar
        reasons.append(f"reversal of last week's direction — threshold ×{reversal_factor}")
    if saving < threshold:
        return Recommendation(current_aws, 0.0, "hysteresis", reasons + ["saving below threshold — no change proposed"])
    return Recommendation(best, saving, binding, reasons)

def pr_body(rec: Recommendation, current: dict, backtest: dict, data_as_of: str) -> str:
    proposed = {"aws": round(rec.w_aws * 100), "gcp": 100 - round(rec.w_aws * 100)}
    return "\n".join([
        f"**Proposed weights:** aws {current['aws']} → {proposed['aws']}, gcp {current['gcp']} → {proposed['gcp']}",
        f"**Estimated saving (variable cost only):** ₹{rec.saving_inr_month:,.0f}/month",
        f"**Binding constraint:** {rec.binding}",
        f"**Backtest ({backtest['days']} days):** {backtest['slo_violations']} SLO violations; "
        f"saving vs static 70/30: {backtest['saving_vs_static_pct']:.1f}%",
        f"**Billing data as of:** {data_as_of}",
        "", *[f"- {r}" for r in rec.reasons],
        "", "Fixed costs (control planes, NAT) are unchanged by a weight shift and are excluded from the saving.",
    ])
```

## 6b. Weekly recommender job (supplies last_direction — without it the reversal guard never fires)

```python
# steering/weekly.py
def last_direction(conn) -> int:
    """Direction of the last *recommender* change. Drills, evacuations and manual edits don't count."""
    rows = conn.execute("""SELECT (weights->>'aws')::int FROM traffic_changes
                            WHERE source = 'recommender' ORDER BY applied_at DESC LIMIT 2""").fetchall()
    if len(rows) < 2:
        return 0
    return (rows[0][0] > rows[1][0]) - (rows[0][0] < rows[1][0])
```
Build each `CellModel` with `marginal_se` from `fit_cost`, `observed_max_share` and `distinct_shares = len(np.unique(np.round(shares, 2)))` from the last 28 days, then call `recommend(..., last_direction=last_direction(conn))`.

## 7. Daily job

```python
# collector/main.py
import os
from datetime import datetime, timedelta, timezone
import psycopg
from .aws import AwsFocusSource
from .gcp import GcpFocusSource
from .writer import write

def main() -> None:
    until = datetime.now(timezone.utc).replace(hour=0, minute=0, second=0, microsecond=0)
    since = until - timedelta(days=int(os.environ.get("COST_LOOKBACK_DAYS", "35")))   # catch restatements
    sources = [AwsFocusSource(os.environ["CB_AWS_FOCUS_BUCKET"], "focus/"),
               GcpFocusSource(os.environ["GCP_PROJECT_ID"], os.environ["CB_GCP_FOCUS_VIEW"])]
    with psycopg.connect(os.environ["DATABASE_URL"]) as conn:
        for src in sources:
            for batch in src.batches(since, until):
                print(src.provider, batch.source_file, write(conn, src.provider, batch), len(batch.rows))

if __name__ == "__main__":
    main()
```
Runs as a Kubernetes CronJob in the control plane at 06:00 IST, then the allocation and volume pullers, then `ensure_cost_partitions()`. The recommender runs weekly (Monday 10:00 IST) only if Q4 freshness ≤ 72 h and Q5 has ≥ 21 days.
