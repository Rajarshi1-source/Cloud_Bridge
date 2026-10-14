---
name: cloudbridge-gitops-delivery
description: Ship CloudBridge's Spring Boot services to both clouds - Dockerfiles, docker-compose for local dev, the GitHub Actions app pipeline (build, Trivy scan, cosign keyless sign, push to Docker Hub by digest), ECR pull-through and Artifact Registry remote mirrors, one Argo CD per cell with the root ApplicationSet, Helm charts (probes, HPA sized for evacuation, PDB, spread, NetworkPolicy, restricted security), Argo Rollouts canary analysis, and cloud-as-canary-ring promotion (GCP ring-canary, then AWS ring-main). Use for ANY work under gitops/, service Dockerfiles, docker-compose.yml, ci-app.yml or ring-promote.yml, or when the user asks how a release reaches EKS, GKE or the EC2/GCE k3s cells, how to roll back, or why Argo CD instead of helm upgrade. MANDATE - one owner per object (Terraform installs only Argo CD), images pulled by digest through mirrors, releases go to one cloud at a time. Not for Terraform infra (terraform-cells) or IaC pipelines (iac-pipeline).
---

# CloudBridge — GitOps Delivery

Two invariants make multi-cloud delivery safe:
1. **One owner per object.** Rev 1 had Terraform `helm_release` *and* a `helm upgrade` step managing the same releases; they overwrote each other and Terraform reported drift forever. Now Terraform (managed cells) or Ansible (budget cells) installs only Argo CD and the root ApplicationSet; Argo CD owns everything else.
2. **One cloud at a time.** Multi-cloud protects against a provider failure, not against your own bad deploy, which would reach both clouds at once. Releases go to the GCP cell (smaller, 30% of users) first, soak, then AWS.

Full files — compose, Dockerfile, chart templates, AnalysisTemplate, ApplicationSet template, `bump_ring.py`, `ci-app.yml`, `ring-promote.yml` — are in `references/starter-code.md`.

## Versions

| Component | Pin |
|---|---|
| Spring Boot / Java / build | 4.1.x (floating patch) / Java 21 / Maven wrapper |
| Base images | `eclipse-temurin:21-jdk` build → `eclipse-temurin:21-jre` run |
| Postgres / Valkey (compose + budget in-cluster) | `postgres:18.4-alpine` / `valkey/valkey:9.0-alpine` |
| Argo CD | 3.3.x — upgrades require Server-Side Apply (`ServerSideApply=true`) because the ApplicationSet CRD exceeds client-side annotation limits |
| Argo Rollouts, Helm | Helm 4.2.x; Rollouts pinned in `platform-addons` chart — verify current on build day |
| Prometheus / Grafana images in compose | `v3.14.0` / `13.2.0`, never `:latest` |

## Repository shape

```
gitops/bootstrap/applicationset.yaml.tftpl   one template, rendered per cell by Terraform templatefile()
                                             (managed) or Ansible with ${ } delimiters (budget)
gitops/charts/{api-gateway,order-service,inventory-service,platform-addons}/
gitops/cells/<cell>/values.yaml              the ONLY per-cloud app config (ingress class, mirror prefix, secret store)
gitops/releases/ring-canary.yaml             image digests — GCP cell reads this
gitops/releases/ring-main.yaml               image digests — AWS cell reads this
```

Per-cell values may differ only in: `cell`, `cloud`, `ingress.className` + annotations (`alb` on EKS, `gce` on GKE, `traefik` on k3s), `imageRegistryMirror`, `secretStore`, and replica floors for the budget profile. Anything else that differs is parity drift (see cloudbridge-parity-contract).

## Images

- Build with layered jars (`java -Djarmode=tools -jar app.jar extract --layers --launcher`), non-root UID 10001, `-XX:MaxRAMPercentage=70 -XX:+ExitOnOutOfMemoryError`. Code-only changes ship a tiny layer — faster pulls during an evacuation scale-up.
- Push to Docker Hub tagged with the commit SHA; **reference by digest everywhere** (`@sha256:…`). A tag can move; a digest is exactly what was scanned and signed. The parity checker compares digests across cells.
- Trivy scan (fail on HIGH/CRITICAL with a fix available), SBOM + provenance from buildx, `cosign sign` keyless via GitHub OIDC.
- Pods pull through mirrors, never Docker Hub directly: ECR pull-through cache rule (`<acct>.dkr.ecr.ap-south-1.amazonaws.com/dockerhub/<you>/cb-…@sha256`), Artifact Registry remote repository (`asia-south1-docker.pkg.dev/<project>/dockerhub/<you>/cb-…@sha256`), k3s `registries.yaml` with an authenticated Docker Hub token. Rate limits and a third-party outage must not sit in the pod-start path during a scale-up.

