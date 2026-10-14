#!/usr/bin/env bash
# Offline IaC checks in pinned containers — no local Terraform/OpenTofu/Ansible and no cloud
# credentials needed. Run from WSL (Docker Engine) or any Linux/macOS host with Docker:
#   bash tools/dev/iac-check.sh            # everything
#   bash tools/dev/iac-check.sh terraform  # or: tofu | actions | ansible | molecule | lock
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TF_IMAGE=hashicorp/terraform:1.15.9
TOFU_IMAGE=ghcr.io/opentofu/opentofu:1.12.8
ACTIONLINT_IMAGE=rhysd/actionlint:1.7.12
TOOLBOX_IMAGE=cloudbridge/ansible-toolbox:local
STACKS="modules/cell live/aws-budget/10-foundation live/gcp-budget/10-foundation"
docker volume create cb-tf-plugins >/dev/null
docker volume create cb-tofu-plugins >/dev/null
fail=0
step() { echo; echo "===== $*"; }
run_or_fail() { "$@" || { echo "FAILED: $*"; fail=1; }; }

tf() { # terraform with the repo mounted read-write (writes .terraform/ and the lock files)
  docker run --rm -v "$REPO/infra":/infra -v cb-tf-plugins:/plugins -e TF_PLUGIN_CACHE_DIR=/plugins \
    -e TF_IN_AUTOMATION=1 -w "/infra/$1" "$TF_IMAGE" "${@:2}"
}

check_terraform() {
  step "terraform fmt"
  run_or_fail tf . fmt -recursive -check -diff
  for s in $STACKS; do
    step "terraform validate + test: $s"
    run_or_fail tf "$s" init -backend=false -input=false -no-color -lockfile=readonly >/dev/null
    run_or_fail tf "$s" validate -no-color
    run_or_fail tf "$s" test -no-color
  done
}

check_tofu() { # on a copy: OpenTofu's lock entries point at its own registry
  for s in $STACKS; do
    step "tofu validate + test: $s"
    run_or_fail docker run --rm -v "$REPO/infra":/src:ro -v cb-tofu-plugins:/plugins -e TF_PLUGIN_CACHE_DIR=/plugins \
      --entrypoint sh "$TOFU_IMAGE" -c \
      "cp -r /src /infra && rm -rf /infra/$s/.terraform /infra/$s/.terraform.lock.hcl && cd /infra/$s \
       && tofu init -backend=false -input=false -no-color >/dev/null && tofu validate -no-color && tofu test -no-color"
  done
}

lock_providers() { # one-time / on provider bumps: lock hashes for the platforms people use
  for s in $STACKS; do
    step "providers lock: $s"
    run_or_fail tf "$s" init -backend=false -input=false -upgrade -no-color >/dev/null
    run_or_fail tf "$s" providers lock -platform=linux_amd64 -platform=linux_arm64 -platform=darwin_arm64 -platform=windows_amd64
  done
}

check_actions() {
  step "actionlint"
  run_or_fail docker run --rm -v "$REPO":/repo -w /repo "$ACTIONLINT_IMAGE" -color
}

toolbox() {
  docker build -q -t "$TOOLBOX_IMAGE" -f "$REPO/tools/dev/ansible-toolbox.Dockerfile" "$REPO/tools/dev" >/dev/null
  docker run --rm -v "$REPO":/work -v /var/run/docker.sock:/var/run/docker.sock \
    -e ANSIBLE_COLLECTIONS_PATH=/tmp/collections:/root/.ansible/collections     -e ANSIBLE_CONFIG=/work/ansible/ansible.cfg -e ANSIBLE_ROLES_PATH=/work/ansible/roles     -w /work/ansible "$TOOLBOX_IMAGE" \
    bash -c "ansible-galaxy collection install -r requirements.yml -p /tmp/collections >/dev/null && $1"
}

check_ansible() {
  step "ansible-lint (production profile) + syntax check"
  run_or_fail toolbox "ansible-lint --profile production --offline && ansible-playbook -i localhost, --syntax-check playbooks/site.yml"
}

check_molecule() {
  step "molecule test: k3s_server"
  run_or_fail toolbox "cd roles/k3s_server && molecule test"
}

case "${1:-all}" in
  terraform) check_terraform ;;
  tofu) check_tofu ;;
  actions) check_actions ;;
  ansible) check_ansible ;;
  molecule) check_molecule ;;
  lock) lock_providers ;;
  all) check_terraform; check_tofu; check_actions; check_ansible; check_molecule ;;
  *) echo "usage: $0 [all|terraform|tofu|actions|ansible|molecule|lock]"; exit 2 ;;
esac
echo
[ $fail -eq 0 ] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit $fail
