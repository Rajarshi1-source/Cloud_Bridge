# CloudBridge infra. Stacks: live/<cloud>-<env>/<layer> and live/global/<layer>; one state, backend
# and CI identity each. No local Terraform? `bash ../tools/dev/iac-check.sh` runs fmt/validate/test
# in containers.
CLOUD ?= aws
ENV   ?= budget
LAYER ?= 10-foundation
STACK  = live/$(CLOUD)-$(ENV)/$(LAYER)

.PHONY: fmt test test-tofu plan apply destroy origin-tls traffic configure budget-up budget-down managed-up managed-bootstrap managed-check managed-down reap

fmt:
	terraform fmt -recursive -check

test:
	cd modules/cell && terraform init -backend=false -input=false && terraform test
	cd live/aws-budget/10-foundation && terraform init -backend=false -input=false && terraform test
	cd live/gcp-budget/10-foundation && terraform init -backend=false -input=false && terraform test
	cd live/global/20-origin-tls && terraform init -backend=false -input=false && terraform test
	cd live/global/30-traffic && terraform init -backend=false -input=false && terraform test
	cd live/aws-dev/10-foundation && terraform init -backend=false -input=false && terraform test
	cd live/gcp-dev/10-foundation && terraform init -backend=false -input=false && terraform test
	cd live/aws-dev/20-bootstrap && terraform init -backend=false -input=false && terraform test
	cd live/gcp-dev/20-bootstrap && terraform init -backend=false -input=false && terraform test
	cd live/global/00-ci-identity && terraform init -backend=false -input=false && terraform test

test-tofu:
	cd modules/cell && tofu init -backend=false -input=false && tofu test

plan:
	cd $(STACK) && terraform init -input=false && terraform plan -input=false -out=tfplan

apply:
	cd $(STACK) && terraform apply -input=false tfplan

destroy:
	cd $(STACK) && terraform init -input=false && terraform destroy -input=false

# Cloudflare Origin CA certificate → both clouds' secret managers (rarely re-applied).
origin-tls:
	cd live/global/20-origin-tls && terraform init -input=false && terraform plan -input=false -out=tfplan \
	  && terraform apply -input=false tfplan

# Load balancer, monitor, pools, admin records, Access. Weights live in terraform.tfvars.json.
traffic:
	cd live/global/30-traffic && terraform init -input=false && terraform plan -input=false -out=tfplan \
	  && terraform apply -input=false tfplan

# Ansible on the budget VMs. ANSIBLE_CONFIG is explicit because Ansible ignores an ansible.cfg in a
# world-writable directory, which every /mnt/<drive> path in WSL is. The SSM transfer bucket and the
# Access values are outputs of other stacks, so they are read here rather than exported by hand.
# Only CF_ACCESS_TEAM_DOMAIN (https://<team>.cloudflareaccess.com) comes from the environment.
configure:
	cd ../ansible && ANSIBLE_CONFIG=$(CURDIR)/../ansible/ansible.cfg \
	  CB_SSM_BUCKET=$$(terraform -chdir=$(CURDIR)/live/aws-budget/10-foundation output -json cluster | jq -r .auth.transfer_bucket) \
	  CF_ACCESS_AUD=$$(terraform -chdir=$(CURDIR)/live/global/30-traffic output -raw admin_access_aud) \
	  CF_ACCESS_ALLOWED_CLIENT_IDS=$$(terraform -chdir=$(CURDIR)/live/global/30-traffic output -raw allocator_client_id) \
	  ansible-playbook playbooks/site.yml

# Order matters: VMs (origins) → certificate → Cloudflare (Access audience, which the cells validate;
# the site answers 503 until the cells are up) → Ansible (k3s, secrets, Argo CD).
# Needs AWS + GCP + Cloudflare credentials and the state buckets (docs/runbooks/week-2-go-live.md).
budget-up:
	$(MAKE) plan apply CLOUD=aws ENV=budget
	$(MAKE) plan apply CLOUD=gcp ENV=budget
	$(MAKE) origin-tls
	$(MAKE) traffic
	$(MAKE) configure

# Stop the spend between demos: Cloudflare first (no traffic to dead origins), then both cells.
# Keeps the state buckets, the secrets and the origin certificate, so budget-up works again.
# The budget Postgres lives on the VM disk: its data is gone after this (demo data only).
budget-down:
	cd live/global/30-traffic && terraform init -input=false && terraform destroy -input=false
	$(MAKE) destroy CLOUD=gcp ENV=budget
	$(MAKE) destroy CLOUD=aws ENV=budget

# ---- Ephemeral managed cells (EKS / GKE) for demos: at most 8 hours, then reaped ----
# make managed-up CLOUD=gcp TTL=4    TTL in hours, 1-8. The API endpoint admits only this machine's
# public IP. AWS also gives the caller's IAM identity cluster-admin (access entries, no aws-auth).
TTL ?= 4
DEV = live/$(CLOUD)-dev/10-foundation

managed-up:
	@[ "$(TTL)" -ge 1 ] 2>/dev/null && [ "$(TTL)" -le 8 ] || { echo "TTL must be 1-8 hours"; exit 1; }
	cd $(DEV) && terraform init -input=false && \
	  TF_VAR_expires_at=$$(( $$(date -u +%s) + $(TTL) * 3600 )) \
	  TF_VAR_admin_cidrs="[\"$$(curl -fsS https://checkip.amazonaws.com)/32\"]" \
	  $(if $(filter aws,$(CLOUD)),TF_VAR_admin_principal_arns="[\"$$(aws sts get-caller-identity --query Arn --output text)\"]") \
	  $(if $(DOCKERHUB_USER),TF_VAR_dockerhub_user=$(DOCKERHUB_USER)) \
	  terraform plan -input=false -out=tfplan && terraform apply -input=false tfplan
	$(MAKE) managed-check CLOUD=$(CLOUD)

# Week 3's "done when": every node Ready. Credentials go to their own kubeconfig, not ~/.kube/config.
managed-bootstrap:
	$(MAKE) plan apply CLOUD=$(CLOUD) ENV=dev LAYER=20-bootstrap

managed-check:
	bash ../tools/dev/managed-check.sh $(CLOUD)

managed-down:
	cd $(DEV) && terraform init -input=false && \
	  TF_VAR_expires_at=0000000000 TF_VAR_admin_cidrs='["192.0.2.1/32"]' terraform destroy -input=false

# What ttl-reaper.yml runs hourly; run it by hand when CI identities aren't set up yet.
reap:
	bash ../tools/dev/reap-expired.sh $(or $(CLOUDS),aws gcp)
