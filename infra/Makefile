# CloudBridge infra. Stacks: live/<cloud>-<env>/<layer>; one state, backend and CI identity each.
# No local Terraform? `bash ../tools/dev/iac-check.sh` runs fmt/validate/test in containers.
CLOUD ?= aws
ENV   ?= budget
STACK  = live/$(CLOUD)-$(ENV)/10-foundation

.PHONY: fmt test test-tofu plan apply budget-up

fmt:
	terraform fmt -recursive -check

test:
	cd modules/cell && terraform init -backend=false -input=false && terraform test
	cd live/aws-budget/10-foundation && terraform init -backend=false -input=false && terraform test
	cd live/gcp-budget/10-foundation && terraform init -backend=false -input=false && terraform test

test-tofu:
	cd modules/cell && tofu init -backend=false -input=false && tofu test

plan:
	cd $(STACK) && terraform init -input=false && terraform plan -input=false -out=tfplan

apply:
	cd $(STACK) && terraform apply -input=false tfplan

# Terraform builds both VMs (tagged cb-ansible-role=k3s_server) → Ansible finds them by tag and
# configures k3s. Needs AWS + GCP credentials and the state buckets (see docs/IMPLEMENTATION_PLAN.md).
budget-up:
	$(MAKE) plan apply CLOUD=aws ENV=budget
	$(MAKE) plan apply CLOUD=gcp ENV=budget
	cd ../ansible && ansible-playbook playbooks/site.yml
