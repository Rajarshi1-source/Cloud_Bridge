# Week 5 on the twin, sourced by twin.sh. `observe`: metrics reach the central receiver only through
# Access, every rule and dashboard answers, the observed split matches the weights. `burn <cloud>`: a
# real outage of one service fires CellSLOBurnFast, and it reaches Slack and EDA. `capacity <cloud>`:
# k6 measures the cell's per-pod RPS into its capacity.yaml.
OBS_FAIL=0
obs_ok() { echo "ok   $1"; }
obs_bad() { echo "FAIL $1"; OBS_FAIL=1; }
PROM_URL="http://127.0.0.1:${CB_TWIN_PROM_PORT:-9090}"
GRAFANA_URL="http://127.0.0.1:${CB_TWIN_GRAFANA_PORT:-3000}"
METRICS_HOST="metrics.$DOMAIN"

prom_query() { # expr: prints one value per result line, as "labels value"
  curl -sS -m 15 -G "$PROM_URL/api/v1/query" --data-urlencode "query=$1" | python3 -I -c '
import json,sys
for r in json.load(sys.stdin)["data"]["result"]:
    print(" ".join(f"{k}={v}" for k,v in sorted(r["metric"].items())), r["value"][1])'
}
prom_value() { prom_query "$1" | awk '{print $NF; exit}'; }
wait_for_series() { # name, expr, seconds
  local deadline=$(( $(date +%s) + $3 ))
  until [ -n "$(prom_query "$2" 2>/dev/null)" ]; do
    [ "$(date +%s)" -lt "$deadline" ] || { obs_bad "$1: no data after $3 s"; return 1; }
    sleep 5
  done
  obs_ok "$1"
}
write_status() { # curl args: a remote write through the edge, as an outsider would try it
  curl -sS -m 10 -o /dev/null -w '%{http_code}' --cacert "$TWIN_DIR/pki/ca.crt" --resolve "$METRICS_HOST:$EDGE_PORT:127.0.0.1" \
    -X POST -H 'Content-Type: application/x-protobuf' "$@" "https://$METRICS_HOST:$EDGE_PORT/api/v1/write"
}
token_headers() { # env file: its service token as curl arguments
  sed -n 's/^CF_ACCESS_CLIENT_ID=/CF-Access-Client-Id: /p; s/^CF_ACCESS_CLIENT_SECRET=/CF-Access-Client-Secret: /p' "$1" | sed 's/^/-H\n/'
}

check_write_path() {
  local allocator metrics code
  mapfile -t allocator < <(token_headers "$TWIN_DIR/access/allocator.env")
  mapfile -t metrics < <(token_headers "$TWIN_DIR/access/metrics.env")
  code=$(write_status); [ "$code" = 403 ] && obs_ok "remote write with no token -> 403" || obs_bad "remote write with no token -> $code (want 403)"
  code=$(write_status "${allocator[@]}"); [ "$code" = 403 ] && obs_ok "remote write with the allocator's token -> 403" || obs_bad "allocator's token -> $code (want 403)"
  code=$(write_status -H 'CF-Access-Client-Id: twin-metrics.access' -H 'CF-Access-Client-Secret: wrong'); [ "$code" = 403 ] && obs_ok "remote write with a wrong secret -> 403" || obs_bad "wrong secret -> $code (want 403)"
  code=$(write_status "${metrics[@]}"); [ "$code" != 403 ] && obs_ok "the metrics token passes Access (receiver answers $code to an empty body)" || obs_bad "metrics token refused"
  code=$(curl -sS -m 10 -o /dev/null -w '%{http_code}' --cacert "$TWIN_DIR/pki/ca.crt" --resolve "$METRICS_HOST:$EDGE_PORT:127.0.0.1" "${metrics[@]}" \
    "https://$METRICS_HOST:$EDGE_PORT/api/v1/query?query=up")
  [ "$code" = 404 ] && obs_ok "only the write path is published -> query gets 404" || obs_bad "query through the metrics host -> $code (want 404)"
}

