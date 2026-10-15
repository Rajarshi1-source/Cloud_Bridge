---
name: cloudbridge-iac-pipeline
description: Run CloudBridge's infrastructure CI/CD in GitHub Actions - OIDC to AWS and GCP (Workload Identity Federation) with no static keys, the reusable _terraform-stack.yml workflow, saved-plan apply behind environment approvals, per-stack concurrency, affected-stack detection, fmt, tflint, Trivy, terraform test on Terraform 1.15 and OpenTofu 1.12, Conftest, Infracost, the plan-risk gate with its labelled eval set, one sticky PR comment, nightly drift detection, PR preview workspaces, and on-demand demo environments - spinning up the managed EKS plus GKE profile for hours and auto-destroying it with the TTL reaper. Use whenever the user touches infra workflows, wants a temporary demo or interview environment brought up or torn down, asks why apply re-plans, how to block destructive Terraform changes, how CI authenticates to clouds, or how to gate merges on plan risk. MANDATE - apply exactly the reviewed plan, read-only plan roles, SHA-pinned actions, block recall 1.0. Not for app image builds (gitops-delivery).
---

# CloudBridge — IaC Pipeline

The pipeline's job is to make one promise true: **what gets applied is exactly what a human reviewed, by an identity that can only touch that stack, one run at a time.** Rev 1 broke all three (static keys, `apply -auto-approve` that re-planned, no concurrency control).

Workflow files, CI-identity Terraform, the affected-stack detector and Conftest policies are in `references/starter-code.md`. The plan-risk rules, their labelled eval set and the CI gate are in `references/eval-harness.md`.

## Identities (Terraform stack `global/00-ci-identity`, bootstrapped once by a human)

| Identity | OIDC trust condition | Permissions |
|---|---|---|
| `cb-plan-aws` | `sub` = `repo:<you>/cloudbridge:pull_request` | ReadOnlyAccess + state bucket read + lock-file write (`use_lockfile` writes a `.tflock` object even during plan) |
| `cb-apply-aws-<env>` | `sub` = `repo:<you>/cloudbridge:environment:aws-<env>` | Scoped admin for `cb-*` tagged resources + state RW |
| `cb-plan-gcp` / `cb-apply-gcp-<env>` | WIF provider with `attribute_condition` on `assertion.repository` and `assertion.environment` | Viewer / scoped editor |
| `cb-ephemeral-aws` / `cb-ephemeral-gcp` (Week 3, the only ones built so far) | `sub` = `repo:<owner>/<repo>:environment:ephemeral`; WIF `principalSet …/attribute.environment/ephemeral` | AWS: PowerUserAccess + IAM only on `cb-*` roles/instance profiles + state `aws-dev/*`; GCP: container/network/security admin, SA admin, projectIamAdmin (GKE node account grants), AR + Secret Manager admin, state objects under `gcp-dev/` (plus `legacyBucketReader`: an object-name IAM condition never matches the bucket-level list permission) |
| `cb-apply-traffic` | `environment:traffic-prod` | Cloudflare token scoped to one zone's Load Balancing, stored as an **environment** secret (Cloudflare has no OIDC federation for this) |

The environment claim is what makes approvals meaningful: an apply role can only be assumed by a job that is running *inside* a protected environment, i.e. after a reviewer approved it.

## Reusable stack workflow (Template Method)

`_terraform-stack.yml` takes `stack`, `cloud`, `mode` (plan|apply), `env`:
1. `environment:` set only for apply → GitHub pauses for required reviewers.
2. `concurrency: group: tf-<stack>, cancel-in-progress: false` — never cancel a running apply; second run waits.
3. OIDC login to the plan or apply identity.
4. `terraform init -input=false -lockfile=readonly` (lock file is committed; CI never silently upgrades providers).
5. `terraform plan -out=tfplan -lock-timeout=5m` → `terraform show -json tfplan > plan.json` → SHA-256 of plan.json in the job summary.
6. Plan mode: plan-risk gate, Conftest, Infracost diff → artifacts for the comment job.
7. Apply mode: `terraform apply tfplan`. A saved plan refuses to apply if state changed since it was made — the safe failure.

### Apply on merge, correctly

```
push to main touching infra/** → affected stacks in dependency order
  10-foundation (gcp, aws) → 20-bootstrap (gcp, aws) → global/30-traffic
  each: plan job (uploads tfplan) → apply job in environment (reviewer sees plan + hash) → apply tfplan
```
The plan and apply run in the same workflow run, so the artifact the reviewer approved is the one applied. Plan files contain sensitive values: artifact retention 1 day, never posted in comments.

## PR checks (one sticky comment)

