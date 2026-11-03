# Sourced by tools/dev/twin.sh. The cost ledger on made-up FOCUS files, in a scratch database dropped at the
# end: the control plane's own ledger must stay empty, so its panels keep saying "no measurement yet" and
# CostDataStale keeps firing. Real AWS exports and the real GCP view have never been read here.
COST_DB=cost_scratch
cost_ok() { echo "ok   $1"; }
cost_bad() { echo "FAIL $1"; COST_FAIL=1; }

cost_sql() { compose exec -T twin-cp-db psql -v ON_ERROR_STOP=1 -q -U allocator "$@"; }

cost_ledger() {
  COST_FAIL=0
  local work password day old dsn token
  work=$(mktemp -d); chmod 777 "$work"
  password=$(cat "$TWIN_DIR/control-plane/cp_writer_password")
  dsn="postgresql://cp_writer:$password@twin-cp-db:5432/$COST_DB"
  token=$(sed -n 's/^CB_CP_TOKEN=//p' "$TWIN_DIR/control-plane/api.env")
  day=$(date -u -d yesterday +%F); old=$(date -u -d '5 days ago' +%F)
  cleanup_cost() {
    rm -rf "$work"
    compose exec -T twin-cp-db psql -q -U allocator -d allocator -c "DROP DATABASE IF EXISTS $COST_DB WITH (FORCE)" >/dev/null 2>&1 || true
  }
  trap cleanup_cost EXIT

  collect() { # a job against the scratch database
    docker run --rm --network cb-twin_twin -e DATABASE_URL="$dsn" -e CB_CELLS_FILE=/parity/cells.yaml \
      -v "$REPO/parity":/parity:ro -v "$work":/out cloudbridge/cost-collector:local "$@"
  }
  scratch_cost() { # what the API would answer, from the API's own query code
    docker run --rm --network cb-twin_twin -e CB_CP_TOKEN=unused -e DATABASE_URL="$dsn" cloudbridge/cp-api:local python -c '
import json, os, psycopg
from cpapi import queries
with psycopg.connect(os.environ["DATABASE_URL"], autocommit=True) as conn:
    answer = queries.cost(conn)
    latest = conn.execute(queries.BILLING_LATEST).fetchone()
    answer["billing_latest"] = latest[0] if latest else None
    print(json.dumps(answer, default=str))'
  }
  expect() { # label, python expression over c (the answer)
    if echo "$COST_ANSWER" | python3 -I -c "import json,sys; c=json.load(sys.stdin); sys.exit(0 if ($2) else 1)"; then cost_ok "$1"; else cost_bad "$1"; echo "     $COST_ANSWER" | cut -c1-600; fi
  }

  compose --progress quiet --profile jobs build twin-collector
  cost_sql -d allocator -c "DROP DATABASE IF EXISTS $COST_DB WITH (FORCE)" -c "CREATE DATABASE $COST_DB"
  local f
  for f in "$REPO"/control-plane/migrations/V*.sql; do cost_sql -d "$COST_DB" <"$f"; done
  cost_ok "migrations V1-V$(ls "$REPO"/control-plane/migrations/V*.sql | wc -l) apply to an empty database"
  collect cells | sed 's/^/     /'

  docker run --rm -v "$REPO/control-plane/cost-collector/samples":/samples:ro -v "$work":/out --entrypoint python \
    cloudbridge/cost-collector:local /samples/make_samples.py /out "$day"

  local first again
  first=$(collect file --provider aws --path /out/aws.parquet --key aws.parquet)
  again=$(collect file --provider aws --path /out/aws.parquet --key aws.parquet)
  grep -q 'inserted 4' <<<"$first" && cost_ok "a file goes in as one transaction: $first" || cost_bad "first ingest: $first"
  grep -q 'unchanged 4' <<<"$again" && cost_ok "the same file again changes nothing" || cost_bad "second ingest: $again"
  [ "$(cost_sql -d "$COST_DB" -Atc 'SELECT count(*) FROM cost_line_items' | tr -d '\r')" = 4 ] && cost_ok "4 rows, not 8" || cost_bad "re-ingesting duplicated rows"

  COST_ANSWER=$(scratch_cost)
  expect "no share and no requests yet: no unit cost anywhere" "all(r['cost_per_1k'] is None for r in c['per_service'])"
  expect "shared cost with no share is shown, not dropped (20)" "c['shared_without_share'] == [{'cell_id':'cb-aws-local','currency':'XXX','cost':20.0}]"
  expect "untagged cost is shown as unallocated, not spread (5)" "[u['cost'] for u in c['unallocated']] == [5.0]"
  expect "one cloud's export alone publishes no freshness gauge" "c['billing_latest'] is None"

  cost_sql -d "$COST_DB" <<SQL
INSERT INTO allocation_daily (day, cell_id, service, cpu_share, mem_share) VALUES
  ('$day', 'cb-aws-local', 'order-service', 0.5, 0.5), ('$day', 'cb-aws-local', 'api-gateway', 0.25, 0.25);
INSERT INTO request_volume_daily (day, cell_id, service, requests, errors) VALUES
  ('$day', 'cb-aws-local', 'order-service', 4000, 0), ('$day', 'cb-aws-local', 'api-gateway', 10000, 0),
  ('$old', 'cb-aws-local', 'order-service', 999999, 0);
SQL
  COST_ANSWER=$(scratch_cost)
  local order='next(r for r in c["per_service"] if r["service"]=="order-service")'
  local gateway='next(r for r in c["per_service"] if r["service"]=="api-gateway")'
  # By hand. order-service: 10 direct + 20 shared x 0.5 = 20, over 4,000 requests = 5 per 1,000.
  # api-gateway: 20 shared x 0.25 = 5, over 10,000 requests = 0.5 per 1,000.
  expect "order-service costs 5.0000 per 1,000, as worked by hand" "$order['cost_per_1k'] == 5.0 and $order['effective_cost'] == 20.0"
  expect "api-gateway costs 0.5000 per 1,000, as worked by hand" "$gateway['cost_per_1k'] == 0.5"
  expect "requests on a day with no bill don't dilute the unit cost" "$order['requests'] == 4000"
  expect "a credit never lowers a unit cost, and is reported beside it" "c['not_usage'] == [{'cell_id':'cb-aws-local','charge_category':'Credit','currency':'XXX','cost':-100.0}]"

  local restated
  restated=$(collect file --provider aws --path /out/aws-restated.parquet --key aws.parquet)
  grep -q 'replaced 4' <<<"$restated" && cost_ok "a restated file replaces its earlier version" || cost_bad "restated ingest: $restated"
  COST_ANSWER=$(scratch_cost)
  # 12 direct + 10 shared = 22, over 4,000 = 5.5
  expect "after the restatement order-service costs 5.5000 per 1,000" "$order['cost_per_1k'] == 5.5"
  [ "$(cost_sql -d "$COST_DB" -Atc 'SELECT count(*) FROM cost_line_items' | tr -d '\r')" = 4 ] && cost_ok "still 4 rows" || cost_bad "the restatement kept the old rows"
  [ "$(cost_sql -d "$COST_DB" -Atc 'SELECT count(*) FROM cost_ingestions' | tr -d '\r')" = 1 ] && cost_ok "and one ingestion record" || cost_bad "the old version's ingestion record stayed"

  collect file --provider gcp --path /out/gcp.parquet --key gcp.parquet | sed 's/^/     /'
  COST_ANSWER=$(scratch_cost)
  expect "a GCP cell with no allocation has no unit cost, and its 7 is flagged" "any(s['cell_id']=='cb-gcp-local' and s['cost']==7.0 for s in c['shared_without_share']) and not any(r['cell_id']=='cb-gcp-local' for r in c['per_service'])"
  expect "with both clouds delivered, the freshness gauge appears" "c['billing_latest'] is not None"
  cost_sql -d "$COST_DB" -c "INSERT INTO request_volume_daily (day, cell_id, service, requests, errors) VALUES ('$old', 'cb-gcp-budget', 'api-gateway', 5000, 0)"
  COST_ANSWER=$(scratch_cost)
  expect "requests on a cell with no bill at all are no row, never a cost of 0" "not any(r['cell_id']=='cb-gcp-budget' for r in c['per_service'])"

  if collect file --provider aws --path /out/out-of-range.parquet --key bad.parquet >/dev/null 2>&1; then
    cost_bad "a row older than every partition was accepted"
  else
    [ "$(cost_sql -d "$COST_DB" -Atc "SELECT count(*) FROM cost_ingestions WHERE source_file LIKE '%bad.parquet%'" | tr -d '\r')" = 0 ] \
      && cost_ok "a file that can't be stored fails whole, and leaves no trace" || cost_bad "a failed file left an ingestion record"
  fi
  if docker run --rm --network cb-twin_twin postgres:18.4-alpine psql "$dsn" -Atc "CREATE TABLE cost_line_items_writer_test () " >/dev/null 2>&1; then
    # Schema public gives PostgreSQL 15+ no CREATE to ordinary roles, so this should never happen.
    cost_bad "cp_writer may create tables: it should only reach partitions through ensure_cost_partitions()"
  else
    cost_ok "cp_writer can't create tables; partitions go through ensure_cost_partitions() alone"
  fi

  echo "== the control plane's own database, which must hold no sample"
  [ "$(cost_sql -d controlplane -Atc 'SELECT count(*) FROM cost_line_items' | tr -d '\r')" = 0 ] && cost_ok "its ledger is empty" || cost_bad "its ledger holds rows"
  compose --profile jobs run --rm --no-deps twin-collector ledger | sed 's/^/     /'
  compose --profile jobs run --rm --no-deps twin-collector allocation | sed 's/^/     /'
  compose --profile jobs run --rm --no-deps twin-collector volumes | sed 's/^/     /'
  compose exec -T twin-cp-db psql -U allocator -d controlplane -c "SELECT day, cell_id, service, requests, errors, p95_ms FROM request_volume_daily ORDER BY 1, 2, 3" | sed 's/^/     /'
  # The job reads whole days, so a Prometheus younger than a day gives it nothing. Today, so far, proves the
  # queries against real series and writes nothing.
  local today
  today=$(docker run --rm --network cb-twin_twin --entrypoint python cloudbridge/cost-collector:local -c '
from datetime import datetime, timezone
from collector.pullers import request_volumes
cells = {"cb-aws-local", "cb-gcp-local"}
for row in request_volumes("http://prometheus:9090", datetime.now(timezone.utc).date(), cells):
    print(*row[1:])')
  sed 's/^/     today so far: /' <<<"$today"
  if [ "$(curl -sG -m 15 "http://127.0.0.1:9090/api/v1/query" --data-urlencode 'query=sum(increase(http_server_requests_seconds_count{uri!~"/actuator.*|/healthz.*"}[1h]))' | grep -c '"value"')" = 0 ]; then
    echo "     no requests in the last hour, so the volume query has nothing to prove here"
  else
    grep -q 'api-gateway [1-9]' <<<"$today" && cost_ok "the volume query reads real requests from Prometheus" || cost_bad "Prometheus has requests but the volume query found none"
  fi

  local answer
  answer=$(curl -sS -m 15 -H "Authorization: Bearer $token" "http://127.0.0.1:${CB_TWIN_API_PORT:-8010}/cost")
  grep -q '"per_service":\[\]' <<<"$answer" && cost_ok "GET /cost has no unit costs" || cost_bad "GET /cost: $(cut -c1-300 <<<"$answer")"
  curl -sS -m 15 "http://127.0.0.1:${CB_TWIN_API_PORT:-8010}/metrics" | grep -q cb_billing_latest_timestamp \
    && cost_bad "/metrics reports a billing time with no billing data" || cost_ok "/metrics has no billing gauge, so CostDataStale's absent() holds"

  echo "== the path through Access"
  local cp="cp.$DOMAIN" cp_secret metrics_secret
  cp_secret=$(sed -n 's/^CF_ACCESS_CLIENT_SECRET=//p' "$TWIN_DIR/access/cp.env")
  metrics_secret=$(sed -n 's/^CF_ACCESS_CLIENT_SECRET=//p' "$TWIN_DIR/access/metrics.env")
  via() { # host, path, then curl arguments; prints the status code
    local h=$1 p=$2; shift 2
    curl -sS -m 15 -o /dev/null -w '%{http_code}' --cacert "$TWIN_DIR/pki/ca.crt" --resolve "$h:$EDGE_PORT:127.0.0.1" "$@" "https://$h:$EDGE_PORT$p"
  }
  local as_cp=(-H "CF-Access-Client-Id: $TWIN_CP_ID" -H "CF-Access-Client-Secret: $cp_secret")
  want() { [ "$2" = "$3" ] && cost_ok "$1 -> $2" || cost_bad "$1 -> $2 (want $3)"; }
  want "cp host with no service token" "$(via "$cp" /)" 403
  want "cp host with the metrics token" "$(via "$cp" / -H "CF-Access-Client-Id: $TWIN_METRICS_ID" -H "CF-Access-Client-Secret: $metrics_secret")" 403
  want "admin host with the cp token" "$(via "admin-aws.$DOMAIN" /admin/leases/report "${as_cp[@]}")" 403
  want "dashboard with the cp token" "$(via "$cp" / "${as_cp[@]}")" 200
  want "API health with the cp token" "$(via "$cp" /api/healthz "${as_cp[@]}")" 200
  want "API overview with the cp token, no bearer" "$(via "$cp" /api/overview "${as_cp[@]}")" 401
  want "API overview with both" "$(via "$cp" /api/overview "${as_cp[@]}" -H "Authorization: Bearer $token")" 200

  cleanup_cost; trap - EXIT
  [ "$COST_FAIL" -eq 0 ] && echo "TWIN COST PASSED" || { echo "TWIN COST FAILED"; exit 1; }
}
