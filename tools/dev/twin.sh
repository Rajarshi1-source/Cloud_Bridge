#!/usr/bin/env bash
# CloudBridge local twin: cb-aws-local and cb-gcp-local, two k3s v1.36 cells built by the same
# Ansible roles, charts and ring files as the budget cells, behind a Cloudflare-like edge that
# reads infra/live/global/30-traffic/terraform.tfvars.json. Needs only Docker, git, python3,
# openssl and curl (WSL Ubuntu-D has them). Argo CD in each cell follows a snapshot of this
# working tree, committed or not, served by the twin's own git server.
#   bash tools/dev/twin.sh up              # build/refresh everything and wait until both cells serve
#   bash tools/dev/twin.sh sync            # publish the working tree again; Argo CD re-syncs
#   bash tools/dev/twin.sh weights         # re-read terraform.tfvars.json into the edge
#   bash tools/dev/twin.sh images [off]    # run service code from the working tree, not the ring digests
#   bash tools/dev/twin.sh promote         # skip the canaries: only the new images, and wait for them
#   bash tools/dev/twin.sh check           # split, affinity, API smoke through the edge
#   bash tools/dev/twin.sh leases          # allocator, forged grants, restarts, no overselling
#   bash tools/dev/twin.sh observe         # metrics through Access, rules, split, Grafana
#   bash tools/dev/twin.sh burn aws|gcp    # stop order-service for real: CellSLOBurnFast must page
#   bash tools/dev/twin.sh capacity aws|gcp  # k6: per-pod RPS into gitops/cells/<cell>/capacity.yaml
#   bash tools/dev/twin.sh outage aws|gcp  # pause a whole cell; traffic must move; then restore it
#   bash tools/dev/twin.sh kubectl aws|gcp ARGS...  # the cell's bundled kubectl
#   bash tools/dev/twin.sh status | down | purge
# Edge: https://app.<domain>:8443 (curl --cacert ~/.cache/cloudbridge-twin/pki/ca.crt --resolve ...)
# Grafana: http://127.0.0.1:3000  Prometheus: http://127.0.0.1:9090
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TWIN_DIR="${CB_TWIN_DIR:-$HOME/.cache/cloudbridge-twin}"
NET="${CB_TWIN_NET:-172.29.80}"
EDGE_PORT="${CB_TWIN_EDGE_PORT:-8443}"
REGISTRY_PORT="${CB_TWIN_REGISTRY_PORT:-5500}"
TOOLBOX_IMAGE=cloudbridge/ansible-toolbox:local
DOMAIN=$(sed -n 's/^domain:[[:space:]]*\([^[:space:]]*\).*/\1/p' "$REPO/gitops/global/values.yaml")
export TWIN_DIR CB_TWIN_NET="$NET" CB_TWIN_EDGE_PORT="$EDGE_PORT" CB_TWIN_REGISTRY_PORT="$REGISTRY_PORT" CB_TWIN_DOMAIN="$DOMAIN"
TWIN_ACCESS_AUD=twin-admin
TWIN_ALLOCATOR_ID=twin-allocator.access
TWIN_METRICS_ID=twin-metrics.access
access_issuer() { echo "http://$NET.7:443"; }
HOST="app.$DOMAIN"
CELLS="aws gcp"
ring_of() { [ "$1" = aws ] && echo ring-main || echo ring-canary; }   # as in gitops/cells and Ansible

compose() { docker compose -f "$REPO/tools/dev/twin/compose.yaml" "$@"; }
kc() { compose exec -T "cell-$1" kubectl "${@:2}"; }
edge_curl() { curl -sS --cacert "$TWIN_DIR/pki/ca.crt" --resolve "$HOST:$EDGE_PORT:127.0.0.1" "$@"; }
edge_url() { echo "https://$HOST:$EDGE_PORT$1"; }
as_root() { # files written by the toolbox and k3s are root-owned; manage them through Docker
  docker run --rm -v "$TWIN_DIR":/twin alpine:3.22 sh -c "$1"
}

