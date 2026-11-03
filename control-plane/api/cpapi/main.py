"""The control plane's API. Off the request path: if it dies users are still served.

Cloudflare Access at the edge and this bearer token here. It refuses to start without a token, because an
API that came up open would let anyone rewrite the audit trail.
"""
from __future__ import annotations

import hmac
import json
import os
import pathlib
import re
import uuid
from datetime import date, datetime, timezone
from typing import Any, Literal

import httpx
import psycopg
from fastapi import Depends, FastAPI, Header, HTTPException, Response
from pydantic import BaseModel, Field

from . import capacity as cap
from . import queries

TOKEN = os.environ.get("CB_CP_TOKEN")
if not TOKEN:
    raise RuntimeError("CB_CP_TOKEN is not set: refusing to start an API with no authentication")

REPO = pathlib.Path(os.environ.get("CB_REPO_DIR", "/repo"))
PROM = os.environ.get("CB_PROM_URL", "http://prometheus:9090")
DEFAULT_ENV = os.environ.get("CB_ENV", "prod")
CELL_RE = re.compile(r"^cb-(aws|gcp)-[a-z0-9-]+$")  # goes into a path and a PromQL selector

app = FastAPI(title="CloudBridge control plane")


class PrometheusDown(Exception):
    pass


def auth(authorization: str = Header(default="")) -> None:
    if not hmac.compare_digest(authorization.encode(), f"Bearer {TOKEN}".encode()):
        raise HTTPException(401, "a valid bearer token is required")


def db():
    with psycopg.connect(os.environ["DATABASE_URL"], autocommit=True) as conn:
        yield conn


def prom(expr: str) -> list[dict]:
    try:
        answer = httpx.get(f"{PROM}/api/v1/query", params={"query": expr}, timeout=10)
        answer.raise_for_status()
    except httpx.HTTPError as error:
        raise PrometheusDown(str(error)) from error
    return answer.json()["data"]["result"]


def now() -> datetime:
    return datetime.now(timezone.utc)


def env_of(conn, cell: str) -> str:
    row = conn.execute("SELECT env FROM cells WHERE id = %s", (cell,)).fetchone() if CELL_RE.match(cell) else None
    if row is None:
        raise HTTPException(404, f"unknown cell {cell!r}")
    return row[0]


# ---------- capacity ----------
def capacity_of(conn, cell: str) -> tuple[dict, dict]:
    env = env_of(conn, cell)
    try:
        measured = cap.measured(REPO, cell)
        current = {}
        for service in cap.SERVICES:
            running = prom(f'count(up{{job="apps",service="{service}",cb_cell="{cell}"}} == 1)')
            if running:
                current[service] = int(float(running[0]["value"][1]))
        peak = prom(f'max_over_time(sum(cb:requests:rate5m{{service="api-gateway",cb_env="{env}"}})[7d:5m])')
        peak_rps = float(peak[0]["value"][1]) if peak else None
        maxima = {service: cap.hpa_max(REPO, cell, service) for service in cap.SERVICES}
        return cap.summary(cell, measured, cap.per_service(measured, maxima, current), peak_rps), measured
    except cap.NotMeasured as refused:
        raise HTTPException(409, str(refused)) from refused
    except PrometheusDown as down:
        raise HTTPException(503, f"Prometheus unreachable, refusing to guess: {down}") from down


@app.get("/capacity/{cell}", dependencies=[Depends(auth)])
def capacity_route(cell: str, conn=Depends(db)) -> dict[str, Any]:
    return {**capacity_of(conn, cell)[0], "as_of": now()}


@app.get("/capacity/{cell}/evacuation-plan", dependencies=[Depends(auth)])
def evacuation_plan(cell: str, headroom: float = 1.2, conn=Depends(db)) -> dict[str, Any]:
    if headroom < 1:
        raise HTTPException(422, "headroom below 1 plans for less than the peak")
    return cap.evacuation_plan(capacity_of(conn, cell)[0], headroom)


# ---------- drills ----------
class DrillIn(BaseModel):
    from_cell: str
    to_cell: str
    mode: Literal["drill", "real"]


class StepIn(BaseModel):
    seq: int = Field(ge=0)
    weights: dict[str, int]
    burn_rate: float | None = None
    p95_ms: float | None = None
    decision: Literal["advance", "hold", "abort"]


class DrillPatch(BaseModel):
    outcome: Literal["aborted", "rolled_back", "completed"]


def configured_weights() -> dict[str, int]:
    return json.loads((REPO / "infra/live/global/30-traffic/terraform.tfvars.json").read_text(encoding="utf-8"))["weights"]


def drill_exists(conn, drill_id: uuid.UUID) -> None:
    if conn.execute("SELECT 1 FROM drills WHERE id = %s", (drill_id,)).fetchone() is None:
        raise HTTPException(404, "no such drill")


