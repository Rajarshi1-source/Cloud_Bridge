# Week 2 go-live: the public multi-cloud link

The repo side of Week 2 is merged and checked in CI. Nothing exists in AWS, GCP or Cloudflare yet. This
runbook takes you from zero accounts to `https://app.<domain>` answering from both clouds at 70/30.

Facts below were checked on 16 Oct 2026 against the providers' own pages (sources at the end). Prices
marked **≈** are estimates: confirm them in the AWS and Google pricing calculators before you sign up.

Rules that apply everywhere:
- Never paste a token or key into chat, a PR, a commit or a shell command line. Read it with `read -rs`.
- Budget alerts warn; they don't stop spending. On these free offers, the account plan is the cap.

---

## 1. Decide first: cost, credits and the clock

### What the budget cells create

From the repo (`infra/modules/cluster/k3s-vm-*`, `cell/shapes.tf`): per cloud, one 2 vCPU / 2 GiB VM
(AWS `t3.small`, GCP `e2-small`) with a 30 GB disk and one static public IPv4, plus a few secrets. No NAT
gateway, no managed database or cache, no EKS or GKE (those are Week 3's managed profile).

| Item | Price | Monthly, running 24/7 |
|---|---|---|
| AWS `t3.small` in `ap-south-1` | on-demand, per second | ≈ US$16 |
| AWS 30 GB gp3 + one public IPv4 (US$0.005/h) | | ≈ US$2.5 + US$3.65 |
| AWS Secrets Manager (2 secrets × US$0.40) | | US$0.80 |
| **AWS cell** | | **≈ US$23**, paid from credits |
| GCP `e2-small` in `asia-south1` + 30 GB pd-balanced + static IPv4 | | ≈ US$20–25 |
| GCP Secret Manager (2 secrets, 6 versions/month free) | | US$0 |
| **GCP cell** | | **≈ US$20–25**, paid from trial credit |
| Cloudflare Load Balancing add-on | "starting at US$5/mo" | **US$5, real money** |
| Cloudflare Free plan, DNS, Origin CA, Zero Trust Free (≤ 50 users) | | US$0 (Zero Trust still asks for a card) |
| Domain | registrar price | ≈ US$10–15/year for a `.com` |

### What the free offers actually cover

| Offer | Terms (verified) | What it means here |
|---|---|---|
| **AWS Free account plan** (accounts created on or after 15 Jul 2025) | US$100 credit at sign-up, up to US$100 more for activities. **No charges incur**. Ends after **6 months** or when credits run out; the account then closes, and content is kept 90 days before deletion. `t3.small` is free-tier eligible for these accounts. | The AWS cell runs about 4–8 months on credits. You can't be billed. |
| AWS Paid account plan | Same credits, then pay-as-you-go. | Choose it only when you mean to pay. |
| **GCP Free Trial** | US$300 credit for **90 days**. **Not billed** unless you upgrade. At the end, resources are stopped, then deleted after a 30-day grace period. No GPUs, no quota increases. | US$300 easily covers the GCP cell for 90 days (≈ US$70 used). **90 days is the binding limit.** |
| GCP Always Free | `e2-micro` and 5 GB Cloud Storage **only in `us-west1`, `us-central1`, `us-east1`**. Secret Manager: 6 versions, 10,000 accesses per month. | Doesn't cover Mumbai. CloudBridge needs 2 GiB per VM (an `e2-micro` has 1 GiB) and runs in `asia-south1`, so the trial credit pays instead. |
| GKE free tier (Week 3) | US$74.40/month credit = one zonal or Autopilot cluster's US$0.10/h management fee. Nodes, disks and networking are extra. | Week 3's ephemeral GKE clusters cost only their nodes. |

**The clocks start at sign-up, not at first deploy.** Create both cloud accounts in the same week you run
`make budget-up`. Week 3's managed profile needs the same accounts, so finish Weeks 3–8 inside GCP's
90 days, or upgrade GCP to a paid account before it closes.

India-specific (not confirmed in official docs; check during sign-up):
- AWS accounts with an Indian address are contracted with AISPL. Confirm the **Free plan** option
  appears. If it doesn't, the budget alerts are your only guard.
- Use a card with international/online transactions enabled. RBI e-mandate rules can decline recurring
  charges. A small verification hold may appear and is reversed.

### Traffic routing: the paid add-on is the right call

| Option | Cost | Fits CloudBridge? |
|---|---|---|
| **A. Cloudflare Load Balancing** (what the repo builds) | US$5/month | **Yes.** Pool weights (70/30), `/healthz/cell` monitor, cookie affinity, fallback pool, drain. The parity, steering, evacuation and break-glass work in Weeks 6–8 all build on its pool weights. |
| B. Two proxied DNS records (round-robin) | US$0 | **No.** Cloudflare does retry another origin when one fails, but there's no weighting (no 70/30), no active health check, and **no session affinity**. Each cell owns its database, so a user who creates an order on AWS and refreshes onto GCP sees it "disappear". |
| C. A Cloudflare Worker as the router | US$0 (100,000 requests/day, 10 ms CPU per request) | **Possible, but it's new code:** weights, affinity cookie, retry, health state via Cron Triggers. It also replaces `30-traffic` and everything built on pool weights. Reconsider only if US$5/month is a hard no. |
| D. Local simulation (compose + a local proxy) | US$0 | For development only. No public link, and it proves nothing about AWS or GCP. |

### Decision

| If… | Do this |
|---|---|
| You can spend about US$5/month plus a domain | **Recommended:** AWS Free plan + GCP Free Trial + Cloudflare Free with the Load Balancing add-on. You run the real architecture, can't be billed by either cloud, and pay only Cloudflare and the domain. Go live now, then start Week 3. |
| You must spend nothing yet | Start Week 3 offline (it needs no accounts) and **don't sign up** for AWS or GCP yet, so their clocks don't start. Come back to this runbook later. |
| US$5/month is permanently out | Plan option C (Worker router) as its own piece of work before going live. Don't hand-edit `30-traffic`. |

---

## 2. Cloudflare

1. **Domain.** Buy one, or use one you own. Add it as a zone (Free plan), keep any existing DNS records
   (email!), set the registrar's nameservers to Cloudflare's, and wait for **Active**.
2. **Load Balancing.** Load Balancing → Enable. This needs a billing profile and is billed monthly.
3. **Zero Trust organization** (needed for the admin hosts' Access app; missing from the first draft
   of this runbook):
   1. Dashboard → Zero Trust → pick a **team name** and the **Free** plan.
   2. Enter payment details. Cloudflare says you won't be charged on Free, but onboarding requires them.
   3. Write the team name down. Week 4 validates Access JWTs against `https://<team>.cloudflareaccess.com`.
4. **Repo values** (IDs aren't secrets; commit them):
   - `gitops/global/values.yaml` → `domain: <your domain>` (Terraform reads it too).
   - `infra/live/global/30-traffic/terraform.tfvars.json` → `zone_id` and `account_id` from the zone's
     Overview page.
5. **API token** (My Profile → API Tokens → Custom token), limited to this zone and account:
   - Zone: Load Balancers Edit, DNS Edit, Zone Settings Edit, SSL and Certificates Edit
   - Account: Load Balancing: Monitors and Pools Edit, Access: Apps and Policies Edit, Access: Service Tokens Edit

## 3. AWS (`ap-south-1`, Mumbai)

1. Sign up at aws.amazon.com/free. Choose the **Free account plan** and confirm it under Billing →
   Free Tier. Watch the credit balance and the plan's end date there. **Don't create an AWS
   Organization or enable IAM Identity Center**: joining Organizations automatically upgrades a Free plan
   account to Paid.
2. Billing → Budgets: a monthly cost budget with alerts at 50 / 80 / 100%.
3. For the CLI, create an IAM user (not root keys) with MFA and an access key, then run
   `aws configure` in WSL. Week 5's CI identities replace this key; delete it then.
4. State bucket. S3 names are global, so pick a unique one now and rename every reference
   (run the rename once: the new name still contains the old one):
   ```bash
   B=cb-tfstate-aws-<something-unique>
   git grep -l cb-tfstate-aws | xargs sed -i "s/cb-tfstate-aws/$B/g"
   aws s3api create-bucket --bucket "$B" --region ap-south-1 --create-bucket-configuration LocationConstraint=ap-south-1
   aws s3api put-bucket-versioning --bucket "$B" --versioning-configuration Status=Enabled
   aws s3api put-public-access-block --bucket "$B" --public-access-block-configuration \
     BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
   ```
   S3 encrypts new objects by default (SSE-S3); the backend also sets `encrypt = true`.
5. Docker Hub pull token: Docker Hub → Personal access tokens → a **read-only** token (the repos are
   public, so *Public Repo Read-only* is enough). It's separate from CI's read/write token. Store it
   **without a trailing newline**. The first draft's `--secret-string file:///dev/stdin` plus Ctrl-D
   stored the newline too, which would break the k3s registry login:
   ```bash
   read -rs PULL_TOKEN
   printf %s "$PULL_TOKEN" | aws secretsmanager create-secret --region ap-south-1 \
     --name cb/dockerhub-pull --secret-string file:///dev/stdin
   ```
   Keep `PULL_TOKEN` set for the GCP step, then `unset PULL_TOKEN`.

## 4. Google Cloud (`asia-south1`, Mumbai)

1. Start the **Free Trial** at console.cloud.google.com. Don't upgrade to a paid account while you're
   learning. Create a project and note its **ID** (not the display name).
2. Billing → Budgets & alerts: a budget for the project, alerts at 50 / 80 / 100%.
3. CLI auth for both gcloud and Terraform/Ansible (Application Default Credentials):
   ```bash
   gcloud auth login && gcloud auth application-default login
   gcloud config set project <project-id>
   gcloud services enable compute.googleapis.com iam.googleapis.com secretmanager.googleapis.com \
     iap.googleapis.com cloudresourcemanager.googleapis.com
   ```
   The first draft listed only three APIs. The budget VM also creates a service account, which needs
   the IAM API.
4. Put the project ID in `infra/live/gcp-budget/10-foundation/terraform.tfvars` and
   `infra/live/global/20-origin-tls/terraform.tfvars`.
5. State bucket (global names again: pick a unique one and rename it like the AWS bucket, once):
   ```bash
   G=cb-tfstate-gcp-<something-unique>
   git grep -l cb-tfstate-gcp | xargs sed -i "s/cb-tfstate-gcp/$G/g"
   gcloud storage buckets create "gs://$G" --location=asia-south1 --uniform-bucket-level-access --public-access-prevention
   gcloud storage buckets update "gs://$G" --versioning
   ```
6. Pull token, no trailing newline (still from `PULL_TOKEN`):
   ```bash
   printf %s "$PULL_TOKEN" | gcloud secrets create cb-dockerhub-pull --replication-policy=automatic --data-file=-
   unset PULL_TOKEN
   ```
7. SSH over IAP for whoever runs Ansible: `roles/iap.tunnelResourceAccessor`, `roles/compute.osAdminLogin`
   and **`roles/iam.serviceAccountUser`**. The budget VM runs as a service account, and OS Login refuses
   SSH without that last role (missing from the first draft). A project Owner already has all three.

## 5. The operator machine (WSL)

1. **Tools.** Nothing that `make budget-up` calls was installed in WSL: make, jq, terraform, ansible,
   aws, the Session Manager plugin and gcloud. The checks so far ran in containers. One script installs
   them all, pinned and integrity-checked: Terraform against its SHA256SUMS, the AWS CLI and
   Session Manager plugin against AWS's GPG signatures (keys in `tools/dev/keys/`), gcloud from Google's
   signed apt repository. It was tested on a clean Ubuntu 26.04, including refusing a bad signature:
   ```bash
   bash tools/dev/install-deploy-tools.sh
   source ~/.venvs/cloudbridge/bin/activate     # in every shell that deploys
   ```
2. **The Cloudflare provider on this network.** `release-assets.githubusercontent.com` is unreachable
   here, and the Cloudflare Terraform provider is published there. So `make origin-tls` and `make traffic`
   can't download it, while the AWS and Google providers come from HashiCorp and work. Fix, once:
   ```bash
   gh workflow run provider-mirror.yml        # GitHub's runner downloads the provider
   bash tools/dev/use-provider-mirror.sh      # fetches the artifact, points ~/.terraformrc at it
   ```
   The lock file's `h1:` hashes still verify the package. On a network without the block, skip this.
3. **Environment** for the deploy shell:
   ```bash
   export CB_HOSTNAME=app.<domain> DOCKERHUB_USER=<docker id> \
          GCP_PROJECT_ID=<project-id> GCP_OSLOGIN_USER=<your OS Login user>
   read -rs CLOUDFLARE_API_TOKEN && export CLOUDFLARE_API_TOKEN
   ```
   Your OS Login username is shown by `gcloud compute os-login describe-profile`.
   `CB_SSM_BUCKET` is no longer yours to export: the first draft asked for it "after the AWS apply",
   but `budget-up` applies AWS and runs Ansible in one go. `make configure` now reads it from the AWS
   foundation's output, and also sets `ANSIBLE_CONFIG`. Ansible ignores an `ansible.cfg` in a
   world-writable directory, and every `/mnt/<drive>` path in WSL is one.

## 6. Bring it up

Merge the domain, IDs and bucket renames through a PR first (`main` is protected): Argo CD reads values
from `main`, not from your disk.

```bash
cd infra
make -n budget-up      # read what will run
make budget-up
```

Terraform prints each plan before applying it; read the AWS and GCP plans before you confirm. In order:
1. Both foundations: the VMs, static IPs, and firewalls admitting 443 only from Cloudflare.
2. `global/20-origin-tls`: the Origin CA certificate, stored in both secret managers.
3. `make configure` (Ansible): hardening, k3s, the registry token, cell secrets, origin TLS and
   Argo CD. It then waits until each origin answers `/healthz/cell` locally.
4. `global/30-traffic`: monitor, pools, the 70/30 load balancer, admin records and Access.

The first Argo CD sync pulls four charts and three images onto a 2 GiB VM: allow 5–10 minutes.

## 7. Done when

```bash
for i in $(seq 1 40); do
  curl -s -o /dev/null -D - "https://app.<domain>/healthz/cell" | grep -i '^x-cb-cell'
done | sort | uniq -c
```
- Both `cb-aws-budget` and `cb-gcp-budget` appear, roughly 70/30. Forty requests is a small sample, so
  expect deviation.
- Each `curl` is a new session with no affinity cookie. A browser keeps its cookie and stays on one cell,
  as intended.
- `curl -sI https://admin-aws.<domain>/admin/leases/report` returns **401** from Cloudflare Access.
- A request straight to an origin IP times out (443 admits Cloudflare only). Don't loosen the firewall to
  test this.

## 8. Stop the spend, and the end dates

- `make budget-down` destroys the traffic stack, then both cells. It keeps the state buckets, secrets and
  origin certificate, so `make budget-up` rebuilds everything. The budget Postgres lives on the VM disk,
  so demo data is lost.
- Stopping a VM is not enough: disks and static IPs still bill.
- Two weeks before GCP's day 90 or AWS's month 6, decide whether to upgrade or tear down. Once a trial or
  Free plan closes, the resources stop and the Terraform state no longer matches reality.

## Corrections to the earlier drafts

Draft guides compared on 16 Oct 2026; what was wrong or missing:

| Draft said | Correct |
|---|---|
| Round-robin DNS as a free substitute for the load balancer | It has no weights, no health checks and **no affinity**: unusable with per-cell databases (§1). |
| "Lightsail 2 GB at US$12/month" as the cost reference | Not what the repo builds. It's EC2 `t3.small` + gp3 + public IPv4 (≈ US$23/month on credits). |
| AWS Free plan: "check whether EC2 is eligible" | `t3.small` is free-tier eligible for accounts created on or after 15 Jul 2025. The Free plan can't bill you. AWS Organizations (and IAM Identity Center, which needs it) upgrades it to Paid. |
| Cloudflare steps without Zero Trust | The traffic stack creates an Access app, policy and service token: set up a Zero Trust org (Free plan, card on file) first. |
| `--secret-string file:///dev/stdin` then paste + Ctrl-D | Stores a trailing newline in the pull token. Use `read -rs` + `printf %s`. |
| GCP: three APIs; roles `iap.tunnelResourceAccessor` + `compute.osAdminLogin` | Also the IAM and Resource Manager APIs, and `iam.serviceAccountUser` (the VM has a service account). |
| Check the tools with `terraform version`, `tofu version`… | None were installed. OpenTofu isn't needed to deploy; `make` and `jq` were missing too. Use `tools/dev/install-deploy-tools.sh`. |
| Export `CB_SSM_BUCKET` after the AWS apply, then run `make budget-up` | Impossible mid-command. `make configure` derives it, and sets `ANSIBLE_CONFIG` for WSL. |
| (not covered) | This network can't download the Cloudflare provider: use the provider mirror (§5). |
| State bucket names `cb-tfstate-aws` / `cb-tfstate-gcp` | Global namespaces: pick unique names up front and rename every reference. |
| GCP trial end: "resources are stopped" | …then **deleted after a 30-day grace period** unless you upgrade. |
| "First 500,000 Load Balancing DNS queries included" | Unverified, and irrelevant here: the load balancer is proxied, so steering happens per request at the edge, not per DNS query. |

Confirmed as stated in the drafts:
- AWS: US$100 + up to US$100 credits, 6 months, 90-day retention.
- GCP: US$300 for 90 days; Always Free is US-only.
- GKE: US$74.40/month credit, US$0.10 per cluster-hour.
- Cloudflare: Load Balancing from US$5/month with a billing profile; Workers free tier 100,000 requests/day and 10 ms CPU.

## Known limits

- The 2 GiB budget VMs are a tight fit. If a pod stays Pending, check `kubectl describe` before raising
  requests; the budget overrides are in `gitops/cells/<cell>/values.yaml`.
- `t3.small` runs in "unlimited" burst mode by default. Sustained CPU above its baseline costs extra,
  paid from credits on the Free plan.
- Canary analysis is off until the in-cell Prometheus exists (Week 5).
- `ci-app.yml` opens a release PR for every `main` build. Add a `CB_BOT_TOKEN` secret, or close and
  reopen each release PR once so `ci-gate` runs.

## Sources

- [AWS Free Tier plans](https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/free-tier-plans.html) · [EC2 free-tier eligible types](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-free-tier-usage.html) · [Supported services, new sign-up](https://docs.aws.amazon.com/accounts/latest/reference/supported-services-sign-up-new.html) · [Public IPv4 charge](https://aws.amazon.com/blogs/aws/new-aws-public-ipv4-address-charge-public-ip-insights) · [Secrets Manager pricing](https://aws.amazon.com/secrets-manager/pricing/)
- [Google Cloud free features and trial](https://docs.cloud.google.com/free/docs/free-cloud-features) · [GKE pricing](https://cloud.google.com/kubernetes-engine/pricing) · [Free Trial FAQ](https://cloud.google.com/signup-faqs)
- [Cloudflare plans: Load Balancing](https://www.cloudflare.com/plans/network-cdn/) · [Enable Load Balancing](https://developers.cloudflare.com/load-balancing/get-started/enable-load-balancing/) · [Round-robin DNS](https://developers.cloudflare.com/dns/manage-dns-records/how-to/round-robin-dns/) · [Workers limits](https://developers.cloudflare.com/workers/platform/limits/) · [Zero Trust setup](https://developers.cloudflare.com/cloudflare-one/setup/)
