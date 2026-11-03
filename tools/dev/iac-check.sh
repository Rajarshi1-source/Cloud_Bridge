#!/usr/bin/env bash
# Offline IaC checks in pinned containers — no local Terraform/OpenTofu/Ansible and no cloud
# credentials needed. Run from WSL (Docker Engine) or any Linux/macOS host with Docker:
#   bash tools/dev/iac-check.sh            # everything
#   bash tools/dev/iac-check.sh terraform  # or: tofu | actions | gitops | ansible | molecule | policy | observability | lock
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TF_IMAGE=hashicorp/terraform:1.15.9
TOFU_IMAGE=ghcr.io/opentofu/opentofu:1.12.8
ACTIONLINT_IMAGE=rhysd/actionlint:1.7.12
TOOLBOX_IMAGE=cloudbridge/ansible-toolbox:local
HELM_IMAGE=alpine/helm:4.2.4
KUBECONFORM_IMAGE=ghcr.io/yannh/kubeconform:v0.7.0
TFLINT_IMAGE=ghcr.io/terraform-linters/tflint:v0.65.0
TRIVY_IMAGE=aquasec/trivy:0.76.1
CONFTEST_IMAGE=openpolicyagent/conftest:v0.71.1
PROMETHEUS_IMAGE=prom/prometheus:v3.14.0
ALERTMANAGER_IMAGE=prom/alertmanager:v0.33.1
BLACKBOX_IMAGE=prom/blackbox-exporter:v0.29.1
STACKS="modules/cell live/aws-budget/10-foundation live/gcp-budget/10-foundation live/aws-dev/10-foundation live/gcp-dev/10-foundation live/aws-dev/20-bootstrap live/gcp-dev/20-bootstrap live/global/00-ci-identity live/global/20-origin-tls live/global/30-traffic"
docker volume create cb-tf-plugins >/dev/null
docker volume create cb-tofu-plugins >/dev/null
fail=0
step() { echo; echo "===== $*"; }
run_or_fail() { "$@" || { echo "FAILED: $*"; fail=1; }; }

tf() { # terraform with the repo mounted read-write (writes .terraform/ and the lock files);
  # the whole repo, because the global stacks read gitops/global/values.yaml
  docker run --rm -v "$REPO":/repo -v cb-tf-plugins:/plugins -e TF_PLUGIN_CACHE_DIR=/plugins \
    -e TF_IN_AUTOMATION=1 -w "/repo/infra/$1" "$TF_IMAGE" "${@:2}"
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
    run_or_fail docker run --rm -v "$REPO/infra":/src/infra:ro -v "$REPO/gitops":/src/gitops:ro \
      -v cb-tofu-plugins:/plugins -e TF_PLUGIN_CACHE_DIR=/plugins --entrypoint sh "$TOFU_IMAGE" -c \
      "cp -r /src /repo && rm -rf /repo/infra/$s/.terraform /repo/infra/$s/.terraform.lock.hcl && cd /repo/infra/$s \
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
    bash -c "ansible-galaxy collection install --no-cache -r requirements.yml -p /tmp/collections >/dev/null && $1"
}

check_ansible() {
  step "ansible-lint (production profile) + syntax check"
  run_or_fail toolbox "ansible-lint --profile production --offline && ansible-playbook -i localhost, --syntax-check playbooks/site.yml"
}

