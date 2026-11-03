#!/usr/bin/env python3
"""Generates the five provisioned dashboards, so every panel gets the same rules:

  - each dashboard answers one question, and each panel's description says how fresh its data is
  - a panel with no data says "no measurement yet", never a placeholder number

    python3 observability/grafana/build_dashboards.py          # write dashboards/*.json
    python3 observability/grafana/build_dashboards.py --check  # fail if they differ from this file
"""
import json
import pathlib
import sys

OUT = pathlib.Path(__file__).parent / "dashboards"
PROM = {"type": "prometheus", "uid": "prometheus"}
CP = {"type": "grafana-postgresql-datasource", "uid": "controlplane"}
NO_DATA = "no measurement yet"
LIVE = "Live: scraped every 15 s, then a 5 minute rate window."
LEDGER = "From the control-plane ledger; see the 'billing data as of' panel for how old it is."


def prom(expr, legend="__auto", instant=False):
    return {"datasource": PROM, "expr": expr, "legendFormat": legend, "instant": instant, "range": not instant, "refId": "A"}


def sql(query, fmt="table"):
    return {"datasource": CP, "rawSql": " ".join(query.split()), "format": fmt, "editorMode": "code", "refId": "A"}


def panel(kind, title, target, width, height, description, unit=None, **options):
    defaults = {"noValue": NO_DATA}
    if unit:
        defaults["unit"] = unit
    for key in ("min", "max", "decimals", "thresholds"):
        if key in options:
            defaults[key] = options.pop(key)
    return {
        "type": kind,
        "title": title,
        "description": description,
        "datasource": target["datasource"],
        "targets": [target],
        "fieldConfig": {"defaults": defaults, "overrides": []},
        "options": options,
        "_w": width,
        "_h": height,
    }


def as_of(table, column, where=""):
    """A stat panel shows numbers only, so a timestamp goes out as epoch milliseconds for dateTimeAsIso."""
    return sql(f"SELECT extract(epoch FROM max({column})) * 1000 AS at FROM {table} {where}".rstrip())


def stat(title, target, width, description, unit=None, **options):
    if unit == "dateTimeAsIso":
        options.setdefault("thresholds", thresholds(("green", None)))  # a date isn't good or bad by its size
    return panel("stat", title, target, width, 4, description, unit, reduceOptions={"calcs": ["lastNotNull"]}, **options)


def series(title, target, width, description, unit=None, **options):
    return panel("timeseries", title, target, width, 8, description, unit, **options)


def table(title, target, width, description, height=8):
    return panel("table", title, target, width, height, description)


def thresholds(*steps):
    return {"mode": "absolute", "steps": [{"color": c, "value": v} for c, v in steps]}


def dashboard(uid, title, description, panels):
    x, y, row_height, placed = 0, 0, 0, []
    for number, p in enumerate(panels, start=1):
        width, height = p.pop("_w"), p.pop("_h")
        if x + width > 24:
            x, y, row_height = 0, y + row_height, 0
        p["id"] = number
        p["gridPos"] = {"x": x, "y": y, "w": width, "h": height}
        x += width
        row_height = max(row_height, height)
        placed.append(p)
    return {
        "uid": uid,
        "title": title,
        "description": description,
        "tags": ["cloudbridge"],
        "schemaVersion": 41,
        "editable": False,
        "refresh": "30s",
        "time": {"from": "now-1h", "to": "now"},
        "timezone": "browser",
        "panels": placed,
    }


