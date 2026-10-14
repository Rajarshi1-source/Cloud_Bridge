---
name: cloudbridge-terraform-cells
description: Build and change CloudBridge's Terraform cell layer - the facade module (modules/cell) that turns one variable, cloud = aws or gcp plus profile = managed or budget, into an identical cell of network, Kubernetes 1.36 (EKS, GKE or k3s on a VM), PostgreSQL 18 and Valkey 9. Use for ANY work on infra/modules or infra/live stacks - adding or editing an AWS or GCP implementation, the shape-parity table, outputs contract, terraform test with mock providers, S3 use_lockfile or GCS backends, state-per-stack layout, EKS access entries, GKE Workload Identity, RDS, Cloud SQL, ElastiCache, Memorystore, adding Azure, or reviewing HCL for this repo, even if the user only says multi-cloud Terraform or the one-variable switch. MANDATE - Terraform 1.15 (OpenTofu 1.12 compatible), one state per cloud x env x layer (never CLI workspaces as the cloud boundary), identical output contract proven by a contract test. Not for Cloudflare weights (cloudflare-traffic) or CI workflows (iac-pipeline).
---

# CloudBridge — Terraform Cells

CloudBridge provisions **cells**: one per cloud per environment, each with network, Kubernetes, Postgres and Valkey. The whole point of the project is that a cell on AWS and a cell on GCP are interchangeable, so every change here is judged by one question: *does it keep the two implementations behind the same interface?*

Read `references/starter-code.md` when you need full module files (facade, EKS, GKE, k3s VM, network, data services, backends, contract test, Makefile). This file holds the rules and the reasoning.

## Pinned versions (verified 7 Oct 2026 — re-check patch levels on build day)

| Component | Pin | Why this pin |
|---|---|---|
| Terraform | `>= 1.15.0, < 2.0.0` | 1.15 adds `deprecated` on variables/outputs and variables in module `source` |
| OpenTofu | 1.12.x | CI-only compatibility proof (validate + test) |
| AWS / Google providers | `~> 6.0` / `~> 7.0` | Exact versions live in the committed `.terraform.lock.hcl` |
| Kubernetes | 1.36 on EKS, GKE (Regular channel) and k3s | Newest minor supported by both managed services |
| PostgreSQL | 18 (RDS `engine_version = "18"`, Cloud SQL `POSTGRES_18`) | Same major as first-party managed service on both clouds |
| Valkey | 9.0 (ElastiCache `9.0`, Memorystore `VALKEY_9_0`) | Same reason |

Pick versions by **intersection**: if one cloud offers something newer, wait. Parity is the product.

## Layout and state

```
infra/modules/cell/                 facade (Abstract Factory) + tests/contract.tftest.hcl
infra/modules/{network,cluster,database,cache,registry-mirror,ci-identity,bootstrap}/<impl>/
infra/live/<cloud>-<env>/10-foundation   network + cluster + data      (one state)
infra/live/<cloud>-<env>/20-bootstrap    Argo CD + root ApplicationSet (one state)
infra/live/global/00-ci-identity         OIDC roles (bootstrapped once by a human)
infra/live/global/30-traffic             Cloudflare (owned by cloudbridge-cloudflare-traffic)
```

- **One directory = one state = one CI identity = one approval gate.** At today's size (≈12–14 stacks) plain directories + a Makefile stay readable; the switch trigger to **Terramate or Terragrunt** is ~25+ stacks or a third cloud — say so when someone wants more DRYness. HashiCorp's own docs say CLI workspaces in a single directory share backend and credentials and are not an isolation boundary — exactly the AWS-prod vs GCP-prod situation. Workspaces are allowed only for short-lived `pr-<n>` previews in dev.
- **Layering exists because of providers.** `kubernetes`/`helm` providers must not be configured from a cluster created in the same apply (unknown values at plan, broken destroys). `20-bootstrap` reads `10-foundation` outputs via `terraform_remote_state`.
- **Backends:** AWS stacks use S3 with `use_lockfile = true` (DynamoDB locking is deprecated); GCP stacks use GCS (native locking). Buckets versioned, encrypted, restricted to the stack's CI roles. Never invent a lock in Valkey/Redis.

## The facade contract

`modules/cell` takes `cloud`, `profile`, `env`, `region`, `shape`, `kubernetes_minor`, `node_count`, `node_max`, `admin_cidrs`, `cloudflare_ipv4`, `gcp_project_id`, `ci_role_arn`, `managed_cache` and returns exactly four outputs:

| Output | Shape | Notes |
|---|---|---|
| `cell` | `{name, cloud, profile, region, shape, origin}` | `origin` = what Cloudflare points at |
| `cluster` (sensitive) | `{name, endpoint, ca_certificate, k8s_version, origin, node_security_group, auth}` | identical keys for EKS, GKE, k3s-aws, k3s-gcp |
| `database` (sensitive) | `{host, port, secret_ref}` or `null` | `null` → bootstrap installs in-cluster Postgres |
| `cache` (sensitive) | `{host, port, tls}` or `null` | `null` → in-cluster Valkey |

Selecting the implementation:

```hcl
locals {
  cluster  = one(concat(module.eks[*].cluster, module.gke[*].cluster,
                        module.k3s_aws[*].cluster, module.k3s_gcp[*].cluster))
  database = one(concat(module.db_aws[*].database, module.db_gcp[*].database))   # null when none
}
```

Use `one(concat(...))`, not `var.cloud == "aws" ? module.eks[0] : module.gke[0]`. The conditional has to unify both branch types and indexing an empty module list errors; `one()` returns the single instantiated implementation and fails loudly if `count` logic ever instantiates two.

## Shape parity