pki() { # local stand-ins for the Cloudflare Origin CA certificate and the edge certificate
  local d="$TWIN_DIR/pki"; mkdir -p "$d"
  # Python 3.13+ verifies strictly: the CA needs key usage, and leaf certificates an authority key ID.
  if [ -f "$d/ca.crt" ] && ! openssl x509 -in "$d/ca.crt" -noout -ext keyUsage 2>/dev/null | grep -q 'Certificate Sign'; then
    rm -f "$d"/*.crt "$d"/*.key "$d"/*.srl
  fi
  [ -f "$d/ca.crt" ] || openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 825 \
    -subj "/CN=CloudBridge twin CA" -addext 'keyUsage=critical,keyCertSign,cRLSign' \
    -keyout "$d/ca.key" -out "$d/ca.crt" 2>/dev/null
  issue() { # name, SANs
    [ -f "$d/$1.crt" ] && return
    local cn=${2%%,*}   # its first name: Traefik matches a certificate on the CN as well as the SANs
    openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/CN=${cn#DNS:}" \
      -keyout "$d/$1.key" -out "$d/$1.csr" 2>/dev/null
    openssl x509 -req -in "$d/$1.csr" -CA "$d/ca.crt" -CAkey "$d/ca.key" -CAcreateserial -days 825 \
      -extfile <(printf 'subjectAltName=%s\nextendedKeyUsage=serverAuth\nkeyUsage=critical,digitalSignature\nauthorityKeyIdentifier=keyid\nsubjectKeyIdentifier=hash\n' "$2") \
      -out "$d/$1.crt" 2>/dev/null
    rm -f "$d/$1.csr"
  }
  # One origin certificate for both cells, like 20-origin-tls: app plus each cell's admin host.
  issue origin "DNS:$HOST,DNS:admin-aws.$DOMAIN,DNS:admin-gcp.$DOMAIN"
  issue edge "DNS:$HOST"
  issue edge-admin "DNS:admin-aws.$DOMAIN,DNS:admin-gcp.$DOMAIN"
  issue edge-metrics "DNS:metrics.$DOMAIN"
  chmod 0644 "$d"/*.crt "$d"/*.key   # read by the toolbox and Traefik containers; local test keys only
  echo "pki: twin CA, origin and edge certificates in $d"
}

access() { # the service tokens the Access stand-in knows: the allocator's, the metrics agents', and one the cells don't allow
  local d="$TWIN_DIR/access"; mkdir -p "$d"
  [ -f "$d/allocator.env" ] && [ -f "$d/metrics.env" ] && return
  # A twin from before Week 5 keeps its allocator token, so the cells' secrets don't change.
  local secret other metrics
  secret=$(sed -n 's/^CF_ACCESS_CLIENT_SECRET=//p' "$d/allocator.env" 2>/dev/null); secret=${secret:-$(openssl rand -hex 32)}
  other=$(openssl rand -hex 32); metrics=$(openssl rand -hex 32)
  printf 'CF_ACCESS_CLIENT_ID=%s\nCF_ACCESS_CLIENT_SECRET=%s\n' "$TWIN_ALLOCATOR_ID" "$secret" >"$d/allocator.env"
  printf 'CF_ACCESS_CLIENT_ID=%s\nCF_ACCESS_CLIENT_SECRET=%s\n' "$TWIN_METRICS_ID" "$metrics" >"$d/metrics.env"
  printf '{"%s": "%s", "twin-other.access": "%s", "%s": "%s"}\n' "$TWIN_ALLOCATOR_ID" "$secret" "$other" "$TWIN_METRICS_ID" "$metrics" >"$d/service-tokens.json"
  chmod 0644 "$d"/allocator.env "$d"/metrics.env "$d"/service-tokens.json   # local test tokens, read by the containers
  echo "access: service tokens in $d"
}

observability_config() { # what the central stack's configuration leaves to each environment
  local d="$TWIN_DIR/observability"
  mkdir -p "$d/targets" "$d/grafana-secrets" "$d/alerts"
  printf -- '- targets: ["https://%s:%s/healthz/cell"]\n' "$HOST" "$EDGE_PORT" >"$d/targets/edge.yml"
  printf 'http://twin-alert-sink:5000/slack' >"$d/slack_url"
  [ -f "$d/grafana-secrets/cp_reader_password" ] || openssl rand -hex 24 >"$d/grafana-secrets/cp_reader_password"
  touch "$d/alerts/received.jsonl"
  chmod -R a+rX "$d"; chmod a+rwx "$d/alerts"; chmod a+rw "$d/alerts/received.jsonl"
}

control_plane_db() { # the control plane's real migrations, and the weights the edge reads as its first traffic change
  cp_psql() { compose exec -T twin-cp-db psql -v ON_ERROR_STOP=1 -q -U allocator "$@"; }
  [ "$(compose exec -T twin-cp-db psql -U allocator -d allocator -Atc "SELECT 1 FROM pg_database WHERE datname='controlplane'" | tr -d '\r')" = 1 ] \
    || cp_psql -d allocator -c "CREATE DATABASE controlplane"
  cp_psql -d controlplane -c "CREATE TABLE IF NOT EXISTS twin_migrations (name text PRIMARY KEY)"
  local f name
  for f in "$REPO"/control-plane/migrations/V*.sql; do
    name=$(basename "$f")
    [ -z "$(cp_psql -d controlplane -Atc "SELECT 1 FROM twin_migrations WHERE name='$name'" | tr -d '\r')" ] || continue
    cp_psql -d controlplane <"$f"
    cp_psql -d controlplane -c "INSERT INTO twin_migrations VALUES ('$name')"
    echo "control plane: applied $name"
  done
  cp_psql -d controlplane -c "ALTER ROLE cp_reader PASSWORD '$(cat "$TWIN_DIR/observability/grafana-secrets/cp_reader_password")'"
  record_weights
}

record_weights() { # traffic_changes follows the tfvars file, as the apply workflow's POST does in production
  local w
  w=$(python3 -I -c 'import json,sys;print(json.dumps(json.load(open(sys.argv[1]))["weights"],sort_keys=True))' "$REPO/infra/live/global/30-traffic/terraform.tfvars.json")
  compose exec -T twin-cp-db psql -v ON_ERROR_STOP=1 -q -U allocator -d controlplane -c \
    "INSERT INTO traffic_changes (weights, source) SELECT '$w'::jsonb, 'manual'
     WHERE NOT EXISTS (SELECT 1 FROM (SELECT weights FROM traffic_changes ORDER BY applied_at DESC LIMIT 1) l WHERE l.weights = '$w'::jsonb)"
}

# Cells normally run the ring digests. After `images`, the snapshot's ring files name digests built
# from the working tree instead (in the snapshot only: gitops/releases/ never changes).
images() {
  local dir="$TWIN_DIR/images" user svc ref digest
  if [ "${1:-}" = off ]; then rm -rf "$dir"; publish; refresh; echo "cells return to the ring digests"; return; fi
  mkdir -p "$dir"
  compose --progress quiet up -d twin-registry
  user=$(sed -n 's/.*: \([^/]*\)\/cb-api-gateway@.*/\1/p' "$REPO/gitops/releases/ring-main.yaml")
  { echo "# Twin overlay, built from the working tree by twin.sh images."; echo "images:"; } >"$dir/ring.tmp"
  for svc in api-gateway order-service inventory-service; do
    ref="127.0.0.1:$REGISTRY_PORT/$user/cb-$svc:twin"
    echo "building $svc"
    DOCKER_BUILDKIT=1 docker build -q -t "$ref" "$REPO/services/$svc" >/dev/null
    digest=$(docker push "$ref" | sed -n 's/.*digest: \(sha256:[0-9a-f]*\).*/\1/p')
    [ -n "$digest" ] || { echo "push of $svc gave no digest"; exit 1; }
    echo "  $svc: $user/cb-$svc@$digest" >>"$dir/ring.tmp"
    echo "  $svc: $digest"
  done
  echo "commit: working-tree" >>"$dir/ring.tmp"
  mv "$dir/ring.tmp" "$dir/ring.yaml"
}