def overview():
    return dashboard("cb-overview", "Multi-cloud overview", "Are both cells healthy, and is the split what I configured?", [
        stat("Configured AWS share", sql("""SELECT applied_at AS "time", (weights->>'aws')::float / 100 AS aws
             FROM traffic_changes ORDER BY applied_at DESC LIMIT 1""", "time_series"), 6,
             "The latest row of traffic_changes: what Terraform was told, updated when a weight changes.", "percentunit"),
        stat("Observed AWS share", prom('cb:split:observed{cb_cell=~"cb-aws-.*"}', "observed", True), 6,
             "The AWS cell's share of gateway requests as the origins saw them. " + LIVE, "percentunit"),
        stat("Configured as of", as_of("traffic_changes", "applied_at"), 6,
             "When the configured weights last changed.", "dateTimeAsIso"),
        stat("Probe through the edge", prom('min(probe_success{job="blackbox-edge"})', "edge", True), 6,
             "1 when the last probe through the edge got a 200 with X-CB-Cell. Scraped every 30 s.",
             thresholds=thresholds(("red", None), ("green", 1))),
        series("Observed split", prom("cb:split:observed", "{{cb_cell}}"), 12,
               "Each cell's share of gateway requests. " + LIVE, "percentunit", min=0, max=1),
        series("Requests per second", prom('cb:requests:rate5m{service="api-gateway"}', "{{cb_cell}}"), 12,
               "Gateway requests per cell, health checks excluded. " + LIVE, "reqps"),
        series("Availability, 1 hour", prom("cb:availability:ratio_rate1h", "{{cb_cell}}"), 8,
               "1 minus the share of gateway 5xx over the last hour. SLO: 99.5%.", "percentunit", max=1),
        series("Error ratio, 5 minutes", prom("cb:error_ratio:rate5m", "{{cb_cell}}"), 8,
               "The share of gateway 5xx. " + LIVE, "percentunit", min=0),
        series("Gateway p95 latency", prom('cb:latency_p95:5m{service="api-gateway"}', "{{cb_cell}}"), 8,
               LIVE, "s", min=0),
        series("Latency by service", prom("cb:latency_p95:5m", "{{cb_cell}} {{service}}"), 12, "p95 of each service. " + LIVE, "s", min=0),
        series("Age of the newest sample", prom('time() - max by (cb_cell) (timestamp(up{job="apps"}))', "{{cb_cell}}"), 12,
               "How old each cell's newest pushed sample is. Above a minute, its agent has stopped or can't reach the receiver.", "s", min=0),
    ])


def cost():
    q1 = """WITH params AS (SELECT current_date - 30 AS since, current_date AS until),
      direct AS (SELECT c.cb_cell AS cell_id, c.cb_service AS service, sum(c.effective_cost) AS cost
        FROM cost_line_items c, params p WHERE c.charge_category = 'Usage' AND c.cb_service IS NOT NULL
        AND c.charge_period_start >= p.since AND c.charge_period_start < p.until GROUP BY 1, 2),
      shared_daily AS (SELECT c.cb_cell AS cell_id, c.charge_period_start::date AS day, sum(c.effective_cost) AS cost
        FROM cost_line_items c, params p WHERE c.charge_category = 'Usage' AND c.cb_cell IS NOT NULL AND c.cb_service IS NULL
        AND c.charge_period_start >= p.since AND c.charge_period_start < p.until GROUP BY 1, 2),
      shared AS (SELECT s.cell_id, a.service, sum(s.cost * a.cpu_share) AS cost
        FROM shared_daily s JOIN allocation_daily a ON a.cell_id = s.cell_id AND a.day = s.day GROUP BY 1, 2),
      vol AS (SELECT cell_id, service, sum(requests) AS req FROM request_volume_daily, params p
        WHERE day >= p.since AND day < p.until GROUP BY 1, 2)
      SELECT v.cell_id, v.service, round(coalesce(d.cost, 0) + coalesce(s.cost, 0), 2) AS cost_30d, v.req AS requests_30d,
        round((coalesce(d.cost, 0) + coalesce(s.cost, 0)) / nullif(v.req, 0) * 1000, 6) AS cost_per_1k_req
      FROM vol v LEFT JOIN direct d USING (cell_id, service) LEFT JOIN shared s USING (cell_id, service)
      ORDER BY v.service, v.cell_id"""
    return dashboard("cb-cost", "Cost per request", "Which cloud is cheaper per unit of work?", [
        stat("Billing data as of", as_of("cost_ingestions", "period_start"), 8,
             "The newest billing day ingested. Bills arrive about a day late; older than 72 hours fires CostDataStale.", "dateTimeAsIso"),
        stat("Last ingestion", as_of("cost_ingestions", "ingested_at"), 8, "When a billing file was last ingested.", "dateTimeAsIso"),
        stat("Unallocated cost, 30 days", sql("""SELECT round(sum(effective_cost), 2) AS cost FROM cost_line_items
             WHERE charge_category = 'Usage' AND cb_cell IS NULL AND charge_period_start >= current_date - 30"""), 8,
             "Cost with no cb-cell tag: shown, never spread silently. " + LEDGER),
        table("Cost per 1,000 requests", sql(q1), 24, "Directly tagged cost first, shared cost by measured share, credits excluded. " + LEDGER),
        table("OpenCost estimate against the bill", sql("""WITH bill AS (SELECT cb_cell AS cell_id, charge_period_start::date AS day,
              sum(effective_cost) AS billed FROM cost_line_items WHERE charge_category = 'Usage' AND cb_cell IS NOT NULL GROUP BY 1, 2),
              est AS (SELECT cell_id, day, sum(opencost_estimate) AS estimated FROM allocation_daily GROUP BY 1, 2)
              SELECT e.day, e.cell_id, round(e.estimated, 2) AS estimated, round(b.billed, 2) AS billed,
              round(100 * (e.estimated / nullif(b.billed, 0) - 1), 2) AS error_pct
              FROM est e JOIN bill b USING (cell_id, day) ORDER BY e.day DESC, e.cell_id LIMIT 30"""), 12,
              "Reconciliation error per cell per day. " + LEDGER),
        table("Unallocated cost by service", sql("""SELECT provider_name, service_name, round(sum(effective_cost), 2) AS cost
              FROM cost_line_items WHERE charge_category = 'Usage' AND cb_cell IS NULL AND charge_period_start >= current_date - 30
              GROUP BY 1, 2 ORDER BY cost DESC LIMIT 20"""), 12, LEDGER),
    ])