check_cells_report() {
  local cloud cell n
  for cloud in $CELLS; do
    cell="cb-$cloud-local"
    wait_for_series "$cell pushes metrics" "up{job=\"apps\",cb_cell=\"$cell\"} == 1" 300 || continue
    n=$(prom_value "count(up{job=\"apps\",cb_cell=\"$cell\"} == 1)")
    [ "$n" = 3 ] && obs_ok "$cell: all 3 services scraped" || obs_bad "$cell: $n of 3 services scraped"
    for label in cb_cloud cb_env cb_profile; do
      prom_query "up{job=\"apps\",cb_cell=\"$cell\"}" | head -1 | grep -q "$label=" && obs_ok "$cell: external label $label" || obs_bad "$cell: external label $label is missing"
    done
    n=$(prom_value "count(argocd_app_info{cb_cell=\"$cell\"})")
    [ "${n:-0}" -ge 1 ] && obs_ok "$cell: Argo CD metrics ($n applications)" || obs_bad "$cell: no Argo CD metrics"
    n=$(prom_value "count(rollout_info{cb_cell=\"$cell\"})")
    [ "${n:-0}" -eq 3 ] && obs_ok "$cell: Rollouts metrics (3 rollouts)" || obs_bad "$cell: ${n:-0} of 3 rollouts in the metrics"
    n=$(kc "$cloud" -n monitoring top pod --no-headers 2>/dev/null | awk '{print $3}') || true
    echo "     $cell agent memory: ${n:-unknown}"
  done
}

check_split() { # real traffic through the edge, then the recorded split against the weights
  local want got i
  echo "     sending 900 requests through the edge over 3 minutes"
  for i in $(seq 900); do
    edge_curl -s -m 5 -o /dev/null -H "CF-Connecting-IP: 198.18.0.$(( i % 250 + 1 ))" "$(edge_url /inventory/SKU-1)" || true
    sleep 0.2
  done
  sleep 45
  for cloud in $CELLS; do
    want=$(python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["weights"][sys.argv[2]])' "$REPO/infra/live/global/30-traffic/terraform.tfvars.json" "$cloud")
    got=$(prom_value "cb:split:observed{cb_cell=\"cb-$cloud-local\"}")
    if [ -z "$got" ]; then obs_bad "cb-$cloud-local: no observed split"; continue; fi
    got=$(python3 -I -c 'import sys;print(round(float(sys.argv[1])*100))' "$got")
    if [ "$got" -ge $(( want - 10 )) ] && [ "$got" -le $(( want + 10 )) ]; then
      obs_ok "cb-$cloud-local observed $got% (weight $want)"
    else
      obs_bad "cb-$cloud-local observed $got%, weight is $want"
    fi
  done
}

check_rules() {
  local name health
  for name in 'cb:requests:rate5m' 'cb:errors:rate5m' 'cb:latency_p95:5m' 'cb:error_ratio:rate5m' 'cb:availability:ratio_rate1h' 'cb:split:observed' 'cb:edge_error_ratio:rate5m'; do
    [ -n "$(prom_query "$name")" ] && obs_ok "recording rule $name has data" || obs_bad "recording rule $name has no data"
  done
  health=$(curl -sS -m 10 "$PROM_URL/api/v1/rules" | python3 -I -c '
import json,sys
rules=[r for g in json.load(sys.stdin)["data"]["groups"] for r in g["rules"]]
bad=[r["name"] for r in rules if r["health"]!="ok"]
print(len(rules), "rules," , "unhealthy:", bad or "none")')
  echo "     $health"
  case "$health" in *"unhealthy: none") obs_ok "every rule evaluates" ;; *) obs_bad "rule errors: $health" ;; esac
  [ "$(prom_value 'min(probe_success{job="blackbox-edge"})')" = 1 ] && obs_ok "blackbox probe through the edge succeeds, X-CB-Cell checked" || obs_bad "blackbox probe fails"
  curl -sS -m 10 "$PROM_URL/api/v1/rules?type=alert" | grep -q '"name":"ExitPlanEvidenceStale"[^}]*' && obs_ok "alert rules loaded" || obs_bad "alert rules missing"
  prom_query 'up{job="control-plane"} == 1' | grep -q control-plane && obs_ok "Prometheus scrapes the control-plane API" || obs_bad "Prometheus isn't scraping the control-plane API"
  prom_query 'ALERTS{alertname="ExitPlanEvidenceStale"}' | grep -q alertstate && obs_ok "ExitPlanEvidenceStale is active: no drill has ever run" || obs_bad "ExitPlanEvidenceStale isn't active, but no drill has run"
}

check_grafana() {
  python3 -I "$REPO/tools/dev/twin/check_grafana.py" "$GRAFANA_URL" "$REPO/observability/grafana/dashboards" || OBS_FAIL=1
}

observe() {
  check_write_path
  check_cells_report
  check_split
  check_rules
  check_grafana
  [ $OBS_FAIL -eq 0 ] && echo "TWIN OBSERVE PASSED" || { echo "TWIN OBSERVE FAILED"; exit 1; }
}