publish() { # snapshot the working tree (tracked + untracked, minus .gitignore) as branch "twin"
  local bare="$TWIN_DIR/git/cloud_bridge.git" idx; idx=$(mktemp)
  [ -d "$bare" ] || git init -q --bare "$bare"
  # autocrlf=input: a Windows checkout has CRLF files; the snapshot must hold what a commit would.
  local g=(git -C "$REPO" -c safe.directory='*' -c core.autocrlf=input -c core.safecrlf=false)
  export GIT_AUTHOR_NAME=cloudbridge-twin GIT_AUTHOR_EMAIL=twin@localhost \
         GIT_COMMITTER_NAME=cloudbridge-twin GIT_COMMITTER_EMAIL=twin@localhost
  GIT_INDEX_FILE="$idx" "${g[@]}" read-tree HEAD
  GIT_INDEX_FILE="$idx" "${g[@]}" add -A
  if [ -f "$TWIN_DIR/images/ring.yaml" ]; then # run the working tree's service images (twin.sh images)
    local blob ring; blob=$("${g[@]}" hash-object -w "$TWIN_DIR/images/ring.yaml")
    for ring in ring-main ring-canary; do
      GIT_INDEX_FILE="$idx" "${g[@]}" update-index --add --cacheinfo "100644,$blob,gitops/releases/$ring.yaml"
    done
  fi
  local tree commit
  tree=$(GIT_INDEX_FILE="$idx" "${g[@]}" write-tree)
  commit=$(echo "twin snapshot of $("${g[@]}" rev-parse --short HEAD)" | "${g[@]}" commit-tree "$tree" -p HEAD)
  rm -f "$idx"
  "${g[@]}" push -q --force "$bare" "$commit:refs/heads/twin"
  echo "git: twin -> $commit (working tree on $("${g[@]}" rev-parse --abbrev-ref HEAD))"
}

