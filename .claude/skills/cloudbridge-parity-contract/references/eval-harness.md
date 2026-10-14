# Parity Checker — Eval Harness

The checker makes a binary claim per check ("these cells match"). Two errors matter:
- **Missed divergence** (said match, wasn't) → failover lands on a different system. Gate: **zero**.
- **False divergence** (said diverged, wasn't) → alert fatigue, people start ignoring parity. Gate: **zero** on the fixture set (it's deterministic code; any false divergence is a bug).

The eval runs entirely offline with fake fact adapters, so it runs on every PR touching `control-plane/parity-checker/**`, `parity/**` or `evals/parity/**`.

## Layout

```
evals/parity/
  cases.yaml        fixture pairs with expected per-check status
  fake_facts.py     FakeFacts adapter (reads values from the case)
  run_eval.py       metrics + gate
```

## cases.yaml

```yaml
# Each case: facts per cell (only the sources the contract asks for), optional ctx, expected statuses.
- name: identical-cells
  now: "2026-10-08T10:00:00Z"
  facts:
    cb-aws-prod: &base
      cluster.k8s_minor: "1.36"
      workloads.image_digests: { api-gateway: "sha256:aaa", order-service: "sha256:bbb" }
      k8s.hpa_max: { api-gateway: 10, order-service: 10 }
      sql.flyway_version: "7"
    cb-gcp-prod: *base
  expect: { k8s.minor: match, images.digests: match, hpa.max: match, flyway.version: match }

- name: digest-order-insensitive              # dict key order must not create divergence
  now: "2026-10-08T10:00:00Z"
  facts:
    cb-aws-prod:
      workloads.image_digests: { order-service: "sha256:bbb", api-gateway: "sha256:aaa" }
    cb-gcp-prod:
      workloads.image_digests: { api-gateway: "sha256:aaa", order-service: "sha256:bbb" }
  expect: { images.digests: match }

- name: hotfix-on-one-cell
  now: "2026-10-08T10:00:00Z"
  facts:
    cb-aws-prod:
      workloads.image_digests: { api-gateway: "sha256:aaa", order-service: "sha256:HOTFIX" }
    cb-gcp-prod:
      workloads.image_digests: { api-gateway: "sha256:aaa", order-service: "sha256:bbb" }
  expect: { images.digests: diverged }

- name: canary-inside-ring-window
  now: "2026-10-08T10:30:00Z"
  ctx: { canary_started_at: "2026-10-08T09:00:00Z" }     # 90 min old
  facts:
    cb-aws-prod: { workloads.image_digests: { order-service: "sha256:old" } }
    cb-gcp-prod: { workloads.image_digests: { order-service: "sha256:new" } }
  exceptions:
    - { check: images.digests, scope: ring-window, max_age_minutes: 120, owner: bot, reason: canary }
  expect: { images.digests: excepted }

- name: canary-stuck-past-window
  now: "2026-10-08T12:30:00Z"
  ctx: { canary_started_at: "2026-10-08T09:00:00Z" }     # 210 min old
  facts:
    cb-aws-prod: { workloads.image_digests: { order-service: "sha256:old" } }
    cb-gcp-prod: { workloads.image_digests: { order-service: "sha256:new" } }
  exceptions:
    - { check: images.digests, scope: ring-window, max_age_minutes: 120, owner: bot, reason: canary }
  expect: { images.digests: diverged }

- name: patch-only-honoured
  now: "2026-10-08T10:00:00Z"
  facts:
    cb-aws-prod: { cluster.k8s_minor: "1.36.2" }
    cb-gcp-prod: { cluster.k8s_minor: "1.36.4" }
  exceptions:
    - { check: k8s.minor, scope: patch-only, expires: "2026-11-15", owner: ricky, reason: gke patch }
  expect: { k8s.minor: excepted }

- name: patch-only-does-not-cover-minor
  now: "2026-10-08T10:00:00Z"
  facts:
    cb-aws-prod: { cluster.k8s_minor: "1.35.6" }
    cb-gcp-prod: { cluster.k8s_minor: "1.36.4" }
  exceptions:
    - { check: k8s.minor, scope: patch-only, expires: "2026-11-15", owner: ricky, reason: gke patch }
  expect: { k8s.minor: diverged }

- name: expired-exception
  now: "2026-12-01T10:00:00Z"
  facts:
    cb-aws-prod: { cluster.k8s_minor: "1.36.2" }
    cb-gcp-prod: { cluster.k8s_minor: "1.36.4" }
  exceptions:
    - { check: k8s.minor, scope: patch-only, expires: "2026-11-15", owner: ricky, reason: gke patch }
  expect: { k8s.minor: diverged }

- name: unreadable-fact-is-unknown
  now: "2026-10-08T10:00:00Z"
  facts:
    cb-aws-prod: { sql.flyway_version: "7" }
    cb-gcp-prod: { sql.flyway_version: "!unavailable" }   # adapter raises FactUnavailable
  expect: { flyway.version: unknown }

- name: unscoped-exception-without-expiry-ignored
  now: "2026-10-08T10:00:00Z"
  facts:
    cb-aws-prod: { k8s.hpa_max: { order-service: 10 } }
    cb-gcp-prod: { k8s.hpa_max: { order-service: 4 } }
  exceptions:
    - { check: hpa.max, owner: someone, reason: "gcp is smaller" }
  expect: { hpa.max: diverged }
```
Add a case for every bug you fix and every check you add (one match + one diverged per check).

## fake_facts.py

```python
# evals/parity/fake_facts.py
from parity.engine import FactUnavailable

class FakeFacts:
    def __init__(self, cell: str, values: dict):
        self.cell, self.values = cell, values

    def get(self, source: str):
        if source not in self.values:
            raise FactUnavailable(f"fixture has no {source}")
        v = self.values[source]
        if v == "!unavailable":
            raise FactUnavailable("simulated read failure")
        return v
```

## run_eval.py

```python
# evals/parity/run_eval.py
import json, pathlib, sys
from datetime import datetime
import yaml

HERE = pathlib.Path(__file__).parent
sys.path.insert(0, str(HERE.parents[1] / "control-plane" / "parity-checker"))
sys.path.insert(0, str(HERE))
from parity.engine import evaluate          # noqa: E402
from fake_facts import FakeFacts            # noqa: E402

CONTRACT = yaml.safe_load((HERE.parents[1] / "parity" / "contract.yaml").read_text())

def ts(s: str) -> datetime:
    return datetime.fromisoformat(s.replace("Z", "+00:00"))

def main() -> int:
    cases = yaml.safe_load((HERE / "cases.yaml").read_text())
    missed = false_div = wrong_other = total = 0
    for case in cases:
        wanted_ids = set(case["expect"])
        contract = {**CONTRACT, "checks": [c for c in CONTRACT["checks"] if c["id"] in wanted_ids]}
        facts = [FakeFacts(cell, vals) for cell, vals in case["facts"].items()]
        ctx = {k: ts(v) for k, v in (case.get("ctx") or {}).items()}
        res = evaluate(contract, facts, case.get("exceptions", []), ctx=ctx, now=ts(case["now"]))
        got = {f.check_id: f.status for f in res.findings}
        for cid, want in case["expect"].items():
            total += 1
            g = got.get(cid)
            if g == want:
                continue
            if want == "diverged" and g in ("match", "excepted"):
                missed += 1
                kind = "MISSED DIVERGENCE"
            elif want in ("match", "excepted") and g == "diverged":
                false_div += 1
                kind = "FALSE DIVERGENCE"
            else:
                wrong_other += 1
                kind = "WRONG STATUS"
            print(f"  {kind}: {case['name']} / {cid}: want={want} got={g}")
    report = {"checks_evaluated": total, "missed_divergences": missed,
              "false_divergences": false_div, "other_mismatches": wrong_other}
    print(json.dumps(report, indent=2))
    if missed or false_div or wrong_other:
        print("GATE FAIL")
        return 1
    print("GATE PASS")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
```

Note the `unknown` expectation: a fact the checker can't read must come back `unknown`. If a refactor makes it `match`, `run_eval.py` reports `WRONG STATUS` and fails — that's the "never pass blind" rule enforced.

## CI

```yaml
# .github/workflows/evals.yml (parity job)
  parity:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@<sha>
      - uses: actions/setup-python@<sha>
        with:
          python-version: "3.14"
      - run: pip install pyyaml && python3 evals/parity/run_eval.py
```
