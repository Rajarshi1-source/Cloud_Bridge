# CloudBridge — Multi-Cloud Deployment Automation (AWS + GCP) with Terraform + Ansible

## Implementation Plan — Rev 2 (Audit + Upgrade)

**Target role:** Junior DevOps / Platform / SRE Engineer (Bangalore, 2026–27 hiring cycle)
**Build window:** 8 weeks (6-week cut line defined in §4.4)
**Versions verified:** 7 October 2026 (see §B — re-verify patch versions on the day you start building)
**Supersedes:** `CloudBridge_Implementation_Plan.md` (Rev 1)

> **Tagline (Rev 2):** *One codebase. Two clouds. Zero blind spots.*
> Rev 1 proved you can deploy to two clouds. Rev 2 proves the two clouds are **still identical**, that the smaller one can **actually absorb all traffic**, and which one is **cheaper per request** — with evidence, not adjectives.

---

## How to read this document

| Part | Sections | What it is |
|---|---|---|
| Audit | §A, §B, §C | What Rev 1 got right, what was missing vs your brief, version matrix, and 23 defects with fixes |
| Foundation | §1 – §13 | Overview, stack, MVP, HLD, LLD (Terraform + Ansible), DB, cache/messaging, patterns, Docker/K8s, CI/CD, observability |
| Differentiators | §14 – §20 | Eight features that beat existing open-source tools, each with design, code, eval gate, and interview framing |
| Cross-cutting | §21 – §29 | Resilience, mitigation, availability/consistency, deployment strategies, security, scaling decisions, cost plan, README, interview prep |
| Appendix | §30 | Sources and verification log |

---

# §A — Completeness Audit (Rev 1 vs Your Brief)

Legend: ✅ present and correct · ⚠️ present but flawed (fixed in Rev 2) · ❌ missing (added in Rev 2)

| # | Brief requirement | Rev 1 | Rev 2 location |
|---|---|---|---|
| 1 | Terraform modules deploy the same Spring Boot microservices to EKS and GKE from one codebase | ⚠️ root module could not plan (C1) | §6, §7 |
| 2 | GitHub Actions with environment-specific Terraform workspaces | ⚠️ workspaces misused as a cross-credential isolation boundary (C3) | §12, §26.1 |
| 3 | 70% AWS / 30% GCP split via Cloudflare load balancer | ⚠️ weights placed where they cannot split traffic (C2) | §7.5 |
| 4 | Cost comparison dashboard, per-service spend across both clouds | ⚠️ unfair comparison + unmeasured numbers (C9, C10) | §9, §17 |
| 5 | Tech stack with exact versions | ⚠️ multiple EOL/outdated pins (C13) | §B, §2 |
| 6 | MVP blueprint | ✅ (re-scoped) | §4 |
| 7 | Detailed system design / architecture (HLD) | ✅ (extended with cells, control plane placement) | §5 |
| 8 | Low-level design | ⚠️ code would not run as written | §6, §7, §8 |
| 9 | Database design + best choice among PostgreSQL / NoSQL / TimescaleDB / Cosmos DB / Cassandra / MongoDB | ✅ verdict kept (PostgreSQL), schema rebuilt on FOCUS | §9 |
| 10 | Cache/messaging choice among Redis / Kafka / ZooKeeper / RabbitMQ | ⚠️ Redis used for state locking (C4); ZooKeeper not addressed | §10 |
| 11 | Design patterns | ✅ (extended: cell, escrow/lease, saga, outbox, adapter) | §11 |
| 12 | Docker & Kubernetes deployment strategy | ⚠️ Terraform and `helm upgrade` both own the same releases (C7) | §12 |
| 13 | DevOps / MLOps wrapper | ❌ no eval gates, no drift job, no policy gates | §13, §19, §20 |
| 14 | Resilience patterns | ❌ | §21 |
| 15 | Mitigation strategies | ❌ | §22 |
| 16 | Availability and consistency patterns | ⚠️ one Q&A paragraph; random steering broke read-your-writes (C12) | §23 |
| 17 | Deployment strategies | ⚠️ only "apply to both at once" | §24 |
| 18 | Interview prep | ✅ (rewritten; Rev 1 answers contained claims an interviewer can break) | §29 |
| 19 | README with architecture diagram, setup steps, screenshots | ⚠️ outline only | §28 |
| 20 | CI/CD: GitHub Actions → DockerHub → EC2 or Railway | ⚠️ EKS/GKE only; no EC2 path | §12.4, §20 (budget profile runs on EC2 + GCE) |
| 21 | docker-compose.yml | ⚠️ obsolete `version:` key, `grafana:latest` | §12.1 |
| 22 | Monitoring dashboard | ⚠️ cross-cloud Prometheus federation (C14) | §13 |
| 23 | Documented "scaling decision" | ⚠️ argued for CLI workspaces (C3) | §26 |
| 24 | Public live link on resume | ❌ two always-on managed clusters cost too much for a fresher; no plan | §20, §27 |
| 25 | **Ansible + Terraform integrated in the MVP** (new ask) | ❌ Rev 1 rejected Ansible outright | §8 |
| 26 | Differentiators that beat existing open-source tools (new ask) | ❌ | §14 – §20 |
| 27 | Decision matrices with "why NOT" tables | ✅ (extended to every major choice) | throughout |

---

# §B — Version Matrix (verified 7 Oct 2026)

Rule used for every pin: **the version must be available on BOTH clouds' managed services**, because parity is the product. Where a version is newest on one cloud only, the plan pins the intersection.