def parity():
    return dashboard("cb-parity", "Parity", "Are the cells still interchangeable?", [
        stat("Latest parity score", sql("""SELECT taken_at AS "time", score FROM parity_snapshots ORDER BY taken_at DESC LIMIT 1""", "time_series"), 12,
             "The newest snapshot's score: 1.0 means every check matched. Unknown never counts as a match.",
             min=0, max=1, thresholds=thresholds(("red", None), ("green", 1))),
        stat("Snapshot as of", as_of("parity_snapshots", "taken_at"), 12, "When the parity check last ran.", "dateTimeAsIso"),
        series("Score over time", sql("""SELECT taken_at AS "time", env AS metric, score FROM parity_snapshots
               WHERE $__timeFilter(taken_at) ORDER BY 1""", "time_series"), 24, "One point per parity run.", min=0, max=1),
        table("Current divergences", sql("""SELECT DISTINCT ON (s.env, f.check_id) s.env, f.check_id, f.status, f.cell_values, s.taken_at
              FROM parity_findings f JOIN parity_snapshots s ON s.id = f.snapshot_id
              WHERE f.status IN ('diverged', 'unknown') AND s.taken_at > now() - interval '2 days'
              ORDER BY s.env, f.check_id, s.taken_at DESC"""), 12, "Checks that diverged or couldn't be read in the last two days; taken_at is the snapshot's time."),
        table("Exceptions expiring within 7 days", sql("""SELECT s.env, f.check_id, f.exception_expires
              FROM parity_findings f JOIN parity_snapshots s ON s.id = f.snapshot_id
              WHERE f.status = 'excepted' AND f.exception_expires <= current_date + 7 AND s.taken_at > now() - interval '1 day'"""), 12,
              "From the last day's snapshots. An expired exception fails the check."),
    ])


