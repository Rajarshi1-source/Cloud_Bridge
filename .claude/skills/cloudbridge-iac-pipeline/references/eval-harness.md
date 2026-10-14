# Plan-Risk Gate — Rules, Eval Set and CI Gate

The plan-risk gate is the one CloudBridge component whose false negatives destroy data, so it gets the same treatment as an ML model: a labelled eval set, metrics, and a merge gate. Rules decide; the optional LLM explainer is evaluated separately for faithfulness.

## Contents
1. `control-plane/plan-risk/rules.py`
2. `control-plane/plan-risk/cli.py` (writes `risk.json`)
3. Eval set layout + label schema
4. Fixture generator (mutating real plans)
5. `evals/plan-risk/run_eval.py` (metrics + gate)
6. Explainer adapter + faithfulness check
7. CI wiring

---

## 1. rules.py

```python
# control-plane/plan-risk/rules.py
from __future__ import annotations
import json

STATEFUL = {
    "aws_db_instance", "aws_rds_cluster", "aws_elasticache_replication_group", "aws_s3_bucket",
    "aws_eks_cluster", "google_sql_database_instance", "google_memorystore_instance",
    "google_storage_bucket", "google_container_cluster",
}
SG_RULE_TYPES = {"aws_security_group_rule", "aws_vpc_security_group_ingress_rule"}
WEB_PORTS = {80, 443}
LARGE_CHANGE = 40

def _after(rc: dict) -> dict:
    return rc["change"].get("after") or {}

def _world_open_aws(after: dict) -> bool:
    cidrs = after.get("cidr_blocks") or []
    if isinstance(cidrs, str):
        cidrs = [cidrs]
    cidrs = list(cidrs) + ([after["cidr_ipv4"]] if after.get("cidr_ipv4") else [])
    return "0.0.0.0/0" in cidrs and after.get("type", "ingress") == "ingress"

def evaluate(plan: dict, stack: str, affected: dict | None = None) -> list[dict]:
    findings: list[dict] = []
    for rc in plan.get("resource_changes", []):
        actions, rtype, addr = rc["change"]["actions"], rc["type"], rc["address"]
        after = _after(rc)

        if rtype in STATEFUL and "delete" in actions:
            why = "replacement of stateful resource" if "create" in actions else "deletion of stateful resource"
            findings.append({"rule": "stateful-destroy", "verdict": "block", "address": addr, "why": why})

        if rtype in SG_RULE_TYPES and _world_open_aws(after) and after.get("from_port") not in WEB_PORTS:
            findings.append({"rule": "open-ingress", "verdict": "block", "address": addr,
                             "why": "world-open non-HTTP ingress"})

        if rtype == "google_compute_firewall" and "0.0.0.0/0" in (after.get("source_ranges") or []):
            ports = {p for a in (after.get("allow") or []) for p in (a.get("ports") or [])}
            if not ports or not ports <= {"80", "443"}:
                findings.append({"rule": "open-ingress", "verdict": "block", "address": addr,
                                 "why": "world-open firewall on non-web ports"})

        if rtype in {"aws_iam_policy", "aws_iam_role_policy"} and after.get("policy"):
            doc = json.loads(after["policy"]) if isinstance(after["policy"], str) else after["policy"]
            stmts = doc.get("Statement", [])
            stmts = stmts if isinstance(stmts, list) else [stmts]
            if any(s.get("Effect") == "Allow" and (s.get("Action") == "*" or "*" in (s.get("Action") or [])) for s in stmts):
                findings.append({"rule": "iam-wildcard", "verdict": "warn", "address": addr, "why": "Allow on Action *"})

    if affected and affected.get("one_sided"):
        clouds = sorted({s["cloud"] for s in affected.get("stacks", []) if s["cloud"] in ("aws", "gcp")})
        findings.append({"rule": "one-sided-change", "verdict": "warn", "address": stack,
                         "why": f"change affects only {clouds}; add a parity exception or change both clouds"})

    n = sum(1 for rc in plan.get("resource_changes", []) if rc["change"]["actions"] not in (["no-op"], ["read"]))
    if n > LARGE_CHANGE:
        findings.append({"rule": "large-change", "verdict": "warn", "address": stack, "why": f"{n} resources change"})
    return findings

def verdict(findings: list[dict]) -> str:
    v = {f["verdict"] for f in findings}
    return "block" if "block" in v else "warn" if "warn" in v else "pass"
```

## 2. cli.py

```python
# control-plane/plan-risk/cli.py
import argparse, json, pathlib, sys
sys.path.insert(0, str(pathlib.Path(__file__).parent))
from rules import evaluate, verdict

def counts(plan: dict) -> str:
    c = {"create": 0, "update": 0, "delete": 0}
    for rc in plan.get("resource_changes", []):
        for a in rc["change"]["actions"]:
            if a in c:
                c[a] += 1
    return f"{c['create']}/{c['update']}/{c['delete']}"

def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("plan")
    ap.add_argument("--stack", required=True)
    ap.add_argument("--affected")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    plan = json.loads(pathlib.Path(a.plan).read_text())
    affected = json.loads(pathlib.Path(a.affected).read_text()) if a.affected and pathlib.Path(a.affected).exists() else None
    f = evaluate(plan, a.stack, affected)
    out = {"stack": a.stack, "counts": counts(plan), "verdict": verdict(f), "findings": f}
    pathlib.Path(a.out).write_text(json.dumps(out, indent=2))
    print(out["verdict"])

if __name__ == "__main__":
    main()
```

