# Week 2 go-live: the public multi-cloud link

Everything in the repo is checked offline in CI. This runbook covers the parts only an account owner
can do, in order. When it's done, `https://app.<domain>` answers from both clouds at 70/30.

Never paste a token or key into chat, a PR or a commit. Each step below reads secrets from a prompt
or a file.

## 1. Cloudflare

1. Add your domain as a zone, switch its nameservers to Cloudflare, and wait for **Active**.
2. Enable the **Load Balancing** add-on (paid; about US$5/month for two origins).
3. Put the domain in `gitops/global/values.yaml` (`domain:`). Terraform and the Helm charts both read
   it from there.
4. Put the zone ID and account ID (from the zone's Overview page) in
   `infra/live/global/30-traffic/terraform.tfvars.json`. IDs aren't secrets; tokens are.
5. Create an API token scoped to this zone and account:
   - Zone: Load Balancers Edit, DNS Edit, Zone Settings Edit, SSL and Certificates Edit
   - Account: Load Balancing: Monitors And Pools Edit, Access: Apps and Policies Edit,
     Access: Service Tokens Edit

   Export it only in the shell that runs Terraform: `read -rs CLOUDFLARE_API_TOKEN && export CLOUDFLARE_API_TOKEN`.

## 2. AWS (ap-south-1)

1. Create a budget with alerts at 50 / 80 / 100%.
2. Create the state bucket `cb-tfstate-aws` with versioning, SSE and Block Public Access on. Bucket
   names are global: if it's taken, pick another and replace `cb-tfstate-aws` everywhere
   (`git grep cb-tfstate-aws`).
3. Store the Docker Hub **read-only** pull token (Docker Hub → Personal access tokens → Read-only):
   `aws secretsmanager create-secret --region ap-south-1 --name cb/dockerhub-pull --secret-string file:///dev/stdin`
   (paste, then Ctrl-D).

## 3. GCP (asia-south1)

1. Create a project with a billing budget and alerts. Enable the Compute Engine, Secret Manager and
   IAP APIs.
2. Put the project ID in `infra/live/gcp-budget/10-foundation/terraform.tfvars` and
   `infra/live/global/20-origin-tls/terraform.tfvars`.
3. Create the state bucket `cb-tfstate-gcp` (asia-south1, uniform access, versioning). If the name is
   taken, rename it the same way as the AWS bucket.
4. Store the same pull token: `gcloud secrets create cb-dockerhub-pull --data-file=-`.
5. Give whoever runs Ansible `roles/iap.tunnelResourceAccessor` and `roles/compute.osAdminLogin`.

## 4. Bring it up

From WSL, with AWS and GCP credentials, the Cloudflare token and these variables exported:

| Variable | Value |
|---|---|
| `CB_HOSTNAME` | `app.<domain>` |
| `DOCKERHUB_USER` | your Docker ID |
| `GCP_PROJECT_ID`, `GCP_OSLOGIN_USER` | the project, and your OS Login username |
| `CB_SSM_BUCKET` | after the AWS apply: `terraform -chdir=live/aws-budget/10-foundation output -json cluster \| jq -r .auth.transfer_bucket` |

The controller also needs ansible-core 2.21 with `ansible-galaxy collection install -r ansible/requirements.yml`,
`boto3`, the AWS Session Manager plugin and `gcloud`.

```bash
cd infra && make budget-up
```

That runs, in order:
1. Both foundations (VMs, static IPs, firewalls that only admit 443 from Cloudflare).
2. `global/20-origin-tls`: the Origin CA certificate, stored in both secret managers.
3. `ansible/playbooks/site.yml`: hardening, k3s, the registry token, the cell secrets, origin TLS and
   Argo CD. It then waits until each origin answers `/healthz/cell` locally.
4. `global/30-traffic`: monitor, pools, the 70/30 load balancer, admin records and Access.

The first Argo CD sync pulls four charts and three images onto a 2 GiB VM; allow 5–10 minutes.

## 5. Done when

```bash
for i in $(seq 1 40); do
  curl -s -o /dev/null -D - "https://app.<domain>/healthz/cell" | grep -i '^x-cb-cell'
done | sort | uniq -c
```

The output shows both `cb-aws-budget` and `cb-gcp-budget`, roughly 70/30. Each `curl` starts a new
session (no affinity cookie), so the split shows up. A browser keeps its cookie and sticks to one
cell, which is the point: each cell owns its database.

Also check:
- `curl -sI https://admin-aws.<domain>/admin/leases/report` returns 401 from Cloudflare Access.
- Hitting an origin IP directly times out (the firewall only admits Cloudflare).

## Known limits

- The 2 GiB budget VMs are a tight fit. If a pod stays Pending, check `kubectl describe` for
  memory pressure before raising requests: the budget overrides live in `gitops/cells/<cell>/values.yaml`.
- Canary analysis is off until the in-cell Prometheus exists (Week 5); canaries pause instead.
- `ci-app.yml` opens a release PR for every `main` build. Add a `CB_BOT_TOKEN` secret, or close and
  reopen each release PR once so `ci-gate` runs.