render() { # the budget roles, run against directories the cells mount
  docker build -q -t "$TOOLBOX_IMAGE" -f "$REPO/tools/dev/ansible-toolbox.Dockerfile" "$REPO/tools/dev" >/dev/null
  local cloud out metrics_secret
  metrics_secret=$(sed -n 's/^CF_ACCESS_CLIENT_SECRET=//p' "$TWIN_DIR/access/metrics.env")
  for cloud in $CELLS; do
    if ! out=$(docker run --rm -v "$REPO":/work:ro -v "$TWIN_DIR":/twin -e ANSIBLE_CONFIG=/work/ansible/ansible.cfg \
        -w /work/ansible "$TOOLBOX_IMAGE" \
        ansible-playbook -i localhost, -c local playbooks/twin.yml \
          -e cb_cell="cb-$cloud-local" -e cb_cloud="$cloud" -e cb_ring="$(ring_of "$cloud")" \
          -e twin_dir="/twin/cb-$cloud-local" -e twin_pki=/twin/pki \
          -e twin_git_url="http://$NET.6/git/cloud_bridge.git" \
          -e cell_secrets_access_team_domain="$(access_issuer)" -e cell_secrets_access_aud="$TWIN_ACCESS_AUD" \
          -e cell_secrets_access_allowed_client_ids="$TWIN_ALLOCATOR_ID" \
          -e cell_secrets_metrics_client_id="$TWIN_METRICS_ID" -e cell_secrets_metrics_client_secret="$metrics_secret" 2>&1); then
      echo "$out"; echo "render failed for cb-$cloud-local"; exit 1
    fi
    echo "ansible: cb-$cloud-local $(grep -oE 'ok=[0-9]+ +changed=[0-9]+' <<<"$out" | tr -s ' ')"
  done
}

weights() {
  mkdir -p "$TWIN_DIR/edge"
  python3 -I "$REPO/tools/dev/twin/edge_config.py" "$REPO" "$TWIN_DIR/edge/lb.yaml"
}

origin_ok() { # one cell's /healthz/cell straight through its own ingress, bypassing the edge
  local id ip
  id=$(compose ps -q "cell-$1" 2>/dev/null) && [ -n "$id" ] || return 1
  ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$id")
  curl -fsS -o /dev/null -m 5 --cacert "$TWIN_DIR/pki/ca.crt" --resolve "$HOST:443:$ip" "https://$HOST/healthz/cell" 2>/dev/null
}

apps() { # Argo CD's view of one cell
  kc "$1" -n argocd get applications -o custom-columns='APP:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' 2>/dev/null \
    | tail -n +2 | tr -s ' ' | paste -sd ';' - || true
}

wait_ready() {
  local deadline=$(( $(date +%s) + ${CB_TWIN_TIMEOUT:-1500} ))
  for cloud in $CELLS; do
    until origin_ok "$cloud"; do
      [ "$(date +%s)" -lt "$deadline" ] || { echo "timed out waiting for cb-$cloud-local"; status; exit 1; }
      echo "  waiting for cb-$cloud-local: $(apps "$cloud")"
      sleep 20
    done
    echo "ready: cb-$cloud-local serves /healthz/cell through its own ingress"
  done
}

refresh() { # tell Argo CD to fetch the new snapshot now instead of at its 3-minute poll
  for cloud in $CELLS; do
    for app in $(kc "$cloud" -n argocd get applications -o name 2>/dev/null); do
      kc "$cloud" -n argocd annotate "$app" argocd.argoproj.io/refresh=hard --overwrite >/dev/null
    done
  done
}

