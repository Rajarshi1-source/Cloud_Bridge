# Parity Contract — Starter Code

## Contents
1. `parity/contract.yaml`, `parity/exceptions.yaml`
2. `parity/engine.py` (scoring + exceptions)
3. `parity/facts.py` (Strategy adapters)
4. `parity/cli.py`
5. `.github/workflows/parity.yml`

Package layout: `control-plane/parity-checker/parity/{engine,facts,cli}.py`, Python 3.14, deps pinned in `pyproject.toml`: `pyyaml`, `kubernetes`, `boto3`, `psycopg[binary]`, `redis`; GCP reads use the `gcloud` CLI authenticated through Workload Identity Federation.

---

## 1. Contract + exceptions

```yaml
# parity/contract.yaml
version: 1
env: prod
cells: [cb-aws-prod, cb-gcp-prod]
config_hash_exclude: [CB_CELL, CLOUD, IMAGE_REGISTRY_MIRROR, SECRET_STORE]
checks:
  - { id: k8s.minor,           source: cluster.k8s_minor,          weight: 3 }
  - { id: images.digests,      source: workloads.image_digests,    weight: 5 }
  - { id: chart.versions,      source: argocd.chart_versions,      weight: 3 }
  - { id: app.config.hash,     source: k8s.configmap_hash,         weight: 4 }
  - { id: resources.requests,  source: workloads.requests,         weight: 2 }
  - { id: hpa.max,             source: k8s.hpa_max,                weight: 3 }
  - { id: networkpolicy.count, source: k8s.networkpolicy_count,    weight: 2 }
  - { id: pg.major,            source: database.major,             weight: 3 }
  - { id: pg.params,           source: database.params,            weight: 2 }
  - { id: valkey.major,        source: cache.major,                weight: 2 }
  - { id: flyway.version,      source: sql.flyway_version,         weight: 5 }
  - { id: shape.class,         source: cell.shape,                 weight: 2 }
pg_params_allowlist: [max_connections, statement_timeout, idle_in_transaction_session_timeout, work_mem, shared_preload_libraries]
pass_threshold: 1.0
```

```yaml
# parity/exceptions.yaml
- check: k8s.minor
  scope: patch-only
  reason: "GKE Regular channel patch auto-upgrade; minors equal"
  owner: ricky
  expires: 2026-11-15
- check: images.digests
  scope: ring-window
  max_age_minutes: 120
  reason: "Canary ring runs the new digest on GCP before promotion"
  owner: release-bot
```

## 2. engine.py

```python
# parity/engine.py
from __future__ import annotations
from dataclasses import dataclass, field
from datetime import date, datetime, timezone
from typing import Any, Protocol

class CellFacts(Protocol):
    cell: str
    def get(self, source: str) -> Any: ...

class FactUnavailable(Exception):
    """Raised by adapters when a fact cannot be read. Never treated as a match."""

@dataclass(frozen=True)
class Finding:
    check_id: str
    weight: float
    values: dict[str, Any]
    status: str                       # match | diverged | excepted | unknown
    exception: dict | None = None
    note: str = ""

@dataclass
class Result:
    score: float
    passed: bool
    findings: list[Finding] = field(default_factory=list)

def _minor(v: Any) -> str:
    parts = str(v).lstrip("v").split(".")
    return ".".join(parts[:2])

def _honoured(ex: dict, values: dict[str, Any], ctx: dict, now: datetime) -> bool:
    if "expires" in ex and date.fromisoformat(str(ex["expires"])) < now.date():
        return False
    scope = ex.get("scope")
    if scope == "patch-only":
        return len({_minor(v) for v in values.values()}) == 1
    if scope == "ring-window":
        started = ctx.get("canary_started_at")
        if started is None:
            return False
        return (now - started).total_seconds() <= int(ex["max_age_minutes"]) * 60
    if scope is None:
        return "expires" in ex          # unscoped exceptions must expire
    return False                        # unknown scope → not honoured

def evaluate(contract: dict, facts: list[CellFacts], exceptions: list[dict],
             ctx: dict | None = None, now: datetime | None = None) -> Result:
    now = now or datetime.now(timezone.utc)
    ctx = ctx or {}
    findings: list[Finding] = []
    for chk in contract["checks"]:
        values: dict[str, Any] = {}
        unknown_note = ""
        for f in facts:
            try:
                values[f.cell] = f.get(chk["source"])
            except FactUnavailable as e:
                values[f.cell] = None
                unknown_note = f"{f.cell}: {e}"
        if unknown_note:
            findings.append(Finding(chk["id"], float(chk["weight"]), values, "unknown", note=unknown_note))
            continue
        if len({_canon(v) for v in values.values()}) == 1:
            findings.append(Finding(chk["id"], float(chk["weight"]), values, "match"))
            continue
        ex = next((e for e in exceptions if e["check"] == chk["id"] and _honoured(e, values, ctx, now)), None)
        status = "excepted" if ex else "diverged"
        findings.append(Finding(chk["id"], float(chk["weight"]), values, status, exception=ex))

    total = sum(f.weight for f in findings)
    good = sum(f.weight for f in findings if f.status in ("match", "excepted"))
    score = good / total if total else 0.0
    return Result(score=score, passed=score >= float(contract.get("pass_threshold", 1.0)), findings=findings)

def _canon(v: Any) -> str:
    """Order-insensitive canonical form so dict/list ordering never causes false divergence."""
    import json
    if isinstance(v, (list, tuple, set)):
        try:
            return json.dumps(sorted(v, key=lambda x: json.dumps(x, sort_keys=True)), sort_keys=True)
        except TypeError:
            return json.dumps(list(v), sort_keys=True, default=str)
    return json.dumps(v, sort_keys=True, default=str)
```

