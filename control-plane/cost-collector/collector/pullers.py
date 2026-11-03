"""The two inputs of a unit cost that aren't on the bill: how many requests, and each service's share."""
from __future__ import annotations

import json
import math
import urllib.parse
import urllib.request
from datetime import date, datetime, timedelta, timezone

SERVICES = ("api-gateway", "order-service", "inventory-service")
# As cb:requests:rate5m counts them: the monitor's probes and scrapes aren't work done for a user.
SELECTOR = 'uri!~"/actuator.*|/healthz.*"'


def _get_json(url: str, params: dict, headers: dict | None = None) -> dict:
    request = urllib.request.Request(f"{url}?{urllib.parse.urlencode(params)}", headers=headers or {})
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def _number(text: str) -> float | None:
    value = float(text)
    return None if math.isnan(value) or math.isinf(value) else value


def request_volumes(prom_url: str, day: date, known_cells: set[str], query=_get_json) -> list[tuple]:
    """One UTC day's totals per cell and service, with increase() at the day's end. Never averaged rates."""
    at = datetime(day.year, day.month, day.day, tzinfo=timezone.utc) + timedelta(days=1)

    def run(expr: str) -> dict:
        answer = query(f"{prom_url}/api/v1/query", {"query": expr, "time": at.isoformat()})
        return {(s["metric"]["cb_cell"], s["metric"]["service"]): _number(s["value"][1]) for s in answer["data"]["result"]}

    totals = run(f"sum by (cb_cell, service) (increase(http_server_requests_seconds_count{{{SELECTOR}}}[1d]))")
    errors = run(f'sum by (cb_cell, service) (increase(http_server_requests_seconds_count{{{SELECTOR},status=~"5.."}}[1d]))')
    p95 = run(f"histogram_quantile(0.95, sum by (cb_cell, service, le) (increase(http_server_requests_seconds_bucket{{{SELECTOR}}}[1d]))) * 1000")
    return [(day, cell, service, int(count), int(errors.get((cell, service)) or 0), p95.get((cell, service)))
            for (cell, service), count in totals.items()
            if count is not None and cell in known_cells and service in SERVICES]


def opencost_allocation(opencost_url: str, cell: str, day: date, query=_get_json) -> list[tuple]:
    """Each service's share of a cell's CPU and memory that day, from the cell's OpenCost API."""
    answer = query(f"{opencost_url}/allocation/compute", {
        "window": f"{day.isoformat()}T00:00:00Z,{(day + timedelta(days=1)).isoformat()}T00:00:00Z",
        "aggregate": "label:app", "accumulate": "true"})
    allocations = answer["data"][0] if answer.get("data") else {}
    cpu_total = sum(v.get("cpuCoreHours", 0) for v in allocations.values())
    memory_total = sum(v.get("ramByteHours", 0) for v in allocations.values())
    if not cpu_total or not memory_total:
        return []  # no share is better than a made-up one: the ledger shows the cost as unallocated
    return [(day, cell, app, v.get("cpuCoreHours", 0) / cpu_total, v.get("ramByteHours", 0) / memory_total, v.get("totalCost"))
            for app, v in allocations.items() if app in SERVICES]
