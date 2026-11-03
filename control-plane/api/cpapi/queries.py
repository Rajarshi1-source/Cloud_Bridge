"""What the dashboard reads. A panel with no rows has nothing to show: no value here defaults to 0."""
from __future__ import annotations

# Cost per 1,000 requests. Direct cost first, shared cost by the day's measured share, unit cost last.
# Requests count only on days the ledger has that cell's bill: two days of cost over thirty days of requests
# would look fifteen times cheaper. A service with no cost has no row, because no bill isn't a cost of zero.
COST_PER_1K = """
WITH params AS (SELECT current_date - 30 AS since, current_date AS until),
usage_rows AS (
  SELECT c.cb_cell AS cell_id, c.cb_service AS service, (c.charge_period_start AT TIME ZONE 'UTC')::date AS day,
         c.billing_currency AS currency, c.effective_cost, c.list_cost
  FROM cost_line_items c, params p
  WHERE c.charge_category = 'Usage' AND c.cb_cell IS NOT NULL
    AND c.charge_period_start >= p.since AND c.charge_period_start < p.until
),
direct AS (
  SELECT cell_id, service, currency, sum(effective_cost) AS cost, sum(list_cost) AS list
  FROM usage_rows WHERE service IS NOT NULL GROUP BY 1, 2, 3
),
shared_daily AS (
  SELECT cell_id, day, currency, sum(effective_cost) AS cost, sum(list_cost) AS list
  FROM usage_rows WHERE service IS NULL GROUP BY 1, 2, 3
),
shared AS (
  SELECT s.cell_id, a.service, s.currency, sum(s.cost * a.cpu_share) AS cost, sum(s.list * a.cpu_share) AS list
  FROM shared_daily s JOIN allocation_daily a ON a.cell_id = s.cell_id AND a.day = s.day
  GROUP BY 1, 2, 3
),
costs AS (
  SELECT cell_id, service, currency, sum(cost) AS cost, sum(list) AS list
  FROM (SELECT * FROM direct UNION ALL SELECT * FROM shared) both_kinds GROUP BY 1, 2, 3
),
billed_days AS (SELECT DISTINCT cell_id, day FROM usage_rows),
vol AS (
  SELECT r.cell_id, r.service, sum(r.requests) AS req
  FROM request_volume_daily r JOIN billed_days b ON b.cell_id = r.cell_id AND b.day = r.day
  GROUP BY 1, 2
)
SELECT c.cell_id, c.service, c.currency, round(c.cost, 2)::float AS effective_cost, round(c.list, 2)::float AS list_cost,
       v.req::bigint AS requests, round(c.cost / nullif(v.req, 0) * 1000, 6)::float AS cost_per_1k
FROM costs c LEFT JOIN vol v USING (cell_id, service)
ORDER BY c.service, c.cell_id, c.currency
"""

# On a cell, with no share to divide it by: left out of cost_per_1k, so it has to be shown beside it.
SHARED_WITHOUT_SHARE = """
SELECT c.cb_cell AS cell_id, c.billing_currency AS currency, round(sum(c.effective_cost), 2)::float AS cost
FROM cost_line_items c
WHERE c.charge_category = 'Usage' AND c.cb_cell IS NOT NULL AND c.cb_service IS NULL
  AND c.charge_period_start >= current_date - 30 AND c.charge_period_start < current_date
  AND NOT EXISTS (SELECT 1 FROM allocation_daily a
                  WHERE a.cell_id = c.cb_cell AND a.day = (c.charge_period_start AT TIME ZONE 'UTC')::date)
GROUP BY 1, 2 ORDER BY 1, 2
"""

UNALLOCATED = """
SELECT provider_name, service_name, billing_currency AS currency, round(sum(effective_cost), 2)::float AS cost
FROM cost_line_items
WHERE charge_category = 'Usage' AND cb_cell IS NULL
  AND charge_period_start >= current_date - 30 AND charge_period_start < current_date
GROUP BY 1, 2, 3 ORDER BY cost DESC LIMIT 20
"""

# Credits and the like never enter a unit cost; they are reported beside it.
NOT_USAGE = """
SELECT cb_cell AS cell_id, charge_category, billing_currency AS currency, round(sum(effective_cost), 2)::float AS cost
FROM cost_line_items
WHERE charge_category <> 'Usage'
  AND charge_period_start >= current_date - 30 AND charge_period_start < current_date
GROUP BY 1, 2, 3 ORDER BY 1, 2, 3
"""

FRESHNESS = """
SELECT provider_name, max(period_start)::text AS latest_day, max(ingested_at) AS ingested_at
FROM cost_ingestions GROUP BY 1 ORDER BY 1
"""

# The older provider's: one fresh export must not hide the other going stale. No gauge until both have
# delivered, so CostDataStale's absent() keeps firing.
BILLING_LATEST = """
SELECT extract(epoch FROM min(latest))::float FROM (
  SELECT max(period_start)::timestamptz AS latest FROM cost_ingestions GROUP BY provider_name
) per_provider HAVING count(*) = 2
"""

LAST_DRILL = """
SELECT extract(epoch FROM max(finished_at))::float FROM drills WHERE outcome = 'completed'
"""


def rows(conn, sql: str, *params) -> list[dict]:
    cursor = conn.execute(sql, params or None)
    names = [column.name for column in cursor.description]
    return [dict(zip(names, row)) for row in cursor.fetchall()]


def cost(conn) -> dict:
    return {
        "per_service": rows(conn, COST_PER_1K),
        "shared_without_share": rows(conn, SHARED_WITHOUT_SHARE),
        "unallocated": rows(conn, UNALLOCATED),
        "not_usage": rows(conn, NOT_USAGE),
        "freshness": rows(conn, FRESHNESS),
    }


def latest_parity(conn, env: str) -> dict | None:
    found = rows(conn, """SELECT id, env, score::float AS score, passed, trigger, commit_sha, taken_at
                          FROM parity_snapshots WHERE env = %s ORDER BY taken_at DESC LIMIT 1""", env)
    return found[0] if found else None


def parity(conn, env: str) -> dict:
    latest = latest_parity(conn, env)
    if latest is None:
        return {"env": env, "latest": None, "findings": [], "trend": [], "expiring": []}
    findings = rows(conn, """SELECT check_id, weight::float AS weight, cell_values, status, note, exception_expires
                             FROM parity_findings WHERE snapshot_id = %s ORDER BY weight DESC, check_id""", latest["id"])
    trend = rows(conn, """SELECT score::float AS score, passed, taken_at FROM parity_snapshots
                          WHERE env = %s ORDER BY taken_at DESC LIMIT 60""", env)
    return {"env": env, "latest": latest, "findings": findings, "trend": trend[::-1],
            "expiring": [f for f in findings if f["exception_expires"] is not None
                         and (f["exception_expires"] - latest["taken_at"].date()).days <= 7]}