| Component | Pin | Verification note |
|---|---|---|
| Terraform | `~> 1.15.0` (latest 1.15.x patch) | 1.15.0 GA 29 Apr 2026; 1.15 adds variable/output `deprecated`, variables in module `source`/`version`, functions inside `mock` blocks, and `terraform validate` now validates backend blocks. 1.16 is alpha — do not use. |
| OpenTofu | `1.12.x` (CI compatibility job only) | 1.12.2 stable as of June 2026. Used to prove the modules are engine-agnostic (§13.3); applies run on Terraform. |
| AWS provider | `~> 6.0` | Exact version locked in `.terraform.lock.hcl`, committed. |
| Google provider | `~> 7.0` | Lock-file pinned. Re-verify current major on build day. |
| Cloudflare provider | `~> 5.22` | v5.22.0 released 9 Jul 2026. v5 is a schema rewrite vs v4 — every Cloudflare example written for v4 (including Rev 1's) is invalid. |
| Kubernetes (managed) | **1.36** on both EKS and GKE | EKS standard support covers 1.35 and 1.36 (1.36 EKS release 2 Jun 2026, standard support to 2 Aug 2027). GKE Regular channel offers 1.34–1.36 (default 1.35.x). 1.36 is the newest minor available on both. |
| Kubernetes (budget profile) | k3s `v1.36.x+k3s1` | Same minor as managed — the parity contract (§14) checks this. |
| ansible-core | `2.21.x` | 2.21.2 released Jul 2026; 2.21 porting guide lists no breaking changes from 2.20. |
| Ansible collections | `amazon.aws`, `google.cloud`, `kubernetes.core`, `community.general`, `ansible.posix` | Pinned in `ansible/requirements.yml`; verify latest on build day. |
| ansible-rulebook (Event-Driven Ansible, OSS) | `1.1.x` | Used for D2 alert-driven drills. |
| PostgreSQL | **18** (18.4 minor) | RDS supports 18.4 (May 2026); Cloud SQL lists PostgreSQL 18 as default. PG18 adds built-in `uuidv7()` — used for cross-cell IDs (§9). |
| Valkey (cache) | **9.0** | ElastiCache added Valkey 9.0 on 5 May 2026; Memorystore for Valkey supports 7.2/8.0/9.0 with 9.0 default. |
| Spring Boot | **4.1.x** + Java 21 LTS | Spring Boot 4.0 OSS support ends 31 Dec 2026; 4.1.x is the current line. Your NaukriNearby stack is on 4.0.6 — for a project starting now, 4.0 would go EOL mid-demo season. Java 21 stays (your baseline; supported on Boot 4.x). |
| Next.js / Node | 16.3.x / Node 24 LTS | Same as your other capstones. |
| Python (cost collector, parity checker, recommender) | 3.14 | Same as HealOps/TraceMap. |
| Argo CD | 3.3.x | 3.3 requires Server-Side Apply for upgrades (ApplicationSet CRD size). |
| Prometheus / Grafana / Helm | 3.14.x / 13.2.x / 4.2.x | Same pins as your TraceMap Rev 3 / HealOps Rev 2 (verified Aug 2026); chart-pinned. |
| Infracost CLI | v0.10.x | v0.10.45 released 3 Jul 2026; Apache-2.0. |
| FOCUS (FinOps cost schema) | Ingest **1.2** exports, store 1.3-compatible columns | Spec 1.4 ratified 4 Jun 2026, 1.3 on 4–5 Dec 2025; AWS made FOCUS 1.2 GA in Data Exports at re:Invent 2025. Ingest what providers actually export; don't target a spec version nobody exports yet. |
| Cloudflare Load Balancing | Paid add-on (starts ~US$5/mo for 2 endpoints) | Not free tier — Rev 1 said "free". |

---

# §C — Defects in Rev 1 (and the Rev 2 fix)

These are the things an interviewer who has run Terraform in production would catch. Each one is also an interview story: *"In my first version I did X; here is why it was wrong and what I changed."* — that sentence is worth more than any feature.

### C1. The root module could not plan
Rev 1 root set `cloud_provider = "both"`, but every child module validated `contains(["aws","gcp"], var.cloud_provider)`. It also referenced `module.kubernetes_aws.lb_ip` and `module.kubernetes_gcp.lb_ip`, which were never declared.
**Fix:** One *stack* per cloud × environment × layer, each instantiating the same facade module with `cloud = "aws"` or `cloud = "gcp"`. A separate `global/traffic` stack consumes both stacks' outputs (§6).

### C2. The 70/30 Cloudflare split would not have happened
Rev 1 put `weight = 0.7` on the single origin inside the AWS pool and `0.3` inside the GCP pool. Origin weights only distribute traffic *among origins inside one pool*. With one origin per pool those weights do nothing, and with `steering_policy = "random"` and no pool weights, the two pools share traffic roughly evenly.
**Fix:** Pool-level weights via `random_steering.pool_weights` (values 0–1) on the load balancer (§7.5), plus a dashboard panel comparing *configured* split vs *observed* split from Cloudflare analytics so you can prove it.

### C3. Terraform CLI workspaces used as a cross-cloud, cross-credential boundary
CLI workspaces inside one working directory share one backend configuration; HashiCorp's own docs say they are not a suitable isolation mechanism when deployments need different credentials and access controls — which is exactly AWS-prod vs GCP-prod. Rev 1 also mixed `-backend-config` files per cloud with workspace names, which are two different mechanisms.
**Fix:** Directory-per-stack (`live/aws-prod/10-foundation`, `live/gcp-prod/10-foundation`, …), each with its own backend and CI identity. Workspaces are kept for the job they are good at: **ephemeral per-PR preview environments** in dev (§26.1). This satisfies the brief's "environment-specific workspaces" honestly.

### C4. Redis used as a Terraform state lock
Terraform backends already lock. Rev 1 also planned DynamoDB locking, which the S3 backend now marks deprecated in favour of `use_lockfile = true` (native S3 lock files, Terraform ≥ 1.10).
**Fix:** S3 backend with `use_lockfile = true` for AWS stacks, GCS backend (native locking) for GCP stacks, GitHub Actions `concurrency` groups per stack to serialise applies. Valkey is not involved in state.

### C5. Long-lived cloud keys in CI
Rev 1 stored `AWS_SECRET_ACCESS_KEY` and a GCP service-account JSON in GitHub Secrets and wrote the JSON to disk in the runner.
**Fix:** GitHub OIDC → AWS IAM role (`aws-actions/configure-aws-credentials`) and GCP Workload Identity Federation (`google-github-actions/auth`). Zero static cloud credentials in the repo or secrets store (§25).

### C6. "Apply on merge" applied an unreviewed plan
`terraform apply -auto-approve` on merge re-computes the plan. What gets applied is not what the reviewer saw.
**Fix:** Plan on `main` → save `tfplan` artifact → environment approval gate shows that plan → `terraform apply tfplan`. A saved plan refuses to apply if state moved underneath it (§12.5).

### C7. Two systems owned the same Helm releases
Terraform `helm_release` for the apps *and* `helm upgrade --install` in a GitHub workflow — they overwrite each other, and Terraform reports drift forever.
**Fix:** Terraform owns infrastructure and bootstraps Argo CD (one `helm_release`). Argo CD owns every application release. One owner per object (§12.3).

### C8. Kubernetes/Helm providers configured from resources created in the same apply
Configuring the `kubernetes`/`helm` provider from `aws_eks_cluster` outputs in the same state is the classic provider-dependency trap (unknown values at plan time, broken destroys).
**Fix:** Layered stacks: `10-foundation` (network, cluster, data) → `20-bootstrap` (Argo CD, External Secrets, monitoring agent) reading `10-foundation` outputs.

### C9. Machine shapes were not equivalent
`standard` mapped to `t3.large` (2 vCPU / 8 GiB) on AWS and `e2-standard-4` (4 vCPU / 16 GiB) on GCP. Any cost comparison built on that is invalid — GCP was given twice the hardware.
**Fix:** A shape-parity table where each abstract size maps to identical vCPU/RAM and the same CPU model class (burstable ↔ burstable, general-purpose ↔ general-purpose), enforced by `terraform test` (§7.2) and listed in the leaky-abstraction register (§20.3).

### C10. The headline cost numbers were not measurements
"₹18,500 vs ₹14,200 (23% cheaper)" was illustrative. Worse, the comparison was between **totals** of a cell carrying 70% of traffic and a cell carrying 30% — so the cheaper total could just mean less traffic. Free-tier credits would also make one cloud look free.
**Fix:** Compare **cost per 1,000 requests** (FOCUS `EffectiveCost`, credits excluded, amortised commitments) over the same window, same metro (Mumbai on both clouds), same shapes. In interviews quote only numbers your dashboard produced, with the date range (§17). Saying "I don't have a number for that yet" is far safer than a number that collapses under one follow-up question.

### C11. Failover assumed the 30% cell could absorb 100% of traffic
"Take down AWS → Cloudflare routes 100% to GCP → it works" — a cell sized for 30% receiving 100% saturates, fails health checks, and you've turned a one-cloud outage into a two-cloud outage.
**Fix:** Capacity contract + pre-warm step + stepped shift with SLO gates (§15). Documented as a scaling decision (§26.2).

### C12. Random steering without affinity broke read-your-writes
Each cloud had its own database with no replication. With per-request random steering, a user creates an order on AWS, refreshes, lands on GCP — order gone.
**Fix:** Cell-based architecture: cookie session affinity pins a user to a home cell, data is cell-local, IDs are globally unique (`uuidv7()`), inventory uses an escrow/lease pattern so two cells can never oversell the same stock (§23).

### C13. Outdated or end-of-life versions and APIs
Kubernetes 1.29, Terraform 1.7, Spring Boot 3.x, Next.js 14, Redis 7, `grafana/grafana:latest`, the `aws-auth` ConfigMap (superseded by EKS access entries), DynamoDB state locking, and the obsolete `version:` key in Compose.
**Fix:** §B matrix; EKS `authentication_mode = "API"` with access entries; EKS Pod Identity and GKE Workload Identity for pod credentials.

### C14. Prometheus federation across clouds over the public internet
Federation requires exposing each cell's Prometheus to the other side and couples the dashboards to the slowest link.
**Fix:** Each cell runs Prometheus in agent mode and pushes via `remote_write` (outbound only) to a central Prometheus 3 with the remote-write receiver enabled, behind Cloudflare Access (§13).

### C15. Over-privileged nodes and an open control plane
GKE nodes ran on the default compute service account with the `cloud-platform` scope; EKS public endpoint open to `0.0.0.0/0`.
**Fix:** Dedicated least-privilege node service account on GKE, Workload Identity for pods; EKS public endpoint restricted to an allowlist (CI egress is handled via OIDC role + `public_access_cidrs`), private endpoint on (§7.3, §7.4, §25).

### C16. Production pulled directly from Docker Hub
Rate limits and a third dependency in the pod start path — exactly when you're scaling a cell up during failover.
**Fix:** Keep Docker Hub as the public registry (your brief asks for it), but pods pull **by digest** through an ECR pull-through cache (AWS) and an Artifact Registry remote repository (GCP) (§12.4).

### C17. GCP cost query built with an f-string and a non-standard schema
`f"... WHERE DATE(usage_start_time) = '{date}'"` is the SQL-injection shape interviewers flag, and the homegrown cost model can't be compared against anything else.
**Fix:** Parameterised BigQuery queries against the FOCUS view; AWS Data Exports in FOCUS 1.2; one normaliser (§17).

### C18. Ansible was rejected outright
Rev 1 correctly said Ansible isn't a provisioning tool, then concluded it had no place. It does — for configuring machines Terraform can't make immutable, and for orchestrating *procedures* (evacuations, drills, failbacks) that have no resource to declare.
**Fix:** §8 — Terraform builds the house; Ansible runs the fire drill.

### C19. Outdated free-tier assumptions
"750 hrs/month t3.micro" is the legacy model. AWS accounts created on or after 15 July 2025 get a credit-based Free plan ($100 at sign-up, up to $200) that ends after 6 months or when credits run out.
**Fix:** Cost plan in §27 built on credits + ephemeral managed clusters + an always-on budget profile.

### C20. Failover timing was overstated
With a 60 s monitor interval and 2 retries, detection alone takes roughly 2–3 minutes before Cloudflare marks a pool unhealthy. "Instant failover" is not a claim to make.
**Fix:** Measured detection + drain time is a recorded output of every drill (§15.5).

### C21. No realistic public live link
Two always-on managed Kubernetes control planes plus NAT gateways and load balancers run to several hundred US dollars a month.
**Fix:** Two profiles behind the same interface: `managed` (EKS/GKE, spun up on demand with a TTL reaper) and `budget` (k3s on one EC2 + one GCE VM, configured by Ansible, always on behind the same Cloudflare LB) (§20).

### C22. Invalid HCL syntax in the variable blocks
`variable "kubernetes_version" { type = string; default = "1.29" }` — HCL has no semicolons, and a single-line block may hold only **one** argument. `terraform fmt` would reject the file before any of the architecture mattered.
**Fix:** Every block in Rev 2 is multi-line where it has more than one argument, and CI runs `terraform fmt -check` + `validate` on every stack.

### C23. Copy-paste from another project
Rev 1's closing "maturity hierarchy" ("my system FIXES the incidents…") is HealOps' story, not CloudBridge's. An interviewer who reads both READMEs will notice.
**Fix:** CloudBridge's own maturity ladder in §29.

---

# §1 — Project Overview & Hook

## 1.1 One-liner

CloudBridge is a multi-cloud deployment platform: one Terraform codebase provisions identical **cells** (network + Kubernetes + Postgres + Valkey) on AWS and GCP, Ansible configures VMs and orchestrates evacuation drills, Argo CD deploys the same Spring Boot microservices to both, and Cloudflare splits traffic 70/30 — while a control plane continuously **proves parity**, **proves failover capacity**, and **measures cost per request** on each cloud.

## 1.2 The hook (Rev 2 — survives follow-up questions)

> "I can point the same Terraform at a different cloud by changing one variable — that part is table stakes. What I built on top is the part most multi-cloud setups skip: a parity check that fails CI when the two clouds drift apart, an Ansible evacuation drill that proves the smaller cloud can actually take all the traffic before I trust it to, and a FOCUS-based cost ledger that compares the clouds per thousand requests instead of comparing bills."

Why Rev 1's hook needed changing: "no vendor lock-in by design" invites the question *"what about IAM, managed databases, load balancer semantics?"* — and the honest answer is that those *don't* abstract cleanly. Rev 2 answers that question before it's asked, with a leaky-abstraction register (§20.3).

## 1.3 Who this is aimed at

| Company type | What they'll probe | Which section answers it |
|---|---|---|
| RBI-regulated fintech (Razorpay, PhonePe, CRED) | Exit strategy, DR evidence, consistency of money data | §15 (evacuation drills produce exit-plan evidence), §23 |
| SaaS at scale (Atlassian, Freshworks) | Terraform structure, state, blast radius, GitOps | §6, §12, §26 |
| Multi-cloud vendors (Nutanix, Broadcom) | Abstraction boundaries, what leaks | §7, §20.3 |
| Any platform team | Cost, on-call, CI/CD discipline | §13, §17, §19 |

## 1.4 What CloudBridge is *not*

Saying this out loud in an interview is a senior signal:
- **Not active-active for writes across clouds.** Each cell owns its data; cross-cloud synchronous writes are deliberately avoided (§23).
- **Not a claim that most companies should be multi-cloud.** It is a demonstration of the engineering required *if* you must (regulatory exit plans, negotiating leverage, M&A, provider-specific services).
- **Not a replacement for multi-region.** Most outages are regional; multi-region inside one cloud is usually cheaper. Multi-cloud protects against provider-wide control-plane failures (the 20 Oct 2025 AWS us-east-1 DynamoDB DNS incident is the canonical recent example) and against commercial lock-in.

---

# §2 — Tech Stack (every choice justified)

## 2.1 Core stack

| Layer | Choice | Why this |
|---|---|---|
| Provisioning (IaC) | Terraform 1.15 (OpenTofu 1.12 compatibility-tested) | Multi-provider in one language; native test framework with mock providers lets the abstraction be tested offline for ₹0. |
| Configuration + procedures | Ansible core 2.21 + ansible-rulebook | Configures the budget-profile VMs (k3s, hardening, exporters) and orchestrates multi-step operations (evacuate, failback, drills) that are procedures, not resources. |
| Managed Kubernetes | EKS 1.36 / GKE 1.36 (Regular channel, zonal) | Same minor on both; zonal GKE cluster qualifies for GKE's free-tier management credit. |
| Budget Kubernetes | k3s 1.36 on 1× EC2 + 1× GCE VM | Always-on public live link at a fraction of managed-cluster cost; same Helm charts. |
| App | Spring Boot 4.1 / Java 21 — `api-gateway` (Spring Cloud Gateway), `order-service`, `inventory-service` | Your baseline language; 4.1 avoids 4.0's Dec 2026 EOL. |
| GitOps | Argo CD 3.3 (one per cell) + Argo Rollouts | Pull-based: no cell holds admin credentials for the other cloud. |
| Global traffic | Cloudflare Load Balancing (provider v5.22) | Cloud-neutral edge; pool-weighted random steering, cookie affinity, health monitors. |
| App DB (per cell) | PostgreSQL 18 — RDS / Cloud SQL (managed) or in-cluster (budget) | §9. |
| Cache (per cell) | Valkey 9.0 — ElastiCache / Memorystore (managed) or in-cluster (budget) | §10. |
| Control-plane DB | PostgreSQL 18 | FOCUS cost ledger, parity snapshots, drills, deployments. |
| Control-plane services | Python 3.14 (FastAPI) — cost collector, parity checker, steering recommender, plan-risk gate | Python is the lingua franca for cloud SDKs and data work. |
| Dashboard | Next.js 16.3 on Node 24 LTS + Grafana 13 | Next.js for the product UI (cost/parity/drills); Grafana for metrics. |
| Metrics | Prometheus 3 (agent mode in cells → central receiver), Alertmanager, blackbox exporter | Outbound-only metrics flow (C14). |
| Cost data | AWS Data Exports (FOCUS 1.2) + GCP BigQuery FOCUS view; OpenCost in-cluster for allocation | Standard schema both providers emit natively. |
| Pre-merge cost | Infracost CLI | Don't rebuild what exists — integrate it and add what it lacks (§17.4). |
| Policy | Trivy (IaC + image), Conftest/OPA, tflint | Security + house rules as code. |
| Registry | Docker Hub (public) + ECR pull-through cache + Artifact Registry remote repo | Brief requires Docker Hub; caches remove it from the hot path. |
| Supply chain | cosign keyless signing, Syft SBOM, actions pinned by commit SHA | |
| Secrets | GitHub OIDC (CI); External Secrets Operator → AWS Secrets Manager / GCP Secret Manager (runtime) | ESO is the secrets adapter: same `ExternalSecret` manifest, different `SecretStore`. |
| LLM (optional plan explainer) | Provider-agnostic adapter, default `gpt-5.4-mini` | Only summarises; never decides (§19). |

## 2.2 Why NOT the alternatives

| Rejected | Why not (interview answer) |
|---|---|
| **Pulumi** | Real languages are a strength for app teams, but most Bangalore DevOps JDs list Terraform, and Terraform's test framework + mocks cover what I need. I kept the modules engine-agnostic instead (OpenTofu job) — that's the lock-in story that matters for IaC. |
| **Crossplane** | Needs a running cluster to create clusters (bootstrap chicken-and-egg), and its abstraction (Compositions) would replace — not demonstrate — the module design. Good choice for a platform team offering self-service later. |
| **Terragrunt / Terramate** | Both solve DRY orchestration across many stacks. At 2 clouds × 2 envs × 3 layers = 12 stacks, plain directories + a Makefile are still readable. I documented the switch trigger in §26.1. |
| **CloudFormation / Deployment Manager** | Single-cloud by definition. |
| **CLI workspaces per cloud/env** | Shared backend + credentials; HashiCorp docs advise against them as an isolation boundary (C3). Kept for ephemeral PR previews. |
| **Ansible for provisioning** | No state, no plan, no drift detection for cloud resources. Terraform owns anything with an API and a lifecycle. |
| **Terraform `local-exec` to run Ansible** | Hides procedures inside resource lifecycles; a failed provisioner taints the resource. Hand-off is via cloud tags + Ansible dynamic inventory instead (§8.3). |
| **Terraform 1.14 `action` blocks for drills** | Actions are provider-defined imperative operations; there is no Cloudflare/Prometheus-aware action that can do a stepped, SLO-gated shift with rollback. Ansible is the right tool for a multi-step saga. |
| **Route 53 / Cloud DNS weighted routing** | Puts the traffic layer inside one of the two clouds you're trying to be independent of. |
| **k8gb (CNCF incubating since Jul 2026)** | Strong Kubernetes-native GSLB, and I'd mention it as the self-hosted alternative. Rejected because it's DNS-based (client TTL caching slows shifts) and I wanted edge-proxied steering with cookie affinity for cell pinning. |
| **Azure as a third cloud** | Triples cost and test matrix without adding a new idea. The facade accepts a third implementation; §29 shows how. |
| **Hub Argo CD managing both clusters** | The hub needs cluster-admin credentials for both clouds and becomes a cross-cloud single point of failure. One Argo CD per cell. |
| **Vault** | Operating Vault HA is a project in itself. ESO + each cloud's secret manager gives the same "one manifest, two backends" story. |
| **Prometheus federation / Thanos sidecars across clouds** | Requires inbound exposure of each cell. Agent-mode `remote_write` is outbound-only. Thanos/Mimir are the scale-out path (§13.4). |

---

# §3 — Competitive Landscape: What Exists, and Where CloudBridge Goes Further

The brief asks for differentiators that **beat existing open-source tools**, not just match them. The honest framing for an interview: *each tool below is excellent at its job; none closes the loop between parity, capacity, cost, and traffic.* The table reflects each project's documented feature set as reviewed in Oct 2026.

| Capability | Terragrunt / Terramate | Atlantis / Digger | Crossplane | k8gb | Cloudflare LB alone | OpenCost | Infracost | **CloudBridge** |
|---|---|---|---|---|---|---|---|---|
| One codebase → many clouds | ✅ (orchestration) | — | ✅ | — | — | — | — | ✅ facade module |
| PR plan + apply workflow | partial | ✅ | — | — | — | — | — | ✅ saved-plan apply |
| **Cross-cloud parity score that gates CI** | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ **D1** |
| Health-based failover | — | — | — | ✅ | ✅ | — | — | ✅ |
| **Capacity-verified, SLO-gated stepped evacuation with drill report** | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ **D2** |
| **Traffic weights recommended from unit cost, with SLO veto + backtest** | ❌ | ❌ | ❌ | ❌ | ❌ (latency/geo only) | ❌ (reports only) | ❌ | ✅ **D3** |
| Pre-merge cost estimate | — | — | — | — | — | — | ✅ | ✅ (uses Infracost) |
| **FOCUS bill reconciled against in-cluster allocation** | — | — | — | — | — | partial | — | ✅ **D4** |
| **Cloud-as-canary-ring releases** | — | — | — | — | — | — | — | ✅ **D5** |
| **Plan-risk gate that flags parity-breaking changes, eval-gated** | — | partial (policies) | — | — | — | — | — | ✅ **D6** |
| **Same interface for managed and budget (k3s) clusters** | — | — | — | — | — | — | — | ✅ **D7** |
| **Leaky-abstraction register (documented non-portable behaviour)** | — | — | — | — | — | — | — | ✅ **D8** |

Positioning sentence: *"CloudBridge doesn't replace Terraform, Cloudflare, OpenCost or Infracost — it uses them. The new part is the control loop around them: it measures whether the two clouds are still interchangeable, whether the failover target can take the load, and what each cloud costs per request — and turns that into reviewed pull requests."*

---

# §4 — MVP Blueprint

## 4.1 MVP scope

**Must have (week 1–6):**
1. Three Spring Boot services + `docker-compose.yml` local stack.
2. Facade Terraform module with AWS and GCP implementations for network, cluster (managed + budget), Postgres, Valkey; contract tests with mock providers.
3. Budget profile live on EC2 + GCE, configured by Ansible, behind Cloudflare LB at a 70/30 split with cookie affinity — **public live link from week 2**.
4. Managed profile (EKS + GKE) on demand via `workflow_dispatch`, with TTL reaper.
5. Argo CD per cell, Helm charts, Argo Rollouts canary.
6. CI/CD: build → Docker Hub (signed, SBOM) → digest bump PR → Argo CD sync; IaC PR plan with OIDC, saved-plan apply with approvals.
7. Observability: agent-mode Prometheus → central Prometheus → Grafana dashboards; SLO alerts.
8. D1 parity check (CI + nightly), D2 evacuation playbook (manual trigger), D4 FOCUS cost ledger + dashboard.

**Differentiator layer (week 7–8):** D3 steering recommender + backtest, D5 ring promotion automation, D6 plan-risk gate + eval, Event-Driven Ansible trigger for drills.

**Post-MVP:** cross-cloud async replication for DR (HA VPN), Kyverno image-signature enforcement, Azure implementation, LLM plan explainer.

## 4.2 The application being deployed

| Service | Role | Per-cell dependencies | Multi-cloud pattern it demonstrates |
|---|---|---|---|
| `api-gateway` | Routing, rate limiting, `/healthz/cell` aggregate health, sets `X-CB-Cell` response header | Valkey (rate limit) | Identical image on both clouds; header proves which cell served you |
| `order-service` | Create/list orders; idempotency keys; transactional outbox | Postgres, Valkey | Cell-local data with globally unique `uuidv7()` IDs |
| `inventory-service` | Stock reads (cache-heavy) + reservations against the cell's escrow lease | Postgres, Valkey | Escrow quota prevents cross-cell overselling without cross-cloud transactions |

## 4.3 8-week plan (ship-first ordering)

The order is deliberate: **a public multi-cloud link exists by the end of week 2**, so even if later weeks slip you have a working, demo-able project.

| Week | Goal | Concrete deliverables | Done when |
|---|---|---|---|
| **1** | App + local + first cloud VMs | 3 services, Testcontainers tests, `docker-compose.yml`; `ci-app.yml` → Docker Hub (signed); `modules/network` + `modules/cluster/k3s-vm` for AWS and GCP; Ansible roles `base_hardening`, `k3s_server`, `node_exporter` with Molecule tests | `docker compose up` works; `make budget-up` creates both VMs and Ansible installs k3s |
| **2** | Live multi-cloud link | `global/30-traffic` Cloudflare stack (monitor, 2 pools, LB 70/30, cookie affinity), origin lock-down to Cloudflare IP ranges; Argo CD bootstrapped on both k3s cells; app synced | `https://app.<domain>` live; `X-CB-Cell` header shows both clouds over many requests |
| **3** | Managed profile | EKS + GKE modules, access entries / Workload Identity, node SA least privilege; `terraform test` contract suite with mocks (both engines); `ephemeral-up.yml` + `ttl-reaper.yml` | `make managed-up CLOUD=gcp` → healthy cluster, auto-destroyed after TTL |
| **4** | Data + cells | RDS/Cloud SQL + ElastiCache/Memorystore modules (with in-cluster fallback for budget), ESO secret stores, idempotency + outbox + escrow lease in services | Order created in a cell survives pod restarts; duplicate POST with same key returns same order |
| **5** | CI/CD hardening + observability | OIDC everywhere, saved-plan apply with environments, concurrency groups, Trivy/Conftest/tflint, Infracost PR comment, drift job; Prometheus agent → central; 4 Grafana dashboards; SLO burn alerts | A PR shows: both plans, cost delta, policy result, in one sticky comment |
| **6** | D1 + D4 | Parity checker (CLI + nightly + post-sync gate), parity exceptions with expiry; FOCUS ingestion for both clouds, OpenCost allocation, cost-per-1k-requests dashboard | Parity score visible; deliberately changing a chart version on one cell fails CI |
| **7** | D2 + D5 | `evacuate.yml` / `failback.yml` playbooks with capacity check, pre-warm, stepped shift, SLO gates, rollback, report; Argo Rollouts analysis + ring promotion workflow | Drill report shows measured detection/shift time and errors during shift |
| **8** | D3 + D6 + polish | Steering recommender + backtest eval in CI; plan-risk rules + eval set; README, architecture diagram, screenshots, demo video, interview rehearsal | Every claim in the README links to a dashboard panel or a drill report |

## 4.4 Cut line (if you're behind)

Drop in this order — each item is independent of the ones after it:
1. LLM plan explainer (rules-only plan-risk gate stays)
2. Event-Driven Ansible trigger (manual `make drill` stays)
3. Automated ring promotion (manual promotion PR stays)
4. Steering recommender automation (keep the cost-per-request panel; compute the recommendation by hand in the README)
5. Managed Valkey (use in-cluster Valkey in managed profile too)

**Never cut:** live link, parity check, one evacuation drill report, cost-per-request panel. Those four are the interview.

---

# §5 — High-Level Design (HLD)

## 5.1 Architecture

```
                                 ┌──────────────────────────────────────────────┐
   Users (India-first) ─────────▶│ CLOUDFLARE EDGE                              │
                                 │  LB app.<domain> (proxied)                    │
                                 │  steering: random, pool_weights aws .7 gcp .3 │
                                 │  session affinity: cookie (home cell)         │
                                 │  monitor: HTTPS GET /healthz/cell (SAS, SEAS) │
                                 └────────────┬─────────────────────┬───────────┘
                                              │                     │
                ┌─────────────────────────────▼───┐     ┌───────────▼─────────────────────────────┐
                │ CELL aws-prod  (ap-south-1)     │     │ CELL gcp-prod  (asia-south1)            │
                │ ingress: ALB (managed) |        │     │ ingress: GCLB (managed) |               │
                │          Traefik on EC2 (budget)│     │          Traefik on GCE (budget)        │
                │ ┌─────────────────────────────┐ │     │ ┌─────────────────────────────────────┐ │
                │ │ K8s 1.36 (EKS | k3s)        │ │     │ │ K8s 1.36 (GKE | k3s)                │ │
                │ │  api-gateway ─▶ order-svc   │ │     │ │  api-gateway ─▶ order-svc           │ │
                │ │             └▶ inventory-svc│ │     │ │             └▶ inventory-svc        │ │
                │ │  Argo CD (pulls from Git)   │ │     │ │  Argo CD (pulls from Git)           │ │
                │ │  ESO ─▶ Secrets Manager     │ │     │ │  ESO ─▶ Secret Manager              │ │
                │ │  Prometheus (agent) ────────┼─┼──┐  │ │  Prometheus (agent) ────────────────┼─┼──┐
                │ │  OpenCost                   │ │  │  │ │  OpenCost                           │ │  │
                │ └─────────────────────────────┘ │  │  │ └─────────────────────────────────────┘ │  │
                │ Postgres 18 (RDS | in-cluster)  │  │  │ Postgres 18 (Cloud SQL | in-cluster)    │  │
                │ Valkey 9 (ElastiCache | in-cl.) │  │  │ Valkey 9 (Memorystore | in-cluster)     │  │
                │ ECR pull-through cache ◀─ Hub   │  │  │ Artifact Registry remote ◀─ Docker Hub  │  │
                └─────────────────────────────────┘  │  └─────────────────────────────────────────┘  │
                         │ FOCUS export (S3)         │                │ FOCUS view (BigQuery)         │
                         ▼                           │                ▼                               │
   ┌──────────────────────────────────────────────────▼────────────────────────────────────────────────▼──┐
   │ CONTROL PLANE (off the request path) — runs on the gcp budget VM, exposed via Cloudflare Access      │
   │  Prometheus 3 (remote-write receiver) · Alertmanager · Grafana 13                                    │
   │  cost-collector · parity-checker · steering-recommender · plan-risk API · Next.js 16 dashboard        │
   │  PostgreSQL 18 (ledger, parity, drills, deployments) · Valkey 9 (cache + Streams)                    │
   └──────────────────────────────────────────────────────────────────────────────────────────────────────┘
                         ▲
   ┌─────────────────────┴──────────────────────────────────────────────────────────────────────────────┐
   │ GITHUB (source of truth)  repo · Actions (OIDC→AWS role / GCP WIF) · Docker Hub images (cosign)    │
   │  IaC PR: fmt/validate/test(TF+Tofu)/trivy/conftest/plan×stacks/infracost/plan-risk → sticky comment│
   │  Apply: saved plan + environment approval · Drift nightly · Parity nightly · TTL reaper hourly     │
   │  Ansible runs from Actions runners: budget config · evacuate/failback/drill playbooks              │
   └────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

## 5.2 Key placement decisions

| Decision | Choice | Reason |
|---|---|---|
| Region pair | `ap-south-1` (Mumbai) + `asia-south1` (Mumbai) | Same metro → fair latency and cost comparison; low latency for Indian users; keeps data in India. |
| Control plane location | GCP budget VM, **not on the request path** | If GCP dies, users are served by AWS; you lose dashboards, not traffic. |
| Where evacuations run from | GitHub Actions runner (outside both clouds) | "The escape hatch can't live in the building that's on fire." |
| Traffic-stack state | GCS (the minority cell's cloud) + break-glass Cloudflare API path in the playbook | If AWS is the failed cloud, the state you need to shift traffic is reachable; if GCS is down, the playbook uses the API directly and Terraform reconciles later (§15.6). |
| Argo CD | One per cell | No cross-cloud admin credentials. |

## 5.3 Core flows

**Flow 1 — Infrastructure change (GitOps for IaC)**
```
PR touches modules/cluster/** ─▶ detect affected stacks (all stacks that import the module)
  ─▶ per stack (matrix): fmt · validate · tflint · trivy config · terraform test (TF + Tofu, mocks)
  ─▶ OIDC login (plan role, read-only) ─▶ terraform plan -out ─▶ show -json
  ─▶ plan-risk gate (D6) + conftest + infracost diff + parity-impact check
  ─▶ ONE sticky PR comment: AWS plan · GCP plan · cost Δ · risk · parity warnings
merge ─▶ re-plan on main (saved) ─▶ environment approval (shows the plan) ─▶ apply tfplan
  ─▶ event to control plane ─▶ deployments table ─▶ parity re-check
```

**Flow 2 — Application release (cloud as canary ring, D5)**
```
merge to services/** ─▶ build, test, push to Docker Hub by digest, cosign sign, SBOM
  ─▶ bot PR: releases/ring-canary.yaml digest bump (gcp cell = canary ring)
  ─▶ Argo CD (gcp) syncs ─▶ Argo Rollouts canary 10%→50%→100% with Prometheus analysis
  ─▶ soak 30 min, SLO burn < 1 ─▶ bot PR: releases/ring-main.yaml (aws cell)
  ─▶ Argo CD (aws) syncs ─▶ parity check confirms digests equal across cells
```

**Flow 3 — Evacuation (D2)**
```
trigger (manual / drill schedule / EDA rule) ─▶ preflight: target capacity ≥ 1.2× peak RPS?
  no ─▶ pre-warm target (raise HPA mins, wait for nodes) ─▶ re-check
  ─▶ shift weights 70/30 → 50/50 → 25/75 → 0/100 (terraform apply on traffic stack)
     each step: wait 2× monitor interval · query burn rate · abort+rollback if burn > threshold
  ─▶ verify 100% on target ─▶ record RTO, errors, cost delta ─▶ drill report + DB row
```

**Flow 4 — Cost (D4) and steering recommendation (D3)**
```
daily: AWS FOCUS (S3 parquet) + GCP FOCUS (BigQuery view) ─▶ normalise ─▶ cost_line_items
  + OpenCost allocation (namespace/service share of node cost) + Prometheus request counts
  ─▶ cost_per_1k_requests per service per cell ─▶ dashboard
weekly: recommender fits fixed + variable cost per cell ─▶ proposes weights under SLO/headroom/floor
  constraints ─▶ backtest ─▶ opens PR on global/30-traffic/terraform.tfvars.json (human merges)
```

---

# §6 — Terraform Architecture

## 6.1 Repository layout

```
cloudbridge/
├── infra/
│   ├── modules/
│   │   ├── cell/                      # FACADE (Abstract Factory): cloud × profile → one cell
│   │   │   ├── main.tf  variables.tf  outputs.tf  shapes.tf
│   │   │   └── tests/contract.tftest.hcl
│   │   ├── network/{aws,gcp}/
│   │   ├── cluster/{aws-eks,gcp-gke,k3s-vm-aws,k3s-vm-gcp}/
│   │   ├── database/{aws-rds,gcp-cloudsql}/
│   │   ├── cache/{aws-elasticache,gcp-memorystore}/
│   │   ├── registry-mirror/{aws-ecr-ptc,gcp-ar-remote}/
│   │   ├── ci-identity/{aws-oidc,gcp-wif}/
│   │   ├── bootstrap/                 # Argo CD + ESO + Prometheus agent + OpenCost (helm)
│   │   └── traffic/cloudflare/
│   ├── live/                          # one directory = one state = one blast radius
│   │   ├── aws-prod/{10-foundation,20-bootstrap}/
│   │   ├── gcp-prod/{10-foundation,20-bootstrap}/
│   │   ├── aws-dev/{10-foundation,20-bootstrap}/
│   │   ├── gcp-dev/{10-foundation,20-bootstrap}/
│   │   ├── global/00-ci-identity/     # OIDC providers + roles (bootstrapped once, by hand)
│   │   └── global/30-traffic/         # Cloudflare (reads both cells' outputs)
│   ├── policy/                        # conftest rego
│   └── Makefile
├── ansible/
│   ├── inventories/{aws_ec2.yml,gcp_compute.yml}
│   ├── roles/{base_hardening,k3s_server,node_exporter,traefik_origin_tls}/
│   ├── playbooks/{site.yml,evacuate.yml,failback.yml,drill.yml,prewarm.yml}
│   ├── rulebooks/cell-degraded.yml
│   ├── molecule/
│   └── requirements.yml
├── gitops/
│   ├── bootstrap/applicationset.yaml
│   ├── charts/{api-gateway,order-service,inventory-service,platform-addons}/
│   ├── releases/{ring-canary.yaml,ring-main.yaml}
│   └── cells/{aws-prod,gcp-prod,aws-dev,gcp-dev}/values.yaml
├── services/{api-gateway,order-service,inventory-service}/
├── control-plane/{cost-collector,parity-checker,steering,plan-risk,dashboard}/
├── evals/{plan-risk,steering,parity}/
├── parity/{contract.yaml,exceptions.yaml}
├── docs/{leaky-abstractions.md,scaling-decisions.md,drills/,adr/}
├── docker-compose.yml
└── .github/workflows/
```

## 6.2 State topology

| Stack | Backend | CI identity (apply) | Blast radius |
|---|---|---|---|
| `live/aws-*/10-foundation` | S3 `cb-tfstate-aws` + `use_lockfile` | `cb-apply-aws-<env>` IAM role | One AWS cell's infra |
| `live/aws-*/20-bootstrap` | same bucket, different key | same | Platform add-ons in one cell |
| `live/gcp-*/10-foundation` | GCS `cb-tfstate-gcp` (native lock) | `cb-apply-gcp-<env>` SA via WIF | One GCP cell's infra |
| `live/gcp-*/20-bootstrap` | same bucket, different prefix | same | |
| `live/global/30-traffic` | GCS `cb-tfstate-gcp/global/traffic` | `cb-apply-traffic` (Cloudflare token scoped to one zone's LB) | Traffic weights only |
| `live/global/00-ci-identity` | local → migrated to S3/GCS after first apply | human admin, once | CI trust itself |

A bad apply in `aws-prod/20-bootstrap` cannot touch GCP, and cannot touch the AWS VPC.

## 6.3 "The one variable"

Every cell stack is three short files. The *only* difference between `live/aws-prod/10-foundation` and `live/gcp-prod/10-foundation` is `terraform.tfvars` and the backend block:

```hcl
# live/gcp-prod/10-foundation/terraform.tfvars
cloud      = "gcp"          # ← the one variable
profile    = "managed"      # managed | budget
env        = "prod"
region     = "asia-south1"
shape      = "small"
gcp_project_id = "cloudbridge-prod-xxxx"
```

Creating a new cloud target for an environment = copy the directory, change `cloud` and the backend. `make new-cell CLOUD=gcp ENV=staging` does exactly that. The honest version of the hook: *"Targeting a different cloud is a three-line change; the cloud-specific complexity lives in the implementations behind the facade, and I can show you exactly what doesn't abstract cleanly."*

---

# §7 — Low-Level Design: Terraform

## 7.1 Shared version constraints

```hcl
# infra/live/_shared/versions.tf  (symlinked into each stack)
terraform {
  required_version = ">= 1.15.0, < 2.0.0"
  required_providers {
    aws        = { source = "hashicorp/aws",          version = "~> 6.0" }
    google     = { source = "hashicorp/google",       version = "~> 7.0" }
    cloudflare = { source = "cloudflare/cloudflare",  version = "~> 5.22" }
    helm       = { source = "hashicorp/helm",         version = "~> 3.0" }
    kubernetes = { source = "hashicorp/kubernetes",   version = "~> 2.38" }
  }
}
```
*Note:* `required_version` excludes nothing OpenTofu-specific; the OpenTofu compatibility job runs `tofu init/validate/test` only (§13.3). Unused providers in a stack are fine; `terraform init` downloads only those referenced. Verify the helm/kubernetes provider majors on build day and commit `.terraform.lock.hcl`.

## 7.2 The facade module (Abstract Factory)

```hcl
# infra/modules/cell/variables.tf
variable "cloud" {
  type        = string
  description = "Target cloud for this cell."
  validation {
    condition     = contains(["aws", "gcp"], var.cloud)
    error_message = "cloud must be \"aws\" or \"gcp\"."
  }
}

variable "profile" {
  type    = string
  default = "managed"
  validation {
    condition     = contains(["managed", "budget"], var.profile)
    error_message = "profile must be \"managed\" (EKS/GKE + managed data) or \"budget\" (k3s on one VM)."
  }
}

variable "env"                { type = string }
variable "region"             { type = string }
variable "shape" {
  type = string
  default = "small"
}
variable "kubernetes_minor" {
  type = string
  default = "1.36"
}
variable "node_count" {
  type = number
  default = 2
}
variable "node_max" {  # sized for evacuation (§26.2)
  type = number
  default = 5
}
variable "gcp_project_id" {
  type = string
  default = null
}
variable "admin_cidrs" {
  type = list(string)
  default = []
}
variable "cloudflare_ipv4" {
  type = list(string)
  description = "Origin allowlist (data.cloudflare_ip_ranges passed in)"
}
variable "managed_cache" {
  type = bool
  default = true
}
variable "ci_role_arn" {
  type = string
  default = null
  description = "AWS only: CI role granted an EKS access entry"
}

locals {
  name = "cb-${var.cloud}-${var.env}"
  labels = {
    "cb-cell"    = local.name
    "cb-cloud"   = var.cloud
    "cb-env"     = var.env
    "managed-by" = "terraform"
  }
}
```

```hcl
# infra/modules/cell/shapes.tf
# Shape parity: identical vCPU / memory and the same CPU class on both clouds.
# Changing a pair here is a cost-comparison event — the parity contract (§14) records it.
locals {
  shapes = {
    small    = { aws = "t3.medium", gcp = "e2-medium",     vcpu = 2, mem_gib = 4,  class = "burstable" }
    standard = { aws = "m6i.large", gcp = "n2-standard-2", vcpu = 2, mem_gib = 8,  class = "general-purpose" }
    large    = { aws = "m6i.xlarge",gcp = "n2-standard-4", vcpu = 4, mem_gib = 16, class = "general-purpose" }
  }
  budget_shapes = {
    small = { aws = "t3.small", gcp = "e2-small", vcpu = 2, mem_gib = 2, class = "burstable" }
  }
  shape_row     = var.profile == "budget" ? local.budget_shapes[var.shape] : local.shapes[var.shape]
  instance_type = local.shape_row[var.cloud]
}
```

```hcl
# infra/modules/cell/main.tf
module "network_aws" {
  source = "../network/aws"
  count  = var.cloud == "aws" ? 1 : 0
  name   = local.name
  cidr   = "10.20.0.0/16"
  azs    = 2
  nat    = var.profile == "managed"        # budget VMs sit in a public subnet, no NAT
  tags   = local.labels
}

module "network_gcp" {
  source     = "../network/gcp"
  count      = var.cloud == "gcp" ? 1 : 0
  name       = local.name
  project_id = var.gcp_project_id
  region     = var.region
  cidr       = "10.30.0.0/16"
  nat        = var.profile == "managed"
  labels     = local.labels
}

locals {
  net = one(concat(module.network_aws, module.network_gcp))
}

module "eks" {
  source          = "../cluster/aws-eks"
  count           = var.cloud == "aws" && var.profile == "managed" ? 1 : 0
  name            = local.name
  k8s_version     = var.kubernetes_minor
  vpc_id          = local.net.network_id
  subnet_ids      = local.net.private_subnet_ids
  instance_type   = local.instance_type
  desired         = var.node_count
  max             = var.node_max
  admin_cidrs     = var.admin_cidrs
  ci_role_arn     = var.ci_role_arn
  tags            = local.labels
}

module "gke" {
  source          = "../cluster/gcp-gke"
  count           = var.cloud == "gcp" && var.profile == "managed" ? 1 : 0
  name            = local.name
  env             = var.env
  project_id      = var.gcp_project_id
  zone            = "${var.region}-a"     # zonal → eligible for GKE free-tier management credit
  k8s_version     = var.kubernetes_minor
  network         = local.net.network_id
  subnetwork      = local.net.private_subnet_ids[0]
  machine_type    = local.instance_type
  desired         = var.node_count
  max             = var.node_max
  admin_cidrs     = var.admin_cidrs
  labels          = local.labels
}

module "k3s_aws" {
  source          = "../cluster/k3s-vm-aws"
  count           = var.cloud == "aws" && var.profile == "budget" ? 1 : 0
  name            = local.name
  subnet_id       = local.net.public_subnet_ids[0]
  vpc_id          = local.net.network_id
  instance_type   = local.instance_type
  origin_cidrs    = var.cloudflare_ipv4
  admin_cidrs     = var.admin_cidrs
  tags            = merge(local.labels, { "cb-ansible-role" = "k3s_server" })
}

module "k3s_gcp" {
  source          = "../cluster/k3s-vm-gcp"
  count           = var.cloud == "gcp" && var.profile == "budget" ? 1 : 0
  name            = local.name
  project_id      = var.gcp_project_id
  zone            = "${var.region}-a"
  network         = local.net.network_id
  subnetwork      = local.net.public_subnet_ids[0]
  machine_type    = local.instance_type
  origin_cidrs    = var.cloudflare_ipv4
  admin_cidrs     = var.admin_cidrs
  labels          = merge(local.labels, { "cb-ansible-role" = "k3s_server" })
}

locals {
  # Every implementation exposes the SAME output object. concat()+one() picks the single
  # instantiated implementation without a conditional that would need identical types.
  cluster = one(concat(module.eks[*].cluster, module.gke[*].cluster,
                       module.k3s_aws[*].cluster, module.k3s_gcp[*].cluster))
}

module "db_aws" {
  source     = "../database/aws-rds"
  count      = var.cloud == "aws" && var.profile == "managed" ? 1 : 0
  name       = local.name
  subnet_ids = local.net.private_subnet_ids
  vpc_id     = local.net.network_id
  allowed_sg = local.cluster.node_security_group
  engine_version = "18"
  tags       = local.labels
}

module "db_gcp" {
  source     = "../database/gcp-cloudsql"
  count      = var.cloud == "gcp" && var.profile == "managed" ? 1 : 0
  name       = local.name
  project_id = var.gcp_project_id
  region     = var.region
  network    = local.net.network_id
  database_version = "POSTGRES_18"
  labels     = local.labels
}

module "cache_aws" {
  source     = "../cache/aws-elasticache"
  count      = var.cloud == "aws" && var.profile == "managed" && var.managed_cache ? 1 : 0
  name       = local.name
  subnet_ids = local.net.private_subnet_ids
  vpc_id     = local.net.network_id
  allowed_sg = local.cluster.node_security_group
  engine_version = "9.0"
  tags       = local.labels
}

module "cache_gcp" {
  source     = "../cache/gcp-memorystore"
  count      = var.cloud == "gcp" && var.profile == "managed" && var.managed_cache ? 1 : 0
  name       = local.name
  project_id = var.gcp_project_id
  region     = var.region
  network    = local.net.network_id
  engine_version = "VALKEY_9_0"
  labels     = local.labels
}

locals {
  # null → bootstrap installs in-cluster Postgres/Valkey (budget profile, or managed_cache=false).
  # one([]) returns null, so the optional implementations need no special casing.
  database = one(concat(module.db_aws[*].database, module.db_gcp[*].database))
  cache    = one(concat(module.cache_aws[*].cache, module.cache_gcp[*].cache))
}
```

> **Why `one(concat(...))` instead of `var.cloud == "aws" ? module.eks[0] : module.gke[0]`:** the conditional must unify both branches' types, and indexing an empty module list errors. `one()` over the concatenated lists returns exactly the instantiated implementation, and fails loudly if zero or two are instantiated — which is itself a correctness check on the `count` logic. For the cluster (always exactly one), a `null` result would surface immediately as an attribute error downstream.

```hcl
# infra/modules/cell/outputs.tf — THE INTERFACE (identical for every cloud × profile)
output "cell" {
  value = {
    name        = local.name
    cloud       = var.cloud
    profile     = var.profile
    region      = var.region
    shape       = local.shape_row          # recorded for cost fairness + parity
    origin      = local.cluster.origin     # hostname (ALB) or IP (GCLB / VM) for Cloudflare
  }
}

output "cluster" {
  value     = local.cluster                # { name, endpoint, ca_certificate, k8s_version,
  sensitive = true                         #   origin, node_security_group, auth = {...} }
}

output "database" {  # { host, port, secret_ref } | null
  value = local.database
  sensitive = true
}
output "cache" {  # { host, port, tls } | null
  value = local.cache
  sensitive = true
}
```

**Contract test — runs offline, both engines, ₹0:**

```hcl
# infra/modules/cell/tests/contract.tftest.hcl
mock_provider "aws" {}
mock_provider "google" {}

variables {
  env             = "test"
  region          = "ap-south-1"
  cloudflare_ipv4 = ["173.245.48.0/20"]
  gcp_project_id  = "cb-test"
}

run "aws_managed_exposes_contract" {
  command   = apply
  variables {
    cloud = "aws"
    profile = "managed"
  }
  assert {
    condition     = output.cell.cloud == "aws" && output.cell.shape.vcpu == 2
    error_message = "AWS managed cell must expose the cell contract with a parity shape."
  }
  assert {
    condition     = alltrue([for k in ["name","endpoint","ca_certificate","k8s_version","origin"] : can(output.cluster[k])])
    error_message = "Cluster contract keys missing on AWS implementation."
  }
}

run "gcp_managed_exposes_same_contract" {
  command   = apply
  variables {
    cloud = "gcp"
    profile = "managed"
    region = "asia-south1"
  }
  assert {
    condition     = alltrue([for k in ["name","endpoint","ca_certificate","k8s_version","origin"] : can(output.cluster[k])])
    error_message = "Cluster contract keys missing on GCP implementation."
  }
}

run "shapes_are_equivalent" {
  command   = plan
  variables {
    cloud = "gcp"
    profile = "managed"
    region = "asia-south1"
    shape = "standard"
  }
  assert {
    condition     = output.cell.shape.vcpu == 2 && output.cell.shape.mem_gib == 8
    error_message = "Shape parity broken: standard must be 2 vCPU / 8 GiB on every cloud."
  }
}

run "rejects_unknown_cloud" {
  command         = plan
  variables       { cloud = "azure" }
  expect_failures = [var.cloud]
}
```

Interview line: *"My abstraction has a contract test. I can prove, without spending a rupee, that every implementation returns the same interface — the facade isn't a convention, it's tested."*

## 7.3 AWS EKS implementation (key file)

```hcl
# infra/modules/cluster/aws-eks/main.tf
data "aws_iam_policy_document" "eks_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${var.name}-cluster"
  assume_role_policy = data.aws_iam_policy_document.eks_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_eks_cluster" "this" {
  name     = var.name
  version  = var.k8s_version
  role_arn = aws_iam_role.cluster.arn

  access_config {
    authentication_mode                         = "API"   # access entries, not aws-auth ConfigMap
    bootstrap_cluster_creator_admin_permissions = false
  }

  vpc_config {
    subnet_ids              = var.subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = var.admin_cidrs              # never 0.0.0.0/0
  }

  upgrade_policy { support_type = "STANDARD" }            # avoid 6× extended-support fee

  tags       = var.tags
  depends_on = [aws_iam_role_policy_attachment.cluster]
}