@app.post("/drills", status_code=201, dependencies=[Depends(auth)])
def open_drill(drill: DrillIn, conn=Depends(db)) -> dict[str, str]:
    env = env_of(conn, drill.from_cell)
    if env_of(conn, drill.to_cell) != env or drill.from_cell == drill.to_cell:
        raise HTTPException(422, "a drill moves traffic between two different cells of one environment")
    row = conn.execute("""INSERT INTO drills (env, from_cell, to_cell, mode, original_weights)
                          VALUES (%s, %s, %s, %s, %s::jsonb) RETURNING id""",
                       (env, drill.from_cell, drill.to_cell, drill.mode, json.dumps(configured_weights()))).fetchone()
    return {"id": str(row[0])}


@app.post("/drills/{drill_id}/steps", status_code=201, dependencies=[Depends(auth)])
def add_step(drill_id: uuid.UUID, step: StepIn, conn=Depends(db)) -> dict[str, str]:
    drill_exists(conn, drill_id)
    conn.execute("""INSERT INTO drill_steps (drill_id, seq, weights, burn_rate, p95_ms, decision)
                    VALUES (%s, %s, %s::jsonb, %s, %s, %s)
                    ON CONFLICT (drill_id, seq) DO UPDATE SET weights = EXCLUDED.weights, burn_rate = EXCLUDED.burn_rate,
                      p95_ms = EXCLUDED.p95_ms, decision = EXCLUDED.decision""",
                 (drill_id, step.seq, json.dumps(step.weights), step.burn_rate, step.p95_ms, step.decision))
    return {"status": "recorded"}


@app.patch("/drills/{drill_id}", dependencies=[Depends(auth)])
def patch_drill(drill_id: uuid.UUID, patch: DrillPatch, conn=Depends(db)) -> dict[str, str]:
    drill_exists(conn, drill_id)
    conn.execute("UPDATE drills SET outcome = %s, finished_at = now() WHERE id = %s", (patch.outcome, drill_id))
    return {"status": "ok"}


@app.post("/drills/{drill_id}/complete", dependencies=[Depends(auth)])
def complete_drill(drill_id: uuid.UUID, conn=Depends(db)) -> dict[str, Any]:
    drill_exists(conn, drill_id)
    steps = conn.execute("SELECT at, burn_rate FROM drill_steps WHERE drill_id = %s ORDER BY seq", (drill_id,)).fetchall()
    # Fewer than two steps measured no shift, which is not a shift of zero seconds.
    shift = int((steps[-1][0] - steps[0][0]).total_seconds()) if len(steps) > 1 else None
    burns = [float(s[1]) for s in steps if s[1] is not None]
    conn.execute("UPDATE drills SET outcome = 'completed', finished_at = now(), shift_seconds = %s, burn_rate_max = %s WHERE id = %s",
                 (shift, max(burns) if burns else None, drill_id))
    return {"id": str(drill_id), "shift_seconds": shift, "burn_rate_max": max(burns) if burns else None}


@app.get("/drills/{drill_id}/original-weights", dependencies=[Depends(auth)])
def original_weights(drill_id: uuid.UUID, conn=Depends(db)) -> dict[str, Any]:
    row = conn.execute("SELECT original_weights FROM drills WHERE id = %s", (drill_id,)).fetchone()
    if row is None:
        raise HTTPException(404, "no such drill")
    return {"weights": row[0]}


# ---------- traffic changes ----------
class TrafficIn(BaseModel):
    weights: dict[str, int]
    source: Literal["manual", "recommender", "evacuation", "failback", "drill", "break_glass"]
    pr_url: str | None = None
    drill_id: uuid.UUID | None = None


@app.post("/traffic-changes", status_code=201, dependencies=[Depends(auth)])
def traffic_change(change: TrafficIn, conn=Depends(db)) -> dict[str, str]:
    try:
        row = conn.execute("INSERT INTO traffic_changes (weights, source, pr_url, drill_id) VALUES (%s::jsonb, %s, %s, %s) RETURNING id",
                           (json.dumps(change.weights), change.source, change.pr_url, change.drill_id)).fetchone()
    except psycopg.errors.RaiseException as refused:  # the trigger enforces sum = 100 and the warm floor
        raise HTTPException(422, str(refused).splitlines()[0]) from refused
    return {"id": str(row[0])}


# ---------- parity ----------
class FindingIn(BaseModel):
    check_id: str
    weight: float = Field(gt=0)
    values: dict[str, Any]
    status: Literal["match", "diverged", "excepted", "unknown"]
    note: str | None = None
    exception_expires: date | None = None


class SnapshotIn(BaseModel):
    env: str
    score: float = Field(ge=0, le=1)
    passed: bool
    trigger: Literal["pr", "post_sync", "nightly", "manual"]
    commit_sha: str | None = None
    findings: list[FindingIn] = Field(min_length=1)