## 3. facts.py (Strategy adapters)

```python
# parity/facts.py
from __future__ import annotations
import hashlib, json, subprocess
from functools import cached_property
from typing import Any
from .engine import FactUnavailable

class BaseFacts:
    """Shared Kubernetes + Terraform + SQL readers; cloud subclasses add database/cache sources."""

    def __init__(self, cell: str, stack_dir: str, kube_context: str, dsn: str, contract: dict):
        self.cell, self.stack_dir, self.kube_context, self.dsn, self.contract = cell, stack_dir, kube_context, dsn, contract

    # ---- dispatcher ----
    def get(self, source: str) -> Any:
        fn = getattr(self, "fact_" + source.replace(".", "_"), None)
        if fn is None:
            raise FactUnavailable(f"no adapter for {source} in {type(self).__name__}")
        try:
            return fn()
        except FactUnavailable:
            raise
        except Exception as e:                       # any read failure is 'unknown', never a match
            raise FactUnavailable(f"{source}: {type(e).__name__}: {e}") from e

    # ---- sources ----
    @cached_property
    def tf(self) -> dict:
        out = subprocess.run(["terraform", f"-chdir={self.stack_dir}", "output", "-json"],
                             capture_output=True, text=True, check=True)
        return {k: v["value"] for k, v in json.loads(out.stdout).items()}

    @cached_property
    def k8s(self):
        from kubernetes import client, config
        config.load_kube_config(context=self.kube_context)
        return client

    def _rollouts(self) -> list[dict]:
        api = self.k8s.CustomObjectsApi()
        return api.list_namespaced_custom_object("argoproj.io", "v1alpha1", "cb-app", "rollouts")["items"]

    # ---- facts ----
    def fact_cluster_k8s_minor(self) -> str:
        v = self.k8s.VersionApi().get_code()
        return f"{v.major}.{v.minor.rstrip('+')}"

    def fact_workloads_image_digests(self) -> dict[str, str]:
        out = {}
        for r in self._rollouts():
            img = r["spec"]["template"]["spec"]["containers"][0]["image"]
            if "@sha256:" not in img:
                raise FactUnavailable(f"{r['metadata']['name']} not pinned by digest: {img}")
            out[r["metadata"]["name"]] = img.split("@", 1)[1]      # mirror prefix differs by design
        return out

    def fact_workloads_requests(self) -> dict[str, dict]:
        return {r["metadata"]["name"]: r["spec"]["template"]["spec"]["containers"][0].get("resources", {}).get("requests", {})
                for r in self._rollouts()}

    def fact_k8s_hpa_max(self) -> dict[str, int]:
        hpas = self.k8s.AutoscalingV2Api().list_namespaced_horizontal_pod_autoscaler("cb-app").items
        return {h.metadata.name: h.spec.max_replicas for h in hpas}

    def fact_k8s_networkpolicy_count(self) -> int:
        return len(self.k8s.NetworkingV1Api().list_namespaced_network_policy("cb-app").items)

    def fact_k8s_configmap_hash(self) -> str:
        exclude = set(self.contract.get("config_hash_exclude", []))
        h = hashlib.sha256()
        for cm in sorted(self.k8s.CoreV1Api().list_namespaced_config_map("cb-app").items, key=lambda c: c.metadata.name):
            if cm.metadata.name == "kube-root-ca.crt":
                continue
            data = {k: v for k, v in (cm.data or {}).items() if k not in exclude}
            h.update(json.dumps({cm.metadata.name: data}, sort_keys=True).encode())
        return h.hexdigest()[:16]

    def fact_argocd_chart_versions(self) -> dict[str, str]:
        api = self.k8s.CustomObjectsApi()
        apps = api.list_namespaced_custom_object("argoproj.io", "v1alpha1", "argocd", "applications")["items"]
        return {a["metadata"]["name"]: a.get("status", {}).get("sync", {}).get("revisions", ["?"])[0][:12] for a in apps}

    def fact_sql_flyway_version(self) -> str:
        import psycopg
        with psycopg.connect(self.dsn, connect_timeout=5) as c:
            row = c.execute("select max(version) from flyway_schema_history where success").fetchone()
        return str(row[0])

    def fact_cell_shape(self) -> dict:
        s = self.tf["cell"]["shape"]
        return {"vcpu": s["vcpu"], "mem_gib": s["mem_gib"], "class": s["class"]}

class AwsManagedFacts(BaseFacts):
    def fact_database_major(self) -> str:
        import boto3
        db = boto3.client("rds", region_name="ap-south-1").describe_db_instances(DBInstanceIdentifier=self.cell)["DBInstances"][0]
        return db["EngineVersion"].split(".")[0]

    def fact_database_params(self) -> dict:
        import boto3
        rds = boto3.client("rds", region_name="ap-south-1")
        group = rds.describe_db_instances(DBInstanceIdentifier=self.cell)["DBInstances"][0]["DBParameterGroups"][0]["DBParameterGroupName"]
        allow = set(self.contract["pg_params_allowlist"])
        out = {}
        for page in rds.get_paginator("describe_db_parameters").paginate(DBParameterGroupName=group):
            for p in page["Parameters"]:
                if p["ParameterName"] in allow:
                    out[p["ParameterName"]] = p.get("ParameterValue")
        return out

    def fact_cache_major(self) -> str:
        import boto3
        rg = boto3.client("elasticache", region_name="ap-south-1").describe_cache_clusters(ShowCacheNodeInfo=False)
        versions = {c["EngineVersion"].split(".")[0] for c in rg["CacheClusters"] if c["ReplicationGroupId"] == self.cell}
        if len(versions) != 1:
            raise FactUnavailable(f"cache versions {versions}")
        return versions.pop()

class GcpManagedFacts(BaseFacts):
    def fact_database_major(self) -> str:
        return self._sql_instance()["databaseVersion"].split("_")[1]           # POSTGRES_18 → 18

    def fact_database_params(self) -> dict:
        allow = set(self.contract["pg_params_allowlist"])
        flags = self._sql_instance().get("settings", {}).get("databaseFlags", [])
        # Cloud SQL reports only flags you set; RDS reports all — normalise "unset" to the engine default.
        return {f["name"]: f["value"] for f in flags if f["name"] in allow}

    def fact_cache_major(self) -> str:
        out = subprocess.run(["gcloud", "memorystore", "instances", "describe", self.cell, "--location=asia-south1",
                              "--format=value(engineVersion)"], capture_output=True, text=True, check=True)
        return out.stdout.strip().split("_")[1]                                  # VALKEY_9_0 → 9

    def _sql_instance(self) -> dict:
        out = subprocess.run(["gcloud", "sql", "instances", "describe", self.cell, "--format=json"],
                             capture_output=True, text=True, check=True)
        return json.loads(out.stdout)

class K3sFacts(BaseFacts):
    def fact_database_major(self) -> str:
        import psycopg
        with psycopg.connect(self.dsn, connect_timeout=5) as c:
            return c.execute("show server_version").fetchone()[0].split(".")[0]

    def fact_cache_major(self) -> str:
        import redis
        info = redis.Redis.from_url(self.contract["cells_valkey_url"][self.cell]).info("server")
        return str(info.get("valkey_version", info.get("redis_version"))).split(".")[0]
```
Parameter normalisation is a real leaky abstraction: RDS lists every parameter with defaults, Cloud SQL lists only flags you set. Normalise both to "explicit value or engine default" (keep a defaults table per PG major) before comparing — otherwise `pg.params` diverges forever on nothing.