status() {
  compose ps --format 'table {{.Service}}\t{{.State}}\t{{.Status}}'
  for cloud in $CELLS; do
    echo "== cb-$cloud-local"
    echo "   argo: $(apps "$cloud")"
    kc "$cloud" -n cb-app get pods --no-headers 2>/dev/null | awk '{print "   " $1, $2, $3}' || true
    if origin_ok "$cloud"; then echo "   origin /healthz/cell: OK"; else echo "   origin /healthz/cell: DOWN"; fi
  done
}

# How many of n requests (no cookie) each cell answered, e.g. "cb-aws-local=141 cb-gcp-local=59".
# n requests through the edge, counted by the cell that answered. A frozen cell still completes the
# TCP handshake and then never answers, and the edge has no response deadline of its own (Cloudflare
# gives up after 100 s with a 524), so each request gets a 5 s client deadline; "none" counts requests
# that got no answer or an answer from no cell (the edge's 503).
split() {
  local n=$1 i cell
  for i in $(seq "$n"); do
    cell=$(edge_curl -m 5 -o /dev/null -D - "$(edge_url /healthz/cell)" 2>/dev/null \
      | tr -d '\r' | sed -n 's/^[Xx]-[Cc][Bb]-[Cc]ell: //p') || true
    echo "${cell:-none}"
  done | sort | uniq -c | awk '{printf "%s=%s ", $2, $1}'
}

check() {
  local fail=0 n=200 weights_json counts
  ok() { echo "ok   $1"; }
  bad() { echo "FAIL $1"; fail=1; }
  for cloud in $CELLS; do origin_ok "$cloud" && ok "origin cb-$cloud-local healthy" || bad "origin cb-$cloud-local unhealthy"; done

  counts=$(split "$n"); echo "     $n requests without a cookie: $counts"
  weights_json=$(sed -n '/"weights"/,/}/p' "$REPO/infra/live/global/30-traffic/terraform.tfvars.json")
  for cloud in $CELLS; do
    local want got
    want=$(sed -n "s/.*\"$cloud\":[[:space:]]*\([0-9]*\).*/\1/p" <<<"$weights_json")
    got=$(sed -n "s/.*cb-$cloud-local=\([0-9]*\).*/\1/p" <<<"$counts"); got=${got:-0}
    # +-10 points is about 3 standard deviations at n=200: a real 70/30 split never fails this.
    if [ "$want" -eq 0 ]; then
      [ "$got" -eq 0 ] && ok "cb-$cloud-local drained (weight 0)" || bad "cb-$cloud-local has weight 0 but took $got"
    elif [ $(( got * 100 / n )) -ge $(( want - 10 )) ] && [ $(( got * 100 / n )) -le $(( want + 10 )) ]; then
      ok "cb-$cloud-local took $(( got * 100 / n ))% (weight $want)"
    else
      bad "cb-$cloud-local took $(( got * 100 / n ))%, weight is $want"
    fi
  done

  local jar; jar=$(mktemp)
  edge_curl -s -o /dev/null -c "$jar" "$(edge_url /healthz/cell)"
  grep -q __cflb "$jar" && ok "edge set the __cflb affinity cookie" || bad "no __cflb cookie"
  local pinned; pinned=$(for i in $(seq 20); do
    edge_curl -s -o /dev/null -D - -b "$jar" "$(edge_url /healthz/cell)" | tr -d '\r' | sed -n 's/^[Xx]-[Cc][Bb]-[Cc]ell: //p'
  done | sort -u)
  [ "$(wc -l <<<"$pinned")" -eq 1 ] && ok "20 requests with the cookie all reached $pinned" || bad "cookie did not pin: $(echo $pinned)"
  rm -f "$jar"

  local code
  code=$(edge_curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{}' "$(edge_url /orders)")
  [ "$code" = 400 ] && ok "POST /orders without Idempotency-Key -> 400" || bad "POST /orders without a key -> $code (want 400)"
  code=$(edge_curl -s -o /dev/null -w '%{http_code}' -X POST "$(edge_url /admin/leases/grant)")
  [ "$code" = 404 ] && ok "/admin/** hidden on the public host -> 404" || bad "/admin/** on the public host -> $code (want 404)"
  [ $fail -eq 0 ] && echo "TWIN CHECK PASSED" || { echo "TWIN CHECK FAILED"; exit 1; }
}

promote() { # the new images everywhere, now. The old and new ReplicaSets of a canary do not fit in a
  # cell at once and thrash each other past the startup probe, and the twin has no traffic to protect:
  # delete the Rollouts and Argo CD recreates them with only the new images.
  local cloud deadline=$(( $(date +%s) + 600 )) state
  for cloud in $CELLS; do kc "$cloud" -n cb-app delete rollout,hpa --all --wait=false >/dev/null; done
  for cloud in $CELLS; do
    until state=$(kc "$cloud" -n cb-app get rollout -o jsonpath='{range .items[*]}{.metadata.name}={.status.phase}/{.status.stableRS}/{.status.currentPodHash} {end}') \
        && [ "$(echo "$state" | wc -w)" = 3 ] && ! echo "$state" | tr ' ' '\n' | awk -F'[=/]' 'NF && ($2!="Healthy" || $3!=$4) {f=1} END {exit !f}'; do
      [ "$(date +%s)" -lt "$deadline" ] || { echo "FAIL cb-$cloud-local still rolling: $state"; exit 1; }
      sleep 10
    done
    echo "promoted: cb-$cloud-local runs only the new images"
  done
}

outage() { # the whole cell disappears, as in a cloud outage; the edge must move every user
  local down=$1 other; case "$down" in aws) other=gcp ;; gcp) other=aws ;; *) echo "outage aws|gcp"; exit 2 ;; esac
  echo "pausing cell-$down (every container in it freezes)"
  compose pause "cell-$down" >/dev/null
  trap 'compose unpause "cell-'"$down"'" >/dev/null 2>&1 || true' EXIT
  local t0; t0=$(date +%s)
  until [ "$(split 10)" = "cb-$other-local=10 " ]; do
    [ $(( $(date +%s) - t0 )) -lt 120 ] || { echo "FAIL traffic still reaches cb-$down-local after 120 s"; exit 1; }
    sleep 2
  done
  echo "ok   all traffic on cb-$other-local $(( $(date +%s) - t0 )) s after the outage began (monitor interval 10 s)"
  echo "     50 requests: $(split 50)"
  compose unpause "cell-$down" >/dev/null; trap - EXIT
  t0=$(date +%s)
  until split 20 | grep -q "cb-$down-local"; do
    [ $(( $(date +%s) - t0 )) -lt 300 ] || { echo "FAIL cb-$down-local did not return within 300 s"; exit 1; }
    sleep 5
  done
  echo "ok   cb-$down-local back in rotation $(( $(date +%s) - t0 )) s after it returned"
}

