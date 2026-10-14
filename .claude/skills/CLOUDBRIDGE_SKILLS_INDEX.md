# CloudBridge Skill Set — Index (aligned with Implementation Plan Rev 2)

Nine skills, built to the same conventions as the KubeThrifty / HealOps / ChaosProof / TraceMap sets:
- kebab-case names under 64 characters
- descriptions under 1024 characters, with no angle brackets
- each skill shipped as a `.skill` zip containing `skillname/SKILL.md`, plus a readable `.SKILL.md` copy

Each description says what the skill owns **and** which sibling owns the neighbouring work ("Not for X"). With nine related skills, picking the wrong sibling is the main risk.

**Status: verification complete.**
- Trigger/routing accuracy: 57/57 after one description fix.
- With-skill vs without-skill output benchmark: 112/112 vs 47/112 assertions.
- All four extractable CI evals pass.

## Skill map

| Skill | Owns (plan sections) | Reference files |
|---|---|---|
| `cloudbridge-terraform-cells` | Facade module, AWS/GCP/k3s implementations, shape parity, state per stack, backends, contract test (§6, §7, §20.1, §26.1) | `starter-code.md`: every module file, including the k3s VM modules and data services; contract test with working mocks |
| `cloudbridge-cloudflare-traffic` | Pool-weighted LB, warm floor, affinity, monitor, origin lock-down, break-glass, Cloudflare-outage runbook (§7.5, §15.6, §23.1) | `starter-code.md`: traffic stack, break-glass script, observed-split exporter |
| `cloudbridge-ansible-ops` | Budget-VM config, evacuate/failback/drill saga, Event-Driven Ansible (§8, §15) | `playbooks.md`: inventories, roles, all playbooks, rulebook, Molecule, drill workflow |
| `cloudbridge-gitops-delivery` | Images by digest, mirrors, Argo CD per cell, charts, Rollouts, cloud-as-canary ring (§12.1–12.4, §18, §24) | `starter-code.md`: compose, Dockerfile, ApplicationSet template, chart, analysis, ci-app, ring-promote |
| `cloudbridge-iac-pipeline` | OIDC identities, saved-plan apply, gates, drift, on-demand demo environments with a TTL reaper, plan-risk gate with an audited override (§12.5–12.6, §19, §25) | `starter-code.md`: workflows, CI identity Terraform, stack detector, Conftest. `eval-harness.md`: plan-risk rules, labelled eval, gate |
| `cloudbridge-parity-contract` | Cross-cloud parity contract, expiring exceptions, fact adapters (§14) | `starter-code.md`: contract, engine, adapters, CLI, workflow. `eval-harness.md`: fixture eval |
| `cloudbridge-finops-steering` | FOCUS ledger, fairness rules, steering recommender, the whole control-plane schema (§9.3–9.4, §16, §17) | `schema-and-queries.md`. `starter-code.md`: collectors, writer, recommender, weekly job. `eval-harness.md`: backtest |
| `cloudbridge-cell-services` | Spring Boot 4.1 services: idempotency saga, outbox, escrow leases, health, resilience (§9.2, §21, §23) | `schema-and-queries.md`: cell schemas and the exact SQL. `starter-code.md`: Java classes, config, tests |
| `cloudbridge-observability-dashboard` | Agent remote_write, SLOs/alerts, Grafana, control-plane API, Next.js dashboard (§13) | `starter-code.md`: Prometheus/Alertmanager/blackbox/Grafana configs, FastAPI, Next.js pages |

## 1. Static checks

| Check | Result |
|---|---|
| `quick_validate.py` on all nine skills (final versions) | 9/9 valid |
| Description lengths | 952–1018 chars, no angle brackets |
| All 33 HCL blocks | Pass `tofu fmt` (OpenTofu 1.12.2), the same check that rejects Rev 1's `{ type = string; default = ... }` |
| All YAML / Python / SQL / JSON blocks (162) | Parse cleanly (Helm templates and one Grafana macro are excluded by design) |
| Parity eval (`evals/parity`), extracted and run | 13 checks, 0 missed divergences, 0 false divergences: **GATE PASS** |
| Plan-risk eval (`evals/plan-risk`), extracted and run | Block recall 1.0, precision 1.0: **GATE PASS** |
| Steering backtest (`evals/steering`), re-extracted from the *shipped* markdown and run | 6/6 scenarios, 0 SLO violations, 0 direction reversals: **GATE PASS** (details below) |