```hcl
shapes = {
  small    = { aws = "t3.medium",  gcp = "e2-medium",     vcpu = 2, mem_gib = 4,  class = "burstable" }
  standard = { aws = "m6i.large",  gcp = "n2-standard-2", vcpu = 2, mem_gib = 8,  class = "general-purpose" }
  large    = { aws = "m6i.xlarge", gcp = "n2-standard-4", vcpu = 4, mem_gib = 16, class = "general-purpose" }
}
budget_shapes = { small = { aws = "t3.small", gcp = "e2-small", vcpu = 2, mem_gib = 2, class = "burstable" } }
```

Every pair must match vCPU, memory and CPU class. Rev 1 mapped `t3.large` (2/8) to `e2-standard-4` (4/16), which silently gave GCP twice the hardware and invalidated the cost comparison. If someone asks to change a row, say that it's a cost-comparison event and that the parity contract and FinOps dashboards will record it.

## Implementation rules

**EKS** — `access_config.authentication_mode = "API"` with `aws_eks_access_entry` + policy association (never the `aws-auth` ConfigMap); `public_access_cidrs = var.admin_cidrs` (never `0.0.0.0/0`); `upgrade_policy.support_type = "STANDARD"` (extended support costs several times more per hour); AL2023 node AMI; `eks-pod-identity-agent` addon; `ignore_changes` on `desired_size` because the autoscaler owns it.

**GKE** — zonal (`location = "<region>-a"`, eligible for GKE's free-tier management credit), `release_channel = REGULAR`, `min_master_version = var.k8s_version`, maintenance window at night IST, `datapath_provider = "ADVANCED_DATAPATH"` (NetworkPolicy enforced), private nodes + master authorized networks, dedicated node service account with only logWriter / metricWriter / monitoring.viewer / artifactregistry.reader, `workload_metadata_config.mode = GKE_METADATA`, shielded nodes, `deletion_protection = var.env == "prod"`.

**k3s VM (budget profile)** — Terraform creates only the VM, static IP, firewall (443 from Cloudflare ranges, nothing else public), and tags/labels `cb-ansible-role = k3s_server`. No `remote-exec`/`local-exec`: Ansible discovers the VM by tag and configures it (see cloudbridge-ansible-ops). No public SSH — AWS uses SSM (instance profile with `AmazonSSMManagedInstanceCore`), GCP uses IAP (firewall allows `35.235.240.0/20` on 22).

**Data services** — `prevent_destroy = true` on databases, caches and state buckets; DB passwords from `random_password` written straight to Secrets Manager / Secret Manager (outputs carry a `secret_ref`, never the password); Multi-AZ / regional HA only in prod.

**Labels/tags** — every resource gets `cb-cell`, `cb-cloud`, `cb-env`, `managed-by = terraform`. Use keys valid as GCP labels (lowercase, hyphen) so the cost ledger can join on them on both clouds.

## HCL hygiene that has already bitten this project

- A single-line block may hold **one** argument. `variable "x" { type = string, default = "a" }` is invalid; HCL has no semicolons. Write multi-argument blocks on multiple lines.
- `terraform fmt -check` and `terraform validate` on every stack; `.terraform.lock.hcl` committed and `init -lockfile=readonly` in CI.
- Don't reference module outputs that don't exist "for now" — the root in Rev 1 referenced `module.kubernetes_aws` that was never declared and could not plan.

## Contract test (keep it green on both engines)

`modules/cell/tests/contract.tftest.hcl` uses `mock_provider "aws" {}` and `mock_provider "google" {}` and `command = apply`, so it runs offline for free. It asserts: AWS and GCP (managed and budget) expose the same `cluster` keys; shapes are equal per size; `cloud = "azure"` is rejected (`expect_failures = [var.cloud]`). Add a run block whenever you add an implementation or an output key. CI runs it on Terraform 1.15 **and** OpenTofu 1.12.

## Workflows

**Add or change something in one implementation**
1. Change it in the AWS *and* GCP implementation in the same PR, or explain in the PR why only one cloud needs it and add a parity exception (cloudbridge-parity-contract).
2. Keep output keys identical; extend the contract test.
3. If the change leaks cloud-specific behaviour into consumers, add a row to `docs/leaky-abstractions.md`.

**Create a new cell** — `make new-cell CLOUD=gcp ENV=staging` copies `live/aws-prod` layout, sets `cloud` in `terraform.tfvars`, points the backend at the right bucket/prefix. The diff should be three short files.

**Add a third cloud (Azure)** — new implementations `network/azure`, `cluster/azure-aks`, `database/azure-flex-pg`, cache; add `"azure"` to the validation; extend shapes with matching sizes; pass the contract test; new rows in the leaky-abstraction register. Existing implementations must not change.

## Leaky abstractions to keep honest

Pod IAM (Pod Identity vs Workload Identity); ingress origin (ALB hostname known only after the controller runs vs GCLB static IP reserved up front — so the AWS managed origin comes from `20-bootstrap`); burstable CPU models; upgrade cadence (manual vs release channels); NetworkPolicy enablement (VPC CNI flag vs Dataplane V2); Postgres parameter groups vs flags; NAT pricing; tags vs labels charset; registry mirrors (ECR pull-through path prefix vs Artifact Registry remote repo hostname). When a user claims "no lock-in", answer with this list.

## Interview soundbites

- "Targeting a different cloud is a three-line tfvars change; the cloud-specific complexity lives behind a facade whose interface is contract-tested for ₹0."
- "One state per cloud, env and layer — a bad apply in AWS bootstrap can't touch GCP or the AWS VPC."
- "I pick versions by intersection: Kubernetes 1.36, Postgres 18 and Valkey 9 are the newest each cloud offers as a managed service."
