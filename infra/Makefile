# CloudBridge infra. Stacks: live/<cloud>-<env>/<layer> and live/global/<layer>; one state, backend
# and CI identity each. No local Terraform? `bash ../tools/dev/iac-check.sh` runs fmt/validate/test
# in containers.
CLOUD ?= aws
ENV   ?= budget
LAYER ?= 10-foundation
STACK  = live/$(CLOUD)-$(ENV)/$(LAYER)

.PHONY: fmt test test-tofu plan apply destroy origin-tls traffic configure budget-up budget-down

fmt:
	terraform fmt -recursive -check

test:
	cd modules/cell && terraform init -backend=false -input=false && terraform test
	cd live/aws-budget/10-foundation && terraform init -backend=false -input=false && terraform test
	cd live/gcp-budget/10-foundation && terraform init -backend=false -input=false && terraform test
	cd live/global/20-origin-tls && terraform init -backend=false -input=false && terraform test
	cd live/global/30-traffic && terraform init -backend=false -input=false && terraform test

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
# world-writable directory, which every /mnt/<drive> path in WSL is. The SSM transfer bucket is an
# output of the AWS foundation, so it is read here rather than exported by hand.
configure:
	cd ../ansible && ANSIBLE_CONFIG=$(CURDIR)/../ansible/ansible.cfg \
	  CB_SSM_BUCKET=$$(terraform -chdir=$(CURDIR)/live/aws-budget/10-foundation output -json cluster | jq -r .auth.transfer_bucket) \
	  ansible-playbook playbooks/site.yml

# Order matters: VMs (origins) → certificate → Ansible (k3s, secrets, Argo CD) → Cloudflare in front.
# Needs AWS + GCP + Cloudflare credentials and the state buckets (docs/runbooks/week-2-go-live.md).
budget-up:
	$(MAKE) plan apply CLOUD=aws ENV=budget
	$(MAKE) plan apply CLOUD=gcp ENV=budget
	$(MAKE) origin-tls
	$(MAKE) configure
	$(MAKE) traffic

# Stop the spend between demos: Cloudflare first (no traffic to dead origins), then both cells.
# Keeps the state buckets, the secrets and the origin certificate, so budget-up works again.
# The budget Postgres lives on the VM disk: its data is gone after this (demo data only).
budget-down:
	cd live/global/30-traffic && terraform init -input=false && terraform destroy -input=false
	$(MAKE) destroy CLOUD=gcp ENV=budget
	$(MAKE) destroy CLOUD=aws ENV=budget