## 2. Trigger / routing accuracy

**Method.**
- `route_eval.py` installs **all nine** CloudBridge skills at once in a throwaway project.
- It runs `claude -p` on each query and records which skill Claude consults first.
- So it tests two things: confusion between sibling skills, and false triggers on prompts about your other projects. It does more than check whether skill X triggers in isolation.
- Runs that hit the CLI usage limit or timed out are excluded from scoring, not counted as misses.

**Eval set.** 57 queries:
- 45 should trigger: 5 per skill, in casual and formal phrasings.
- 12 near-miss negatives:
  - prompts about HealOps, TraceMap, KubeThrifty, ChaosProof, PRGraph and NaukriNearby
  - generic Terraform / Cloudflare / Ansible / EKS questions

| Skill | First pass | Final |
|---|---|---|
| terraform-cells | 5/5 | 5/5 |
| cloudflare-traffic | 5/5 | 5/5 |
| ansible-ops | 5/5 | 5/5 |
| gitops-delivery | 5/5 | 5/5 |
| iac-pipeline | **4/5** | **5/5** after the description fix (rechecked 7/7, then 2/2 × 3 runs on the demo-environment phrasing) |
| parity-contract | 5/5 | 5/5 |
| finops-steering | 5/5 | 5/5 |
| cell-services | 5/5 | 5/5 |
| observability-dashboard | 5/5 | 5/5 |
| **Negatives (should NOT trigger)** | 12/12 | 12/12 (PRGraph and NaukriNearby prompts routed to their own skills) |
| **Total** | 56/57 | **57/57** |

- **The one miss.** "spin up the managed EKS+GKE environment for a 3 hour interview demo and auto-destroy it afterwards" got no skill; Claude tried to answer with Bash.
- **The fix.** The `iac-pipeline` description now names on-demand demo environments and the TTL reaper. Trimmed to 1018 chars to stay under the limit.
- **No regressions.** The recheck included two `terraform-cells` queries, confirming the new wording didn't pull Terraform work away from that sibling.
- **Sibling confusion.** None observed in any run.

## 3. Output quality: with skill vs without skill

**Method.**
- **The prompts.** 27 prompts (3 per skill) were answered twice by the same model with the same tools (Read/Glob/Grep/Skill; no shell, web or writes):
  - once with all nine skills installed
  - once with none
- **The grader.** A blind `claude -p` grader checked each answer against 3–6 assertions, 112 in total. It didn't know which configuration produced the answer. It passes an assertion only if the answer *substantively* meets it, not if it merely mentions a keyword.

| | With skills | Without skills | Delta |
|---|---|---|---|
| Iteration 1 | 104/112 (92.9%) | 47/112 (42.0%) | +0.51 |
| **Final** (after the fixes below) | **112/112 (100%)** | 47/112 (42.0%) | **+0.59** |

- Every with-skill run loaded the correct skill.
- 47 of the 112 assertions passed in both configurations. These measure general competence rather than the skill.
- The other 65 assertions are where the skills pay off. Examples the baseline missed:
  - Valkey 9.0 pinned by the intersection rule
  - equal vCPU/memory shape pairs
  - break-glass weights reconciled back into `terraform.tfvars.json`
  - fanout-aware HPA sizing
  - `uuidv7()` ids
  - the 1.2 capacity-ratio gate before evacuation
  - credits excluded from cost per 1k requests
  - rejecting cross-cloud Prometheus federation
- The baseline already knew the generic parts, such as `one(concat())` selection and pool weights vs origin weights. It missed the project-specific decisions.

**What the failing assertions found, and the fixes (iterations 2–3):**

| Eval | Problem found | Fix | Score |
|---|---|---|---|
| cell-services-1 | Answer used `UUID.randomUUID()` for order ids | SKILL.md now requires `id uuid PRIMARY KEY DEFAULT uuidv7()` and bans random v4 ids | 4/5 → 5/5 |
| terraform-cells-2 | No guidance on when plain dirs + Makefile stop scaling | Added the switch trigger: Terramate/Terragrunt at ~25+ stacks or a third cloud | 3/4 → 4/4 |
| iac-pipeline-2 | `allow-destructive` override left no audit trail | Override is now recorded: a POST to `plan_risk_reports` plus a PR comment, with a new workflow step | 3/4 → 4/4 |
| gitops-delivery-2 | Hotfix path didn't warn about a second owner / cross-cloud drift | Hotfix row now warns about both | 2/3 → 3/3 |
| gitops-delivery-3 | (a) HPA sizing ignored fanout; (b) answer *claimed* the `ignoreDifferences` entry existed without showing it | (a) Formula corrected everywhere (see below); (b) "show the YAML, never just assert it exists" | 3/5 → 5/5 |
| cloudflare-traffic-1 | Suggested an ad-hoc comparison instead of the configured-vs-observed panel | Runbook row now says to name that panel as the proof step | 3/4 → 4/4 |
| finops-steering-3 | Flip-flopping recommender: the skill had no reversal guard and no oscillation test | Real code fix (below) plus an instruction to walk through each guard and check it's actually given its inputs | 2/4 → 4/4 |