def drills():
    return dashboard("cb-drills", "Drills", "Can the smaller cell take everything, and how fast?", [
        stat("Last successful drill", as_of("drills", "finished_at", "WHERE outcome = 'completed'"), 8,
             "Older than 14 days, or none at all, fires ExitPlanEvidenceStale.", "dateTimeAsIso"),
        stat("Latest shift time", sql("""SELECT shift_seconds FROM drills WHERE outcome = 'completed' ORDER BY finished_at DESC LIMIT 1"""), 8,
             "Measured by the newest completed drill.", "s"),
        stat("Latest capacity ratio", sql("""SELECT capacity_ratio_after_prewarm FROM drills WHERE outcome = 'completed' ORDER BY finished_at DESC LIMIT 1"""), 8,
             "Capacity after pre-warm, against peak traffic. Below 1.2 the evacuation refuses to start."),
        table("Drill history", sql("""SELECT started_at::date AS day, from_cell, to_cell, mode, outcome, capacity_ratio,
              capacity_ratio_after_prewarm, prewarm_seconds, shift_seconds, errors_during, burn_rate_max, report_path
              FROM drills ORDER BY started_at DESC LIMIT 20"""), 24, "The exit-plan evidence: every number comes from a run; the day column dates it."),
        table("Steps of the latest drill", sql("""SELECT seq, at, weights, burn_rate, p95_ms, decision FROM drill_steps
              WHERE drill_id = (SELECT id FROM drills ORDER BY started_at DESC LIMIT 1) ORDER BY seq"""), 12, "Weights, burn and p95 at each step; at is when it was recorded."),
        series("Shift time trend", sql("""SELECT finished_at AS "time", from_cell AS metric, shift_seconds FROM drills
               WHERE outcome = 'completed' AND $__timeFilter(finished_at) ORDER BY 1""", "time_series"), 12, "One point per completed drill.", "s", min=0),
    ])


def delivery():
    return dashboard("cb-delivery", "Delivery", "Is delivery healthy?", [
        series("Argo CD syncs", prom("sum by (cb_cell, phase) (increase(argocd_app_sync_total[1h]))", "{{cb_cell}} {{phase}}"), 12,
               "Syncs per hour by result, pushed by each cell's agent every 15 s.", "short", min=0),
        series("Applications out of sync or unhealthy", prom('sum by (cb_cell) (argocd_app_info{sync_status!="Synced"}) or sum by (cb_cell) (argocd_app_info{health_status!="Healthy"})', "{{cb_cell}}"), 12,
               "Live from each cell's Argo CD.", "short", min=0),
        series("Rollouts by phase", prom("sum by (cb_cell, phase) (rollout_info{phase!=\"Healthy\"})", "{{cb_cell}} {{phase}}"), 12,
               "Rollouts that aren't Healthy. Live from each cell's Argo Rollouts.", "short", min=0),
        table("Latest release per cell", sql("""SELECT DISTINCT ON (cell_id) cell_id, commit_sha, status, started_at FROM deployments
             WHERE kind = 'release' ORDER BY cell_id, started_at DESC"""), 12, "From the deployments table; started_at dates it."),
        table("Deploy frequency, 30 days", sql("""SELECT cell_id, kind, count(*) AS deployments,
              count(*) FILTER (WHERE status = 'rolled_back') AS rolled_back,
              round(100.0 * count(*) FILTER (WHERE status IN ('failed', 'rolled_back')) / count(*), 1) AS change_failure_pct,
              max(started_at) AS latest FROM deployments WHERE started_at > now() - interval '30 days' GROUP BY 1, 2 ORDER BY 1, 2"""), 12,
              "Change-failure rate counts failed and rolled-back deployments; latest dates the row."),
        table("Lead time, commit to each cell", sql("""SELECT commit_sha, min(started_at) AS first_cell, max(finished_at) AS last_cell,
              max(finished_at) - min(started_at) AS lead_time FROM deployments WHERE kind = 'release' AND status = 'applied'
              GROUP BY 1 ORDER BY first_cell DESC LIMIT 20"""), 12, "From first cell (canary ring) to last (main ring)."),
    ])


DASHBOARDS = {"overview": overview, "cost": cost, "parity": parity, "drills": drills, "delivery": delivery}


def main() -> None:
    OUT.mkdir(exist_ok=True)
    stale = []
    for name, build in DASHBOARDS.items():
        text = json.dumps(build(), indent=2, sort_keys=True) + "\n"
        path = OUT / f"{name}.json"
        if "--check" in sys.argv:
            if not path.exists() or path.read_text(encoding="utf-8") != text:
                stale.append(path.name)
        else:
            path.write_text(text, encoding="utf-8", newline="\n")
    if stale:
        sys.exit(f"out of date, run build_dashboards.py: {', '.join(stale)}")
    print(f"dashboards: {len(DASHBOARDS)} {'match' if '--check' in sys.argv else 'written'}")


if __name__ == "__main__":
    main()