origin_ip() { docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$(compose ps -q "cell-$1")"; }

burn() { # order-service goes away for real; only the alert may say so. Argo CD is stopped meanwhile, or it would heal it.
  local cloud=$1 cell="cb-$1-local" deadline ip sink="$TWIN_DIR/observability/alerts/received.jsonl" before
  case "$cloud" in aws|gcp) ;; *) echo "burn aws|gcp"; exit 2 ;; esac
  restore_burn() {
    kc "$cloud" -n cb-app scale rollout order-service --replicas=1 >/dev/null 2>&1 || true
    kc "$cloud" -n argocd scale statefulset argocd-application-controller --replicas=1 >/dev/null 2>&1 || true
    docker rm -f cb-twin-burn >/dev/null 2>&1 || true
  }
  trap restore_burn EXIT
  before=$(wc -l <"$sink" 2>/dev/null || echo 0)
  kc "$cloud" -n argocd scale statefulset argocd-application-controller --replicas=0 >/dev/null
  kc "$cloud" -n cb-app scale rollout order-service --replicas=0 >/dev/null
  ip=$(origin_ip "$cloud")
  echo "order-service on $cell is gone; 5 orders a second straight at its origin"
  docker run -d --name cb-twin-burn --network cb-twin_twin -u root -v "$REPO/tools/load":/scripts:ro \
    -e CB_HOST="$HOST" -e CB_ORIGIN_IP="$ip" -e CB_SKU=SKU-1 -e CB_RATE=5 -e CB_DURATION=20m -e CB_ORDER_SHARE=1 \
    grafana/k6:2.3.0 run --quiet /scripts/per-pod-rps.js >/dev/null
  deadline=$(( $(date +%s) + 720 ))
  until prom_query "ALERTS{alertname=\"CellSLOBurnFast\",alertstate=\"firing\",cb_cell=\"$cell\"}" | grep -q firing; do
    [ "$(date +%s)" -lt "$deadline" ] || { obs_bad "CellSLOBurnFast did not fire on $cell in 12 minutes"; prom_query "cb:error_ratio:rate5m"; prom_query "cb:error_ratio:rate1h"; exit 1; }
    sleep 15
  done
  obs_ok "CellSLOBurnFast fires on $cell: $(prom_query "ALERTS{alertname=\"CellSLOBurnFast\",alertstate=\"firing\"}" | head -1 | cut -c1-140)"
  deadline=$(( $(date +%s) + 120 ))
  until tail -n +$(( before + 1 )) "$sink" | grep -q '"/endpoint"' && tail -n +$(( before + 1 )) "$sink" | grep -q '"/slack"'; do
    [ "$(date +%s)" -lt "$deadline" ] || { obs_bad "the alert did not reach both Slack and EDA"; exit 1; }
    sleep 5
  done
  tail -n +$(( before + 1 )) "$sink" | grep '"/endpoint"' | tail -1 | grep -q "$cell" && obs_ok "EDA webhook got it, labelled $cell" || obs_bad "EDA webhook payload doesn't name $cell"
  obs_ok "Slack stand-in got it"
  restore_burn; trap - EXIT
  echo "order-service restored; Argo CD resumes"
  [ $OBS_FAIL -eq 0 ] && echo "TWIN BURN PASSED" || { echo "TWIN BURN FAILED"; exit 1; }
}

capacity() { # the load SKU's lease is written straight into the cell, so stock can't end the test early
  local cloud=$1 cell="cb-$1-local"
  case "$cloud" in aws|gcp) ;; *) echo "capacity aws|gcp"; exit 2 ;; esac
  source "$REPO/tools/dev/twin/leases.sh"
  psql_cell "$cloud" "INSERT INTO inventory.products (sku, name, price_paise) VALUES ('SKU-LOAD', 'Load test', 49900) ON CONFLICT DO NOTHING;
    INSERT INTO inventory.inventory_lease (sku, granted_qty, sold_qty, lease_epoch, expires_at) VALUES ('SKU-LOAD', 100000000, 0, 1, now() + interval '1 day')
    ON CONFLICT (sku) DO UPDATE SET granted_qty = 100000000, expires_at = now() + interval '1 day'" >/dev/null
  python3 -I "$REPO/tools/load/measure_capacity.py" --cell "$cell" --origin-ip "$(origin_ip "$cloud")" --host "$HOST" \
    --network cb-twin_twin --prometheus "$PROM_URL" --sku SKU-LOAD ${CB_CAPACITY_RATES:+--rates "$CB_CAPACITY_RATES"}
}
