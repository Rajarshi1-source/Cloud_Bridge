"""Scoring and exceptions. Pure: every fact comes through CellFacts, so the eval runs offline."""
from __future__ import annotations

import json
from dataclasses import dataclass, field
from datetime import date, datetime, timezone
from typing import Any, Protocol


class CellFacts(Protocol):
    cell: str

    def get(self, source: str) -> Any: ...


class FactUnavailable(Exception):
    """An adapter couldn't read a fact. Never treated as a match."""


@dataclass(frozen=True)
class Finding:
    check_id: str
    weight: float
    values: dict[str, Any]
    status: str  # match | diverged | excepted | unknown
    exception: dict | None = None
    note: str = ""


@dataclass
class Result:
    score: float
    passed: bool
    findings: list[Finding] = field(default_factory=list)


def _minor(version: Any) -> str:
    return ".".join(str(version).lstrip("v").split("+")[0].split(".")[:2])


def _canon(value: Any) -> str:
    """Order-insensitive, so the order of a list or dict never causes a false divergence."""
    if isinstance(value, (list, tuple, set)):
        value = sorted(value, key=lambda item: json.dumps(item, sort_keys=True, default=str))
    return json.dumps(value, sort_keys=True, default=str)


def _blind(value: Any) -> bool:
    # Two empty answers are equal and prove nothing: a namespace nobody could list must not pass.
    return value is None or value == "" or value == {} or value == []


def _honoured(exception: dict, values: dict[str, Any], ctx: dict, now: datetime) -> bool:
    if not exception.get("owner") or not exception.get("reason"):
        return False
    if "expires" in exception:
        try:
            if date.fromisoformat(str(exception["expires"])) < now.date():
                return False
        except ValueError:
            return False
    scope = exception.get("scope")
    if scope == "patch-only":
        return len({_minor(v) for v in values.values()}) == 1
    if scope == "ring-window":
        started, rings = ctx.get("canary_started_at"), ctx.get("ring_digests")
        if started is None or not rings:
            return False
        # The window covers the release flow only: a hotfix in either cell during a canary still diverges.
        if any(values.get(cell) != rings.get(cell) for cell in values):
            return False
        return (now - started).total_seconds() <= int(exception["max_age_minutes"]) * 60
    if scope is None:
        return "expires" in exception  # an unscoped exception must expire
    return False  # an unknown scope is not honoured


def evaluate(contract: dict, facts: list[CellFacts], exceptions: list[dict],
             ctx: dict | None = None, now: datetime | None = None) -> Result:
    if len(facts) < 2:
        raise ValueError("parity compares at least two cells")
    now, ctx = now or datetime.now(timezone.utc), ctx or {}
    findings: list[Finding] = []
    for check in contract["checks"]:
        check_id, weight = check["id"], float(check["weight"])
        values: dict[str, Any] = {}
        problems: list[str] = []
        for fact in facts:
            try:
                values[fact.cell] = fact.get(check["source"])
                if _blind(values[fact.cell]):
                    problems.append(f"{fact.cell}: read nothing")
            except FactUnavailable as error:
                values[fact.cell] = None
                problems.append(f"{fact.cell}: {error}")
        if problems:
            findings.append(Finding(check_id, weight, values, "unknown", note="; ".join(problems)))
            continue
        wanted = check.get("minor_equals")
        off_target = [cell for cell, value in values.items() if wanted and _minor(value) != str(wanted)]
        if len({_canon(v) for v in values.values()}) == 1 and not off_target:
            findings.append(Finding(check_id, weight, values, "match"))
            continue
        note = f"expected minor {wanted}: {', '.join(off_target)} differ" if off_target else ""
        honoured = None if off_target else next(
            (e for e in exceptions if e.get("check") == check_id and _honoured(e, values, ctx, now)), None)
        findings.append(Finding(check_id, weight, values, "excepted" if honoured else "diverged", honoured, note))
    total = sum(f.weight for f in findings)
    good = sum(f.weight for f in findings if f.status in ("match", "excepted"))
    score = good / total if total else 0.0
    return Result(score, bool(findings) and score >= float(contract.get("pass_threshold", 1.0)), findings)
