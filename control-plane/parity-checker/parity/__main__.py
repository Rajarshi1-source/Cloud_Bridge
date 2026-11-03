"""parity check: live cells. parity static: what Git would deploy (needs helm template output).

    python -m parity check --env local --post http://127.0.0.1:8010/parity/snapshots
    python -m parity static --env budget --rendered /out
"""
import argparse
import json
import os
import pathlib
import sys
import urllib.request
from datetime import datetime

import yaml

from .engine import Result, evaluate
from .facts import ADAPTERS, RenderedFacts


def load(path: pathlib.Path):
    return yaml.safe_load(path.read_text(encoding="utf-8"))


def for_env(contract: dict, env: dict) -> dict:
    skip = env.get("skip") or {}
    return {**contract, "checks": [c for c in contract["checks"] if c["id"] not in skip]}


def ring_context(releases: pathlib.Path, cells: dict) -> dict:
    """When the canary began, and the digests each cell's ring says it should run (GCP canary, AWS main)."""
    rings = {name: load(releases / f"{name}.yaml") for name in ("ring-canary", "ring-main")}
    digests = {}
    for cell, config in cells.items():
        images = rings["ring-main" if config["cloud"] == "aws" else "ring-canary"]["images"]
        digests[cell] = {service: image.split("@", 1)[1] for service, image in images.items()}
    started = rings["ring-canary"].get("releasedAt")
    return {
        "ring_digests": digests,
        "canary_started_at": datetime.fromisoformat(str(started).replace("Z", "+00:00")) if started else None,
    }


def report(result: Result, as_json: bool, env: str, trigger: str) -> dict:
    payload = {
        "env": env,
        "score": round(result.score, 4),
        "passed": result.passed,
        "trigger": trigger,
        "commit_sha": os.environ.get("GITHUB_SHA"),
        "findings": [
            {"check_id": f.check_id, "weight": f.weight, "values": f.values, "status": f.status, "note": f.note,
             "exception_expires": (f.exception or {}).get("expires")}
            for f in result.findings
        ],
    }
    if as_json:
        print(json.dumps(payload, indent=2, default=str))
    else:
        print(f"parity {env}: score {result.score:.3f}, {'PASS' if result.passed else 'FAIL'}")
        marks = {"match": "  ", "excepted": "~ ", "diverged": "x ", "unknown": "? "}
        for f in result.findings:
            detail = f" ({f.note})" if f.note else ""
            shown = "" if f.status == "match" else " " + json.dumps(f.values, default=str, sort_keys=True)[:300]
            print(f"{marks[f.status]}{f.check_id:<22} w={f.weight:<4} {f.status:<9}{detail}{shown}")
    return payload


def post(url: str, payload: dict) -> None:
    request = urllib.request.Request(url, data=json.dumps(payload, default=str).encode(), method="POST", headers={
        "Content-Type": "application/json",
        "Authorization": f"Bearer {os.environ['CB_CP_TOKEN']}",
    })
    with urllib.request.urlopen(request, timeout=15) as response:
        print(f"snapshot stored: HTTP {response.status}", file=sys.stderr)


def main() -> int:
    parser = argparse.ArgumentParser(prog="parity")
    parser.add_argument("mode", choices=["check", "static"])
    parser.add_argument("--env", required=True)
    parser.add_argument("--repo", default=".")
    parser.add_argument("--trigger", default="manual", choices=["pr", "post_sync", "nightly", "manual"])
    parser.add_argument("--rendered", help="static: directory of helm template output, <cell>--<chart>.yaml")
    parser.add_argument("--post", help="check: control-plane URL to store the snapshot at")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    repo = pathlib.Path(args.repo)
    contract = load(repo / "parity/contract.yaml")
    env = load(repo / "parity/cells.yaml")[args.env]
    exceptions = load(repo / "parity/exceptions.yaml") or []
    scoped = for_env(contract, env)

    if args.mode == "static":
        # No digests here: a merged canary differs from main by design, and must not fail unrelated PRs.
        scoped["checks"] = [c for c in scoped["checks"] if c["source"] in RenderedFacts.SOURCES]
        facts = [RenderedFacts(cell, pathlib.Path(args.rendered), contract) for cell in env["cells"]]
        result = evaluate(scoped, facts, [])
    else:
        facts = [ADAPTERS[c["adapter"]](cell, c, contract) for cell, c in env["cells"].items()]
        result = evaluate(scoped, facts, exceptions, ring_context(repo / "gitops/releases", env["cells"]))

    payload = report(result, args.json, args.env, args.trigger)
    if args.post:
        post(args.post, payload)
    return 0 if result.passed else 1


if __name__ == "__main__":
    sys.exit(main())