case "${1:-}" in
  up)
    mkdir -p "$TWIN_DIR"
    pki; access; observability_config; publish; render; weights
    compose --progress quiet up -d --build --remove-orphans --quiet-pull --wait twin-cp-db
    compose --progress quiet up -d --build --remove-orphans --quiet-pull
    control_plane_db
    refresh
    echo "Argo CD is installing and syncing both cells (first start: about 10 minutes)."
    wait_ready
    echo "Edge: curl --cacert $TWIN_DIR/pki/ca.crt --resolve $HOST:$EDGE_PORT:127.0.0.1 $(edge_url /healthz/cell)"
    ;;
  images)
    images "${2:-}"
    if [ "${2:-}" != off ]; then
      publish
      if [ -n "$(compose ps -q cell-aws 2>/dev/null)" ]; then refresh; echo "Argo CD rolls the new images out (watch: bash tools/dev/twin.sh status)"; fi
    fi
    ;;
  sync) observability_config; publish; render; refresh; control_plane_db; echo "Argo CD re-syncs from the new snapshot (watch: bash tools/dev/twin.sh status)" ;;
  weights) weights; record_weights ;;
  check) check ;;
  promote) promote ;;
  leases) source "$REPO/tools/dev/twin/leases.sh"; leases ;;
  outage) outage "${2:-}" ;;
  observe) source "$REPO/tools/dev/twin/observe.sh"; observe ;;
  burn) source "$REPO/tools/dev/twin/observe.sh"; burn "${2:-}" ;;
  capacity) source "$REPO/tools/dev/twin/observe.sh"; capacity "${2:-}" ;;
  status) status ;;
  kubectl) case "${2:-}" in aws|gcp) kc "${@:2}" ;; *) echo "kubectl aws|gcp ARGS..."; exit 2 ;; esac ;;
  down) compose down; echo "stopped; cells, data and certificates kept (purge removes them)" ;;
  purge) compose down -v; as_root "rm -rf /twin/*"; echo "removed the twin's volumes and $TWIN_DIR" ;;
  *) sed -n '2,16p' "$0"; exit 2 ;;
esac