# Nodes
data "aws_iam_policy_document" "node_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${var.name}-node"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly",
  ])
  role       = aws_iam_role.node.name
  policy_arn = each.value
}

resource "aws_eks_node_group" "default" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.name}-default"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.subnet_ids
  instance_types  = [var.instance_type]
  ami_type        = "AL2023_x86_64_STANDARD"

  scaling_config {
    desired_size = var.desired
    min_size     = 1
    max_size     = var.max
  }
  update_config { max_unavailable = 1 }

  lifecycle { ignore_changes = [scaling_config[0].desired_size] }  # autoscaler owns desired
  tags       = var.tags
  depends_on = [aws_iam_role_policy_attachment.node]
}

resource "aws_eks_addon" "pod_identity" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "eks-pod-identity-agent"
}

# CI deploy role gets cluster access via an access entry (no aws-auth edits)
resource "aws_eks_access_entry" "ci" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = var.ci_role_arn
}

resource "aws_eks_access_policy_association" "ci_admin" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = var.ci_role_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope { type = "cluster" }
}
```

```hcl
# infra/modules/cluster/aws-eks/outputs.tf — must match every other implementation
output "cluster" {
  value = {
    name                = aws_eks_cluster.this.name
    endpoint            = aws_eks_cluster.this.endpoint
    ca_certificate      = base64decode(aws_eks_cluster.this.certificate_authority[0].data)
    k8s_version         = aws_eks_cluster.this.version
    origin              = null   # set by bootstrap once the ALB exists; see §7.6
    node_security_group = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
    auth = { kind = "aws-eks", cluster_name = aws_eks_cluster.this.name }
  }
}
```

## 7.4 GCP GKE implementation (key file)

```hcl
# infra/modules/cluster/gcp-gke/main.tf
resource "google_service_account" "nodes" {
  project      = var.project_id
  account_id   = "${var.name}-nodes"
  display_name = "CloudBridge GKE nodes (least privilege)"
}

resource "google_project_iam_member" "nodes" {
  for_each = toset([
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/artifactregistry.reader",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.nodes.email}"
}

resource "google_container_cluster" "this" {
  project             = var.project_id
  name                = var.name
  location            = var.zone                     # zonal
  network             = var.network
  subnetwork          = var.subnetwork
  min_master_version  = var.k8s_version
  deletion_protection = var.env == "prod"

  release_channel { channel = "REGULAR" }
  maintenance_policy {
    recurring_window {
      start_time = "2026-01-01T20:30:00Z"            # 02:00 IST
      end_time   = "2026-01-01T23:30:00Z"
      recurrence = "FREQ=WEEKLY;BYDAY=SA,SU"
    }
  }

  remove_default_node_pool = true
  initial_node_count       = 1
  datapath_provider        = "ADVANCED_DATAPATH"     # Dataplane V2: NetworkPolicy enforced

  workload_identity_config { workload_pool = "${var.project_id}.svc.id.goog" }
  ip_allocation_policy {}                            # VPC-native

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }
  master_authorized_networks_config {
    dynamic "cidr_blocks" {
      for_each = var.admin_cidrs
      content { cidr_block = cidr_blocks.value }
    }
  }

  resource_labels = var.labels
}

resource "google_container_node_pool" "default" {
  project  = var.project_id
  name     = "${var.name}-default"
  location = var.zone
  cluster  = google_container_cluster.this.name
  initial_node_count = var.desired

  autoscaling {
    min_node_count = 1
    max_node_count = var.max
  }
  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    machine_type    = var.machine_type
    disk_type       = "pd-balanced"
    disk_size_gb    = 50
    service_account = google_service_account.nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]  # IAM roles above are the real limit
    workload_metadata_config { mode = "GKE_METADATA" }
    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
    labels = var.labels
  }

  lifecycle { ignore_changes = [initial_node_count] }
}
```

> The `cloud-platform` scope on a **dedicated** SA with four narrow roles is Google's recommended pattern — scopes are legacy; IAM is the effective boundary. Rev 1's problem (C15) was the *default* compute SA, which commonly holds Editor.

## 7.5 Cloudflare traffic stack (provider v5)

```hcl
# infra/live/global/30-traffic/variables.tf
variable "zone_id"    { type = string }
variable "account_id" { type = string }
variable "hostname"   { type = string }               # app.<domain>

variable "weights" {
  type        = map(number)                           # percent, e.g. { aws = 70, gcp = 30 }
  description = "Traffic share per cell. Changed only by PR (manual, recommender, or evacuation playbook)."
  validation {
    condition     = sum(values(var.weights)) == 100
    error_message = "Weights must sum to 100."
  }
  validation {
    # Warm floor: a cell either takes >= 10% or is explicitly drained to 0 (evacuation).
    condition     = alltrue([for w in values(var.weights) : w == 0 || w >= 10])
    error_message = "Each cell must be 0 (drained) or >= 10% (keeps caches, JIT and autoscaler warm)."
  }
}

variable "fallback_cell" {
  type = string
  default = "gcp"
}
```

```hcl
# infra/live/global/30-traffic/main.tf
data "terraform_remote_state" "aws" {
  backend = "s3"
  config  = { bucket = "cb-tfstate-aws", key = "aws-prod/10-foundation.tfstate", region = "ap-south-1" }
}
data "terraform_remote_state" "gcp" {
  backend = "gcs"
  config  = { bucket = "cb-tfstate-gcp", prefix = "gcp-prod/10-foundation" }
}

locals {
  origins = {
    aws = data.terraform_remote_state.aws.outputs.cell.origin
    gcp = data.terraform_remote_state.gcp.outputs.cell.origin
  }
}

resource "cloudflare_load_balancer_monitor" "cell" {
  account_id     = var.account_id
  type           = "https"
  method         = "GET"
  path           = "/healthz/cell"
  expected_codes = "200"
  interval       = 60
  retries        = 2
  timeout        = 5
  header         = { "Host" = [var.hostname] }
  description    = "CloudBridge cell health (aggregates gateway + order DB readiness)"
}

resource "cloudflare_load_balancer_pool" "cell" {
  for_each   = local.origins
  account_id = var.account_id
  name       = "cb-${each.key}-prod"
  monitor    = cloudflare_load_balancer_monitor.cell.id
  origins = [{
    name    = "${each.key}-ingress"
    address = each.value
    enabled = true
    header  = { host = [var.hostname] }
  }]
  minimum_origins = 1
  check_regions   = ["SAS", "SEAS"]                   # probe from near the Mumbai origins
}

resource "cloudflare_load_balancer" "app" {
  zone_id          = var.zone_id
  name             = var.hostname
  proxied          = true
  default_pools    = [for k in ["aws", "gcp"] : cloudflare_load_balancer_pool.cell[k].id]
  fallback_pool    = cloudflare_load_balancer_pool.cell[var.fallback_cell].id
  steering_policy  = "random"

  random_steering = {
    default_weight = 0
    pool_weights   = { for k, pct in var.weights : cloudflare_load_balancer_pool.cell[k].id => pct / 100 }
  }

  session_affinity     = "cookie"                     # home cell (C12)
  session_affinity_ttl = 82800
  session_affinity_attributes = {
    samesite               = "Lax"
    secure                 = "Always"
    drain_duration         = 60
    zero_downtime_failover = "sticky"
  }
}
```

```json
// infra/live/global/30-traffic/terraform.tfvars.json — the file the demo, the recommender and
// the evacuation playbook all edit (always via PR or a recorded playbook run). JSON rather than
// HCL so Ansible and Python can read/write it without an HCL parser.
{ "weights": { "aws": 70, "gcp": 30 } }
```
(Terraform loads `terraform.tfvars.json` automatically; real JSON has no comments — the comment above is for this document only.)

> **Schema caution:** Cloudflare's v5 provider is generated from their API schema and evolves every 2–3 weeks. Field names above match the v5 resource docs for `cloudflare_load_balancer` (`random_steering.pool_weights`, `session_affinity_attributes`) — run `terraform validate` against your pinned v5.22.x and adjust nested attribute spelling if the generator changed it.

**Origin lock-down** (both clouds accept 443 only from Cloudflare):
```hcl
data "cloudflare_ip_ranges" "cf" {}
# passed into each cell stack as var.cloudflare_ipv4 → AWS SG ingress rule / GCP firewall source_ranges
```

## 7.6 Ingress origins per profile

| Profile | AWS origin | GCP origin | How `cell.origin` is produced |
|---|---|---|---|
| managed | ALB hostname from AWS Load Balancer Controller | Static global IP reserved by Terraform (`google_compute_global_address`), referenced by Ingress annotation | AWS: ALB is created by the controller after bootstrap → `20-bootstrap` outputs it via `data "aws_lb"` lookup on tag `ingress.k8s.aws/stack`. GCP: known at `10-foundation` time. |
| budget | EC2 Elastic IP | GCE static external IP | Known at `10-foundation` time |

So the traffic stack reads AWS managed origin from `aws-prod/20-bootstrap` outputs. This is a real leaky abstraction (entry #2 in §20.3): *AWS ingress gives you a hostname you learn after the controller runs; GCP lets you reserve an IP up front.*

## 7.7 Backends

```hcl
# live/aws-prod/10-foundation/backend.tf
terraform {
  backend "s3" {
    bucket       = "cb-tfstate-aws"
    key          = "aws-prod/10-foundation.tfstate"
    region       = "ap-south-1"
    encrypt      = true
    use_lockfile = true          # native S3 locking; DynamoDB locking is deprecated
  }
}

# live/gcp-prod/10-foundation/backend.tf
terraform {
  backend "gcs" {
    bucket = "cb-tfstate-gcp"
    prefix = "gcp-prod/10-foundation"   # GCS backend locks natively
  }
}
```
Both buckets: versioning on, public access blocked, lifecycle keeps 30 noncurrent versions (state rollback), access restricted to the stack's CI roles.

---

# §8 — Ansible + Terraform Integration

## 8.1 The division of labour

> **Terraform builds the house. Ansible configures what's inside the rooms that aren't prefabricated — and runs the fire drill.**

| Job | Owner | Why |
|---|---|---|
| VPCs, clusters, VMs, DBs, caches, IAM, Cloudflare | Terraform | Resources with an API lifecycle need state, plan, drift detection |
| Kubernetes apps and add-ons | Argo CD (Helm) | Continuous reconciliation from Git |
| OS hardening, k3s install, node_exporter, origin TLS on budget VMs | **Ansible** | VMs aren't immutable images here; idempotent config management is exactly Ansible's job |
| Evacuate / failback / drill / pre-warm | **Ansible playbooks** | Multi-step procedures with checks, waits, branches and compensation — a saga, not a resource |
| Alert → drill trigger (non-prod), alert → proposal (prod) | **Event-Driven Ansible** (`ansible-rulebook`) | Reacts to Alertmanager webhooks |

## 8.2 Why NOT the other integration styles

| Option | Why not |
|---|---|
| Terraform `remote-exec`/`local-exec` provisioners calling Ansible | HashiCorp calls provisioners a last resort; failures taint resources; re-running config means replacing VMs |
| `ansible/ansible` Terraform provider to register hosts | Couples inventory to Terraform state reads; cloud tags + dynamic inventory need no coupling |
| Packer golden image instead of Ansible on boot | Better at scale (immutable); planned as post-MVP. For 2 VMs, Ansible gives faster iteration and is what the brief asks to show. Packer would still use the same Ansible roles as its provisioner — no wasted work. |
| Ansible `kubernetes.core.helm` for app deploys | Second owner of releases (the same mistake as C7) |

## 8.3 Hand-off contract: tags, not state

Terraform tags every budget VM with `cb-ansible-role = k3s_server`, `cb-cell`, `cb-cloud`, `cb-env`. Ansible discovers hosts by tags:

```yaml
# ansible/inventories/aws_ec2.yml
plugin: amazon.aws.aws_ec2
regions: [ap-south-1]
filters:
  "tag:cb-ansible-role": k3s_server
  instance-state-name: running
