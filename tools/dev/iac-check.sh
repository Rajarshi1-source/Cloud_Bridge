#!/usr/bin/env bash
# Offline IaC checks in pinned containers — no local Terraform/OpenTofu/Ansible and no cloud
# credentials needed. Run from WSL (Docker Engine) or any Linux/macOS host with Docker:
#   bash tools/dev/iac-check.sh            # everything
#   bash tools/dev/iac-check.sh terraform  # or: tofu | actions | gitops | ansible | molecule | policy | observability | parity | lock
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
PYTHON_IMAGE=python:3.14-slim
STACKS="modules/cell live/aws-budget/10-foundation live/gcp-budget/10-foundation live/aws-dev/10-foundation live/gcp-dev/10-foundation live/aws-dev/20-bootstrap live/gcp-dev/20-bootstrap live/global/00-ci-identity live/global/20-origin-tls live/global/30-traffic"
docker volume create cb-tf-plugins >/dev/null
docker volume create cb-tofu-plugins >/dev/null
fail=0
step() { echo; echo "===== $*"; }
run_or_fail() { "$@" || { echo "FAILED: $*"; fail=1; }; }

# A copy of a directory in a Docker volume, for tools that walk a tree. With the twin up, reading a
# directory on WSL's /mnt/d fails now and then with "readdirent: cannot allocate memory" (8 of 25 tflint
# runs, 0 of 25 on a volume or with the twin stopped). tflint reports it, but a walker that treats it as
# the end of the directory checks part of the tree and passes. So: git's list of files, opened by name,
# no directory read of the tracked files, and tar fails if one can't be read.
snapshot() { # directory under the repo; prints the volume's name. Callers must treat failure as a failed check.
  local dir=$1 volume="cb-src-$1" file want got
  want=$(git -C "$REPO" -c safe.directory='*' ls-files -co --exclude-standard -- "$dir" | wc -l)
  [ "$want" -gt 0 ] || { echo "snapshot of $dir: git lists no files" >&2; return 1; }
  docker volume create "$volume" >/dev/null
  git -C "$REPO" -c safe.directory='*' ls-files -z -co --exclude-standard -- "$dir" \
    | while IFS= read -r -d '' file; do
        if [ -e "$REPO/$file" ] || [ -L "$REPO/$file" ]; then printf '%s\0' "$file"; fi
      done \
    | tar -C "$REPO" --null -T - -cf - \
    | docker run -i --rm -v "$volume":/snapshot alpine:3.22 sh -c "rm -rf /snapshot/* /snapshot/.[!.]* && tar -xf - -C /snapshot && cd /snapshot/$dir" \
    || { echo "snapshot of $dir: couldn't copy it" >&2; return 1; }
  got=$(docker run --rm -v "$volume":/snapshot alpine:3.22 sh -c 'find /snapshot \( -type f -o -type l \) | wc -l')
  # A file deleted but not yet committed is listed and not copied, so got can be lower, but never zero.
  [ "$got" -gt 0 ] || { echo "snapshot of $dir: the volume is empty" >&2; return 1; }
  echo "$volume"
}

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
  local infra gitops
  infra=$(snapshot infra) && gitops=$(snapshot gitops) || { echo "FAILED: snapshot"; fail=1; return; }
  for s in $STACKS; do
    step "tofu validate + test: $s"
    run_or_fail docker run --rm -v "$infra":/in/infra:ro -v "$gitops":/in/gitops:ro \
      -v cb-tofu-plugins:/plugins -e TF_PLUGIN_CACHE_DIR=/plugins --entrypoint sh "$TOFU_IMAGE" -c \
      "mkdir /repo && cp -r /in/infra/infra /repo/infra && cp -r /in/gitops/gitops /repo/gitops && rm -rf /repo/infra/$s/.terraform /repo/infra/$s/.terraform.lock.hcl && cd /repo/infra/$s \
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
  local gitops; gitops=$(snapshot gitops) || { echo "FAILED: snapshot of gitops"; fail=1; return; }
  run_or_fail docker run --rm -v "$gitops":/in:ro -v cb-gitops-out:/out --entrypoint sh "$HELM_IMAGE" -c '
    set -eu; rm -rf /out/* /work; cp -r /in/gitops /work; cd /work
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
  local infra; infra=$(snapshot infra) || { echo "FAILED: snapshot of infra"; fail=1; return; }
  step "tflint (terraform, aws and google rulesets)"
  docker volume create cb-tflint-plugins >/dev/null
  run_or_fail docker run --rm -v "$infra":/s -v cb-tflint-plugins:/root/.tflint.d -w /s/infra \
    --entrypoint sh "$TFLINT_IMAGE" -c 'tflint --init --config /s/infra/.tflint.hcl >/dev/null && tflint --recursive --config /s/infra/.tflint.hcl --format compact'
  step "trivy config (HIGH, CRITICAL)"
  docker volume create cb-trivy-cache >/dev/null
  run_or_fail docker run --rm -v "$infra":/s:ro -v cb-trivy-cache:/root/.cache/trivy "$TRIVY_IMAGE" \
    config --severity HIGH,CRITICAL --exit-code 1 --quiet /s/infra
  step "conftest verify"
  run_or_fail docker run --rm -v "$infra":/s:ro -w / "$CONFTEST_IMAGE" verify -p /s/infra/policy
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

parity_render() { # gitops snapshot, output volume, shell commands to run on the copy first: every chart x cell
  docker run --rm -v "$1":/in:ro -v "$2":/out -e CHANGE="$3" --entrypoint sh "$HELM_IMAGE" -c '
    set -eu; rm -rf /out/* /work; cp -r /in/gitops /work; cd /work; eval "$CHANGE"
    for chart in charts/*/; do
      chart=${chart%/}; name=${chart#charts/}
      [ "$(sed -n "s/^type: //p" "$chart/Chart.yaml")" = library ] && continue
      helm dependency build "$chart" >/dev/null
      for cell in cells/*/; do
        cell=${cell%/}; c=${cell#cells/}
        case "$c" in *aws*) ring=ring-main ;; *) ring=ring-canary ;; esac
        helm template "$name" "$chart" --namespace cb-app -f global/values.yaml -f "$cell/values.yaml" -f "releases/$ring.yaml" > "/out/$c--$name.yaml"
      done
    done'
}

parity_py() { # arguments to `python -m parity`, with the output volume at /out
  docker run --rm -v "$REPO":/repo:ro -v cb-parity-out:/out:ro -w /repo -e PYTHONPATH=/repo/control-plane/parity-checker -e PYTHONDONTWRITEBYTECODE=1 \
    -v cb-pip-cache:/root/.cache/pip --entrypoint sh "$PYTHON_IMAGE" -c \
    'pip install -q --root-user-action=ignore pyyaml==6.0.3 && exec "$@"' sh "$@"
}

parity_must_catch() { # what a PR changes in one cell, the check that must fail
  local out; step "parity static must catch: $3"
  run_or_fail parity_render "$gitops" cb-parity-out "$1"
  out=$(parity_py python -m parity static --env budget --rendered /out 2>&1); local rc=$?
  echo "$out" | grep -v '^  ' | cut -c1-200
  if [ $rc -ne 1 ] || ! grep -q "^x $2 " <<<"$out"; then echo "FAILED: $3 wasn't caught (exit $rc)"; fail=1; fi
}

check_parity() { # the eval gate, the adapters, and every environment's cells as Git would deploy them
  step "parity eval gate: zero missed, zero false divergences"
  run_or_fail parity_py python evals/parity/run_eval.py
  step "parity adapters on fixtures"
  run_or_fail parity_py python -m unittest discover -s control-plane/parity-checker/tests
  local gitops; gitops=$(snapshot gitops) || { echo "FAILED: snapshot of gitops"; fail=1; return; }
  docker volume create cb-parity-out >/dev/null
  step "parity static: both cells of each environment, from the charts in this tree"
  run_or_fail parity_render "$gitops" cb-parity-out :
  local env
  for env in budget dev local; do run_or_fail parity_py python -m parity static --env "$env" --rendered /out; done
  # A check that can't fail proves nothing: each of these is one line in one cell's values.
  parity_must_catch 'printf "addons:\n  traefik:\n    chartVersion: 41.7.2\n" >>cells/cb-aws-budget/values.yaml' chart.versions "a chart version changed in one cell"
  parity_must_catch 'sed -i "s/^  max: 1$/  max: 2/" cells/cb-gcp-budget/values.yaml' hpa.max "max replicas changed in one cell"
  parity_must_catch 'sed -i "s/cpu: 100m, memory: 256Mi/cpu: 200m, memory: 256Mi/" cells/cb-aws-budget/values.yaml' resources.requests "requests changed in one cell"
  parity_must_catch 'printf "env:\n  EXTRA: \"1\"\n" >>cells/cb-aws-budget/values.yaml' app.config.hash "an environment variable added in one cell"
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
  parity) check_parity ;;
  lock) lock_providers ;;
  all) check_terraform; check_tofu; check_actions; check_gitops; check_ansible; check_molecule; check_policy; check_observability; check_parity ;;
  *) echo "usage: $0 [all|terraform|tofu|actions|gitops|ansible|molecule|policy|observability|parity|lock]"; exit 2 ;;
esac
echo
[ $fail -eq 0 ] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit $fail
