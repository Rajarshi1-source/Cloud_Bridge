---
name: cloudbridge-parity-contract
description: Build and operate CloudBridge's cross-cloud parity check - parity/contract.yaml (weighted checks such as k8s minor, image digests, chart versions, rendered config hash, resource requests, HPA bounds, NetworkPolicy count, Postgres and Valkey major, Postgres parameter allowlist, Flyway schema version, shape class), parity/exceptions.yaml with owners and expiry dates, the Python checker with per-cloud fact adapters (Strategy pattern), scoring, the post-sync, nightly and PR-time runs, and its fixture-based eval. Use whenever the user wants to know whether the AWS and GCP cells are still identical, asks about drift between clouds, wants to add a parity check or an exception, sees a failing parity job, or asks how CloudBridge differs from Terraform drift detection or Argo CD sync status, even if they never say parity. MANDATE - an unreadable fact is unknown, never a match; expired exceptions fail; the checker reports, it never mutates a cell. Not for single-stack Terraform drift (iac-pipeline).
---

# CloudBridge — Parity Contract (D1)

"Same app on two clouds" decays quietly: a hotfix lands in one cell, GKE auto-upgrades a patch, someone edits an RDS parameter group in the console. The failover you rely on then lands on a cell that isn't the same. Existing tools look at the wrong pair:

| Tool | Compares | Misses |
|---|---|---|
| Terraform drift (`plan -detailed-exitcode`, platform drift detection) | one stack vs its own code | cell A vs cell B |
| Argo CD sync status | one cluster vs Git | per-cell values that legitimately differ, and anything not in Git |
| Parity contract | **cell A vs cell B**, semantically | — (that's its job) |

Starter code (contract, exceptions, engine, fact adapters, CLI, workflow) is in `references/starter-code.md`; the fixture eval is in `references/eval-harness.md`.

## Contract model

`parity/contract.yaml` lists checks; each has an `id`, a `source` (a fact path the adapters understand) and a `weight`. Weights express how badly a divergence hurts failover:

| Weight | Checks | Why |
|---|---|---|
| 5 | `images.digests`, `flyway.version` | Different code or schema = different behaviour under the same traffic |
| 4 | `app.config.hash` | Same code, different config is still different behaviour |
| 3 | `k8s.minor`, `chart.versions`, `hpa.max`, `pg.major` | Platform behaviour and evacuation capacity |
| 2 | `resources.requests`, `networkpolicy.count`, `pg.params`, `valkey.major`, `shape.class` | Performance and security posture |

`hpa.max` compares **max** replicas — both cells must be able to take 100% of traffic — while min may differ by profile. `app.config.hash` hashes rendered ConfigMaps after removing allowlisted per-cell keys (`CB_CELL`, `CLOUD`, `*_MIRROR`, `SECRET_STORE`).

`score = Σ weight(match or excepted) / Σ weight(all)`; pass requires `score == 1.0` (every check matches or is excepted). A score below 1 is not "mostly fine" — it is a list of specific divergences.

## Exceptions are loans

```yaml
- check: k8s.minor
  scope: patch-only            # honoured only if the minor versions are equal
  reason: "GKE Regular auto-upgraded the patch"
  owner: ricky
  expires: 2026-11-15
- check: images.digests
  scope: ring-window           # honoured only while the canary is younger than max_age_minutes
  max_age_minutes: 120
  owner: release-bot
```
Rules: every exception has `owner`, `reason` and either `expires` or a time-bounded `scope`. Expired → the check is `diverged` again. Scopes are evaluated by code, not trusted: `patch-only` recomputes minors; `ring-window` reads the canary start time from the ring file. The release flow (cloudbridge-gitops-delivery) relies on `ring-window`: a canary stuck longer than 2 hours becomes a CI failure.

## Facts: Strategy per cloud × profile

`CellFacts.get(source)` is implemented by `AwsManagedFacts`, `GcpManagedFacts`, `K3sFacts` — each reads from the sources it can reach: Terraform outputs (via `terraform output -json` with the plan identity), the cell's Kubernetes API (read-only ServiceAccount, through Argo CD's API or a short-lived kubeconfig), the cloud API for database parameters, and a read-only SQL user for `flyway_schema_history`.

**An unreadable fact is `unknown`, never `match`.** A checker that silently passes when it can't see is worse than no checker. `unknown` counts against the score and is reported with the exception type.

## Where it runs

| Trigger | What runs | Effect |
|---|---|---|
| PR (`iac-pr.yml` / plan-risk) | "one-sided change" rule — affected stacks touch one cloud only | warn in PR comment |
| Argo CD sync of either cell (notification → `repository_dispatch`) | full contract for that env | commit status on the release PR; issue on failure |
| Nightly 03:00 IST | full contract for `prod` and `budget` | issue + Slack on failure; snapshot stored |
| Manual `parity check --env prod` | full contract, table output | — |

Snapshots go to `parity_snapshots` + `parity_findings` (schema in cloudbridge-finops-steering `references/schema-and-queries.md`). Dashboard: score trend, current divergences, exceptions expiring in 7 days.

The checker **never changes a cell**. Fixing a divergence is a normal PR — Terraform, Argo or Ansible — so the fix is reviewed like any other change.

## Adding a check

1. Add the entry to `contract.yaml` with a weight justified by "how much does this divergence hurt failover?".
2. Implement the `source` in every fact adapter (or return `unknown` deliberately with a comment).
3. Add an eval fixture pair that diverges on it and one that matches (`references/eval-harness.md`); the eval gate requires zero missed divergences.
4. If it can legitimately differ per cloud, write down why in `docs/leaky-abstractions.md` and add an allowlist rule rather than a permanent exception.

## Profiles

`env: budget` contracts drop managed-only checks (`pg.params` from RDS/Cloud SQL APIs) and add `k3s.version` against the managed minor. Budget and managed are compared within their own env, never against each other.

## Interview soundbites

- "Terraform drift tells me a stack differs from its code; Argo tells me a cluster differs from Git. Neither tells me AWS differs from GCP — and that's the drift that breaks failover."
- "Twelve weighted checks, from image digest to Flyway schema version. A canary is an allowed two-hour divergence; a forgotten hotfix fails the next night."
- "If the checker can't read a fact, it's unknown, not a pass."