The brief's "GitHub Actions → Docker Hub → EC2" path exists: the AWS budget cell is an EC2 instance and receives releases through Argo CD — pull-based GitOps, not SSH-and-restart. Say that explicitly in interviews.

## Chart essentials (every service)

| Concern | Setting | Reason |
|---|---|---|
| Probes | `startupProbe` liveness path, 30 × 2 s; `livenessProbe` `/actuator/health/liveness`; `readinessProbe` `/actuator/health/readiness` | JVM start on small nodes takes 15–25 s; liveness must not kill a starting pod |
| HPA | CPU 65% + request rate; `minReplicas` 2 managed / 1 budget; **`maxReplicas = ceil(1.2 × peak_gateway_rps_all_cells × fanout / per_pod_rps)`** so this cell can take 100% of traffic (show the arithmetic in the PR; if per-pod RPS isn't measured yet, say so and leave a TODO, don't invent it); always ship the `ignoreDifferences` entry for `/spec/minReplicas` in the ApplicationSet template, and show that YAML snippet whenever pre-warm or HPA is discussed — never just assert it exists | Evacuation capacity is reviewed like code; pre-warm overrides mins without Argo reverting them |
| PDB | `minAvailable: 1` | GKE auto-upgrades and node drains can't take a service to zero |
| Spread | zone `topologySpreadConstraints`, `ScheduleAnyway` | Zone loss inside a cell |
| Security | non-root, `readOnlyRootFilesystem`, drop ALL, `seccompProfile: RuntimeDefault`, `automountServiceAccountToken: false` unless needed | Same restricted posture on all clouds |
| NetworkPolicy | default-deny in `cb-app`; explicit allows | Enforced by Dataplane V2 (GKE), VPC CNI network policy (EKS), k3s built-in controller |
| Rollout | Argo Rollouts canary 10 → 50 → 100 with `AnalysisTemplate` (error rate < 1%, p95 < 300 ms over 5 m) | In-cell progressive delivery |
| Resources | Start: gateway 200m/320Mi, order 300m/448Mi, inventory 200m/384Mi requests | Replace with k6-measured numbers; record per-pod RPS in `gitops/cells/<cell>/capacity.yaml` for the capacity check |

## Release flow (cloud as canary ring)

```
merge services/** → build, test (Testcontainers), push, scan, sign → digests artifact
  → bot PR: releases/ring-canary.yaml (labels: release, ring-canary)
  → merge → Argo CD in GCP cell syncs → Rollouts canary with analysis
  → ring-promote.yml: after Rollout Healthy + 30 min soak + burn < 1 + p95 within 10% of AWS
  → bot PR: copy digests to releases/ring-main.yaml → merge → AWS cell syncs
```

Rollback = `git revert` of the ring file; Argo syncs the previous digest. The parity contract allows a `ring-window` exception for at most 2 hours, so a stuck canary becomes a CI failure rather than a silent split-brain release.

Database migrations follow **expand → migrate → contract** (Flyway). Two cells run adjacent versions for up to two hours, so every migration must be backward compatible with the previous app version; contract steps ship only after both rings run the new code.

## docker-compose (local)

Whole system on a laptop: three services, Postgres 18, Valkey 9, control-plane API with `COST_SOURCE=fixtures` (replays sample FOCUS files, no cloud credentials), dashboard, Prometheus with the remote-write receiver, Grafana, and a `k6` service behind the `load` profile. No top-level `version:` key (obsolete in the Compose spec). Note PG18 images mount data at `/var/lib/postgresql` (version-specific subdirectory layout) — verify the volume path on build day.

## Argo CD placement

One Argo CD per cell, each pulling from Git. A hub Argo CD would need cluster-admin credentials for both clouds and become a cross-cloud single point of failure. The cross-cell view comes from the parity checker, not from a hub.

## When asked to…

| Request | Do |
|---|---|
| "Deploy to prod" | Merge the ring PRs; never `kubectl apply` or `helm upgrade` by hand |
| "Hotfix only AWS" / "helm upgrade by hand" | Push back twice: a manual `helm upgrade` creates a second owner that Argo will revert (or fight), and a hotfix on one cloud is a **cross-cloud parity divergence** the nightly parity check will fail on. If truly urgent: ring-main PR + a parity exception with an expiry |
| "Use :latest" | No — digests only |
| "Add a service" | New chart from the template, add to ApplicationSet list generator, add to `bump_ring.py`, add to parity `images.digests`, add capacity entry |
| "Speed up the pipeline" | Cache Maven via setup-java, buildx GHA cache, keep matrix per service |

## Interview soundbites

- "My smaller cloud is my canary — multi-cloud doesn't protect you from yourself; staged rollout across clouds does."
- "Terraform installs Argo CD and nothing else in the cluster. One owner per object."
- "Everything is pulled by digest through each cloud's registry cache — Docker Hub is where I publish, not where production pulls from."