keyed_groups:
  - key: tags['cb-env']
    prefix: env
  - key: tags['cb-cloud']
    prefix: cloud
compose:
  ansible_host: public_ip_address
  cb_cell: tags['cb-cell']
```

```yaml
# ansible/inventories/gcp_compute.yml
plugin: google.cloud.gcp_compute
projects: ["{{ lookup('env', 'GCP_PROJECT_ID') }}"]
zones: [asia-south1-a]
filters:
  - labels.cb-ansible-role = k3s_server
  - status = RUNNING
auth_kind: application        # WIF credentials from google-github-actions/auth
keyed_groups:
  - key: labels['cb-env']
    prefix: env
  - key: labels['cb-cloud']
    prefix: cloud
compose:
  ansible_host: networkInterfaces[0].accessConfigs[0].natIP
  cb_cell: labels['cb-cell']
```

SSH access: no inbound SSH from the internet. Runners connect via **AWS SSM Session Manager** (`community.aws.aws_ssm` connection plugin) and **GCP IAP TCP forwarding** (`gcloud compute ssh --tunnel-through-iap` as `ansible_ssh_common_args` ProxyCommand). That's a leaky abstraction too (#7 in §20.3), handled per group with `group_vars/cloud_aws.yml` / `cloud_gcp.yml`.

## 8.4 Roles

```yaml
# ansible/roles/k3s_server/defaults/main.yml
k3s_version: "v1.36.2+k3s1"          # parity contract checks minor == managed clusters
k3s_disable: [traefik]               # we install Traefik via Argo CD (one owner)
k3s_tls_san: ["{{ ansible_host }}"]
k3s_kubelet_args:
  - "kube-reserved=cpu=100m,memory=256Mi"
  - "system-reserved=cpu=100m,memory=128Mi"
  - "eviction-hard=memory.available<100Mi"
```

```yaml
# ansible/roles/k3s_server/tasks/main.yml
- name: Write k3s config
  ansible.builtin.template:
    src: config.yaml.j2
    dest: /etc/rancher/k3s/config.yaml
    mode: "0600"
  notify: restart k3s

- name: Check installed k3s version
  ansible.builtin.command: k3s --version
  register: k3s_installed
  changed_when: false
  failed_when: false

- name: Install k3s (pinned, idempotent)
  ansible.builtin.shell: |
    set -euo pipefail
    curl -sfL https://get.k3s.io -o /tmp/k3s-install.sh
    INSTALL_K3S_VERSION="{{ k3s_version }}" sh /tmp/k3s-install.sh
  args: { executable: /bin/bash }
  when: k3s_version not in (k3s_installed.stdout | default(''))

- name: Wait for node Ready
  ansible.builtin.command: k3s kubectl wait --for=condition=Ready node --all --timeout=180s
  changed_when: false

- name: Export kubeconfig to runner (for Argo CD bootstrap only)
  ansible.builtin.fetch:
    src: /etc/rancher/k3s/k3s.yaml
    dest: "{{ playbook_dir }}/../.kube/{{ cb_cell }}.yaml"
    flat: true
  no_log: true
```

`base_hardening` covers: SSH password auth off, unattended security upgrades, `auditd`, `chrony`, sysctl hardening, a 1 GiB swapfile with low swappiness on 2 GiB VMs (prevents OOM during JVM start-up bursts), journald size cap. Each role has a **Molecule** scenario (Docker driver) run in CI with `ansible-lint`.

## 8.5 Playbooks at a glance

| Playbook | Purpose | Idempotent? | Section |
|---|---|---|---|
| `site.yml` | Configure budget VMs (hardening, k3s, exporters, origin TLS) | Yes | §8.4 |
| `prewarm.yml` | Raise target-cell HPA mins + wait for nodes | Yes (target state) | §15 |
| `evacuate.yml` | Capacity check → stepped, SLO-gated shift → report | Resumable; records each step | §15 |
| `failback.yml` | Reverse shift to recorded pre-evacuation weights | Resumable | §15 |
| `drill.yml` | Scheduled evacuate + failback in dev/budget, writes drill report | — | §15 |

## 8.6 Event-Driven Ansible

```yaml
# ansible/rulebooks/cell-degraded.yml
- name: Cell degradation → drill or proposal
  hosts: localhost
  sources:
    - ansible.eda.alertmanager:
        host: 0.0.0.0
        port: 5000
  rules:
    - name: Non-prod — run the evacuation drill automatically
      condition: >
        event.alert.labels.alertname == "CellSLOBurnFast" and
        event.alert.labels.env != "prod" and event.alert.status == "firing"
      action:
        run_playbook:
          name: playbooks/evacuate.yml
          extra_vars:
            from_cell: "{{ event.alert.labels.cb_cloud }}"
            mode: drill

    - name: Prod — never auto-shift; open a reviewed proposal instead
      condition: >
        event.alert.labels.alertname == "CellSLOBurnFast" and
        event.alert.labels.env == "prod" and event.alert.status == "firing"
      action:
        run_playbook:
          name: playbooks/propose_evacuation.yml   # opens a GitHub issue + PR with the weight change
          extra_vars:
            from_cell: "{{ event.alert.labels.cb_cloud }}"