## 4. cli.py

```python
# parity/cli.py
import argparse, json, os, sys
from datetime import datetime, timezone
import yaml
from .engine import evaluate
from .facts import AwsManagedFacts, GcpManagedFacts, K3sFacts

ADAPTERS = {"aws-managed": AwsManagedFacts, "gcp-managed": GcpManagedFacts, "k3s": K3sFacts}

def main() -> int:
    ap = argparse.ArgumentParser(prog="parity")
    ap.add_argument("--contract", default="parity/contract.yaml")
    ap.add_argument("--exceptions", default="parity/exceptions.yaml")
    ap.add_argument("--cells", default="parity/cells.yaml", help="cell → adapter, stack dir, kube context, dsn env var")
    ap.add_argument("--trigger", default="manual", choices=["pr", "post_sync", "nightly", "manual"])
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()

    contract = yaml.safe_load(open(a.contract))
    exceptions = yaml.safe_load(open(a.exceptions)) or []
    cells = yaml.safe_load(open(a.cells))[contract["env"]]
    facts = [ADAPTERS[c["adapter"]](cell=name, stack_dir=c["stack"], kube_context=c["context"],
                                    dsn=os.environ[c["dsn_env"]], contract=contract)
             for name, c in cells.items()]
    ring = yaml.safe_load(open("gitops/releases/ring-canary.yaml"))
    ctx = {"canary_started_at": datetime.fromisoformat(ring["releasedAt"].replace("Z", "+00:00"))}

    res = evaluate(contract, facts, exceptions, ctx)
    if a.json:
        print(json.dumps({"score": res.score, "passed": res.passed,
                          "findings": [f.__dict__ for f in res.findings]}, default=str, indent=2))
    else:
        print(f"parity score {res.score:.3f} — {'PASS' if res.passed else 'FAIL'}")
        for f in res.findings:
            mark = {"match": "  ", "excepted": "~ ", "diverged": "✗ ", "unknown": "? "}[f.status]
            print(f"{mark}{f.check_id:<22} w={f.weight:<3} {f.status:<9} {json.dumps(f.values, default=str)[:110]}")
    return 0 if res.passed else 1

if __name__ == "__main__":
    sys.exit(main())
```

