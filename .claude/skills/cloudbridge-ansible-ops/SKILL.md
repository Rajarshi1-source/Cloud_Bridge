---
name: cloudbridge-ansible-ops
description: Write and run CloudBridge's Ansible layer - configuring the budget-profile VMs (EC2 and GCE running k3s 1.36) and orchestrating multi-step operations - evacuate, failback, pre-warm and scheduled evacuation drills with capacity checks, SLO gates, compensation and drill reports, plus Event-Driven Ansible rulebooks fed by Alertmanager. Use for ANY work under ansible/ - roles (base_hardening, k3s_server, node_exporter, origin TLS, registries mirror, Argo CD auto-deploy manifests), aws_ec2 and gcp_compute dynamic inventories, SSM and IAP connections, Molecule and ansible-lint, community.general.terraform calls, ansible-rulebook - or when the user asks how Ansible and Terraform fit together, how to run a DR or failover drill, or how to prove the GCP cell can take all traffic. MANDATE - ansible-core 2.21; Terraform owns resources, Ansible owns VM config and procedures; hand-off by cloud tags, never provisioners; prod never auto-shifts traffic. Not for Cloudflare resource definitions (cloudflare-traffic).
---

# CloudBridge — Ansible Operations

> **Terraform builds the house. Ansible configures the rooms that aren't prefabricated — and runs the fire drill.**

Ansible has two jobs in CloudBridge, and both are things Terraform and Argo CD are bad at:
1. **Configuration management** of the budget-profile VMs (no golden images yet, so idempotent config is the right tool).
2. **Procedures**: evacuations, failbacks and drills are multi-step sagas with checks, waits, branches and compensation — there is no resource to declare.

Complete files (requirements, ansible.cfg, inventories, group_vars, roles, playbooks, rulebook, Molecule) are in `references/playbooks.md`.

## Versions

| Component | Pin |
|---|---|
| ansible-core | 2.21.x (2.21 porting guide lists no breaking changes from 2.20) |
| Collections | `amazon.aws`, `community.aws` (SSM connection), `google.cloud`, `kubernetes.core`, `community.general` (terraform module), `ansible.posix` — exact versions in `requirements.yml`, verify on build day |
| ansible-rulebook | 1.1.x with `ansible.eda` collection |
| k3s | `v1.36.x+k3s1` — same minor as EKS/GKE, checked by the parity contract |
| Target OS | Ubuntu 24.04 LTS on both clouds |

## Ownership boundaries (the question interviewers ask)

| Thing | Owner | Why not Ansible / why Ansible |
|---|---|---|
| VMs, IPs, firewalls, IAM, clusters, DBs, Cloudflare | Terraform | Needs state, plan, drift detection |
| Apps + cluster add-ons | Argo CD | Continuous reconciliation from Git |
| OS hardening, k3s install, exporters, origin certs, registry mirror on budget VMs | **Ansible** | Mutable hosts need idempotent config |
| Argo CD bootstrap on budget k3s | **Ansible** writes a k3s `HelmChart` + root ApplicationSet into `/var/lib/rancher/k3s/server/manifests/` | The k3s API is never exposed; k3s auto-applies that directory. Managed cells get the same chart via Terraform `20-bootstrap` |
| Evacuate / failback / pre-warm / drill | **Ansible** playbooks | Sagas with compensation |
| Alert → drill (non-prod) / alert → proposal PR (prod) | **ansible-rulebook** | Reacts to Alertmanager webhooks |

Rejected integration styles, with reasons you can say out loud: Terraform `remote-exec`/`local-exec` (provisioner failure taints resources; re-config means replacement); the `ansible/ansible` Terraform provider for inventory (couples inventory to state reads); Ansible `kubernetes.core.helm` for apps (a second owner of releases — the exact bug Rev 1 had with Terraform + `helm upgrade`).

## Hand-off: tags, not state

Terraform tags every budget VM `cb-ansible-role = k3s_server` plus `cb-cell`, `cb-cloud`, `cb-env`. The `amazon.aws.aws_ec2` and `google.cloud.gcp_compute` inventory plugins filter on those tags and build groups `cloud_aws`, `cloud_gcp`, `env_prod`, …, so Ansible never reads Terraform state.

Connections (no public SSH anywhere):
- AWS: `community.aws.aws_ssm` connection plugin (SSM Session Manager; needs an S3 bucket for file transfer).
- GCP: SSH through IAP — `ansible_ssh_common_args` with a `gcloud compute start-iap-tunnel` ProxyCommand; OS Login user from the CI service account.

These differ, so they live in `group_vars/cloud_aws.yml` and `group_vars/cloud_gcp.yml` — a documented leaky abstraction.

## Roles