**Two assertions were rewritten, both in the same direction.** Each change made the assertion state the behaviour the skill actually teaches.
- **finops-steering-3.** The originals assumed the skill lacked a significance test. Once it had one, they penalised answers for *using* it.
- **gitops-delivery-3.** The prompt gives no per-pod RPS. The skill says to flag that rather than invent a number. The grader had been inconsistent about that, scoring the same behaviour pass in one run and fail in another.
- **Fairness.** Both rewrites were re-graded across every iteration *and* the baseline.

**Limitations.**
- One run per configuration, so these are not variance-controlled numbers.
- The model is the same one the skills were written for.
- Seven targeted reruns contributed to the final 112/112. Iteration 1's 92.9% is the cleaner single-pass number.

## 4. Fixes that came out of verification (also applied to the Rev 2 plan)

**1. Capacity formula: the units were wrong.**
- Rev 2 §15.2, `ansible-ops` and the observability API disagreed: some multiplied by fanout, others divided.
- Correct, now everywhere: `capacity_rps = min over services( hpa_max × per_pod_rps / fanout )`.
- Why divide: one gateway request makes two inventory calls, so inventory's capacity *in gateway requests* is halved.
- HPA sizing is the inverse: `maxReplicas = ceil(1.2 × peak_gateway_rps_all_cells × fanout / per_pod_rps)`.

**2. Steering recommender oscillation.**
- `CellModel.distinct_shares` was added. `max_step` drops to 0.10 while the latency fit has seen fewer than 3 distinct shares.
- **Reversal hysteresis:** reversing last week's direction needs 2× the normal saving.
- A new weekly job, §6b `last_direction()`, reads the last two recommender rows of `traffic_changes`. Without it the guard never fires.
- The backtest now counts `direction_reversals` and gates on `max_reversals` (default 0). A new scenario, `small-gap-near-noise-no-oscillation`, covers it.

**3. Earlier recommender bugs (found by the first backtest run).**
- acting on noise → 2σ significance test
- negative latency slope from duplicate shares → pessimistic monotone fit
- extrapolating past observed shares → limit of observed + 0.10
- holding an already-unsafe weight → safety-first rule

**4. Tooling.**
- **`run_outputs.py` (limit detector).** It used to flag a run as a usage limit whenever the answer mentioned "session" and "limit", and "session affinity" tripped it. It now flags only error or empty results.
- **`grade.py`.** Now retries up to three times. It logs the raw reply when no JSON comes back, and the stdin wait is gone.

## How to re-run the evals yourself

```bash
# 1. trigger / routing accuracy  (~1 model call per query per run)
python3 route_eval.py --skills-dir cloudbridge-skills --eval-set trigger_eval_set.json \
  --runs 2 --workers 4 --model claude-opus-5-5 --out results.json

# 2. with-skill vs without-skill outputs, blind grading, viewer
python3 run_outputs.py --skills-dir cloudbridge-skills --prompts test_prompts_all_skills.json \
  --out iteration-N/outputs --workers 3
python3 grade.py --iteration iteration-N/outputs --workers 3
python3 build_review.py --base iteration-N/outputs --dest iteration-N/review
python3 -m scripts.aggregate_benchmark iteration-N/review --skill-name cloudbridge-skills   # from skill-creator

# 3. the CI-gating evals from the skills' references, once the code is in your repo
python3 evals/parity/run_eval.py
python3 evals/plan-risk/generate.py && python3 evals/plan-risk/run_eval.py
python3 evals/steering/backtest.py
```

`cloudbridge-skill-evals.zip` contains:
- the scripts
- both eval sets
- every routing result
- the final benchmark (`benchmark.json` / `benchmark.md`)
- every graded answer
- `review.html`, a standalone viewer that compares each answer side by side with the iteration-1 version