## 5. .github/workflows/parity.yml

```yaml
name: parity
on:
  schedule:
    - cron: "30 21 * * *"         # 03:00 IST
  repository_dispatch:
    types: [argocd-synced]
  workflow_dispatch: {}
permissions:
  contents: read
  id-token: write
  issues: write
  statuses: write
jobs:
  check:
    runs-on: ubuntu-24.04
    strategy:
      matrix:
        env: [prod, budget]
    steps:
      - uses: actions/checkout@<sha>
      - uses: actions/setup-python@<sha>
        with:
          python-version: "3.14"
      - uses: aws-actions/configure-aws-credentials@<sha>
        with:
          role-to-assume: ${{ vars.AWS_PARITY_ROLE }}      # read-only + EKS access entry (view policy)
          aws-region: ap-south-1
      - uses: google-github-actions/auth@<sha>
        with:
          workload_identity_provider: ${{ vars.GCP_WIF_PROVIDER }}
          service_account: ${{ vars.GCP_PARITY_SA }}
      - run: pip install -e control-plane/parity-checker
      - id: run
        run: |
          set +e
          python3 -m parity.cli --contract parity/contract-${{ matrix.env }}.yaml --trigger nightly --json > parity.json
          echo "rc=$?" >> "$GITHUB_OUTPUT"
        env:
          CB_AWS_DSN: ${{ secrets.CB_AWS_PARITY_DSN }}
          CB_GCP_DSN: ${{ secrets.CB_GCP_PARITY_DSN }}
      - run: |
          curl -fsS -X POST "${{ vars.CB_CP_API }}/parity/snapshots" -H "Authorization: Bearer ${{ secrets.CB_CP_TOKEN }}" \
            -H 'Content-Type: application/json' --data @parity.json
      - if: steps.run.outputs.rc != '0'
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          gh issue create --label parity --title "parity (${{ matrix.env }}): divergence $(date -u +%F)" \
            --body "$(jq -r '.findings[] | select(.status=="diverged" or .status=="unknown") | "- \(.check_id): \(.status) \(.values)"' parity.json)"
          exit 1
```
