"""The parity gate: zero missed divergences, zero false ones. Offline; facts come from cases.yaml."""
import json
import pathlib
import sys
from datetime import datetime

import yaml

HERE = pathlib.Path(__file__).resolve().parent
sys.path[:0] = [str(HERE.parents[1] / "control-plane" / "parity-checker"), str(HERE)]
from fake_facts import FakeFacts  # noqa: E402
from parity.engine import evaluate  # noqa: E402

CONTRACT = yaml.safe_load((HERE.parents[1] / "parity" / "contract.yaml").read_text(encoding="utf-8"))


def timestamp(text: str) -> datetime:
    return datetime.fromisoformat(text.replace("Z", "+00:00"))


def main() -> int:
    cases = yaml.safe_load((HERE / "cases.yaml").read_text(encoding="utf-8"))
    missed = false_divergence = other = total = 0
    covered = set()
    for case in cases:
        contract = {**CONTRACT, "checks": [c for c in CONTRACT["checks"] if c["id"] in case["expect"]]}
        facts = [FakeFacts(cell, values) for cell, values in case["facts"].items()]
        ctx = dict(case.get("ctx") or {})
        if "canary_started_at" in ctx:
            ctx["canary_started_at"] = timestamp(ctx["canary_started_at"])
        result = evaluate(contract, facts, case.get("exceptions", []), ctx=ctx, now=timestamp(case["now"]))
        got = {f.check_id: f.status for f in result.findings}
        for check_id, want in case["expect"].items():
            total += 1
            covered.add((check_id, want))
            status = got.get(check_id)
            if status == want:
                continue
            if want == "diverged" and status in ("match", "excepted"):
                missed += 1
                kind = "MISSED DIVERGENCE"
            elif want in ("match", "excepted") and status == "diverged":
                false_divergence += 1
                kind = "FALSE DIVERGENCE"
            else:
                other += 1
                kind = "WRONG STATUS"
            print(f"  {kind}: {case['name']} / {check_id}: want={want} got={status}")
    # Adding a check means adding fixtures: every check needs a matching pair and a diverging pair.
    uncovered = sorted(
        f"{c['id']}:{want}" for c in CONTRACT["checks"] for want in ("match", "diverged") if (c["id"], want) not in covered
    )
    print(json.dumps({"checks_evaluated": total, "missed_divergences": missed, "false_divergences": false_divergence,
                      "other_mismatches": other, "uncovered": uncovered}, indent=2))
    if missed or false_divergence or other or uncovered:
        print("GATE FAIL")
        return 1
    print("GATE PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