| Gate | Tool | Fails PR when |
|---|---|---|
| Format / validity | `terraform fmt -check -recursive`, `validate` per stack | Any |
| Lint | tflint with aws + google rulesets | Error |
| IaC security | Trivy config (`trivy config infra/`) | HIGH/CRITICAL without an inline justification |
| Module contract | `terraform test` (mocks) on Terraform 1.15 **and** `tofu test` on OpenTofu 1.12 | Either engine fails — proves the modules stay engine-agnostic |
| House rules | Conftest on `plan.json` (`infra/policy/*.rego`) | `deny` |
| Cost | Infracost diff | Never fails; posts delta (and per-request framing from the FinOps skill) |
| Plan risk | `control-plane/plan-risk` rules | `block` without the `allow-destructive` label |

The comment shows, per affected stack: change counts, plan-risk verdict + findings, Infracost delta, policy result. AWS and GCP stacks appear side by side so a one-sided change is obvious.

## Plan-risk gate (D6)

Rules decide; an optional LLM only explains.
- **block**: delete or replace of a stateful type (RDS, Cloud SQL, ElastiCache, Memorystore, buckets, EKS/GKE clusters); world-open non-HTTP ingress (SG rule or GCP firewall `0.0.0.0/0`).
- **warn**: IAM wildcard actions; > 40 resources changing; **one-sided change** — affected stacks include `aws-*` but not `gcp-*` (or vice versa), which is a parity divergence unless an exception is added (cloudbridge-parity-contract).
- `allow-destructive` label overrides a block, and the override is **recorded**: the gate job POSTs `{pr_number, stack, plan_sha256, verdict: block, overridden: true, approver}` to the control plane (`plan_risk_reports`) and adds a PR comment naming who applied the label. An override nobody can audit is just a bypass.

Optional explainer: provider-agnostic adapter (`llm.provider`, `llm.model`, default `gpt-5.4-mini`, 10 s timeout, budget breaker). Input = plan JSON summary + rule findings; output = three plain sentences. It never changes the verdict; on any failure the comment shows rules only.

**Eval gate** (`evals/plan-risk/`, run in `evals.yml`): 60 labelled plans; CI fails if block-class recall < 1.00 or precision < 0.90; explainer faithfulness (every resource address it mentions exists in the plan) < 0.98. A missed destructive change is the one error this pipeline can't afford, which is why recall on `block` is pinned at 1.0 rather than "high".

## Scheduled jobs

| Job | Schedule | Behaviour |
|---|---|---|
| `drift.yml` | nightly 02:30 IST | `plan -detailed-exitcode` on every live stack with plan identities; exit 2 → issue labelled `drift` containing the summarised diff (never secrets) |
| `ttl-reaper.yml` | hourly (`17 * * * *`) | Runs `tools/dev/reap-expired.sh` per cloud: reads `expires_at` **from each `*-dev` stack's state** (cloud-agnostic, no tag-search APIs, and it also reaps cells created from a laptop), then `plan -destroy -out` + `apply`. Environment `ephemeral` must have **no required reviewers** or the reaper waits forever; skips a cloud whose identity isn't configured |
| `ephemeral-up.yml` | manual (`cloud`, `ttl_hours` 1–8, `admin_cidr` /24–/32, optional `admin_arn`) | Applies `live/<cloud>-dev` with `TF_VAR_expires_at`; shares the `ephemeral-<cloud>` concurrency group with the reaper so a reap never runs mid-apply |

## Workspaces (where the brief's "workspaces" requirement lives)

Directory-per-stack is the isolation boundary. CLI workspaces are used only for `pr-<n>` preview environments in the dev account: `terraform workspace select -or-create pr-123` in `live/aws-dev/10-foundation`, destroyed when the PR closes. Same backend and credentials are acceptable there because it's dev and short-lived.

## Supply chain

All actions pinned to a full commit SHA, Dependabot updates them. Tool versions pinned (`setup-terraform` with `1.15.x`, `opentofu/setup-opentofu` with `1.12.x`, Trivy, tflint, Conftest, Infracost). `permissions:` set per workflow to the minimum (`id-token: write` only where OIDC is used).

## Debugging checklist

| Symptom | Likely cause |
|---|---|
| `Error acquiring the state lock` in CI | Another run holds it — concurrency group missing, or a cancelled run left a lock; `force-unlock` only after confirming no apply is running |
| `Saved plan is stale` | State changed between plan and apply (another merge) — re-run the workflow; this is the safety working |
| AWS `Not authorized to perform sts:AssumeRoleWithWebIdentity` | `sub` claim mismatch — PR jobs present `pull_request`, environment jobs present `environment:<name>` |
| GCP `Permission iam.serviceAccounts.getAccessToken denied` | Missing `roles/iam.workloadIdentityUser` binding for the principalSet |
| Engines job fails only on OpenTofu | A Terraform-only feature crept into modules (e.g. a 1.15-only attribute) — keep it out of shared modules |

## Interview soundbites

- "My pipeline applies the exact plan the reviewer approved — a saved plan refuses to apply if state moved."
- "Plan roles are read-only; apply roles can only be assumed from inside an approved environment."
- "The plan-risk gate has an eval set, and its recall on destructive changes is pinned at 1.0 — that's a merge gate, not a hope."