@app.post("/parity/snapshots", status_code=201, dependencies=[Depends(auth)])
def store_snapshot(snapshot: SnapshotIn, conn=Depends(db)) -> dict[str, str]:
    if snapshot.passed and snapshot.score < 1:
        raise HTTPException(422, "a snapshot below 1.0 can't have passed")
    with conn.transaction():
        row = conn.execute("""INSERT INTO parity_snapshots (env, score, passed, trigger, commit_sha)
                              VALUES (%s, %s, %s, %s, %s) RETURNING id""",
                           (snapshot.env, snapshot.score, snapshot.passed, snapshot.trigger, snapshot.commit_sha)).fetchone()
        with conn.cursor() as cursor:
            cursor.executemany("""INSERT INTO parity_findings (snapshot_id, check_id, weight, cell_values, status, note, exception_expires)
                                  VALUES (%s, %s, %s, %s::jsonb, %s, %s, %s)""",
                               [(row[0], f.check_id, f.weight, json.dumps(f.values), f.status, f.note, f.exception_expires)
                                for f in snapshot.findings])
    return {"id": str(row[0])}


@app.get("/parity", dependencies=[Depends(auth)])
def parity(env: str = DEFAULT_ENV, conn=Depends(db)) -> dict[str, Any]:
    return {**queries.parity(conn, env), "as_of": now()}


# ---------- what the dashboard reads ----------
@app.get("/overview", dependencies=[Depends(auth)])
def overview(env: str = DEFAULT_ENV, conn=Depends(db)) -> dict[str, Any]:
    cells = queries.rows(conn, "SELECT id AS cell, cloud::text AS cloud FROM cells WHERE env = %s ORDER BY id", env)
    latest = queries.rows(conn, "SELECT weights, source, applied_at FROM traffic_changes ORDER BY applied_at DESC LIMIT 1")
    availability, latency, observed, reachable = {}, {}, None, True
    try:
        availability = {r["metric"]["cb_cell"]: float(r["value"][1]) for r in prom(f'cb:availability:ratio_rate1h{{cb_env="{env}"}}')}
        latency = {r["metric"]["cb_cell"]: float(r["value"][1]) for r in prom(f'cb:latency_p95:5m{{service="api-gateway",cb_env="{env}"}}')}
        # cb:split:observed, within one environment: the receiver may hold several.
        users = f'http_server_requests_seconds_count{{service="api-gateway",cb_env="{env}",uri!~"/actuator.*|/healthz.*|/admin.*"}}'
        split = {r["metric"]["cb_cell"]: float(r["value"][1]) for r in prom(
            f"sum by (cb_cell) (rate({users}[5m])) / ignoring (cb_cell) group_left () (sum (rate({users}[5m])) > 0)")}
        shares = {c["cloud"]: split[c["cell"]] * 100 for c in cells if c["cell"] in split}
        if shares:  # a cell with traffic and one without is a measured 100/0
            observed = {c["cloud"]: shares.get(c["cloud"], 0.0) for c in cells}
    except PrometheusDown:
        reachable = False
    latency = {cell: None if value != value else value * 1000 for cell, value in latency.items()}  # NaN: no requests
    availability = {cell: None if value != value else value for cell, value in availability.items()}
    drills = queries.rows(conn, """SELECT id, from_cell, to_cell, outcome, shift_seconds, finished_at FROM drills
                                   WHERE env = %s AND outcome <> 'running' ORDER BY finished_at DESC LIMIT 1""", env)
    return {
        "as_of": now(), "env": env, "prometheus_reachable": reachable,
        "configured": latest[0] if latest else None,
        "observed": observed,
        "cells": [{**c, "availability": availability.get(c["cell"]), "p95_ms": latency.get(c["cell"])} for c in cells],
        "parity": queries.latest_parity(conn, env),
        "last_drill": drills[0] if drills else None,
    }


@app.get("/cost", dependencies=[Depends(auth)])
def cost(conn=Depends(db)) -> dict[str, Any]:
    return {**queries.cost(conn), "as_of": now(), "window_days": 30}


# ---------- unauthenticated ----------
@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/metrics")
def metrics(conn=Depends(db)) -> Response:
    """Timestamps only, and only when the thing happened: the staleness alerts rely on absent()."""
    lines = []
    for name, sql in (("cb_billing_latest_timestamp", queries.BILLING_LATEST), ("cb_last_drill_success_timestamp", queries.LAST_DRILL)):
        row = conn.execute(sql).fetchone()
        if row and row[0] is not None:
            lines += [f"# TYPE {name} gauge", f"{name} {row[0]}"]
    return Response("\n".join(lines) + "\n", media_type="text/plain; version=0.0.4")