```

Interview framing: *"Automation decides fast in dev; in prod it prepares the change and a human approves it in one click. Cloudflare's own health monitor already handles hard-down — EDA handles the slow-burn degradation that health checks don't catch."*

---

# §9 — Database Design & Choice

CloudBridge has **two** databases with different jobs. Both are PostgreSQL 18 — for different reasons — and the interview answer should make that explicit.

| Database | Lives where | Holds | Write rate |
|---|---|---|---|
| **Cell DB** (one per cell) | RDS / Cloud SQL (managed) or in-cluster StatefulSet (budget) | Orders, idempotency keys, outbox, inventory stock + escrow lease | Tens of writes/sec at demo load |
| **Control-plane DB** | GCP budget VM (in-cluster, nightly backup to GCS + S3) | FOCUS cost line items, request volumes, deployments, parity snapshots, drills, traffic changes, recommendations, plan-risk reports | A few thousand rows/day (billing) + events |

## 9.1 Decision matrix

| Criterion (weight) | PostgreSQL 18 | TimescaleDB | MongoDB | Cassandra | Cosmos DB | Generic NoSQL KV |
|---|---|---|---|---|---|---|
| Available as **managed service on both AWS and GCP** with the same major (25%) | ✅ RDS 18.4 + Cloud SQL 18 | ❌ not offered as an extension on RDS or Cloud SQL | ⚠️ only via a third party (Atlas) or DocumentDB (API-compatible, not MongoDB) | ⚠️ Keyspaces (AWS) vs self-run on GCP | ❌ Azure-only — contradicts the project's thesis | ⚠️ DynamoDB vs Firestore: different APIs |
| Relational joins: cell → deployment → service → cost (20%) | ✅ native | ✅ | ⚠️ `$lookup` | ❌ | ⚠️ | ❌ |
| Transactions for order + outbox + escrow decrement in one commit (20%) | ✅ | ✅ | ✅ (multi-doc) | ❌ (LWT only) | ✅ (partition-scoped) | ⚠️ |
| Time-series volume of the cost ledger (10%) | ✅ fine with monthly partitions at thousands of rows/day | ✅ best-in-class | ⚠️ | ✅ | ✅ | ⚠️ |
| Semi-structured FOCUS tags / raw billing payloads (10%) | ✅ JSONB + GIN | ✅ | ✅ | ⚠️ | ✅ | ⚠️ |
| Globally unique IDs without coordination (10%) | ✅ `uuidv7()` built in from PG18 | ✅ (PG extension) | ✅ ObjectId | ✅ timeuuid | ✅ | ⚠️ |
| Ops familiarity in Indian product companies (5%) | ✅ | ⚠️ | ✅ | ⚠️ | ⚠️ | ✅ |

### Verdict: PostgreSQL 18 for both

**Cell DB:** the parity requirement decides it — the only database with the same major version as a first-party managed service on both clouds, plus the transactional guarantees that orders, outbox and escrow need in one commit.

**Control-plane DB:** the cost ledger *is* time-series-shaped, which is the honest case for TimescaleDB. It loses because (a) volume is thousands of rows a day, which native monthly partitioning handles with sub-100 ms queries, and (b) it isn't available on RDS/Cloud SQL, so choosing it would make the control plane the one component that can't move clouds. Your portfolio standard (TimescaleDB for *high-frequency* time-series, as in TraceMap-class metrics) is respected — this isn't high-frequency.

**When I'd change my mind:** per-second resource metrics in the ledger (→ TimescaleDB or ClickHouse, as in TraceMap), or > 10 cells writing orders with cross-cell queries (→ a distributed SQL engine such as CockroachDB/YugabyteDB, accepting the latency).

## 9.2 Cell DB schema (identical in every cell — enforced by Flyway migrations from one repo)

```sql
-- services/order-service/src/main/resources/db/migration/V1__cell_schema.sql
CREATE TABLE orders (
    id              uuid PRIMARY KEY DEFAULT uuidv7(),         -- PG18: time-ordered, cell-independent
    cell            text        NOT NULL,                      -- 'cb-aws-prod' — provenance for DR merges
    customer_id     uuid        NOT NULL,
    status          text        NOT NULL CHECK (status IN ('PENDING','CONFIRMED','CANCELLED')),
    total_paise     bigint      NOT NULL CHECK (total_paise >= 0),   -- money as integer paise
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX orders_customer_created ON orders (customer_id, created_at DESC);

CREATE TABLE order_items (
    order_id    uuid   NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
    sku         text   NOT NULL,
    qty         int    NOT NULL CHECK (qty > 0),
    price_paise bigint NOT NULL CHECK (price_paise >= 0),
    PRIMARY KEY (order_id, sku)
);

-- Idempotency: a retried POST (client retry, Cloudflare retry, failover mid-request) returns the
-- original result instead of creating a second order.
CREATE TABLE idempotency_keys (
    key            text        PRIMARY KEY,
    request_hash   text        NOT NULL,          -- same key + different body → 422
    order_id       uuid        REFERENCES orders(id),
    response_code  int,
    created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idempotency_created ON idempotency_keys (created_at);  -- TTL sweep after 24 h

-- Transactional outbox: domain events are written in the same transaction as the state change,
-- then relayed to Valkey Streams. No dual-write.
CREATE TABLE outbox (
    id           uuid        PRIMARY KEY DEFAULT uuidv7(),
    aggregate    text        NOT NULL,
    aggregate_id uuid        NOT NULL,
    event_type   text        NOT NULL,
    payload      jsonb       NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    published_at timestamptz
);
CREATE INDEX outbox_unpublished ON outbox (created_at) WHERE published_at IS NULL;

-- Inventory with escrow leases (§23.3): each cell may only sell what its lease grants.
CREATE TABLE inventory_lease (
    sku           text        PRIMARY KEY,
    granted_qty   int         NOT NULL CHECK (granted_qty >= 0),
    sold_qty      int         NOT NULL DEFAULT 0 CHECK (sold_qty >= 0),
    lease_epoch   bigint      NOT NULL,           -- fencing token from the allocator
    expires_at    timestamptz NOT NULL,
    CHECK (sold_qty <= granted_qty)               -- the invariant that makes overselling impossible
);
```

Reserve stock (single statement, no read-modify-write race):
```sql
UPDATE inventory_lease
   SET sold_qty = sold_qty + :qty
 WHERE sku = :sku
   AND expires_at > now()                 -- expired lease → cell stops selling (fencing by time)
   AND sold_qty + :qty <= granted_qty
RETURNING granted_qty - sold_qty AS remaining;
-- 0 rows → out of stock in this cell (or lease expired) → 409
```

## 9.3 Control-plane schema

```sql
-- control-plane/migrations/V1__control_plane.sql
CREATE TYPE cloud_t   AS ENUM ('aws','gcp');
CREATE TYPE profile_t AS ENUM ('managed','budget');

CREATE TABLE cells (
    id          text PRIMARY KEY,                       -- 'cb-aws-prod'
    cloud       cloud_t   NOT NULL,
    profile     profile_t NOT NULL,
    env         text      NOT NULL,
    region      text      NOT NULL,
    stack_path  text      NOT NULL,                     -- infra/live/aws-prod
    shape       jsonb     NOT NULL,                     -- {vcpu, mem_gib, class, instance_type}
    status      text      NOT NULL DEFAULT 'unknown',
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE services (
    name   text PRIMARY KEY,                            -- order-service
    repo   text NOT NULL                                -- docker.io/<you>/cb-order-service
);

-- Every apply and every release, per cell
CREATE TABLE deployments (
    id            uuid PRIMARY KEY DEFAULT uuidv7(),
    cell_id       text NOT NULL REFERENCES cells(id),
    kind          text NOT NULL CHECK (kind IN ('infra','release','traffic')),
    stack         text,                                 -- 10-foundation
    engine        text,                                 -- terraform 1.15.x
    plan_sha256   text,                                 -- hash of the reviewed plan JSON
    changes       jsonb,                                -- {add, change, destroy}
    image_digests jsonb,                                -- {"order-service":"sha256:..."}
    commit_sha    text NOT NULL,
    pr_number     int,
    run_id        bigint,
    status        text NOT NULL CHECK (status IN ('planned','approved','applied','failed','rolled_back')),
    started_at    timestamptz NOT NULL DEFAULT now(),
    finished_at   timestamptz
);
CREATE INDEX deployments_cell_time ON deployments (cell_id, started_at DESC);

-- FOCUS-shaped cost ledger (column names follow FOCUS so any FOCUS tool can read it)
CREATE TABLE cost_line_items (
    id                   bigint GENERATED ALWAYS AS IDENTITY,
    provider_name        text        NOT NULL,          -- FOCUS ProviderName
    billing_account_id   text        NOT NULL,
    charge_period_start  timestamptz NOT NULL,
    charge_period_end    timestamptz NOT NULL,
    charge_category      text        NOT NULL,          -- Usage | Purchase | Tax | Credit | Adjustment
    service_category     text,                          -- Compute | Databases | Networking | Storage ...
    service_name         text,                          -- Amazon EC2 | Compute Engine ...
    resource_id          text,
    region_id            text,
    billed_cost          numeric(18,6) NOT NULL,
    effective_cost       numeric(18,6) NOT NULL,        -- after discounts, amortised commitments
    list_cost            numeric(18,6),
    billing_currency     char(3)     NOT NULL,
    tags                 jsonb       NOT NULL DEFAULT '{}',
    cb_cell              text GENERATED ALWAYS AS (tags->>'cb-cell') STORED,
    cb_service           text GENERATED ALWAYS AS (tags->>'cb-service') STORED,
    source_file          text        NOT NULL,          -- export object / BQ job id (lineage)
    ingested_at          timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (id, charge_period_start)
) PARTITION BY RANGE (charge_period_start);

CREATE TABLE cost_line_items_2026_10 PARTITION OF cost_line_items
    FOR VALUES FROM ('2026-10-01') TO ('2026-11-01');
-- monthly partitions created ahead by the collector; old ones detached + archived to object storage
CREATE INDEX cli_cell_period ON cost_line_items (cb_cell, charge_period_start);
CREATE INDEX cli_tags ON cost_line_items USING gin (tags);

-- Idempotent re-ingestion: a re-delivered export file replaces its own rows only
CREATE TABLE cost_ingestions (
    source_file   text PRIMARY KEY,
    provider_name text NOT NULL,
    period_start  date NOT NULL,
    row_count     int  NOT NULL,
    checksum      text NOT NULL,
    ingested_at   timestamptz NOT NULL DEFAULT now()
);

-- OpenCost allocation shares (in-cluster truth for splitting shared node cost)
CREATE TABLE allocation_daily (
    day        date NOT NULL,
    cell_id    text NOT NULL REFERENCES cells(id),
    service    text NOT NULL REFERENCES services(name),
    cpu_share  numeric(7,6) NOT NULL,
    mem_share  numeric(7,6) NOT NULL,
    opencost_estimate numeric(18,6),                    -- for reconciliation vs the bill
    PRIMARY KEY (day, cell_id, service)
);

-- Request volume per service per cell per day (from Prometheus recording rules)
CREATE TABLE request_volume_daily (
    day       date   NOT NULL,
    cell_id   text   NOT NULL REFERENCES cells(id),
    service   text   NOT NULL REFERENCES services(name),
    requests  bigint NOT NULL,
    errors    bigint NOT NULL,
    p95_ms    numeric(10,2),
    PRIMARY KEY (day, cell_id, service)
);

-- Traffic weight history: who changed the split, why, and from which source
CREATE TABLE traffic_changes (
    id          uuid PRIMARY KEY DEFAULT uuidv7(),
    weights     jsonb NOT NULL,                         -- {"aws":70,"gcp":30}
    source      text  NOT NULL CHECK (source IN ('manual','recommender','evacuation','failback','drill','break_glass')),
    pr_url      text,
    drill_id    uuid,
    applied_at  timestamptz NOT NULL DEFAULT now()
);

-- CHECK constraints can't contain subqueries, so the "weights sum to 100" invariant is a trigger
-- (the same rule Terraform's variable validation enforces at plan time — defence in depth).
CREATE FUNCTION weights_sum_100() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF (SELECT sum(value::int) FROM jsonb_each_text(NEW.weights)) <> 100 THEN
    RAISE EXCEPTION 'traffic weights must sum to 100, got %', NEW.weights;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER traffic_weights_sum BEFORE INSERT OR UPDATE ON traffic_changes
  FOR EACH ROW EXECUTE FUNCTION weights_sum_100();
```

```sql
-- Parity (D1)
CREATE TABLE parity_snapshots (
    id         uuid PRIMARY KEY DEFAULT uuidv7(),
    env        text NOT NULL,
    score      numeric(5,4) NOT NULL,                   -- 0..1 weighted
    passed     boolean NOT NULL,
    trigger    text NOT NULL CHECK (trigger IN ('pr','post_sync','nightly','manual')),
    commit_sha text,
    taken_at   timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE parity_findings (
    snapshot_id uuid NOT NULL REFERENCES parity_snapshots(id) ON DELETE CASCADE,
    check_id    text NOT NULL,                          -- k8s.minor, image.order-service, pg.major ...
    weight      numeric(4,2) NOT NULL,
    aws_value   text,
    gcp_value   text,
    status      text NOT NULL CHECK (status IN ('match','diverged','excepted','unknown')),
    exception_expires date,
    PRIMARY KEY (snapshot_id, check_id)
);

-- Evacuation drills (D2)
CREATE TABLE drills (
    id               uuid PRIMARY KEY DEFAULT uuidv7(),
    env              text NOT NULL,
    from_cell        text NOT NULL REFERENCES cells(id),
    to_cell          text NOT NULL REFERENCES cells(id),
    mode             text NOT NULL CHECK (mode IN ('drill','real')),
    outcome          text NOT NULL CHECK (outcome IN ('running','completed','aborted','rolled_back')),
    capacity_ratio   numeric(6,3),                      -- target capacity ÷ peak RPS at start
    prewarm_seconds  int,
    shift_seconds    int,                               -- first step → 100% on target
    errors_during    bigint,
    burn_rate_max    numeric(8,3),
    report_path      text,                              -- docs/drills/2026-11-02-aws-to-gcp.md
    started_at       timestamptz NOT NULL DEFAULT now(),
    finished_at      timestamptz
);
CREATE TABLE drill_steps (
    drill_id   uuid NOT NULL REFERENCES drills(id) ON DELETE CASCADE,
    seq        int  NOT NULL,
    weights    jsonb NOT NULL,
    burn_rate  numeric(8,3),
    p95_ms     numeric(10,2),
    decision   text NOT NULL CHECK (decision IN ('advance','hold','abort')),
    at         timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (drill_id, seq)
);

-- Steering recommendations (D3) and plan-risk reports (D6)
CREATE TABLE steering_recommendations (
    id              uuid PRIMARY KEY DEFAULT uuidv7(),
    current_weights jsonb NOT NULL,
    proposed        jsonb NOT NULL,
    est_saving_inr_month numeric(12,2),
    constraints     jsonb NOT NULL,                     -- which constraints bound the answer
    backtest        jsonb NOT NULL,                     -- {days, slo_violations, saving_vs_static}
    pr_url          text,
    decided         text CHECK (decided IN ('merged','closed','pending')),
    created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE plan_risk_reports (
    id          uuid PRIMARY KEY DEFAULT uuidv7(),
    pr_number   int  NOT NULL,
    stack       text NOT NULL,
    plan_sha256 text NOT NULL,
    verdict     text NOT NULL CHECK (verdict IN ('pass','warn','block')),
    findings    jsonb NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);
```

## 9.4 Key queries

```sql
-- Q1. Cost per 1,000 requests, per service, per cell, last 30 days (the dashboard headline)
WITH cost AS (
  SELECT c.cb_cell AS cell_id, a.service,
         sum(c.effective_cost * a.cpu_share)   AS svc_cost          -- shared node cost split by OpenCost share
  FROM cost_line_items c
  JOIN allocation_daily a
    ON a.cell_id = c.cb_cell AND a.day = c.charge_period_start::date
  WHERE c.charge_category = 'Usage'                                 -- credits excluded (fairness)
    AND c.charge_period_start >= now() - interval '30 days'
  GROUP BY 1, 2
), vol AS (
  SELECT cell_id, service, sum(requests) AS req
  FROM request_volume_daily
  WHERE day >= current_date - 30
  GROUP BY 1, 2
)
SELECT cost.cell_id, cost.service,
       round(cost.svc_cost, 2)                                     AS cost_30d,
       vol.req                                                     AS requests_30d,
       round(cost.svc_cost / nullif(vol.req, 0) * 1000, 4)         AS cost_per_1k_req
FROM cost JOIN vol USING (cell_id, service)
ORDER BY cost.service, cost.cell_id;

-- Q2. OpenCost estimate vs actual bill — reconciliation error per cell per day
SELECT a.day, a.cell_id,
       sum(a.opencost_estimate)                           AS estimated,
       (SELECT sum(effective_cost) FROM cost_line_items c
         WHERE c.cb_cell = a.cell_id AND c.charge_period_start::date = a.day
           AND c.charge_category = 'Usage')               AS billed,
       round(100 * (sum(a.opencost_estimate) /
             nullif((SELECT sum(effective_cost) FROM cost_line_items c
                      WHERE c.cb_cell = a.cell_id AND c.charge_period_start::date = a.day
                        AND c.charge_category = 'Usage'), 0) - 1), 2) AS error_pct
FROM allocation_daily a
GROUP BY a.day, a.cell_id
ORDER BY a.day DESC;

-- Q3. Parity trend
SELECT date_trunc('day', taken_at) AS day, env, min(score) AS worst_score, bool_and(passed) AS all_passed
FROM parity_snapshots GROUP BY 1, 2 ORDER BY 1 DESC;

-- Q4. Drill history (the "exit plan evidence" table)
SELECT started_at::date, from_cell, to_cell, outcome, capacity_ratio,
       prewarm_seconds, shift_seconds, errors_during, burn_rate_max
FROM drills ORDER BY started_at DESC LIMIT 20;
```

---

# §10 — Cache & Messaging

## 10.1 Decision matrix

| Option | What it is | Fit for CloudBridge | Verdict |
|---|---|---|---|
| **Valkey 9.0** | Redis-protocol in-memory store, BSD-licensed, Linux Foundation | Cache, rate limits, idempotency fast-path, Streams for events; **managed on both clouds at the same major** (ElastiCache since May 2026, Memorystore default) | ✅ **Chosen** |
| Redis 8 | Original project; Redis 8 returned to an OSI licence (AGPLv3 option) | Technically equivalent for this workload; both clouds now steer managed users to Valkey, so Redis 8 would break managed-service parity | ❌ (client code is identical — switching is a config change) |
| Kafka 4.x | Distributed log; KRaft-only since 4.0 (no ZooKeeper) | Event volume here is dozens/hour (deploys, drills, drift); a 3-broker cluster per cell for that is absurd | ❌ — switch trigger: > 10k events/s or multi-consumer replay over days |
| RabbitMQ | Broker with routing | Would add a second stateful system per cell for one queue Valkey Streams already handles | ❌ |
| ZooKeeper | Coordination service (consensus, config, leader election) — **not** a cache or a message queue | Nothing here needs consensus; Kafka itself no longer needs it | ❌ — answering "why not ZooKeeper" correctly is the point: it was never in the same category |
| NATS JetStream | Lightweight streaming | Good fit, but another system to run in two clouds | ❌ (mentioned as the next step up) |

## 10.2 Valkey usage map

**In each cell:**

| Key / stream | Purpose | TTL / retention |
|---|---|---|
| `inv:{sku}` | Inventory read cache (cache-aside) | 30 s + jitter |
| `rl:{client}:{window}` | Gateway rate limiting (sliding window via `INCR` + `EXPIRE`) | window |
| `idem:{key}` | Idempotency fast-path: `SET NX PX 86400000` before DB insert; DB unique key is the source of truth | 24 h |
| `stream:cell-events` | Outbox relay target (`order.created`, `inventory.lease.renewed`) | `MAXLEN ~ 100000` |

**In the control plane:**

| Key / stream | Purpose |
|---|---|
| `dash:cost:{range}` | Dashboard query cache (1 h; invalidated on ingestion event) |
| `dash:parity:latest` | Latest parity snapshot (invalidated on new snapshot) |
| `stream:cp-events` | `deployment.*`, `parity.*`, `drill.*`, `cost.ingested` — consumer groups: `dashboard-sse`, `notifier`, `recommender` |

**Explicitly not in Valkey:** Terraform state or locks (C4), anything that must survive a cache flush (idempotency truth lives in Postgres).

Failure mode: Valkey down → inventory reads go to Postgres (circuit breaker opens on cache), rate limiting fails **open** with a conservative in-memory limiter, idempotency falls back to the DB constraint. The cell degrades; it doesn't fail `/healthz/cell`.

---

# §11 — Design Patterns

| Pattern | Where | Why it's the right pattern (interview line) |
|---|---|---|
| **Abstract Factory** | `modules/cell` facade → `network/*`, `cluster/*`, `database/*`, `cache/*` | "One input interface, several product families (AWS managed, GCP managed, k3s on either), one output interface — proven by a contract test." |
| **Facade** | `cell` outputs consumed by bootstrap and traffic stacks | Consumers never see a cloud-specific resource name. |
| **Strategy** | Python `CloudAdapter` protocol: `AwsAdapter`, `GcpAdapter` for cost ingestion, parity facts, capacity queries | New cloud = new strategy class, no changes to callers. |
| **Adapter** | FOCUS normaliser (provider export → common schema); ESO `SecretStore`; LLM adapter for the plan explainer | Same principle at three layers: data, secrets, AI. |
| **Cell-based architecture** | Each cloud is an independent cell with its own data; users pinned by cookie | Blast-radius containment; no cross-cloud synchronous calls on the request path. |
| **Escrow / lease with fencing** | Inventory allocation per cell (§23.3) | Prevents overselling without distributed transactions. |
| **Transactional Outbox** | `outbox` table → Valkey Streams relay | No dual writes between DB and stream. |
| **Idempotency Key** | `POST /orders` | Retries across failover are safe. |
| **Saga with compensation** | `evacuate.yml`: each weight step has a compensating step (restore previous weights) | Long-running multi-system operation with no global transaction. |
| **Circuit Breaker / Bulkhead / Timeout** | Resilience4j in services; separate thread pools for DB vs cache | Contain dependency failure. |
| **Control loop (reconciler)** | Argo CD, parity checker, steering recommender | Desired state in Git, observed state measured, difference acted on (or proposed). |
| **Specification / Policy-as-code** | Conftest rules on plan JSON, parity contract YAML | Rules are data, testable and reviewable. |
| **Template Method** | Reusable GitHub workflow `_terraform-stack.yml` called per stack | Same lifecycle, different parameters. |
| **Observer / Pub-Sub** | Valkey Streams consumer groups in control plane | Decoupled reactions to events. |

---

# §12 — Docker, Kubernetes & CI/CD

## 12.1 docker-compose.yml (local dev — whole system on a laptop)

```yaml
# docker-compose.yml  (Compose spec: no top-level `version:` key)
name: cloudbridge

x-java: &java
  restart: unless-stopped
  environment: &java-env
    JAVA_TOOL_OPTIONS: "-XX:MaxRAMPercentage=70 -XX:+UseSerialGC -Xss512k"
    SPRING_PROFILES_ACTIVE: local
    CB_CELL: cb-local-dev
  depends_on:
    postgres: { condition: service_healthy }
    valkey:   { condition: service_healthy }

services:
  api-gateway:
    <<: *java
    build: ./services/api-gateway
    ports: ["8080:8080"]
    environment:
      <<: *java-env
      ORDER_URL: http://order-service:8081
      INVENTORY_URL: http://inventory-service:8082
      VALKEY_URL: redis://valkey:6379

  order-service:
    <<: *java
    build: ./services/order-service
    environment:
      <<: *java-env
      SPRING_DATASOURCE_URL: jdbc:postgresql://postgres:5432/cell
      SPRING_DATASOURCE_USERNAME: cell
      SPRING_DATASOURCE_PASSWORD: cell
      VALKEY_URL: redis://valkey:6379

  inventory-service:
    <<: *java
    build: ./services/inventory-service
    environment:
      <<: *java-env
      SPRING_DATASOURCE_URL: jdbc:postgresql://postgres:5432/cell
      SPRING_DATASOURCE_USERNAME: cell
      SPRING_DATASOURCE_PASSWORD: cell
      VALKEY_URL: redis://valkey:6379

  postgres:
    image: postgres:18.4-alpine
    environment:
      POSTGRES_USER: cell
      POSTGRES_PASSWORD: cell
      POSTGRES_DB: cell
    volumes:
      - pg:/var/lib/postgresql
      - ./control-plane/migrations/init-cp.sql:/docker-entrypoint-initdb.d/10-cp.sql:ro
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U cell"]
      interval: 5s
      retries: 10

  valkey:
    image: valkey/valkey:9.0-alpine
    command: ["valkey-server", "--save", "", "--appendonly", "no"]
    healthcheck:
      test: ["CMD", "valkey-cli", "ping"]
      interval: 5s
      retries: 10

  control-plane-api:
    build: ./control-plane
    environment:
      DATABASE_URL: postgresql://cell:cell@postgres:5432/controlplane
      VALKEY_URL: redis://valkey:6379
      COST_SOURCE: fixtures            # replays sample FOCUS files — no cloud credentials locally
    depends_on:
      postgres: { condition: service_healthy }

  dashboard:
    build: ./control-plane/dashboard
    ports: ["3000:3000"]
    environment:
      CP_API_URL: http://control-plane-api:8000

  prometheus:
    image: prom/prometheus:v3.14.0    # pin to the current 3.14.x patch on build day
    command: ["--config.file=/etc/prometheus/prometheus.yml", "--web.enable-remote-write-receiver"]
    volumes: ["./observability/prometheus:/etc/prometheus:ro"]
    ports: ["9090:9090"]

  grafana:
    image: grafana/grafana:13.2.0     # pinned, never :latest
    ports: ["3001:3000"]
    volumes: ["./observability/grafana/provisioning:/etc/grafana/provisioning:ro"]

  k6:
    image: grafana/k6:1.0.0          # pin the current 1.x patch on build day
    profiles: ["load"]                # docker compose --profile load run k6 run /scripts/cell.js
    volumes: ["./load:/scripts:ro"]

volumes:
  pg: {}
```
`postgres:18` images mount data at `/var/lib/postgresql` (PG18 image layout changed to version-specific subdirectories) — that's why the volume target isn't `/var/lib/postgresql/data`. Verify on build day; it's a small detail interviewers who run Postgres 18 notice.

## 12.2 Service image (same Dockerfile pattern for all three)

```dockerfile
# services/order-service/Dockerfile
# syntax=docker/dockerfile:1.7
FROM eclipse-temurin:21-jdk AS build
WORKDIR /src
COPY mvnw pom.xml ./
COPY .mvn .mvn
RUN --mount=type=cache,target=/root/.m2 ./mvnw -q dependency:go-offline
COPY src src
RUN --mount=type=cache,target=/root/.m2 ./mvnw -q -DskipTests package \
 && java -Djarmode=tools -jar target/*.jar extract --layers --launcher --destination /out

FROM eclipse-temurin:21-jre
RUN useradd --uid 10001 --create-home app
WORKDIR /app
COPY --from=build /out/dependencies/ ./
COPY --from=build /out/spring-boot-loader/ ./
COPY --from=build /out/snapshot-dependencies/ ./
COPY --from=build /out/application/ ./
USER 10001
EXPOSE 8081
ENTRYPOINT ["java", "-XX:MaxRAMPercentage=70", "-XX:+ExitOnOutOfMemoryError", "org.springframework.boot.loader.launch.JarLauncher"]
```
Layered jars mean a code-only change ships a ~100 KB layer, not the whole dependency tree — faster pulls through the registry caches during a scale-up.

## 12.3 Kubernetes: Argo CD per cell, Helm charts, Rollouts

**One owner rule:** Terraform `20-bootstrap` installs exactly one `helm_release` — Argo CD — plus the root `ApplicationSet`. Everything else (ESO, Prometheus agent, OpenCost, Traefik or AWS LB Controller, the apps) is an Argo CD Application from `gitops/`.

```yaml
# gitops/bootstrap/applicationset.yaml  (applied into each cell's own Argo CD)
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: cloudbridge-apps
  namespace: argocd
spec:
  goTemplate: true
  generators:
    - list:
        elements:
          - { app: api-gateway }
          - { app: order-service }
          - { app: inventory-service }
  template:
    metadata:
      name: "{{.app}}"
    spec:
      project: cloudbridge
      sources:
        - repoURL: https://github.com/<you>/cloudbridge
          targetRevision: main
          path: "gitops/charts/{{.app}}"
          helm:
            valueFiles:
              - "$values/gitops/cells/${cell}/values.yaml"
              - "$values/gitops/releases/${ring}.yaml"
        - repoURL: https://github.com/<you>/cloudbridge
          targetRevision: main
          ref: values
      destination:
        server: https://kubernetes.default.svc
        namespace: cb-app
      syncPolicy:
        automated: { prune: true, selfHeal: true }
        syncOptions: [CreateNamespace=true, ServerSideApply=true]
```
> This file is a Terraform template: `20-bootstrap` renders it per cell with `templatefile()`, filling `${cell}` (`cb-gcp-prod`) and `${ring}` (`ring-canary` for GCP, `ring-main` for AWS). `templatefile` only interprets `${…}` and `%{…}`, so Argo's Go-template `{{.app}}` passes through untouched. The `$values` prefix is Argo CD's multi-source `ref`; without braces it is literal text to `templatefile`, so it also passes through unchanged.

```yaml
# gitops/releases/ring-canary.yaml  — bot PRs bump digests here first (GCP cell = canary ring)
images:
  api-gateway:       docker.io/<you>/cb-api-gateway@sha256:...
  order-service:     docker.io/<you>/cb-order-service@sha256:...
  inventory-service: docker.io/<you>/cb-inventory-service@sha256:...
```

```yaml
# gitops/cells/cb-aws-prod/values.yaml  — the ONLY per-cloud differences in app config
cell: cb-aws-prod
cloud: aws
imageRegistryMirror: "<acct>.dkr.ecr.ap-south-1.amazonaws.com/dockerhub"   # pull-through cache prefix
ingress:
  className: alb
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
secretStore: aws-secrets-manager
```

**Chart essentials** (all three services):

| Concern | Setting | Why |
|---|---|---|
| Probes | `startupProbe` on `/actuator/health/liveness` (failureThreshold 30 × 2 s), `livenessProbe` same path, `readinessProbe` on `/actuator/health/readiness` | JVM start can take 15–25 s on small nodes; liveness must not kill a starting pod |
| Cell health | Gateway `/healthz/cell` = gateway ready AND order-service ready AND cell DB reachable; cache **not** included | Cloudflare should drain a cell that can't take orders, not one with a cold cache |
| Resources | gateway 200m/320Mi req, 500m/512Mi lim; order 300m/448Mi; inventory 200m/384Mi | Measured with k6 in week 5 — update the table with your numbers |
| HPA | CPU 65% + `http_server_requests_seconds_count` rate via Prometheus adapter; `minReplicas` 2 (managed) / 1 (budget); `maxReplicas` sized for 100% traffic (§26.2) | Evacuation capacity is a chart value, reviewed like code |
| PDB | `minAvailable: 1` | Node upgrades on GKE auto-upgrade can't take the service to zero |
| Spread | `topologySpreadConstraints` on `topology.kubernetes.io/zone`, `whenUnsatisfiable: ScheduleAnyway` | Zone failure inside a cell |
| Security | non-root UID 10001, `readOnlyRootFilesystem`, drop ALL caps, `seccompProfile: RuntimeDefault` | Same restricted PSS on both clouds |
| NetworkPolicy | default-deny in `cb-app`; allow gateway→order/inventory, apps→DB/cache CIDRs, ingress controller→gateway | GKE Dataplane V2 enforces; EKS needs the VPC CNI network policy feature enabled — leaky abstraction #5 |
| Rollouts | Argo Rollouts canary 10% → 50% → 100% with `AnalysisTemplate` on error rate < 1% and p95 < 300 ms | In-cell progressive delivery; the cloud ring is the outer loop (§18) |

## 12.4 Build & release pipeline (GitHub Actions → Docker Hub → cells)

```yaml
# .github/workflows/ci-app.yml
name: app
on:
  pull_request: { paths: ["services/**"] }
  push: { branches: [main], paths: ["services/**"] }

permissions:
  contents: read
  id-token: write          # cosign keyless
  pull-requests: write

jobs:
  build:
    runs-on: ubuntu-24.04
    strategy:
      matrix: { service: [api-gateway, order-service, inventory-service] }
    steps:
      - uses: actions/checkout@<sha>                 # every action pinned to a full commit SHA
      - uses: actions/setup-java@<sha>
        with: { distribution: temurin, java-version: "21", cache: maven }
      - run: ./services/${{ matrix.service }}/mvnw -f services/${{ matrix.service }} -B verify   # unit + Testcontainers
      - uses: docker/setup-buildx-action@<sha>
      - uses: docker/login-action@<sha>
        if: github.ref == 'refs/heads/main'
        with: { username: "${{ vars.DOCKERHUB_USER }}", password: "${{ secrets.DOCKERHUB_TOKEN }}" }
      - id: push
        uses: docker/build-push-action@<sha>
        with:
          context: services/${{ matrix.service }}
          push: ${{ github.ref == 'refs/heads/main' }}
          tags: docker.io/${{ vars.DOCKERHUB_USER }}/cb-${{ matrix.service }}:${{ github.sha }}
          provenance: mode=max
          sbom: true
      - name: Scan image (fail on HIGH/CRITICAL with a fix available)
        uses: aquasecurity/trivy-action@<sha>
        with: { image-ref: "docker.io/${{ vars.DOCKERHUB_USER }}/cb-${{ matrix.service }}:${{ github.sha }}", severity: "HIGH,CRITICAL", ignore-unfixed: true, exit-code: "1" }
      - uses: sigstore/cosign-installer@<sha>
        if: github.ref == 'refs/heads/main'
      - if: github.ref == 'refs/heads/main'
        run: cosign sign --yes docker.io/${{ vars.DOCKERHUB_USER }}/cb-${{ matrix.service }}@${{ steps.push.outputs.digest }}
      - if: github.ref == 'refs/heads/main'
        run: echo "${{ matrix.service }}=${{ steps.push.outputs.digest }}" >> digests.env
      - uses: actions/upload-artifact@<sha>
        if: github.ref == 'refs/heads/main'
        with: { name: "digest-${{ matrix.service }}", path: digests.env }

  promote-canary:
    needs: build
    if: github.ref == 'refs/heads/main'
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@<sha>
      - uses: actions/download-artifact@<sha>
        with: { pattern: "digest-*", merge-multiple: true }
      - run: python3 tools/bump_ring.py --ring ring-canary --digests digests.env
      - uses: peter-evans/create-pull-request@<sha>
        with:
          branch: release/canary-${{ github.sha }}
          title: "release(canary): ${{ github.sha }} → gcp ring"
          labels: release,ring-canary
```

Why pull **by digest**: a tag can be moved; a digest is the exact bytes that were scanned and signed. The parity checker compares digests across cells, not tags.

**Registry caches** (Terraform `modules/registry-mirror`):
- AWS: `aws_ecr_pull_through_cache_rule` with `upstream_registry_url = "registry-1.docker.io"` and a Docker Hub credential in Secrets Manager; images referenced as `<acct>.dkr.ecr.ap-south-1.amazonaws.com/dockerhub/<you>/cb-order-service@sha256:…`.
- GCP: `google_artifact_registry_repository` with `mode = "REMOTE_REPOSITORY"` and a Docker Hub upstream.
- Budget k3s: `/etc/rancher/k3s/registries.yaml` mirror entry written by Ansible (pulls from Docker Hub with an authenticated token).

**"→ EC2" from your brief:** the budget AWS cell *is* an EC2 instance; the release path above deploys to it through Argo CD, so the brief's GitHub Actions → Docker Hub → EC2 path exists — just GitOps-style (pull) rather than SSH-and-restart (push), which is the point to make in the interview.

## 12.5 Infrastructure pipeline

```yaml
# .github/workflows/_terraform-stack.yml  (reusable — Template Method)
on:
  workflow_call:
    inputs:
      stack:  { type: string, required: true }     # infra/live/aws-prod/10-foundation
      cloud:  { type: string, required: true }     # aws | gcp | global
      mode:   { type: string, required: true }     # plan | apply
      env:    { type: string, required: true }     # GitHub environment name, e.g. aws-prod

permissions: { contents: read, id-token: write, pull-requests: write }

jobs:
  run:
    runs-on: ubuntu-24.04
    environment: ${{ inputs.mode == 'apply' && inputs.env || '' }}   # approval gate only for apply
    concurrency:
      group: tf-${{ inputs.stack }}
      cancel-in-progress: false                                      # never kill a running apply
    defaults: { run: { working-directory: "${{ inputs.stack }}" } }
    steps:
      - uses: actions/checkout@<sha>
      - uses: hashicorp/setup-terraform@<sha>
        with: { terraform_version: "1.15.x", terraform_wrapper: false }

      - if: inputs.cloud == 'aws'
        uses: aws-actions/configure-aws-credentials@<sha>
        with:
          role-to-assume: ${{ inputs.mode == 'apply' && vars.AWS_APPLY_ROLE || vars.AWS_PLAN_ROLE }}
          aws-region: ap-south-1
      - if: inputs.cloud == 'gcp' || inputs.cloud == 'global'
        uses: google-github-actions/auth@<sha>
        with:
          workload_identity_provider: ${{ vars.GCP_WIF_PROVIDER }}
          service_account: ${{ inputs.mode == 'apply' && vars.GCP_APPLY_SA || vars.GCP_PLAN_SA }}

      - run: terraform init -input=false -lockfile=readonly
      - run: terraform plan -input=false -lock-timeout=5m -out=tfplan
      - run: terraform show -json tfplan > plan.json && sha256sum plan.json | cut -d' ' -f1 > plan.sha256

      - if: inputs.mode == 'plan'
        name: Gates — plan-risk (D6), conftest, infracost
        run: |
          python3 $GITHUB_WORKSPACE/control-plane/plan-risk/cli.py plan.json --stack "${{ inputs.stack }}" --out risk.md
          conftest test plan.json -p $GITHUB_WORKSPACE/infra/policy --output github
          infracost diff --path plan.json --format json --out-file infracost.json

      - if: inputs.mode == 'apply'
        run: terraform apply -input=false tfplan        # exactly the plan the approver saw
```

What the approver sees: GitHub environment protection rules (required reviewers on `aws-prod`, `gcp-prod`, `traffic-prod`) pause the job **after** the plan exists; the job summary shows the plan, its SHA-256, and the plan-risk verdict. A stale plan (state changed since) fails safely.

**CI identities (Terraform `global/00-ci-identity`):**

| Identity | Trust condition (OIDC `sub`) | Permissions |
|---|---|---|
| `cb-plan-aws` | `repo:<you>/cloudbridge:pull_request` | ReadOnlyAccess + state bucket read + lockfile write |
| `cb-apply-aws-prod` | `repo:<you>/cloudbridge:environment:aws-prod` | Scoped admin for tagged resources + state bucket RW |
| `cb-plan-gcp` / `cb-apply-gcp-prod` | WIF attribute condition on `assertion.repository` + `assertion.environment` | Viewer / scoped editor roles |
| `cb-apply-traffic` | `environment:traffic-prod` | Cloudflare API token limited to the zone's Load Balancing (token stored as an environment secret — Cloudflare has no OIDC federation for this) |

## 12.6 Other workflows

| Workflow | Trigger | What it does |
|---|---|---|
| `iac-pr.yml` | PR on `infra/**` | Detects affected stacks (module dependency map), runs fmt/validate/tflint/Trivy config/`terraform test`, calls `_terraform-stack.yml` (plan) per stack, posts one sticky comment |
| `iac-engines.yml` | PR on `infra/modules/**` | Matrix `[terraform 1.15, tofu 1.12]` → `init -backend=false`, `validate`, `test` (mocks). Fails if the modules stop being engine-agnostic |
| `iac-apply.yml` | push to `main` on `infra/**` | Plan → approval → apply per affected stack, in dependency order (`10-foundation` → `20-bootstrap` → `global/30-traffic`) |
| `drift.yml` | nightly 02:30 IST | `terraform plan -detailed-exitcode` on every live stack; exit 2 → issue labelled `drift` with the diff |
| `parity.yml` | nightly + `workflow_run` after Argo sync webhook | Runs parity checker (D1); fails → issue + Slack |
| `ephemeral-up.yml` | `workflow_dispatch` (cloud, env, ttl_hours) | Applies managed-profile stacks, labels with `cb-expires-at`, posts the URL |
| `ttl-reaper.yml` | hourly | Destroys stacks whose `cb-expires-at` passed (destroy runs with the same saved-plan discipline, auto-approved only for `*-dev` environments) |
| `budget-config.yml` | push on `ansible/**` + weekly | `ansible-playbook site.yml` against budget VMs (idempotent; weekly run catches config drift) |
| `drill.yml` | weekly (dev/budget) + `workflow_dispatch` | Runs `ansible/playbooks/drill.yml`, commits the drill report to `docs/drills/` |
| `evals.yml` | PR on `control-plane/**` or `evals/**` | Plan-risk eval, steering backtest, parity unit tests — thresholds gate merge (§13.3) |
| `ring-promote.yml` | `workflow_run` when canary Rollout analysis succeeds + 30 min soak | Opens PR copying `ring-canary.yaml` digests to `ring-main.yaml` |

Supply-chain note: in March 2025 the widely used `tj-actions/changed-files` action was compromised by retagging — a pinned commit SHA would have been unaffected. That's the one-sentence reason every action above is `@<sha>`, with Dependabot updating the SHAs.

---

# §13 — Observability and the DevOps/MLOps Wrapper

## 13.1 Metrics architecture

```
cell (EKS | GKE | k3s)                                          control plane (gcp budget VM)
 ├─ Prometheus 3 --agent ── remote_write (HTTPS, outbound) ──▶  Prometheus 3 --web.enable-remote-write-receiver
 │    scrapes: apps (Micrometer), kube-state-metrics,            ├─ recording rules (SLIs, cost denominators)
 │             node-exporter, OpenCost, Argo CD, Rollouts        ├─ Alertmanager → Slack, EDA webhook
 └─ external_labels: {cb_cell, cb_cloud, cb_env, cb_profile}    └─ Grafana 13 (dashboards below)
                                                                 blackbox exporter → app.<domain> via Cloudflare
                                                                 cf-exporter → Cloudflare GraphQL analytics
```

The receiver endpoint is published through **Cloudflare Access** with a service token per cell — no open ports on the control-plane VM, and the cells never accept inbound connections for metrics.

Recording rules that everything else builds on:
```yaml
groups:
  - name: cb-sli
    rules:
      - record: cb:requests:rate5m
        expr: sum by (cb_cell, service) (rate(http_server_requests_seconds_count{uri!~"/actuator.*"}[5m]))
      - record: cb:errors:rate5m
        expr: sum by (cb_cell, service) (rate(http_server_requests_seconds_count{status=~"5..", uri!~"/actuator.*"}[5m]))
      - record: cb:latency_p95:5m
        expr: histogram_quantile(0.95, sum by (cb_cell, service, le) (rate(http_server_requests_seconds_bucket[5m])))
      - record: cb:availability:ratio_rate1h
        expr: 1 - (sum by (cb_cell) (rate(http_server_requests_seconds_count{status=~"5..",service="api-gateway"}[1h]))
                    / sum by (cb_cell) (rate(http_server_requests_seconds_count{service="api-gateway"}[1h])))
```

## 13.2 Dashboards (the "monitoring dashboard" from your brief — five of them, each answering one question)

| Dashboard | Question it answers | Key panels |
|---|---|---|
| **Multi-cloud overview** | Is each cell healthy, and is the split what I configured? | Configured vs observed split (Terraform weights vs Cloudflare analytics); golden signals per cell; pool health; `X-CB-Cell` distribution from blackbox probes |
| **Cost per request** (Next.js + Grafana) | Which cloud is cheaper *per unit of work*? | Cost/1k req per service per cell; FOCUS freshness ("billing data as of"); OpenCost vs bill reconciliation error |
| **Parity** | Are the cells still interchangeable? | Score trend, current divergences, exceptions nearing expiry |
| **Drills** | Can the smaller cell take everything, and how fast? | Step timeline, burn rate per step, RTO trend across drills, capacity ratio |
| **Delivery** | How healthy is my delivery pipeline? | Deploy frequency per cell, lead time (commit → canary → main), change-failure rate (rollbacks), MTTR from drills, drift issues open |

## 13.3 Quality gates — the "MLOps-style" wrapper

Your portfolio standard is *eval harnesses that gate CI*. CloudBridge has three components that make decisions, so each has an eval:

| Component | Eval set | Metric | Gate (CI fails if…) |
|---|---|---|---|
| Plan-risk rules (D6) | `evals/plan-risk/` — 60 labelled plan JSONs (generated by applying mutations to real plans via mocks: deletes of stateful resources, replacements, IAM wildcards, open ingress, one-sided parity changes, harmless changes) | Recall on `block` class; precision overall | Block-class recall < **1.00** (a missed destructive change is unacceptable) or precision < 0.90 |
| Plan explainer (optional LLM) | Same 60 plans | Faithfulness: every resource address in the summary exists in the plan; verdict never contradicts rules | Faithfulness < 0.98 |
| Steering recommender (D3) | `evals/steering/` — 90 days of recorded daily cost + volume + p95 per cell (synthetic until you have real history; replace as data accrues) | Saving vs static 70/30; SLO violations in replay | Any replayed SLO violation, or saving drops > 20% vs the last merged model |
| Parity checker (D1) | `evals/parity/` — fixture pairs of cell facts with known divergences | Detection accuracy | Any missed divergence |
| Terraform modules | `terraform test` (mocks) on Terraform 1.15 **and** OpenTofu 1.12 | Pass/fail | Any failure on either engine |
| Ansible roles | Molecule + `ansible-lint` (production profile) | Pass/fail | Any failure |

## 13.4 Scale-out path (what changes at 10× cells)

| Today | At 10+ cells | Trigger |
|---|---|---|
| Single central Prometheus receiver | Grafana Mimir or Thanos Receive | > ~1M active series or retention > 30 days |
| Cost ledger in Postgres with monthly partitions | Same, + DuckDB over archived Parquet for ad-hoc history | > 50M line items |
| One Argo CD per cell | Same (pull model scales linearly) + a read-only Argo CD dashboard aggregator | — |
| Directory-per-stack + Makefile | Terramate or Terragrunt for stack orchestration | > ~25 stacks or > 3 clouds (§26.1) |

## 13.5 SLOs and alerts

| SLO | Target | Measured at | Alert |
|---|---|---|---|
| Global availability | 99.9% / 28 days | Blackbox probes through Cloudflare from the control plane + Cloudflare 5xx analytics | Multi-window burn rate: 14.4× over 1 h & 5 m (page), 6× over 6 h & 30 m (ticket) |
| Per-cell availability | 99.5% / 28 days | `cb:availability:ratio_rate1h` per cell | `CellSLOBurnFast` → Slack + EDA (§8.6) |
| Edge latency | p95 < 400 ms (Mumbai probe) | Blackbox | Ticket |
| Parity | score = 1.0 (or all divergences excepted) | Nightly | Issue |
| Drill freshness | Last successful drill < 14 days old | `drills` table | Issue: "exit plan evidence is stale" |
| Cost data freshness | Billing data < 72 h old | `cost_ingestions` | Ticket |

---

# §14 — D1: Parity Contract & Drift Score

## 14.1 The problem it solves

"Same app on two clouds" decays. Someone hotfixes a chart value in one cell, GKE auto-upgrades a patch, a Postgres parameter changes in RDS only. Six weeks later failover lands on a cell that *isn't* the same, and the outage is the surprise. Terraform drift detection (and the platforms built on it) compares **one stack's code to its own reality**; Argo CD compares **one cluster to Git**. Neither compares **cell A to cell B**.

## 14.2 The contract

```yaml
# parity/contract.yaml
version: 1
env: prod
cells: [cb-aws-prod, cb-gcp-prod]
checks:
  - id: k8s.minor            # e.g. "1.36"
    source: cluster.k8s_version | minor
    weight: 3
  - id: images.digests       # every service image digest
    source: argocd.app[*].status.summary.images
    weight: 5
  - id: chart.versions
    source: argocd.app[*].spec.sources[0].targetRevision+chart.version
    weight: 3
  - id: app.config.hash      # sha256 of rendered ConfigMaps excluding allowlisted per-cloud keys
    source: k8s.configmaps[cb-app] | hash(exclude=[CB_CELL, CLOUD, *_MIRROR])
    weight: 4
  - id: resources.requests
    source: k8s.deployments[cb-app].containers[*].resources
    weight: 2
  - id: hpa.bounds
    source: k8s.hpa[cb-app].{min,max}
    weight: 3                # max must be equal: both cells must be able to take 100%
  - id: networkpolicy.count
    source: k8s.networkpolicies[cb-app] | count
    weight: 2
  - id: pg.major
    source: database.engine_version | major
    weight: 3
  - id: pg.params            # selected parameters only (max_connections, statement_timeout, ...)
    source: database.parameters[allowlist]
    weight: 2
  - id: valkey.major
    source: cache.engine_version | major
    weight: 2
  - id: flyway.version       # schema migration level in each cell DB
    source: sql:"select max(version) from flyway_schema_history where success"
    weight: 5
  - id: shape.class
    source: cell.shape.{vcpu,mem_gib,class}
    weight: 2
pass_threshold: 1.0          # all checks match or are excepted
```

```yaml
# parity/exceptions.yaml — every divergence must have an owner, a reason and an expiry
- check: k8s.minor
  reason: "GKE Regular auto-upgraded to 1.36.4 patch; EKS on 1.36.2 — patch-level only, minor equal"
  scope: patch-only
  owner: ricky
  expires: 2026-11-15
- check: images.digests
  reason: "Canary ring: gcp runs new digest for up to 2h before promotion"
  scope: ring-window
  max_age_minutes: 120
  owner: release-bot
```

An **expired** exception fails the check — exceptions are loans, not waivers.

## 14.3 Checker (core)

```python
# control-plane/parity-checker/parity/engine.py
from __future__ import annotations
from dataclasses import dataclass
from datetime import date, datetime, timezone
from typing import Protocol, Any

class CellFacts(Protocol):
    """Strategy: one implementation per cloud × profile (AwsManagedFacts, GcpManagedFacts, K3sFacts)."""
    def get(self, source: str) -> Any: ...

@dataclass(frozen=True)
class Finding:
    check_id: str
    weight: float
    values: dict[str, Any]
    status: str           # match | diverged | excepted | unknown
    note: str = ""

def _exception_for(check_id: str, values: dict[str, Any], exceptions: list[dict], now: datetime) -> dict | None:
    for ex in exceptions:
        if ex["check"] != check_id:
            continue
        if "expires" in ex and date.fromisoformat(str(ex["expires"])) < now.date():
            continue                                   # expired → not honoured
        if ex.get("scope") == "patch-only":
            minors = {str(v).rsplit(".", 1)[0] for v in values.values()}
            if len(minors) == 1:
                return ex
            continue
        if ex.get("scope") == "ring-window":
            # caller passes canary_started_at in values["_meta"]
            started = values.get("_meta", {}).get("canary_started_at")
            if started and (now - started).total_seconds() <= ex["max_age_minutes"] * 60:
                return ex
            continue
        return ex
    return None

def evaluate(contract: dict, facts: dict[str, CellFacts], exceptions: list[dict],
             now: datetime | None = None) -> tuple[float, list[Finding]]:
    now = now or datetime.now(timezone.utc)
    findings: list[Finding] = []
    for chk in contract["checks"]:
        values: dict[str, Any] = {}
        unknown = False
        for cell, f in facts.items():
            try:
                values[cell] = f.get(chk["source"])
            except Exception as e:                     # a fact we can't read is never a "match"
                values[cell] = f"<error: {type(e).__name__}>"
                unknown = True
        comparable = {k: v for k, v in values.items() if not k.startswith("_")}
        if unknown:
            status = "unknown"
        elif len({repr(v) for v in comparable.values()}) == 1:
            status = "match"
        elif _exception_for(chk["id"], values, exceptions, now):
            status = "excepted"
        else:
            status = "diverged"
        findings.append(Finding(chk["id"], float(chk["weight"]), comparable, status))

    total = sum(f.weight for f in findings)
    good = sum(f.weight for f in findings if f.status in ("match", "excepted"))
    return (good / total if total else 0.0), findings
```

Where it runs:
1. **PR time** (cheap): plan-risk gate flags *one-sided* changes — a module change that affects AWS stacks but not GCP stacks (§19).
2. **Post-sync**: Argo CD notification → `parity.yml` → full check; result posted as a commit status on the release PR.
3. **Nightly**: catches out-of-band changes (console edits, auto-upgrades).

## 14.4 Interview framing

> "Terraform drift tells me a stack differs from its code. Argo tells me a cluster differs from Git. Neither tells me AWS differs from GCP — and that's the drift that breaks failover. So I wrote a parity contract: twelve weighted checks, from image digests to Flyway schema version, with exceptions that expire. A canary release is an allowed two-hour divergence; a forgotten hotfix fails CI the next night."

---

# §15 — D2: Capacity-Verified, SLO-Gated Evacuation (Ansible)

## 15.1 Why this beats "Cloudflare fails over automatically"

Cloudflare (and k8gb) fail over on **health**. Neither knows whether the surviving cell can carry the load it's about to receive. CloudBridge adds the two things health-based failover can't: **capacity verification before shifting** and **stepped shifting with SLO gates and rollback**. Every run produces a dated report — evidence that the exit plan works, which is what RBI's 2023 IT-outsourcing Master Direction asks regulated entities to have (a documented exit strategy that preserves business continuity). Say "evidence for", never "compliant with".

## 15.2 Capacity math

```
peak_rps_total      = max over last 7 days of sum(cb:requests:rate5m{service="api-gateway"})
per_pod_rps[svc]    = measured with k6 at p95 < 300 ms, error < 0.5%   (week-5 load test; stored in cells/<cell>/capacity.yaml)
target_capacity_rps = min over services( hpa_max[svc] × per_pod_rps[svc] × fanout_factor[svc] )
node_capacity_ok    = sum(hpa_max × requests) ≤ node_max × allocatable

capacity_ratio      = target_capacity_rps / peak_rps_total
proceed if capacity_ratio ≥ 1.2   (20% headroom)
prewarm if capacity_ratio ≥ 1.2 only after raising mins; abort if node_capacity_ok is false
```

`fanout_factor` matters: one gateway request may cause one order-service call and two inventory calls.

## 15.3 Playbook

```yaml
# ansible/playbooks/evacuate.yml
- name: Evacuate traffic from one cell to another (stepped, SLO-gated, compensating)
  hosts: localhost
  connection: local
  gather_facts: false
  vars:
    from_cell: aws                         # cloud key in weights map
    to_cell: gcp
    mode: drill                            # drill | real
    steps: [50, 25, 0]                     # from_cell share after each step
    step_wait_s: 150                       # ≥ 2 × Cloudflare monitor interval + drain
    burn_abort: 6.0                        # abort if 5m burn rate on to_cell exceeds this
    p95_abort_ms: 600
    prom: "{{ lookup('env', 'CB_PROM_URL') }}"
    cp_api: "{{ lookup('env', 'CB_CP_API') }}"
    traffic_stack: "{{ playbook_dir }}/../../infra/live/global/30-traffic"

  tasks:
    - name: Record pre-evacuation weights (compensation target)
      ansible.builtin.slurp:
        src: "{{ traffic_stack }}/terraform.tfvars.json"
      register: tfvars_raw

    - ansible.builtin.set_fact:
        original_weights: "{{ (tfvars_raw.content | b64decode | from_json).weights }}"

    - name: Open drill record
      ansible.builtin.uri:
        url: "{{ cp_api }}/drills"
        method: POST
        body_format: json
        body: { from_cell: "cb-{{ from_cell }}-prod", to_cell: "cb-{{ to_cell }}-prod", mode: "{{ mode }}" }
        headers: { Authorization: "Bearer {{ lookup('env', 'CB_CP_TOKEN') }}" }
        status_code: 201
      register: drill

    - name: Capacity check on target
      ansible.builtin.uri:
        url: "{{ cp_api }}/capacity/cb-{{ to_cell }}-prod"
        return_content: true
      register: cap

    - name: Pre-warm target if needed
      ansible.builtin.include_tasks: tasks/prewarm.yml
      when: cap.json.capacity_ratio_at_current_mins < 1.2

    - name: Re-check capacity after pre-warm
      ansible.builtin.uri:
        url: "{{ cp_api }}/capacity/cb-{{ to_cell }}-prod"
        return_content: true
      register: cap2

    - name: Abort when target cannot absorb the load
      ansible.builtin.fail:
        msg: "Target capacity ratio {{ cap2.json.capacity_ratio }} < 1.2 — refusing to evacuate (would cascade)."
      when: cap2.json.capacity_ratio < 1.2

    - name: Shift traffic step by step
      block:
        - ansible.builtin.include_tasks: tasks/shift_step.yml
          loop: "{{ steps }}"
          loop_control: { loop_var: from_share, index_var: seq }
      rescue:
        - name: Compensate — restore original weights
          community.general.terraform:
            project_path: "{{ traffic_stack }}"
            state: present
            variables_files: ["{{ traffic_stack }}/terraform.tfvars.json"]
            complex_vars: true
            variables:
              weights: "{{ original_weights }}"
        - ansible.builtin.uri:
            url: "{{ cp_api }}/drills/{{ drill.json.id }}"
            method: PATCH
            body_format: json
            body: { outcome: rolled_back }
            headers: { Authorization: "Bearer {{ lookup('env', 'CB_CP_TOKEN') }}" }
        - ansible.builtin.fail:
            msg: "Evacuation aborted and rolled back at step {{ seq | default('?') }}."

    - name: Close drill record + render report
      ansible.builtin.uri:
        url: "{{ cp_api }}/drills/{{ drill.json.id }}/complete"
        method: POST
        headers: { Authorization: "Bearer {{ lookup('env', 'CB_CP_TOKEN') }}" }
```

```yaml
# ansible/playbooks/tasks/shift_step.yml
- ansible.builtin.set_fact:
    step_weights: "{{ {from_cell: from_share, to_cell: 100 - from_share} }}"

- name: "Apply weights {{ step_weights }}"
  community.general.terraform:
    project_path: "{{ traffic_stack }}"
    state: present
    complex_vars: true
    variables:
      weights: "{{ step_weights }}"
  register: tf_step
  failed_when: tf_step.failed

- name: Wait for health checks and session drain
  ansible.builtin.pause:
    seconds: "{{ step_wait_s }}"

- name: Read SLO burn and p95 on the receiving cell
  ansible.builtin.uri:
    url: "{{ prom }}/api/v1/query"
    method: POST
    body_format: form-urlencoded
    body:
      query: >
        (sum(rate(http_server_requests_seconds_count{cb_cell="cb-{{ to_cell }}-prod",service="api-gateway",status=~"5.."}[5m]))
         / sum(rate(http_server_requests_seconds_count{cb_cell="cb-{{ to_cell }}-prod",service="api-gateway"}[5m]))) / 0.005
    return_content: true
  register: burn

- ansible.builtin.uri:
    url: "{{ prom }}/api/v1/query"
    method: POST
    body_format: form-urlencoded
    body: { query: 'cb:latency_p95:5m{cb_cell="cb-{{ to_cell }}-prod",service="api-gateway"} * 1000' }
    return_content: true
  register: p95

- ansible.builtin.set_fact:
    burn_now: "{{ (burn.json.data.result[0].value[1] | default('0')) | float }}"
    p95_now: "{{ (p95.json.data.result[0].value[1] | default('0')) | float }}"

- name: Record step
  ansible.builtin.uri:
    url: "{{ cp_api }}/drills/{{ drill.json.id }}/steps"
    method: POST
    body_format: json
    body:
      seq: "{{ seq }}"
      weights: "{{ step_weights }}"
      burn_rate: "{{ burn_now }}"
      p95_ms: "{{ p95_now }}"
      decision: "{{ 'abort' if (burn_now | float > burn_abort or p95_now | float > p95_abort_ms) else 'advance' }}"
    headers: { Authorization: "Bearer {{ lookup('env', 'CB_CP_TOKEN') }}" }
    status_code: 201

- name: Gate
  ansible.builtin.fail:
    msg: "SLO gate failed at {{ step_weights }}: burn={{ burn_now }} p95={{ p95_now }}ms"
  when: burn_now | float > burn_abort or p95_now | float > p95_abort_ms
```

> **Design note — where the weights live:** the traffic stack reads `terraform.tfvars.json` (JSON so Ansible can parse it). After a real evacuation the playbook opens a PR committing the final weights, so Git matches reality; the `traffic_changes` table records `source = evacuation` with the drill ID. In drill mode, failback runs immediately and no PR is needed.

## 15.4 Data during an evacuation (be precise in the interview)

| Data | During evacuation from AWS | RPO / impact |
|---|---|---|
| New orders | Created in GCP cell — fine | 0 |
| Order history of users whose home cell was AWS | Not visible until failback (cell-local data) | Read-degraded, **no loss** (data is safe in RDS) |
| Inventory | GCP cell sells only its own lease; AWS lease expires → allocator re-grants to GCP after `expires_at` + safety margin | Briefly lower sellable stock; **never oversold** |
| Post-MVP: async logical replication of orders cross-cloud over HA VPN | History readable from replica | RPO = replication lag (minutes) |

## 15.5 Drill report (auto-generated)

```markdown
# Drill 2026-11-02 — cb-aws-prod → cb-gcp-prod (mode: drill)
| Metric | Value |
|---|---|
| Capacity ratio before / after pre-warm | 0.71 / 1.34 |
| Pre-warm time | 212 s |
| Shift time (first step → 100% on GCP) | 468 s |
| Max 5m burn rate on GCP | 0.8 |
| 5xx during shift (edge) | 3 of 41,220 |
| Cloudflare health-detection time (forced failure test) | 147 s |
| Outcome | completed; failback completed in 455 s |
```
*(Numbers above are a template — your README shows only the numbers your drills produce.)*

## 15.6 Break-glass when Terraform state is unreachable

If the state backend for the traffic stack can't be reached, `evacuate.yml -e break_glass=true` calls the Cloudflare Load Balancer API directly (`PATCH /zones/{zone}/load_balancers/{id}` with new `random_steering.pool_weights`), records `source = break_glass`, and opens a high-priority issue. The next `terraform plan` on the traffic stack shows the drift; you then commit the weights so code and reality match. This is the one place CloudBridge deliberately bypasses IaC — documented, logged, and reconciled.

If **Cloudflare itself** fails (as it did for several hours on 18 Nov 2025), the LB is unavailable too. Documented runbook: switch the hostname's DNS record to DNS-only pointing at the healthier cell's origin (works only if Cloudflare DNS is answering), or accept the outage — a second authoritative DNS provider is the real fix and is listed as out of scope with its cost. Naming your remaining single point of failure is a senior answer.

---

# §16 — D3: Unit-Economics Traffic Steering (recommender, not autopilot)

## 16.1 Idea

Cloudflare steers by randomness, geography or latency. OpenCost and the cloud consoles report cost. Nothing connects **cost per request** back to **traffic weights**. CloudBridge does — as a weekly pull request a human merges, constrained by SLOs and capacity, and validated by a backtest.

## 16.2 Model

Average cost per request is misleading because a cell has fixed costs (control plane, NAT, minimum nodes) that don't move when you shift traffic. The recommender fits, per cell:

```
daily_cost_c(r) = F_c + v_c × r        r = requests/day handled by cell c
```
via least squares over the last 28 days (F = fixed, v = marginal cost per request). Then:

```
minimise   Σ_c v_c × w_c × R              (R = forecast total requests/day, Σ w_c = 1)
subject to w_c ∈ {0} ∪ [0.10, 1]           (warm floor, same as Terraform validation)
           w_c × R_peak ≤ capacity_c / 1.2  (headroom)
           p95_c(w_c) ≤ 300 ms               (latency model from the last 28 days' load/latency curve)
           |w_c − w_c,current| ≤ 0.20        (max step per week — no whiplash)
           saving ≥ max(₹500/month, 5%)      (hysteresis — don't churn for noise)
```

With two cells this is a one-dimensional search over `w_aws ∈ {0.10, 0.11, …, 0.90}` — no solver needed, which keeps it explainable.

```python
# control-plane/steering/recommender.py
from dataclasses import dataclass
from typing import Callable
import numpy as np

@dataclass(frozen=True)
class CellModel:
    name: str
    fixed_inr_day: float
    marginal_inr_per_req: float
    capacity_rps: float
    p95_at: Callable[[float], float]   # traffic share → predicted p95 ms (fitted piecewise-linear)

def fit_cost(days_requests: np.ndarray, days_cost: np.ndarray) -> tuple[float, float]:
    A = np.vstack([np.ones_like(days_requests), days_requests]).T
    (fixed, marginal), *_ = np.linalg.lstsq(A, days_cost, rcond=None)
    return max(fixed, 0.0), max(marginal, 0.0)

def recommend(aws: CellModel, gcp: CellModel, total_req_day: float, peak_rps: float,
              current_aws: float, floor=0.10, max_step=0.20, min_saving_inr_month=500.0):
    def daily_variable_cost(w_aws: float) -> float:
        return total_req_day * (w_aws * aws.marginal_inr_per_req + (1 - w_aws) * gcp.marginal_inr_per_req)

    best = current_aws
    base = daily_variable_cost(current_aws)
    for w in np.round(np.arange(floor, 1 - floor + 1e-9, 0.01), 2):
        if abs(w - current_aws) > max_step: continue
        if w * peak_rps > aws.capacity_rps / 1.2: continue
        if (1 - w) * peak_rps > gcp.capacity_rps / 1.2: continue
        if aws.p95_at(w) > 300 or gcp.p95_at(1 - w) > 300: continue
        if daily_variable_cost(w) < daily_variable_cost(best):
            best = float(w)
    saving_month = (base - daily_variable_cost(best)) * 30
    if saving_month < max(min_saving_inr_month, 0.05 * base * 30):
        return current_aws, 0.0, ["saving below hysteresis threshold"]
    return best, saving_month, [f"marginal ₹/1k req: aws={aws.marginal_inr_per_req*1000:.3f}, gcp={gcp.marginal_inr_per_req*1000:.3f}"]
```

## 16.3 Output

A PR on `infra/live/global/30-traffic/terraform.tfvars.json` with a body like:

> **Proposed:** aws 70 → 55, gcp 30 → 45. **Estimated saving:** ₹X/month on variable cost.
> **Binding constraint:** max weekly step (0.20). **Backtest (90 days):** 0 SLO violations, saving vs static 70/30: Y%.
> **Not changed by this PR:** fixed costs (control planes, NAT) — those only change if a cell is removed.

## 16.4 Guardrails and eval

- Recommender has **no apply permission**. Its GitHub App can open PRs on one file.
- Backtest gate in `evals.yml` (§13.3): replaying the last 90 days with the proposed policy must produce zero SLO violations.
- Fairness inputs come from D4 (credits excluded, same shapes, same metro). If FOCUS data is older than 72 h, the recommender refuses to run.

Interview line: *"It's a recommender with a backtest, not an autopilot. Traffic changes go through the same review as code — the model just writes the PR."*

---

# §17 — D4: FOCUS Cost Ledger with Fair-Comparison Rules

## 17.1 Ingestion

| Cloud | Source | How |
|---|---|---|
| AWS | Data Exports → FOCUS 1.2 → Parquet in `s3://cb-billing-aws/focus/` | Terraform `aws_bcmdataexports_export` in `global/00-billing`; collector reads new objects daily |
| GCP | Cloud Billing export to BigQuery + the FOCUS view | Collector runs a **parameterised** query (fix for C17) |

```python
# control-plane/cost-collector/collector/gcp.py
from google.cloud import bigquery

FOCUS_SQL = """
SELECT ProviderName, BillingAccountId, ChargePeriodStart, ChargePeriodEnd, ChargeCategory,
       ServiceCategory, ServiceName, ResourceId, RegionId,
       BilledCost, EffectiveCost, ListCost, BillingCurrency, Tags
FROM `{dataset}.focus_view`
WHERE ChargePeriodStart >= @start AND ChargePeriodStart < @end
"""

def fetch(client: bigquery.Client, dataset: str, start, end):
    job = client.query(
        FOCUS_SQL.format(dataset=dataset),            # dataset is config, validated against ^[\w.-]+$
        job_config=bigquery.QueryJobConfig(query_parameters=[
            bigquery.ScalarQueryParameter("start", "TIMESTAMP", start),
            bigquery.ScalarQueryParameter("end", "TIMESTAMP", end),
        ]),
    )
    return job.result(), job.job_id                    # job id stored as lineage (source_file)
```

Both adapters yield the same FOCUS row shape; one `normalise()` maps tag keys (`cb-cell` vs `cb_cell` — GCP labels disallow some characters; leaky abstraction #9) and writes to `cost_line_items` inside a transaction that first deletes rows from the same `source_file` (idempotent re-ingestion).

## 17.2 Fairness rules (each one is a sentence you can say in the interview)

1. **Unit cost, not totals.** Compare cost per 1,000 requests; totals mostly measure the traffic split.
2. **Credits excluded.** `charge_category = 'Usage'` only — free-tier and promotional credits are shown separately, never netted.
3. **EffectiveCost and ListCost both shown.** Effective includes discounts you negotiated; list shows the sticker price. A cloud that wins only on discounts is a negotiation story, not an engineering one.
4. **Same shapes, same metro, same window.** Enforced by §7.2 shapes table + Mumbai regions + identical date ranges.
5. **Shared cost allocation is labelled as an estimate.** Node cost is split by OpenCost CPU/memory share; the panel shows the reconciliation error between OpenCost's estimate and the bill (Q2 in §9.4).
6. **Freshness shown.** Billing exports lag by up to a day or two; every panel says "billing data as of …".

## 17.3 What you'll likely see (and how to talk about it)

Don't predict the winner. Do predict *which line items will differ*, then check: NAT gateway processing (AWS) vs Cloud NAT, load balancer hourly + LCU vs GCLB forwarding rules, managed control plane (EKS fee vs GKE free-tier credit for one zonal cluster), egress to Cloudflare. The interview answer is the method plus whatever your ledger shows on the day, with the date range.

## 17.4 Infracost integration (don't rebuild it — extend it)

Infracost estimates the **list-price** delta of a plan. CloudBridge adds one thing in the PR comment: the estimate expressed per request at the current traffic weight, using D4's measured volumes — *"this change adds ~₹1,900/month to the AWS cell ≈ +₹0.004 per 1k requests at today's 70% weight."*

---

# §18 — D5: Cloud as a Canary Ring

Multi-cloud protects you from a provider failure — **not from your own bad deploy**, which would reach both clouds at once. So releases go one cloud at a time:

```
digest built ─▶ ring-canary (GCP cell, 30% of users)
                 └─ Argo Rollouts canary inside the cell: 10% → 50% → 100% with AnalysisTemplate
                 └─ 30 min soak: burn rate < 1, p95 within 10% of AWS cell, parity = excepted(ring-window)
             ─▶ ring-main (AWS cell, 70%)
```

Why GCP is the canary: the smaller cell limits user exposure; and because the parity contract allows only a 2-hour ring window, a stuck canary turns into a CI failure rather than a silent split-brain release.

Rollback is a Git revert of the ring file; Argo CD syncs the previous digest. Expand/contract DB migrations (Flyway) are mandatory because two cells can run adjacent versions for up to two hours.

Interview line: *"My smaller cloud is my canary. Multi-cloud doesn't protect you from yourself — staged rollout across clouds does."*

---

# §19 — D6: Plan-Risk Gate (rules first, LLM optional)

## 19.1 Rules (deterministic — these decide)

```python
# control-plane/plan-risk/rules.py
STATEFUL = {
    "aws_db_instance", "aws_rds_cluster", "aws_elasticache_replication_group", "aws_s3_bucket",
    "aws_eks_cluster", "google_sql_database_instance", "google_memorystore_instance",
    "google_storage_bucket", "google_container_cluster",
}

def evaluate(plan: dict, stack: str, affected_stacks: set[str]) -> list[dict]:
    out = []
    for rc in plan.get("resource_changes", []):
        actions, rtype, addr = rc["change"]["actions"], rc["type"], rc["address"]
        if rtype in STATEFUL and "delete" in actions:
            verdict = "block"
            why = "replacement of stateful resource" if "create" in actions else "deletion of stateful resource"
            out.append({"rule": "stateful-destroy", "verdict": verdict, "address": addr, "why": why})
        after = rc["change"].get("after") or {}
        if rtype in {"aws_security_group_rule", "aws_vpc_security_group_ingress_rule"} \
           and "0.0.0.0/0" in str(after.get("cidr_blocks", after.get("cidr_ipv4", ""))) \
           and after.get("from_port") not in (80, 443):
            out.append({"rule": "open-ingress", "verdict": "block", "address": addr, "why": "world-open non-HTTP ingress"})
        if rtype == "google_compute_firewall" and "0.0.0.0/0" in after.get("source_ranges", []):
            out.append({"rule": "open-ingress", "verdict": "block", "address": addr, "why": "world-open firewall"})
        if rtype.endswith("iam_policy") and '"Action":"*"' in str(after.get("policy", "")).replace(" ", ""):
            out.append({"rule": "iam-wildcard", "verdict": "warn", "address": addr, "why": "wildcard action"})

    # Parity-aware rule — the one no generic policy tool has:
    clouds = {s.split("/")[2].split("-")[0] for s in affected_stacks if s.startswith("infra/live/")}
    if {"aws", "gcp"} - clouds and clouds & {"aws", "gcp"}:
        out.append({"rule": "one-sided-change", "verdict": "warn", "address": stack,
                    "why": f"change affects only {sorted(clouds)} — parity divergence unless an exception is added"})

    changes = sum(1 for rc in plan.get("resource_changes", []) if rc["change"]["actions"] != ["no-op"])
    if changes > 40:
        out.append({"rule": "large-change", "verdict": "warn", "address": stack, "why": f"{changes} resources change"})
    return out
```

`block` needs a maintainer to add the `allow-destructive` label (which re-runs the gate) — the label itself is audited in `plan_risk_reports`.

## 19.2 Optional LLM explainer

A provider-agnostic adapter (config: `llm.provider`, `llm.model`, default `gpt-5.4-mini`) turns plan JSON + rule findings into a three-sentence plain-English summary for the PR comment. It **never changes the verdict**. If the call fails, times out (10 s) or the budget breaker trips, the comment shows rules only. The faithfulness eval (§13.3) checks that every resource address it mentions exists in the plan.

---

# §20 — D7: Two Profiles Behind One Interface, and D8: the Leaky-Abstraction Register

## 20.1 Profiles

| | `managed` | `budget` |
|---|---|---|
| Cluster | EKS / GKE 1.36 | k3s 1.36 on one VM per cloud (t3.small / e2-small, 2 vCPU / 2 GiB) |
| Configured by | Terraform + Argo CD | Terraform (VM, IP, firewall) → **Ansible** (OS, k3s) → Argo CD |
| Data | RDS / Cloud SQL, ElastiCache / Memorystore | In-cluster Postgres 18 + Valkey 9 (StatefulSets, nightly `pg_dump` to S3/GCS) |
| Ingress | ALB / GCLB | Traefik on the VM, Cloudflare Origin CA certificate |
| Lifetime | On demand, TTL reaper (default 4 h) | Always on — **the live link on your resume** |
| Same charts / same Argo / same parity contract? | ✅ | ✅ (parity contract `env: budget` excludes managed-only checks) |

Budget-profile JVM settings (2 GiB VM): `-XX:MaxRAMPercentage=60 -XX:+UseSerialGC -XX:TieredStopAtLevel=1`, one replica each, requests trimmed. Stretch goal: GraalVM native images for the budget profile (Spring Boot 4 supports native compilation) to cut memory several-fold — a good "scaling decision" follow-up.

## 20.2 Why this is a differentiator

The "one variable" now has two dimensions: `cloud` and `profile`. Same interface, four implementations, one contract test. And it solves the most common capstone failure — a dead link on the resume because the cloud bill was unaffordable.

## 20.3 Leaky-abstraction register (`docs/leaky-abstractions.md`)

| # | Concern | AWS behaviour | GCP behaviour | How CloudBridge handles it |
|---|---|---|---|---|
| 1 | Pod → cloud IAM | EKS Pod Identity (association per SA) | Workload Identity (KSA ↔ GSA binding) | Per-cloud `identity` submodule; same K8s ServiceAccount names |
| 2 | Ingress origin | ALB **hostname**, known only after the controller runs | Static **IP** reservable up front | AWS origin read from `20-bootstrap`; GCP from `10-foundation` (§7.6) |
| 3 | Burstable CPU | t3 credit model (baseline per vCPU) | e2 shared-core bursting | Shapes table marks `class`; cost comparisons only within a class |
| 4 | K8s upgrades | Manual minor upgrades; standard vs extended-support pricing | Release channels auto-upgrade | GKE maintenance window + parity `patch-only` exception |
| 5 | NetworkPolicy | VPC CNI must have network policy enabled | Dataplane V2 enforces natively | EKS addon config flag; parity checks policy count |
| 6 | Managed Postgres params | Parameter groups | Database flags | Allowlist of parameters compared by parity (`pg.params`) |
| 7 | VM access for Ansible | SSM Session Manager | IAP TCP forwarding | Per-cloud `group_vars` connection settings |
| 8 | Egress pricing | NAT gateway per-GB processing + hourly | Cloud NAT per-GB + per-VM | Shown as separate line in cost-per-request breakdown |
| 9 | Tags vs labels | Tags allow most characters | Labels: lowercase, limited charset | Single key style `cb-cell` that is valid on both |
| 10 | Registry mirror | ECR pull-through cache rule (path prefix) | Artifact Registry remote repo (separate hostname) | `imageRegistryMirror` per-cell value |
| 11 | Health checks | ALB target health inside the region | GCLB health checks from Google probers | Cloudflare monitor is the single source of truth for cell health |
| 12 | Free tier | Credit-based plan (new accounts since Jul 2025) | $300 trial credit + GKE management credit for one zonal/Autopilot cluster | Cost ledger excludes credits (§17.2) |

> **Interview line:** *"The abstraction is real at the interface. Underneath, these twelve things are different — and I've written down how each one is handled. That list is the answer to 'is there really no lock-in?'"*

---

# §21 — Resilience Patterns

| Layer | Pattern | Implementation | Failure it contains |
|---|---|---|---|
| Edge | Health-based pool failover + fallback pool | Cloudflare monitor on `/healthz/cell`, `fallback_pool = gcp` | Hard-down cell |
| Edge | Session affinity with zero-downtime failover | `session_affinity = cookie`, `zero_downtime_failover = sticky` | Users bouncing between cells mid-session |
| Traffic | Warm floor (≥ 10% or 0) | Terraform validation + recommender constraint | Cold cell (empty caches, unJITed code, scaled-in nodes) failing on first real load |
| Traffic | Stepped, gated, compensating shift | `evacuate.yml` saga (§15) | Cascading overload of the receiving cell |
| Service | Timeouts everywhere | Gateway route timeout 2 s; HTTP clients 800 ms connect / 1.5 s read; JDBC `socketTimeout` 3 s | Thread exhaustion from slow dependencies |
| Service | Circuit breaker | Resilience4j on gateway→order, gateway→inventory, services→Valkey | Retry storms against a failing dependency |
| Service | Retry with jitter, idempotent only | GETs and `POST /orders` (has idempotency key); max 2 retries, exponential + full jitter | Transient errors without duplicate side effects |
| Service | Bulkhead | Separate executors for DB and cache calls; virtual threads with `@ConcurrencyLimit` on DB-bound endpoints | One slow dependency starving everything |
| Service | Load shedding | Gateway returns 503 + `Retry-After` when in-flight > limit; health stays green | Overload turns into graceful degradation, not crash loops |
| Service | Graceful degradation | Cache down → DB reads; rate limiter fails open with local limits | Non-critical dependency outages |
| Data | Idempotency keys | `idempotency_keys` + Valkey fast-path | Duplicate orders from retries/failover |
| Data | Outbox | `outbox` relay | Lost events on crash between DB commit and publish |
| Data | Escrow lease with fencing | `inventory_lease` (§23.3) | Overselling across cells; zombie cell selling after partition |
| Platform | PDB + topology spread + HPA | Charts (§12.3) | Node drains, zone loss, traffic spikes |
| Platform | Pull-through registry caches | §12.4 | Docker Hub rate limits / outage during scale-up |
| IaC | Saved-plan apply + concurrency groups | §12.5 | Applying an unreviewed or concurrent change |
| IaC | `prevent_destroy` on stateful resources | Lifecycle blocks in `database/*`, `cache/*`, state buckets | Accidental destroy of data |
| Ops | Break-glass path | §15.6 | IaC backend unavailable during an incident |

---

# §22 — Mitigation Strategies (Risk Register)

| # | Risk | Likelihood | Impact | Mitigation | Detection |
|---|---|---|---|---|---|
| R1 | Cloud bill shock during the build | High | High | Budget profile always-on; managed profile with TTL reaper; AWS Budgets + GCP budget alerts at 50/80/100%; Infracost on every PR | Budget alerts, reaper logs |
| R2 | Cells drift apart silently | High | High | Parity contract (D1), nightly | Parity score < 1 |
| R3 | Failover overloads the smaller cell | Medium | Critical | Capacity ratio ≥ 1.2 gate, pre-warm, stepped shift (D2) | Drill reports, burn-rate alerts |
| R4 | Bad release reaches both clouds | Medium | High | Cloud canary ring + in-cell Rollouts analysis (D5) | AnalysisRun failure |
| R5 | Destructive Terraform change merged | Low | Critical | Plan-risk `block` rules (D6), `prevent_destroy`, approvals, state versioning | Gate output, plan diffs |
| R6 | CI credential leak | Low | Critical | OIDC only, per-environment trust conditions, plan role read-only, SHA-pinned actions | CloudTrail / Cloud Audit Logs alerts on unexpected principals |
| R7 | Cloudflare outage (single edge provider) | Low | Critical | Documented runbook (DNS-only to one origin); accepted residual risk with the cost of a second DNS provider stated | External uptime probe (not on Cloudflare) |
| R8 | Billing data late or wrong | Medium | Medium | Freshness gate on recommender; reconciliation panel; idempotent re-ingestion | Freshness alert |
| R9 | Provider schema churn (Cloudflare v5) | Medium | Low | Pin minor; Renovate PRs run `terraform validate` + plan on the traffic stack | CI failure on update PR |
| R10 | GKE auto-upgrade changes behaviour | Medium | Medium | Maintenance window, Regular channel, parity patch-only exception, release-notes check | Parity nightly |
| R11 | Budget VM runs out of memory | Medium | Medium | JVM caps, swapfile, kubelet eviction thresholds, one replica each | node_exporter memory alert |
| R12 | Split-brain inventory after a network partition | Low | High | Lease expiry enforced *inside* the cell (fencing by time, allocator waits lease + clock-skew margin before re-granting) | Lease-renewal failure metric |

---

# §23 — Availability & Consistency Patterns

## 23.1 Availability arithmetic (do this on the whiteboard)

Per-cell target 99.5%. If the two cells failed independently, both down at once = 0.005 × 0.005 = 0.0025% → cells-layer availability ≈ **99.9975%**.

But the request path is **serial** through Cloudflare. If you assume ~99.95% for the edge layer over a month (no SLA on lower plans — state the assumption), end-to-end ≈ 0.999975 × 0.9995 ≈ **99.947%**.

**Conclusion to say out loud:** *"Adding a second cloud moved my availability ceiling from the cloud to the edge provider. That's why I have a runbook for Cloudflare failing and why I don't claim four nines."* Plus: independence is an assumption — a shared bad deploy breaks it, which is what the canary ring (D5) addresses.

## 23.2 CAP choices per data type

| Data | Choice | Mechanism |
|---|---|---|
| Orders | **CP within a cell**, partitioned by home cell across clouds | Postgres transactions; cookie affinity; no cross-cloud writes |
| Inventory | **Availability via escrow** — each cell sells from its own lease; global invariant (never oversell) holds without coordination on the hot path | §23.3 |
| Cache | AP, disposable | TTLs; never a source of truth |
| Traffic config | Single writer (Git → Terraform), eventually applied at the edge | PR + saved plan; break-glass logged |
| Cost ledger | Eventually consistent (billing exports lag) | Freshness metadata on every panel |

## 23.3 Escrow inventory (the distributed-systems story)

```
Allocator (control plane, hourly or on demand):
  for each SKU: total_stock = authoritative stock (warehouse feed / admin)
                grant_aws = floor(total_stock × w_aws × 0.9)   ← 10% held back as reserve
                grant_gcp = floor(total_stock × w_gcp × 0.9)
  issues lease {sku, granted_qty, lease_epoch+1, expires_at = now + 15 min} to each cell via its admin API

Cell:
  sells only while expires_at > now() AND sold_qty + qty <= granted_qty   (single UPDATE, §9.2)
  renews its lease every 5 min, reporting sold_qty
  a renewal carrying an older lease_epoch is rejected (fencing token)

Cell unreachable (evacuation, partition):
  allocator waits expires_at + 60 s (clock-skew margin) → the dead cell has already stopped selling
  → re-grants that cell's unsold quantity to the surviving cell
```

Properties: **never oversells** (each cell's local `CHECK` + leases sum ≤ stock); may **undersell** briefly (stock stranded in an unreachable cell until its lease expires) — a deliberate trade of a little availability of stock for zero overselling. That's the sentence for the interview.

## 23.4 Read-your-writes

Cookie affinity pins a session to its home cell for 23 h; `zero_downtime_failover = sticky` moves it only when the home pool is unhealthy. Order IDs are `uuidv7()` with a `cell` column, so if cross-cloud replication is added later, histories merge without ID collisions.

## 23.5 RPO / RTO

| Scenario | RTO (target, to be replaced by drill measurements) | RPO |
|---|---|---|
| Pod / node failure | < 1 min (K8s) | 0 |
| Zone failure inside a cell | < 3 min (spread + PDB) | 0 (Multi-AZ DB in prod; budget: last nightly dump) |
| Whole cell down, forced by Cloudflare health | detection ≈ 2–3 min (60 s × retries) + drain | 0 for new orders; home-cell history unavailable until failback |
| Planned evacuation (drill) | measured: pre-warm + shift (§15.5) | 0 |
| Control plane down | No user impact; dashboards and recommender pause | Last DB backup (nightly) |

---

# §24 — Deployment Strategies

| What | Strategy | Rollback |
|---|---|---|
| App release across clouds | **Ring**: GCP cell (canary) → soak → AWS cell | Revert ring file → Argo sync |
| App release inside a cell | **Canary** via Argo Rollouts (10/50/100 with analysis) | Automatic abort on failed analysis |
| DB schema | **Expand → migrate → contract** with Flyway, contract step only after both rings run the new version | Expand steps are backward-compatible by construction |
| Infrastructure | **Plan-gated, stack-by-stack**: dev cells → prod GCP → prod AWS → traffic | Revert PR + apply; state versioning for emergencies |
| Traffic | **Weighted shift** in ≤ 20-point steps with SLO gates | Compensation step restores recorded weights |
| Kubernetes upgrades | **Cell-at-a-time**: upgrade GCP prod, run a drill, then AWS | Drain traffic away from the upgrading cell first (it's just an evacuation) |
| Budget VMs | **Rebuild, don't patch in place** for OS majors: Terraform replaces VM → Ansible configures → Argo syncs → shift back | Old VM kept until new one passes health |

"Blue/green" in CloudBridge is literally the two cells: drain one, upgrade it, shift back — the evacuation machinery doubles as the upgrade machinery.

---

# §25 — Security

| Area | Control |
|---|---|
| CI → cloud | GitHub OIDC; AWS role trust on `sub` = repo + environment; GCP WIF attribute conditions on repository + environment; separate plan (read-only) and apply roles |
| Cluster access | EKS access entries (API mode), public endpoint CIDR-restricted; GKE private nodes + authorised networks |
| Pod → cloud | EKS Pod Identity / GKE Workload Identity; no node-level credentials used by apps |
| Secrets | ESO → Secrets Manager / Secret Manager; DB passwords generated by Terraform `random_password` and written straight to the secret store (marked `sensitive`); state buckets encrypted and access-restricted |
| Origins | Accept 443 only from Cloudflare ranges; Cloudflare Origin CA certs; Full (strict) TLS |
| Control plane | Cloudflare Access in front of dashboard, Grafana and the remote-write receiver |
| Supply chain | Actions pinned by SHA (Dependabot updates), cosign keyless signatures, SBOM attestation, Trivy image + IaC scanning; post-MVP: Kyverno `verifyImages` in prod cells |
| Workloads | Restricted Pod Security on `cb-app`, default-deny NetworkPolicy, read-only root FS, non-root |
| VMs (budget) | No public SSH; SSM / IAP only; unattended security upgrades; auditd |
| Audit | CloudTrail + Cloud Audit Logs; plan SHA-256 stored per deployment; `traffic_changes` records every weight change with source |

---

# §26 — Documented Scaling Decisions (`docs/scaling-decisions.md`)

## 26.1 Decision 1 — State topology: stacks per cloud × env × layer, workspaces only for ephemeral previews

**Context.** 2 clouds × 2 envs × 3 layers + global stacks ≈ 12–14 states. Requirements: separate credentials per cloud and environment, small blast radius, one PR showing both clouds.

| Option | Pros | Cons |
|---|---|---|
| A. One state per environment containing both clouds | One apply | Blast radius = both clouds; one credential set needs admin on both; provider-in-same-apply problems (C8) |
| B. One directory, CLI workspaces per cloud/env | DRY | Shared backend + credentials; HashiCorp advises against workspaces as an isolation boundary; easy to apply to the wrong workspace |
| **C. Directory per stack calling shared modules** ✅ | Each state has its own backend, CI identity, approval gate; facade keeps code DRY; PR comment aggregates all affected stacks | More directories; needs a stack-dependency map in CI |
| D. Terragrunt / Terramate | Generates C with less boilerplate; dependency graphs built in | Another tool; not needed at this size |

**Decision:** C. Workspaces are used only for `pr-<n>` preview environments in the dev account, where shared credentials are acceptable and lifetimes are hours.

**Revisit when:** > ~25 stacks or a third cloud → adopt Terramate or Terragrunt (they formalise exactly this layout).

## 26.2 Decision 2 — Failover capacity: warm standby with burst, not 2× idle capacity

**Context.** With a 70/30 split, the GCP cell normally runs ~30% load. To survive losing AWS it must serve 100%.

| Option | Monthly cost | RTO impact |
|---|---|---|
| Size both cells for 100% all the time (active-active at 2×) | Highest — roughly double compute | Best: no pre-warm |
| **Size for current share; set HPA/node max for 100%; pre-warm on evacuation** ✅ | Pay for current load + headroom | Adds pre-warm minutes to planned evacuations; unplanned failover relies on autoscaling speed |
| Cold standby (scale to zero) | Lowest | Long RTO; violates warm floor |

**Decision:** middle option, with the warm floor (≥ 10%) and capacity ratio ≥ 1.2 checked before any planned shift. The drills measure the real pre-warm time; if unplanned-failover tests show autoscaling is too slow, raise `minReplicas` on the minority cell — the cost of that change is visible in the cost-per-request dashboard before you make it.

**Interview line:** *"I didn't buy 2× capacity — I bought the ability to prove, every two weeks, how long it takes the small cloud to become the big one."*

---

# §27 — Cost Plan (realistic for a fresher)

Prices change and vary by region — run `infracost breakdown` on each stack and put the output in the README rather than trusting any table, including this one.

| Item | Always-on (budget profile) | Per managed demo session (~4 h, both clouds) |
|---|---|---|
| Compute | 1× t3.small (Mumbai) + 1× e2-small (Mumbai) | 2+2 small nodes |
| Control plane fee | — | EKS hourly fee (standard support); GKE zonal cluster covered by the free-tier management credit (one cluster per billing account) |
| Networking | 2 static public IPv4 (AWS charges per public IPv4 hour) | NAT gateway / Cloud NAT, ALB / GCLB |
| Data | In-cluster PG + Valkey (free) | Smallest RDS / Cloud SQL / ElastiCache / Memorystore tiers (or in-cluster via `managed_cache=false`) |
| Edge | Cloudflare Free plan + Load Balancing add-on (starts ~US$5/mo for 2 endpoints) | same |
| Rough order of magnitude | Low tens of US$/month | A few US$ per session |

Credits: new AWS accounts (since 15 Jul 2025) get up to US$200 on a 6-month Free plan; GCP's new-customer trial credit covers the GCP side for a while. **Use the AWS Paid plan with credits** if you need services the Free plan restricts — and set budget alerts on day 1.

Cost hygiene built into the project (and worth mentioning): TTL reaper, nightly cost report in Slack, Infracost on PRs, budget alerts as Terraform resources (`aws_budgets_budget`, `google_billing_budget`).

---

# §28 — README Blueprint

````markdown
# CloudBridge — one codebase, two clouds, zero blind spots

[Live: https://app.<domain>](https://app.<domain>) · [Dashboard](https://cp.<domain>) (read-only demo login) ·
[Latest drill report](docs/drills/) · [Parity status](badge) · [Architecture decisions](docs/adr/)

> Same Spring Boot services on AWS and GCP from one Terraform codebase. Cloudflare splits traffic 70/30.
> CloudBridge continuously proves the clouds are identical (parity), that the smaller one can take
> all the traffic (evacuation drills), and which one is cheaper per request (FOCUS cost ledger).

## Architecture
```mermaid
flowchart LR
  U[Users] --> CF[Cloudflare LB<br/>70/30 + cookie affinity]
  CF --> A[AWS cell<br/>EKS or k3s on EC2]
  CF --> G[GCP cell<br/>GKE or k3s on GCE]
  A -. remote_write .-> CP[Control plane<br/>Prometheus · Grafana · ledger · parity]
  G -. remote_write .-> CP
  GH[GitHub Actions<br/>OIDC · plans · Ansible drills] --> A & G & CF
```

## Try it in 60 seconds
curl -sI https://app.<domain> | grep -i x-cb-cell     # run it 10 times — you'll see both clouds

## Run locally
docker compose up --build    # gateway :8080 · dashboard :3000 · grafana :3001

## Deploy your own (budget profile, ~15 min)
make bootstrap-ci-identity   # once, with admin credentials
make budget-up               # Terraform: VMs on both clouds → Ansible: k3s → Argo CD: apps
make traffic-up WEIGHTS=aws=70,gcp=30

## What's measured (numbers from my dashboard, with dates)
| Metric | AWS cell | GCP cell | Window |
| Cost per 1k requests (EffectiveCost, credits excluded) | … | … | 1–30 Nov 2026 |
| Last evacuation drill: shift time / errors | … | … | 2026-11-30 |
| Parity score (30-day min) | … | | |

## Screenshots
1. Multi-cloud overview — configured vs observed split
2. Cost per request by service
3. Parity dashboard showing an expiring exception
4. Drill timeline with burn rate per step
5. PR comment: AWS plan + GCP plan + cost delta + plan-risk verdict
6. Argo CD in both cells showing the same digests

## Scaling decisions · Leaky abstractions · What I'd do next
docs/scaling-decisions.md · docs/leaky-abstractions.md · docs/roadmap.md
````

Screenshot tip: take them from the **live** system, label each with the date, and keep the "What's measured" table filled only with values you can reproduce on screen in the interview.

---

# §29 — Interview Prep

## 29.1 The 30-second pitch

> "CloudBridge runs the same Spring Boot services on AWS and GCP from one Terraform codebase — changing one variable targets a different cloud. Ansible configures the VMs and runs evacuation drills; Argo CD deploys; Cloudflare splits traffic 70/30. The part I'm proudest of is the control loop: a parity check that fails CI when the clouds drift apart, drills that prove the smaller cloud can take all the traffic before I'd trust it to, and a FOCUS cost ledger that compares the clouds per thousand requests. It's live — here's the link."

## 29.2 CloudBridge's maturity ladder (replaces C23)

1. "I deployed an app to Kubernetes."
2. "I wrote Terraform for one cloud."
3. "I wrote Terraform that targets two clouds from one codebase."
4. **"I can prove the two clouds are still the same, prove the failover target has the capacity, and show what each costs per request — and every one of those proofs gates CI or produces a dated report."** ← CloudBridge

## 29.3 Soundbites

- "Terraform builds the house; Ansible runs the fire drill."
- "Health-based failover asks *is it up?* My evacuation asks *can it take the load?*"
- "Totals measure the traffic split; cost per request measures the cloud."
- "Multi-cloud protects you from your provider, not from yourself — so my smaller cloud is my canary."
- "My abstraction has a contract test — I can prove both implementations return the same interface for ₹0."
- "The escape hatch can't live in the building that's on fire — evacuations run from CI, outside both clouds."
- "Adding a second cloud moved my availability ceiling to the edge provider. I wrote down that risk instead of hiding it."
- "Exceptions are loans, not waivers — they expire."

## 29.4 Questions and answers

**Q1. Walk me through the architecture.**
Two cells, one per cloud, each with network, Kubernetes 1.36, Postgres 18 and Valkey 9 from one facade module. Cloudflare in front with pool weights 70/30 and cookie affinity. Argo CD in each cell pulls from Git. A control plane off the request path holds metrics, the cost ledger, parity and drill history. CI uses OIDC to both clouds; evacuations run from CI with Ansible. (Then draw §5.1.)

**Q2. What does "change one variable" really mean — and what doesn't abstract?**
The stack's `cloud = "gcp"` selects implementations behind a facade whose outputs are contract-tested. What doesn't abstract: IAM models, ingress (hostname vs IP), upgrade cadence, burst CPU models, egress pricing — twelve items in my leaky-abstraction register, each with how I handle it.

**Q3. Why not Terraform workspaces?**
Workspaces in one directory share a backend and credentials; HashiCorp's docs say they're not an isolation boundary for that case. I use a directory per stack — separate state, CI role and approval gate — and keep workspaces for short-lived PR previews in dev. I'd move to Terramate/Terragrunt past ~25 stacks.

**Q4. How do you keep Terraform state safe?**
S3 with native lock files (`use_lockfile`; DynamoDB locking is deprecated) and GCS with native locking, versioned buckets, restricted to each stack's CI role. Applies use a saved plan behind an approval gate, and `concurrency` groups serialise runs per stack.

**Q5. Why Ansible in 2026 when you have Terraform and Argo CD?**
Two jobs neither does: configuring VMs that aren't immutable images (k3s, hardening on the budget cells), and orchestrating multi-step procedures — evacuation with capacity checks, SLO gates and compensation. Hand-off is via cloud tags and dynamic inventory, not provisioners.

**Q6. Prove the 70/30 split is real.**
Pool-level `random_steering.pool_weights`, not origin weights — my first version put weights on single-origin pools, which does nothing. The overview dashboard plots configured vs observed split from Cloudflare analytics.

**Q7. AWS goes down. What happens, minute by minute?**
Cloudflare's monitor fails twice at 60 s intervals → AWS pool unhealthy after ~2–3 min → sticky sessions move to GCP. GCP's HPA and node autoscaler absorb the load; if it's an unplanned failover, users see some latency while it scales. New orders work; AWS users' history is unavailable until failback; inventory never oversells because AWS's lease expires. Planned version: my playbook pre-warms first and shifts in steps — my last drill's numbers are on the dashboard.

**Q8. Can GCP actually handle 100%?**
That's the question the drill answers. Capacity ratio = HPA max × measured per-pod RPS ÷ peak RPS, must be ≥ 1.2 before any planned shift; otherwise the playbook pre-warms or refuses.

**Q9. How is data kept consistent across clouds?**
It isn't synchronously — by design. Cells own their data; users are pinned by cookie; IDs are `uuidv7()`; inventory uses escrow leases with fencing. Cross-cloud async replication is post-MVP for history availability during evacuation.

**Q10. Which cloud is cheaper?**
"For my workload in Mumbai, between <dates>, cost per 1k requests was X on AWS and Y on GCP, credits excluded, same shapes." Then explain which line items drove it. If I don't have the number yet: say so and explain the method.

**Q11. Why PostgreSQL — not TimescaleDB, Mongo, Cassandra, Cosmos?**
Parity decides: it's the only option with the same major as a first-party managed service on both clouds. Cosmos is Azure-only; TimescaleDB isn't offered on RDS or Cloud SQL; Cassandra has no transactions for order + outbox + escrow. The cost ledger is time-series-shaped but thousands of rows a day — monthly partitions are enough.

**Q12. Why Valkey — not Kafka, RabbitMQ, ZooKeeper?**
Event volume is dozens per hour; Valkey Streams handles it and both clouds offer Valkey 9 managed. Kafka 4 no longer even needs ZooKeeper, and ZooKeeper was never a cache or a queue — it's a coordination service; nothing here needs consensus.

**Q13. How do you stop a bad release hitting both clouds?**
Ring deployment: GCP first with in-cell canary analysis, 30-min soak, then AWS. Parity allows that divergence for at most two hours.

**Q14. How do you detect drift?**
Three kinds: stack vs code (nightly `plan -detailed-exitcode`), cluster vs Git (Argo CD self-heal), cell vs cell (parity contract). The third is the one most setups miss.

**Q15. How do CI pipelines authenticate to clouds?**
OIDC: AWS role trust on repo + environment claim; GCP Workload Identity Federation with attribute conditions. No static keys. Plan roles are read-only; apply roles exist only in protected environments.

**Q16. What's your single point of failure?**
Cloudflare. I documented a DNS-only runbook and the cost of a second DNS provider; the Nov 2025 Cloudflare outage is the reason that section exists.

**Q17. Why one Argo CD per cell instead of a hub?**
A hub needs admin credentials to both clouds and becomes a cross-cloud SPOF. Pull-based, per-cell Argo keeps each cell independent; the parity checker gives me the cross-cell view.

**Q18. Is multi-cloud a good idea?**
Usually not for most teams — multi-region in one cloud covers most outages more cheaply. It makes sense for regulatory exit plans (RBI's 2023 IT-outsourcing directions require a documented exit strategy), negotiating leverage, M&A, or provider-specific services. CloudBridge shows the engineering cost honestly: parity, capacity and cost all need continuous proof.

**Q19. How would you add Azure?**
Implement `network/azure`, `cluster/azure-aks`, `database/azure-flex-pg`, `cache/azure-*`, add `"azure"` to the facade validation, pass the contract test, add a pool to Cloudflare, an adapter to the cost collector (Azure exports FOCUS too), and three rows to the leaky-abstraction register. Existing implementations don't change.

**Q20. What would you do differently at a real company?**
Packer images instead of configuring VMs at boot; Terramate past 25 stacks; Mimir for metrics; cross-cloud replication if the business needs history during failover; and I'd question whether active traffic on both clouds is needed at all versus a warm standby.

## 29.5 Live demo script (7 minutes)

1. `curl` the live link a few times — `X-CB-Cell` alternates (proves two clouds).
2. Overview dashboard — configured vs observed split.
3. Open a PR changing a chart value **only** in the AWS cell values → plan-risk "one-sided change" warning + parity check fails. Close it.
4. Open the cost-per-request dashboard; read the numbers with dates.
5. Trigger `drill.yml` on the budget profile → watch steps 50/25/0 with burn rate → report lands in `docs/drills/`.
6. Show the traffic `terraform.tfvars.json` change history (`traffic_changes` table) — every weight change has a source.
7. Close with the leaky-abstraction register.

## 29.6 Resume bullets

- Built **CloudBridge**, a multi-cloud platform deploying Spring Boot microservices to **AWS and GCP from one Terraform codebase** (facade module with contract tests on Terraform and OpenTofu), traffic split 70/30 via **Cloudflare**; live at app.<domain>.
- Integrated **Ansible** for VM configuration (k3s, hardening) and **SLO-gated, capacity-verified evacuation drills**; measured cloud-to-cloud shift time of **<N> s** with **<E>** errors.
- Built a **cross-cloud parity check** (12 weighted checks, expiring exceptions) gating CI, and a **FOCUS-based cost ledger** comparing clouds per 1k requests.
- Shipped GitOps CI/CD with **GitHub OIDC** (no static cloud keys), saved-plan applies, policy/cost gates, cosign-signed images, and per-cell **Argo CD** with cloud-as-canary-ring releases.

Fill `<N>`/`<E>` only from your drill reports.

---

# §30 — Sources & Verification Log (checked 7 Oct 2026)

| Fact used | Source |
|---|---|
| Terraform 1.14 GA 19 Nov 2025 with `action` blocks; 1.15.0 GA 29 Apr 2026 (deprecation attributes, variables in module source) | github.com/hashicorp/terraform releases; danielmschmidt.de "What's new in Terraform 1.15"; InfoQ June 2026 |
| OpenTofu 1.12.x stable (1.12.2 as of June 2026) | scalr.com OpenTofu guide; opentofu releases |
| S3 backend `use_lockfile`; DynamoDB locking deprecated | developer.hashicorp.com/terraform/language/backend/s3 |
| EKS standard support 1.35 and 1.36; 1.36 EKS release 2 Jun 2026 | docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions; ecorpit.com EKS calendar summary |
| GKE Regular channel minor versions 1.34–1.36, default 1.35.x | docs.cloud.google.com/kubernetes-engine/docs/release-notes |
| ansible-core 2.21 (2.21.2 Jul 2026), no breaking changes vs 2.20 | github.com/ansible/ansible releases; Debian changelog; ansible porting guide 2.21 |
| Cloudflare provider v5.22.0 (9 Jul 2026); `random_steering.pool_weights` on load balancers | github.com/cloudflare/terraform-provider-cloudflare releases; developers.cloudflare.com/api/terraform/resources/load_balancers |
| Cloudflare Load Balancing is a paid add-on, ~US$5/mo for 2 endpoints | developers.cloudflare.com/load-balancing; costbench.com |
| RDS PostgreSQL 18.4; Cloud SQL PostgreSQL 18 default | aws.amazon.com what's-new May 2026; docs.cloud.google.com/sql/docs/postgres/db-versions |
| ElastiCache Valkey 9.0 (5 May 2026); Memorystore for Valkey 9.0 default | aws.amazon.com what's-new 2026/05; docs.cloud.google.com/memorystore/docs/valkey/supported-versions |
| Spring Boot 4.0 EOL 31 Dec 2026; 4.1.x current | spring.io blog; endoflife data (isitpatched.com) |
| FOCUS 1.3 ratified Dec 2025, 1.4 ratified 4 Jun 2026; AWS FOCUS 1.2 GA in Data Exports | focus.finops.org; finops.org; opslyft.com |
| Argo CD 3.3 upgrade requires Server-Side Apply | argo-cd.readthedocs.io upgrading 3.2→3.3 |
| Infracost CLI v0.10.45 (3 Jul 2026), Apache-2.0 | infracost GitHub via dev.co / tech-insider.org |
| k8gb CNCF incubating (Jul/Aug 2026) | cncf.io announcement 5 Aug 2026 |
| AWS Free plan: credit-based, 6 months, accounts from 15 Jul 2025 | aws.amazon.com what's-new 2025/07 |
| AWS us-east-1 DynamoDB DNS outage, 20 Oct 2025 | InfoQ Nov 2025; AWS health updates |
| Cloudflare global outage, 18 Nov 2025 (oversized Bot Management feature file) | blog.cloudflare.com/18-november-2025-outage (via coverage) |
| RBI Master Direction on Outsourcing of IT Services (Apr 2023) requires an exit strategy | rbi.org.in Master Direction RBI/2023-24/102 |

**Re-verify on build day:** Google and Helm/Kubernetes provider majors, Argo Rollouts and Kyverno versions, exact Prometheus/Grafana/k6 image patches, Cloudflare v5 nested attribute names, current instance prices in Mumbai.

---

*CloudBridge Implementation Plan — Rev 2 · 7 October 2026*