## 3. Eval set

```
evals/plan-risk/
  cases/
    001-rds-replace.json          plan JSON (resource_changes only is enough)
    001-rds-replace.label.json    {"verdict": "block", "rules": ["stateful-destroy"]}
    ...
  base/                           real plans captured from mock applies (seed material)
  generate.py
  run_eval.py
```

Label schema:
```json
{ "verdict": "block | warn | pass", "rules": ["stateful-destroy"], "affected": {"one_sided": false, "stacks": []}, "note": "why this label" }
```

Target mix (60 cases): 18 block (stateful delete/replace across 9 types, open ingress on 22/5432/6379, GCP firewall 0.0.0.0/0 on 22), 18 warn (IAM wildcard, one-sided, large change), 24 pass — **including hard negatives**: stateful *update in place*, SG rule open on 443 only, a `delete` of a non-stateful resource (route table association), `read` actions from data sources, replacement of a `random_password` (not stateful by our definition), Cloudflare pool weight change.

## 4. generate.py (mutations over real plans)

```python
# evals/plan-risk/generate.py
"""Create labelled cases by mutating seed plans. Seeds come from `terraform show -json` of
mock-provider applies, so the JSON shape is real, not hand-written."""
import copy, json, pathlib

BASE = pathlib.Path(__file__).parent / "base"
OUT = pathlib.Path(__file__).parent / "cases"

def rc(address, rtype, actions, after=None):
    return {"address": address, "type": rtype, "change": {"actions": actions, "after": after or {}}}

MUTATIONS = [
    ("rds-replace", lambda p: p["resource_changes"].append(rc("module.cell.module.db_aws[0].aws_db_instance.this", "aws_db_instance", ["delete", "create"])), "block"),
    ("cloudsql-delete", lambda p: p["resource_changes"].append(rc("module.cell.module.db_gcp[0].google_sql_database_instance.this", "google_sql_database_instance", ["delete"])), "block"),
    ("gke-replace", lambda p: p["resource_changes"].append(rc("module.cell.module.gke[0].google_container_cluster.this", "google_container_cluster", ["create", "delete"])), "block"),
    ("ssh-open", lambda p: p["resource_changes"].append(rc("aws_vpc_security_group_ingress_rule.ssh", "aws_vpc_security_group_ingress_rule", ["create"], {"cidr_ipv4": "0.0.0.0/0", "from_port": 22, "to_port": 22})), "block"),
    ("https-open", lambda p: p["resource_changes"].append(rc("aws_vpc_security_group_ingress_rule.web", "aws_vpc_security_group_ingress_rule", ["create"], {"cidr_ipv4": "0.0.0.0/0", "from_port": 443, "to_port": 443})), "pass"),
    ("rds-update-in-place", lambda p: p["resource_changes"].append(rc("module.cell.module.db_aws[0].aws_db_instance.this", "aws_db_instance", ["update"], {"backup_retention_period": 14})), "pass"),
    ("iam-star", lambda p: p["resource_changes"].append(rc("aws_iam_role_policy.x", "aws_iam_role_policy", ["create"], {"policy": json.dumps({"Statement": [{"Effect": "Allow", "Action": "*", "Resource": "*"}]})})), "warn"),
    ("password-rotate", lambda p: p["resource_changes"].append(rc("random_password.admin", "random_password", ["delete", "create"])), "pass"),
]

def main() -> None:
    OUT.mkdir(exist_ok=True)
    i = 0
    for seed in sorted(BASE.glob("*.json")):
        base = json.loads(seed.read_text())
        for name, mutate, label in MUTATIONS:
            i += 1
            plan = copy.deepcopy(base)
            mutate(plan)
            stem = f"{i:03d}-{seed.stem}-{name}"
            (OUT / f"{stem}.json").write_text(json.dumps(plan))
            (OUT / f"{stem}.label.json").write_text(json.dumps({"verdict": label, "note": name}))

if __name__ == "__main__":
    main()
```
Generated cases are a floor, not the whole set: hand-add the tricky ones (one-sided changes need an `affected` block in the label file, large-change needs a seed with > 40 changes). Commit the cases — the eval set is versioned with the rules.

## 5. run_eval.py (metrics + gate)

