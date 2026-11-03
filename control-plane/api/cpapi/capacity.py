"""The one place capacity is computed, so the playbook, the recommender and the dashboard agree.

    capacity_rps(cell) = min over services( hpa_max x per_pod_rps / fanout )

Per-pod RPS and fanout are what k6 measured on this cell (gitops/cells/<cell>/capacity.yaml). HPA max is
what Git deploys, the chart's value unless the cell overrides it: no cell runs kube-state-metrics, and
Argo CD keeps the live object equal to Git. Anything not measured raises: a guessed capacity is how an
evacuation cascades.
"""
from __future__ import annotations

import math
import os
import pathlib

import yaml

SERVICES = ("api-gateway", "order-service", "inventory-service")


class NotMeasured(Exception):
    pass


def _yaml(path: pathlib.Path) -> dict:
    return yaml.safe_load(path.read_text(encoding="utf-8")) or {}


def _cell_dir(repo: pathlib.Path, cell: str) -> pathlib.Path:
    """The cell's directory. The name comes from a URL, so it is never trusted to stay under gitops/cells."""
    base = os.path.normpath(repo / "gitops" / "cells")
    path = os.path.normpath(os.path.join(base, cell))
    if not path.startswith(base + os.sep):
        raise NotMeasured(f"{cell!r} is not a cell")
    return pathlib.Path(path)


def measured(repo: pathlib.Path, cell: str) -> dict:
    path = _cell_dir(repo, cell) / "capacity.yaml"
    if not path.exists():
        raise NotMeasured(f"{cell} has no capacity.yaml: its capacity was never measured")
    return _yaml(path)


def hpa_max(repo: pathlib.Path, cell: str, service: str) -> int:
    chart = _yaml(repo / "gitops" / "charts" / service / "values.yaml")
    values = _cell_dir(repo, cell) / "values.yaml"
    override = (_yaml(values).get("replicas") or {}).get("max") if values.exists() else None
    return int(override if override is not None else chart["replicas"]["max"])


def per_service(cap: dict, maxima: dict[str, int], current: dict[str, int]) -> list[dict]:
    rps, fanout = cap.get("perPodRps") or {}, {"api-gateway": 1, **(cap.get("fanout") or {})}
    rows = []
    for service in SERVICES:
        per_pod, out = rps.get(service), fanout.get(service)
        if not per_pod or not out:  # zero is what an unmeasured template holds
            raise NotMeasured(f"{service}: per-pod RPS or fanout not measured, refusing to guess")
        running = current.get(service)
        rows.append({
            "service": service, "hpa_max": maxima[service], "current": running,
            "per_pod_rps": per_pod, "fanout": out,
            "capacity_rps": maxima[service] * per_pod / out,
            "capacity_rps_at_current": running * per_pod / out if running is not None else None,
        })
    return rows


def summary(cell: str, cap: dict, rows: list[dict], peak_rps: float | None) -> dict:
    if not peak_rps:
        raise NotMeasured("no traffic history: the capacity ratio is undefined")
    now = [r["capacity_rps_at_current"] for r in rows]
    return {
        "cell": cell, "peak_rps_7d": peak_rps,
        "capacity_rps": min(r["capacity_rps"] for r in rows),
        "capacity_ratio": min(r["capacity_rps"] for r in rows) / peak_rps,
        "capacity_ratio_at_current_replicas": None if None in now else min(now) / peak_rps,
        "per_service": rows,
        "measured_at": cap.get("measuredAt"),
    }


def evacuation_plan(summary_: dict, headroom: float) -> dict:
    """Replicas to pre-warm so this cell can take everyone. Capped at HPA max: above that is a shortage to
    report, not to hide, which is what the plan's shortfall says."""
    need = summary_["peak_rps_7d"] * headroom
    services = []
    for row in summary_["per_service"]:
        wanted = max(1, math.ceil(need * row["fanout"] / row["per_pod_rps"]))
        services.append({"service": row["service"], "min_replicas": min(row["hpa_max"], wanted),
                         "shortfall_replicas": max(0, wanted - row["hpa_max"])})
    return {"cell": summary_["cell"], "target_rps": need, "services": services}