check_gitops() { # lint + render every chart for every cell, then schema-check the output
  step "helm lint + template (every chart x every cell) + kubeconform"
  docker volume create cb-gitops-out >/dev/null
  run_or_fail docker run --rm -v "$REPO/gitops":/src:ro -v cb-gitops-out:/out --entrypoint sh "$HELM_IMAGE" -c '
    set -eu; rm -rf /out/* /work; cp -r /src /work; cd /work
    for chart in charts/*/; do
      chart=${chart%/}; name=${chart#charts/}
      [ "$(sed -n "s/^type: //p" "$chart/Chart.yaml")" = library ] && continue
      helm dependency build "$chart" >/dev/null
      for cell in cells/*/; do
        cell=${cell%/}; c=${cell#cells/}
        case "$c" in *aws*) ring=ring-main ;; *) ring=ring-canary ;; esac
        vals="-f global/values.yaml -f $cell/values.yaml -f releases/$ring.yaml"
        helm lint --strict --quiet "$chart" $vals >/dev/null
        helm template "$name" "$chart" --namespace cb-app $vals > "/out/$c--$name.yaml"
        echo "rendered $c / $name"
      done
    done
    for cell in cells/*/; do
      c=${cell#cells/}; c=${c%/}
      case "$c" in *aws*) ring=ring-main ;; *) ring=ring-canary ;; esac
      sed -e "s/\${cell}/$c/g" -e "s/\${ring}/$ring/g" bootstrap/applicationset.yaml.tftpl > "/out/$c--root-appset.yaml"
      ! grep -n "\${" "/out/$c--root-appset.yaml"
    done'
  # Kubernetes schemas are published up to 1.34; every API used here is GA and unchanged in 1.36.
  run_or_fail docker run --rm -v cb-gitops-out:/out:ro "$KUBECONFORM_IMAGE" -strict -summary \
    -kubernetes-version 1.34.12 -schema-location default \
    -schema-location "https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" \
    /out
}

check_molecule() { # every role that has a scenario
  for scenario in "$REPO"/ansible/roles/*/molecule/default; do
    role=$(basename "$(dirname "$(dirname "$scenario")")")
    step "molecule test: $role"
    run_or_fail toolbox "cd roles/$role && molecule test"
  done
}

check_policy() { # what the PR comment reports as static checks; the tools themselves are pinned above
  step "terraform fmt"
  run_or_fail tf . fmt -recursive -check -diff
  step "tflint (terraform, aws and google rulesets)"
  docker volume create cb-tflint-plugins >/dev/null
  run_or_fail docker run --rm -v "$REPO/infra":/data -v cb-tflint-plugins:/root/.tflint.d -w /data \
    --entrypoint sh "$TFLINT_IMAGE" -c 'tflint --init --config /data/.tflint.hcl >/dev/null && tflint --recursive --config /data/.tflint.hcl --format compact'
  step "trivy config (HIGH, CRITICAL)"
  docker volume create cb-trivy-cache >/dev/null
  run_or_fail docker run --rm -v "$REPO/infra":/infra:ro -v cb-trivy-cache:/root/.cache/trivy "$TRIVY_IMAGE" \
    config --severity HIGH,CRITICAL --exit-code 1 --quiet --skip-dirs '**/.terraform' /infra
  step "conftest verify"
  run_or_fail docker run --rm -v "$REPO/infra/policy":/policy:ro -w / "$CONFTEST_IMAGE" verify -p /policy
  step "CI tools unit tests"
  run_or_fail python3 -I -m unittest discover -s "$REPO/tools/ci" -p 'test_*.py'
}

check_observability() { # the central stack's configuration and rules, offline
  local o="$REPO/observability"
  step "promtool: config, rules and rule unit tests"
  run_or_fail docker run --rm -v "$o/prometheus":/p:ro -w /p --entrypoint promtool "$PROMETHEUS_IMAGE" check rules rules/sli.yml rules/alerts.yml
  run_or_fail docker run --rm -v "$o/prometheus":/etc/prometheus:ro -w /etc/prometheus --entrypoint promtool "$PROMETHEUS_IMAGE" check config --syntax-only prometheus.yml
  run_or_fail docker run --rm -v "$o/prometheus":/p:ro -w /p --entrypoint promtool "$PROMETHEUS_IMAGE" test rules tests/alerts_test.yml
  step "amtool check-config"
  run_or_fail docker run --rm -v "$o/alertmanager":/a:ro --entrypoint amtool "$ALERTMANAGER_IMAGE" check-config /a/alertmanager.yml
  step "blackbox config"
  run_or_fail docker run --rm -v "$o/blackbox":/b:ro "$BLACKBOX_IMAGE" --config.file=/b/blackbox.yml --config.check
  step "Grafana dashboards match their generator; capacity tool unit tests"
  run_or_fail python3 -I "$o/grafana/build_dashboards.py" --check
  run_or_fail python3 -I -m unittest discover -s "$REPO/tools/load" -p 'test_*.py'
}

case "${1:-all}" in
  terraform) check_terraform ;;
  tofu) check_tofu ;;
  actions) check_actions ;;
  gitops) check_gitops ;;
  ansible) check_ansible ;;
  molecule) check_molecule ;;
  policy) check_policy ;;
  observability) check_observability ;;
  lock) lock_providers ;;
  all) check_terraform; check_tofu; check_actions; check_gitops; check_ansible; check_molecule; check_policy; check_observability ;;
  *) echo "usage: $0 [all|terraform|tofu|actions|gitops|ansible|molecule|policy|observability|lock]"; exit 2 ;;
esac
echo
[ $fail -eq 0 ] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit $fail