```python
# evals/plan-risk/run_eval.py
import json, pathlib, sys
ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "control-plane" / "plan-risk"))
from rules import evaluate, verdict

CASES = pathlib.Path(__file__).parent / "cases"
GATE_BLOCK_RECALL = 1.00
GATE_PRECISION = 0.90

def main() -> int:
    tp = fp = fn = 0
    block_tp = block_fn = 0
    rows = []
    for case in sorted(CASES.glob("*[0-9a-z].json")):
        if case.name.endswith(".label.json"):
            continue
        label = json.loads(case.with_name(case.stem + ".label.json").read_text())
        plan = json.loads(case.read_text())
        got = verdict(evaluate(plan, "evals", label.get("affected")))
        want = label["verdict"]
        flagged_got, flagged_want = got != "pass", want != "pass"
        tp += flagged_got and flagged_want
        fp += flagged_got and not flagged_want
        fn += (not flagged_got) and flagged_want
        if want == "block":
            block_tp += got == "block"
            block_fn += got != "block"
        rows.append((case.stem, want, got, "ok" if got == want else "MISMATCH"))

    precision = tp / (tp + fp) if tp + fp else 1.0
    recall = tp / (tp + fn) if tp + fn else 1.0
    block_recall = block_tp / (block_tp + block_fn) if block_tp + block_fn else 1.0
    exact = sum(r[3] == "ok" for r in rows) / len(rows)

    for r in rows:
        if r[3] != "ok":
            print(f"  {r[0]}: want={r[1]} got={r[2]}")
    report = {"cases": len(rows), "precision": round(precision, 3), "recall": round(recall, 3),
              "block_recall": round(block_recall, 3), "exact_match": round(exact, 3)}
    print(json.dumps(report, indent=2))
    pathlib.Path("plan-risk-eval.json").write_text(json.dumps(report))

    if block_recall < GATE_BLOCK_RECALL:
        print(f"GATE FAIL: block recall {block_recall:.3f} < {GATE_BLOCK_RECALL}")
        return 1
    if precision < GATE_PRECISION:
        print(f"GATE FAIL: precision {precision:.3f} < {GATE_PRECISION}")
        return 1
    print("GATE PASS")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
```

## 6. Explainer adapter + faithfulness

```python
# control-plane/plan-risk/explainer.py
"""Optional. Summarises plan + findings in plain English. Never changes the verdict."""
from __future__ import annotations
import json, os, re, time
from typing import Protocol

class LLM(Protocol):
    def complete(self, system: str, user: str, timeout_s: float) -> str: ...

class OpenAICompatible:
    """Works with any OpenAI-compatible endpoint; provider and model come from config, never code."""
    def __init__(self, base_url: str, model: str, api_key: str):
        from openai import OpenAI
        self.client, self.model = OpenAI(base_url=base_url, api_key=api_key), model
    def complete(self, system: str, user: str, timeout_s: float) -> str:
        r = self.client.chat.completions.create(model=self.model, timeout=timeout_s, max_tokens=300,
                                                messages=[{"role": "system", "content": system},
                                                          {"role": "user", "content": user}])
        return r.choices[0].message.content or ""

def from_config() -> LLM | None:
    if os.environ.get("CB_LLM_ENABLED") != "1":
        return None
    return OpenAICompatible(base_url=os.environ.get("CB_LLM_BASE_URL", "https://api.openai.com/v1"),
                            model=os.environ.get("CB_LLM_MODEL", "gpt-5.4-mini"),
                            api_key=os.environ["CB_LLM_API_KEY"])

SYSTEM = ("You summarise Terraform plans for reviewers. Three sentences. Mention only resource addresses "
          "that appear in the input. Do not give a verdict; the verdict is provided.")

def explain(plan: dict, findings: list[dict], verdict: str, llm: LLM | None, budget_s: float = 10.0) -> str | None:
    if llm is None:
        return None
    changes = [{"address": rc["address"], "actions": rc["change"]["actions"]}
               for rc in plan.get("resource_changes", []) if rc["change"]["actions"] != ["no-op"]][:80]
    user = json.dumps({"verdict": verdict, "findings": findings, "changes": changes})
    t0 = time.monotonic()
    try:
        text = llm.complete(SYSTEM, user, timeout_s=budget_s)
    except Exception:
        return None
    if time.monotonic() - t0 > budget_s:
        return None
    return text if faithful(text, plan) else None

ADDR = re.compile(r"\b(?:module\.[\w\-\[\]\"]+\.)*[a-z0-9_]+\.[\w\-]+(?:\[[^\]]+\])?")

def faithful(text: str, plan: dict) -> bool:
    known = {rc["address"] for rc in plan.get("resource_changes", [])}
    mentioned = {m for m in ADDR.findall(text) if "_" in m.split(".")[-2] or m.startswith("module.")}
    return all(any(m in k or k.endswith(m) for k in known) for m in mentioned)
```
Faithfulness eval: run `explain()` over the 60 cases with the configured model; `faithfulness = faithful_count / answered_count`; gate ≥ 0.98. A response that fails `faithful()` is dropped at runtime anyway, so production never shows an invented address — the eval tells you whether the model is worth calling at all.

## 7. CI wiring

```yaml
# .github/workflows/evals.yml (plan-risk job)
  plan-risk:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@<sha>
      - uses: actions/setup-python@<sha>
        with:
          python-version: "3.14"
      - run: python3 evals/plan-risk/run_eval.py
      - uses: actions/upload-artifact@<sha>
        with:
          name: plan-risk-eval
          path: plan-risk-eval.json
```
Trigger on changes to `control-plane/plan-risk/**` or `evals/plan-risk/**`. Mark the job a required status check in branch protection — that's what makes it a gate.
