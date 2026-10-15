# Week 3: ephemeral managed cells (EKS / GKE)

The managed profile runs a cell on EKS or GKE instead of a k3s VM. In Week 3 it exists only as an
**ephemeral** cell: up to 8 hours for a demo or a test, then destroyed by the TTL reaper. Prod
managed cells with RDS / Cloud SQL come later. Their data services carry `prevent_destroy`, so the
facade refuses to give an expiring cell any (`managed_data = false` runs Postgres and Valkey
in-cluster instead).

**Done when:** `make managed-up CLOUD=gcp` yields a cluster whose nodes are all Ready, and the reaper
destroys it after its TTL.

## What it creates

| | GCP (`gcp-dev`) | AWS (`aws-dev`) |
|---|---|---|
| Cluster | Zonal GKE, REGULAR channel, Dataplane V2, private nodes, Workload Identity, shielded nodes | EKS 1.36, API auth mode (access entries only), STANDARD support, AL2023 nodes, Pod Identity |
| Nodes | 2 × `e2-medium` (autoscale to 3) | 2 × `t3.medium` (autoscale to 3) |
| Network | VPC + Cloud NAT | VPC + one NAT gateway |
| Image mirror | Artifact Registry remote repository for Docker Hub | ECR pull-through cache for Docker Hub |
| API access | Master authorized networks = your IP | Public endpoint limited to your IP; your IAM identity gets cluster-admin |
| Labels/tags | `cb-expires-at=<unix seconds>` on everything | same |

**Rough cost while running** (≈, confirm in the pricing calculators):
- GKE: one zonal cluster's management fee is covered by GKE's US$74.40/month credit, so you pay the
  nodes, NAT and disks, roughly US$0.10–0.15/hour, from the GCP trial credit.
- EKS: control plane US$0.10/hour plus nodes and a NAT gateway, roughly US$0.25–0.35/hour.
- An 8-hour session costs about one to three US dollars.
- AWS: check that your Free account plan allows EKS before relying on it (not verified). The plan
  can't bill you; if EKS isn't allowed, the apply simply fails.

## One-time prerequisites (on top of the Week 2 runbook)

GCP:
```bash
gcloud services enable container.googleapis.com artifactregistry.googleapis.com
```
Put the project ID in `infra/live/gcp-dev/10-foundation/terraform.tfvars`.

AWS: ECR's Docker Hub pull-through rule reads credentials from a secret whose name **must** start
with `ecr-pullthroughcache/`. Store it without a trailing newline:
```bash
read -rs PULL_TOKEN
jq -nc --arg u "$DOCKERHUB_USER" --arg t "$PULL_TOKEN" '{username: $u, accessToken: $t}' \
  | aws secretsmanager create-secret --region ap-south-1 --name ecr-pullthroughcache/cb-dockerhub \
      --secret-string file:///dev/stdin
unset PULL_TOKEN
```

Tools: rerun `bash tools/dev/install-deploy-tools.sh`. It now adds `kubectl` (1.36.5, checksum
verified) and `gke-gcloud-auth-plugin`.

## From the laptop

```bash
cd infra
make managed-up CLOUD=gcp TTL=4     # TTL 1-8 hours; plan, apply, then wait for nodes Ready
make managed-check CLOUD=gcp        # again later: nodes + time left
make managed-down CLOUD=gcp         # early teardown
make reap                           # destroy whatever has expired (what the hourly workflow runs)
```

`managed-up` only lets your current public IP reach the API endpoint. It writes credentials to
`~/.kube/cloudbridge-<cloud>-dev`, never `~/.kube/config`. Add `DOCKERHUB_USER=<id>` on GCP to
make the Artifact Registry mirror authenticate to Docker Hub with your `cb-dockerhub-pull` token.

## From GitHub (ephemeral-up.yml + ttl-reaper.yml)

1. Apply the CI identities once, with your own credentials. They create no static keys.
   `infra/live/global/00-ci-identity` contains:
   - an AWS OIDC provider and role `cb-ephemeral-aws`
   - a GCP Workload Identity pool and service account `cb-ephemeral-gcp`

   Both trust **only** `repo:Rajarshi1-source/Cloud_Bridge:environment:ephemeral`. State access is
   limited to the dev stacks.
   ```bash
   cd infra/live/global/00-ci-identity && terraform init && terraform apply
   ```
2. In GitHub, go to Settings → Environments → **ephemeral**:
   - **No required reviewers.** The hourly reaper runs in this environment and would otherwise wait
     forever for an approval.
   - Deployment branches: `main` only.
   - Variables `AWS_EPHEMERAL_ROLE`, `GCP_WIF_PROVIDER` and `GCP_EPHEMERAL_SA`, from the stack's outputs.
3. Run Actions → **ephemeral-up**: choose the cloud and TTL, and enter your IP as `/32`.
4. **ttl-reaper** runs at minute 17 of every hour. It reads each dev stack's `expires_at` from state, so
   it also reaps cells you brought up from the laptop. Until step 1 is done it only prints a notice;
   use `make reap` meanwhile.

## What's deferred to Week 4

The managed cells' `20-bootstrap` comes in Week 4, with:
- Argo CD and the root ApplicationSet, installed by Terraform
- the `cb-<cloud>-dev` and prod cell values
- AWS Load Balancer Controller and ALB / GCE ingress health checks
- External Secrets for the DB, cache and origin TLS Secrets

Those need the data layer and secret plumbing Week 4 builds. Week 3 already creates the IAM side
(Pod Identity roles for the ALB controller and the EBS CSI driver).
