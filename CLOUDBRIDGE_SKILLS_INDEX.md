# CloudBridge Skill Set — Index (aligned with Implementation Plan Rev 2)

Nine skills, same conventions as the KubeThrifty / HealOps / ChaosProof / TraceMap sets: kebab-case names under 64 chars, descriptions under 1024 chars with no angle brackets, `.skill` zip with `skillname/SKILL.md` inside, plus a readable `.SKILL.md` copy. Each description says what it owns **and** which sibling owns the neighbouring work ("Not for X"), because with nine related skills the main risk is picking the wrong sibling.

## Skill map

| Skill | Owns (plan sections) | Reference files |
|---|---|---|
| `cloudbridge-terraform-cells` | Facade module, AWS/GCP/k3s implementations, shapes parity, state-per-stack, backends, contract test (§6, §7, §20.1, §26.1) | `starter-code.md` — every module file incl. k3s VM modules, data services, contract test with working mocks |
| `cloudbridge-cloudflare-traffic` | Pool-weighted LB, warm floor, affinity, monitor, origin lock-down, break-glass, Cloudflare-outage runbook (§7.5, §15.6, §23.1) | `starter-code.md` — traffic stack, break-glass script, observed-split exporter |
| `cloudbridge-ansible-ops` | Budget-VM config, evacuate/failback/drill saga, Event-Driven Ansible (§8, §15) | `playbooks.md` — inventories, roles, all playbooks, rulebook, Molecule, drill workflow |
| `cloudbridge-gitops-delivery` | Images by digest, mirrors, Argo CD per cell, charts, Rollouts, cloud-as-canary-ring (§12.1–12.4, §18, §24) | `starter-code.md` — compose, Dockerfile, ApplicationSet template, chart, analysis, ci-app, ring-promote |
| `cloudbridge-iac-pipeline` | OIDC identities, saved-plan apply, gates, drift, TTL reaper, plan-risk gate (§12.5–12.6, §19, §25) | `starter-code.md` — workflows, CI identity Terraform, stack detector, Conftest; `eval-harness.md` — plan-risk rules + labelled eval + gate |
| `cloudbridge-parity-contract` | Cross-cloud parity contract, expiring exceptions, fact adapters (§14) | `starter-code.md` — contract, engine, adapters, CLI, workflow; `eval-harness.md` — fixture eval |
| `cloudbridge-finops-steering` | FOCUS ledger, fairness rules, steering recommender, whole control-plane schema (§9.3–9.4, §16, §17) | `schema-and-queries.md`; `starter-code.md` — collectors, writer, recommender; `eval-harness.md` — backtest |
| `cloudbridge-cell-services` | Spring Boot 4.1 services: idempotency saga, outbox, escrow leases, health, resilience (§9.2, §21, §23) | `schema-and-queries.md` — cell schemas + exact SQL; `starter-code.md` — Java classes, config, tests |
| `cloudbridge-observability-dashboard` | Agent remote_write, SLOs/alerts, Grafana, control-plane API, Next.js dashboard (§13) | `starter-code.md` — Prometheus/Alertmanager/blackbox/Grafana configs, FastAPI, Next.js pages |

## What was verified while building

| Check | Result |
|---|---|
| `quick_validate.py` on all nine skills | 9/9 valid |
| Descriptions | 952–1012 chars, no angle brackets |
| All 33 HCL blocks across the skills | Pass `tofu fmt` (OpenTofu 1.12.2) — the same check that rejects Rev 1's `{ type = string; default = ... }` |
| All YAML / Python / SQL / JSON blocks (162 total) | Parse cleanly (Helm templates and one Grafana macro excluded by design) |
| Parity eval (`evals/parity`) — extracted and run | 13 checks, 0 missed divergences, 0 false divergences → GATE PASS |
| Plan-risk eval (`evals/plan-risk`) — extracted and run on generated cases | block recall 1.0, precision 1.0 → GATE PASS |
| Steering backtest (`evals/steering`) — extracted and run | First run **failed** and exposed three recommender bugs (acting on noise, negative latency slope from duplicate shares, holding an already-unsafe weight). Fixed with a 2σ significance test, a pessimistic monotone latency fit, a no-extrapolation limit and a safety-first rule; now 5/5 scenarios pass with 0 SLO violations |

## Test prompts

27 realistic prompts (3 per skill) with assertions are in each skill's `evals/evals.json` and combined in `test_prompts_all_skills.json`. They're written for a with-skill vs without-skill output comparison; that run wasn't done here (see below).

## Trigger / routing accuracy eval

Method: `route_eval.py` installs **all nine** CloudBridge skills at once in a throwaway project, runs `claude -p` on each query, and records which skill Claude consults first. This tests sibling confusion and false triggers on your other capstones (HealOps, TraceMap, KubeThrifty, ChaosProof, PRGraph, NaukriNearby), not just "does skill X trigger in isolation".

Eval set: 57 queries — 45 should-trigger (5 per skill, casual and formal phrasings) and 12 near-miss negatives (other capstones, generic Terraform/Cloudflare/Ansible/EKS questions).

**Results so far (iteration 1):**

| Skill | Scored queries | Correct routing |
|---|---|---|
| cloudbridge-terraform-cells | 5 | 5/5 (10/10 runs) |
| cloudbridge-cloudflare-traffic | 5 | 5/5 (10/10 runs) |
| cloudbridge-ansible-ops | 5 | 5/5 (10/10 runs) |
| remaining 6 skills + 12 negatives | — | **not yet scored**: the nested `claude -p` runs hit the account's session usage limit partway through (resets 02:20 IST). Those runs returned an error, not a routing decision, so they're excluded rather than counted as failures. |

No sibling confusion was observed in the 30 scored runs. The remaining 42 queries are scheduled to re-run after the limit resets; this file and the packages will be updated with the full table (and any description fixes).

## How to re-run the evals yourself

```bash
# trigger / routing accuracy (uses your Claude Code CLI quota: ~1 model call per query per run)
python3 route_eval.py --skills-dir cloudbridge-skills --eval-set trigger_eval_set.json \
  --runs 2 --workers 4 --model claude-opus-5-5 --out results.json

# the three CI-gating evals from the skills' references, once the code is in your repo
python3 evals/parity/run_eval.py
python3 evals/plan-risk/generate.py && python3 evals/plan-risk/run_eval.py
python3 evals/steering/backtest.py
```
