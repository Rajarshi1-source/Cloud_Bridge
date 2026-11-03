#!/usr/bin/env python3
"""One stack's plan, reduced to what a PR comment may show: counts and a hash, never any values.

    python3 tools/ci/plan_report.py plan.json --stack infra/live/gcp-budget/10-foundation --cloud gcp > report.json
"""
import argparse
import hashlib
import json
import pathlib


def counts(plan: dict) -> dict[str, int]:
    result = {"add": 0, "change": 0, "destroy": 0}
    for resource in plan.get("resource_changes", []):
        actions = resource["change"]["actions"]
        if "create" in actions:
            result["add"] += 1
        if "update" in actions:
            result["change"] += 1
        if "delete" in actions:
            result["destroy"] += 1
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("plan", type=pathlib.Path)
    parser.add_argument("--stack", required=True)
    parser.add_argument("--cloud", required=True)
    args = parser.parse_args()
    raw = args.plan.read_bytes()
    print(json.dumps({
        "stack": args.stack,
        "cloud": args.cloud,
        "status": "planned",
        "counts": counts(json.loads(raw)),
        "plan_sha256": hashlib.sha256(raw).hexdigest(),
    }))


if __name__ == "__main__":
    main()