| Role | Does | Idempotency notes |
|---|---|---|
| `base_hardening` | SSH password auth off, unattended security upgrades, auditd, chrony, sysctl hardening, 1 GiB swapfile with `vm.swappiness=10` (2 GiB VMs + JVM start bursts), journald cap | Templates + `notify` handlers |
| `k3s_server` | Pinned k3s install via the official script with `INSTALL_K3S_VERSION`, config file (`disable: [traefik]` because Traefik is Argo-managed, kubelet reservations, eviction thresholds), wait for Ready | Install only when `k3s --version` doesn't contain the pin |
| `registries_mirror` | `/etc/rancher/k3s/registries.yaml` with authenticated Docker Hub endpoint | Restarts k3s only on change |
| `cell_secrets` | `cb-app` namespace (restricted Pod Security) + `cell-db` / `cell-cache` / `cell-admin` Secrets (the last from `CF_ACCESS_*`, the role fails without them) in the auto-deploy dir; the DB password is generated once on the VM (budget Postgres lives on that disk) | `copy force: false`; `no_log: true` |
| `origin_tls` | Cloudflare Origin CA cert + key (`global/20-origin-tls`) from the cloud secret store into a `kubernetes.io/tls` Secret manifest in the auto-deploy dir | `no_log: true` |
| `node_exporter` | Pinned binary + systemd unit | Version-checked |
| `argocd_autodeploy` | Renders HelmChart CR (`argo-cd` chart 10.10.5, slimmed for 2 GiB) + root ApplicationSet with `cell` and `ring` (`cb_ring` from `group_vars/cloud_*`) filled | Files only; k3s reconciles |

Every role is covered by a Molecule scenario (Docker driver, Ubuntu 24.04 image) and passes `ansible-lint --profile production`; `iac-check.sh molecule` runs every `roles/*/molecule/default`. The three file-only roles share one scenario (`argocd_autodeploy`), which also proves the ApplicationSet keeps Argo's `{{.app}}` after Ansible renders it. Verify-playbook variables need the role prefix too (production profile). k3s can't fully run in Molecule's container; the scenario asserts the config files and the install command line instead, and the real install is verified by the weekly `budget-config.yml` run.

## Playbooks

| Playbook | Purpose |
|---|---|
| `site.yml` | Configure all budget VMs (roles above), then smoke-test `/healthz/cell` through the origin |
| `prewarm.yml` | Raise HPA `minReplicas` on the target cell to the evacuation level and wait for pods + nodes Ready |
| `evacuate.yml` | The saga below |
| `failback.yml` | Restore the weights recorded at evacuation start, stepwise, then reset HPA mins |
| `drill.yml` | `evacuate.yml mode=drill` → hold 10 min → `failback.yml` → render `docs/drills/<date>-<from>-to-<to>.md` |
| `propose_evacuation.yml` | Prod alert path: opens a GitHub issue + PR with the proposed weights and current capacity ratio; a human merges |

### The evacuation saga

1. **Record** current weights from `infra/live/global/30-traffic/terraform.tfvars.json` (the compensation target) and open a drill record via the control-plane API.
2. **Capacity check**: `capacity_ratio = min_svc(hpa_max × per_pod_rps / fanout) / peak_rps_7d` from `GET /capacity/<cell>` — divide by fanout: if each gateway request makes two inventory calls, inventory's pods serve half as many *gateway* requests. Proceed at ≥ 1.2. The formula lives only in the control-plane API so the playbook, recommender and dashboard can't disagree.
3. **Pre-warm** if the ratio at *current* replica counts is < 1.2; re-check; **refuse** if still < 1.2 — evacuating into an undersized cell turns a one-cloud incident into a two-cloud one.
4. **Shift in steps** (default from-cell share 50 → 25 → 0) using `community.general.terraform` on the traffic stack. After each step: wait ≥ 2 × monitor interval + drain (150 s), query 5-minute burn rate and p95 on the receiving cell from Prometheus, record the step, **abort** if burn > 6 or p95 > 600 ms.
5. **Compensate** in `rescue:` — re-apply the recorded weights, mark the drill `rolled_back`, fail loudly.
6. **Close**: mark complete; control plane renders the report (capacity ratio before/after, pre-warm seconds, shift seconds, max burn, edge 5xx during shift).
7. **Real evacuations** open a PR committing the final weights so Git matches reality; drills fail back immediately.

`break_glass=true` swaps step 4's Terraform call for the Cloudflare API script (cloudbridge-cloudflare-traffic) when the traffic state backend is unreachable.

Evacuations run from a **GitHub Actions runner**, outside both clouds: the escape hatch can't live in the building that's on fire.

## Event-Driven Ansible

`rulebooks/cell-degraded.yml` listens on `ansible.eda.alertmanager`:
- `CellSLOBurnFast` firing in **non-prod** → run `evacuate.yml mode=drill`.
- `CellSLOBurnFast` firing in **prod** → run `propose_evacuation.yml` only. Automation prepares, a human approves. Cloudflare's monitor already handles hard-down; EDA is for the slow-burn degradation health checks miss.

Guard against flapping: rulebook throttle (`throttle: once_within: 30 minutes, group_by_attributes: [event.alert.labels.cb_cell]`).

## Writing new Ansible here — checklist

- Prefer modules over `shell`; when `shell` is unavoidable (k3s installer), make it conditional and set `changed_when`.
- Every playbook that changes traffic must record to the control-plane API and must have a `rescue:` compensation.
- No secrets in vars files — read from AWS Secrets Manager / GCP Secret Manager lookups (`amazon.aws.secretsmanager_secret`, `google.cloud.gcp_secret_manager`) with `no_log: true`.
- Use FQCNs (`ansible.builtin.template`) — ansible-lint production profile requires them.
- Keep cloud differences in `group_vars/cloud_*.yml`, never `when: cloud == "aws"` scattered through tasks.

## Interview soundbites

- "Health-based failover asks *is it up?* My playbook asks *can it take the load?* — and refuses if the answer is no."
- "Every drill writes a dated report: capacity ratio, pre-warm time, shift time, errors. That's exit-plan evidence, not a slide."
- "In dev, automation acts; in prod, automation writes the PR."
