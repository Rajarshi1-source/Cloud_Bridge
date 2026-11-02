# Week 4 "done when" on the twin, sourced by twin.sh (bash tools/dev/twin.sh leases): the allocator
# really grants both cells through the edge and Access stand-in, a forged grant never lands, an order
# survives pod restarts, a repeated POST returns the same order, and stock is never oversold.
LEASE_FAIL=0
lease_ok() { echo "ok   $1"; }
lease_bad() { echo "FAIL $1"; LEASE_FAIL=1; }
expect() { # name, wanted status, actual status
  if [ "$2" = "$3" ]; then lease_ok "$1 -> $3"; else lease_bad "$1 -> $3 (want $2)"; fi
}

admin_host() { echo "admin-$1.$DOMAIN"; }
admin_curl() { # cloud, curl args (through the edge, with Access in front)
  local host; host=$(admin_host "$1")
  curl -sS -m 10 --cacert "$TWIN_DIR/pki/ca.crt" --resolve "$host:$EDGE_PORT:127.0.0.1" "${@:2}"
}
admin_url() { echo "https://$(admin_host "$1"):$EDGE_PORT$2"; }
allocator_auth() { # the allocator's service token as curl headers
  sed -n 's/^CF_ACCESS_CLIENT_ID=/CF-Access-Client-Id: /p; s/^CF_ACCESS_CLIENT_SECRET=/CF-Access-Client-Secret: /p' \
    "$TWIN_DIR/access/allocator.env" | sed 's/^/-H\n/'
}
token_args() { mapfile -t TOKEN_ARGS < <(allocator_auth); }
origin_curl() { # cloud, curl args: straight at the cell's ingress, as an attacker who found the origin would
  local id ip host; host=$(admin_host "$1")
  id=$(compose ps -q "cell-$1"); ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$id")
  curl -sS -m 10 --cacert "$TWIN_DIR/pki/ca.crt" --resolve "$host:443:$ip" "${@:2}"
}
origin_url() { echo "https://$(admin_host "$1")$2"; }
report() { admin_curl "$1" "${TOKEN_ARGS[@]}" "$(admin_url "$1" /admin/leases/report)"; }
# One figure of a SKU's lease from a report on stdin: lease_field SKU-1 grantedQty
lease_field() { python3 -I -c 'import json,sys
rows=[r for r in json.load(sys.stdin) if r["sku"]==sys.argv[1]]
print(rows[0][sys.argv[2]] if rows else 0)' "$1" "$2"; }
grant_body() { # sku remaining reportedSold epoch ttl_seconds
  printf '{"sku":"%s","remainingQty":%s,"reportedSold":%s,"epoch":%s,"expiresAt":"%s"}' \
    "$1" "$2" "$3" "$4" "$(date -u -d "+$5 seconds" +%Y-%m-%dT%H:%M:%SZ)"
}
post_grant() { # cloud body, then curl args: prints the status
  admin_curl "$1" -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d "$2" "${@:3}" \
    "$(admin_url "$1" /admin/leases/grant)"
}
psql_cell() { # cloud sql: as the cell's own database user
  kc "$1" -n cb-app exec statefulset/postgres -- sh -c \
    'PGPASSWORD="$POSTGRES_PASSWORD" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "$0"' "$2"
}

wait_for_grants() {
  local deadline=$(( $(date +%s) + 240 )) cloud epoch
  for cloud in $CELLS; do
    until epoch=$(report "$cloud" 2>/dev/null | lease_field SKU-1 leaseEpoch 2>/dev/null) && [ "${epoch:-0}" -ge 1 ]; do
      [ "$(date +%s)" -lt "$deadline" ] || { lease_bad "no grant reached cb-$cloud-local in 240 s"; compose logs --tail 20 twin-allocator; return 1; }
      sleep 5
    done
    lease_ok "cb-$cloud-local holds a lease from the allocator (epoch $epoch)"
  done
}

check_grants_within_stock() {
  local sku stock total g
  for sku in SKU-1 SKU-2; do
    stock=$(compose exec -T twin-cp-db psql -U allocator -d allocator -Atc "SELECT total_qty FROM stock WHERE sku='$sku'" | tr -d '\r')
    total=0
    for cloud in $CELLS; do g=$(report "$cloud" | lease_field "$sku" grantedQty); total=$(( total + g )); done
    [ "$total" -le "$stock" ] && lease_ok "$sku: granted across cells $total <= stock $stock" || lease_bad "$sku: granted $total > stock $stock"
  done
}

check_forged_grants() {
  local epoch body code forged other
  epoch=$(report aws | lease_field SKU-1 leaseEpoch)
  body=$(grant_body SKU-1 9999 0 $(( epoch + 1 )) 600)
  expect "forged grant, no token, through the edge" 403 "$(post_grant aws "$body")"
  expect "forged grant, wrong secret, through the edge" 403 \
    "$(post_grant aws "$body" -H 'CF-Access-Client-Id: twin-allocator.access' -H 'CF-Access-Client-Secret: guess')"
  code=$(edge_curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d "$body" \
    "${TOKEN_ARGS[@]}" "$(edge_url /admin/leases/grant)")
  expect "grant with the real token on the public host" 404 "$code"
  code=$(origin_curl aws -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d "$body" \
    "$(origin_url aws /admin/leases/grant)")
  expect "forged grant straight at the origin, no JWT" 401 "$code"
  forged=$(docker run --rm "$TOOLBOX_IMAGE" python3 -I -c '
import base64,json,sys,time
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import padding,rsa
b=lambda r: base64.urlsafe_b64encode(r).rstrip(b"=").decode()
now=int(time.time())
msg=b(json.dumps({"alg":"RS256","kid":sys.argv[1],"typ":"JWT"}).encode())+"."+b(json.dumps(
  {"iss":sys.argv[2],"aud":[sys.argv[3]],"common_name":sys.argv[4],"iat":now,"nbf":now,"exp":now+300}).encode())
print(msg+"."+b(rsa.generate_private_key(public_exponent=65537,key_size=2048).sign(msg.encode(),padding.PKCS1v15(),hashes.SHA256())))
' forged "$ACCESS_ISSUER" "$ACCESS_AUD" "$ACCESS_CLIENT_ID")
  code=$(origin_curl aws -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d "$body" \
    -H "Cf-Access-Jwt-Assertion: $forged" "$(origin_url aws /admin/leases/grant)")
  expect "right claims signed with the attacker's own key, at the origin" 401 "$code"
  other=$(sed -n 's/.*"twin-other.access": *"\([^"]*\)".*/\1/p' "$TWIN_DIR/access/service-tokens.json")
  expect "a valid Access token that is not on the cell's allowlist" 403 \
    "$(post_grant aws "$body" -H 'CF-Access-Client-Id: twin-other.access' -H "CF-Access-Client-Secret: $other")"
  [ "$(report aws | lease_field SKU-1 leaseEpoch)" -lt $(( epoch + 2 )) ] \
    && lease_ok "none of those moved the lease" || lease_bad "a forged grant moved the lease"
}

check_grant_bounds() { # the real token, with values a buggy allocator might send
  local epoch sold granted
  epoch=$(report aws | lease_field SKU-2 leaseEpoch)
  sold=$(report aws | lease_field SKU-2 soldQty)
  expect "authenticated grant, stale epoch" 409 "$(post_grant aws "$(grant_body SKU-2 1 "$sold" 1 600)" "${TOKEN_ARGS[@]}")"
  expect "authenticated grant, epoch jump" 422 "$(post_grant aws "$(grant_body SKU-2 1 "$sold" $(( epoch + 5000 )) 600)" "${TOKEN_ARGS[@]}")"
  expect "authenticated grant, 2 h lease" 422 "$(post_grant aws "$(grant_body SKU-2 1 "$sold" $(( epoch + 1 )) 7200)" "${TOKEN_ARGS[@]}")"
  expect "authenticated grant, quantity over the cap" 422 "$(post_grant aws "$(grant_body SKU-2 100000 "$sold" $(( epoch + 1 )) 600)" "${TOKEN_ARGS[@]}")"
  expect "authenticated grant, unknown SKU" 422 "$(post_grant aws "$(grant_body NO-SUCH-SKU 1 0 1 600)" "${TOKEN_ARGS[@]}")"
  granted=$(psql_cell aws "SELECT count(*) FROM inventory.lease_grant_log WHERE outcome='OUT_OF_BOUNDS' OR outcome='UNKNOWN_SKU'" | tr -d '\r')
  [ "${granted:-0}" -ge 4 ] && lease_ok "rejected attempts are in the audit log ($granted rows)" || lease_bad "audit log has only ${granted:-0} rejected rows"
}

place_order() { # args: key, then the jar; prints "status orderId"
  local customer=11111111-1111-4111-8111-111111111111
  edge_curl -s -o "$TWIN_DIR/order-body" -w '%{http_code}' -b "$2" -c "$2" -X POST -H 'Content-Type: application/json' \
    -H "Idempotency-Key: $1" -H "CF-Connecting-IP: 203.0.113.9" \
    -d "{\"customerId\":\"$customer\",\"items\":[{\"sku\":\"SKU-1\",\"qty\":1,\"pricePaise\":49900}]}" "$(edge_url /orders)"
  # A replay's body comes from jsonb, so it has the same fields with different spacing and order.
  echo " $(sed -E 's/.*"orderId": *"([^"]+)".*/\1/' "$TWIN_DIR/order-body")"
}

check_orders() {
  local jar key first again cell cloud id code
  jar=$(mktemp); key=$(cat /proc/sys/kernel/random/uuid)
  first=$(place_order "$key" "$jar"); id=${first#* }
  expect "order placed through the edge" 201 "${first%% *}"
  again=$(place_order "$key" "$jar")
  [ "$again" = "$first" ] && lease_ok "repeat POST with the same key returned the same order $id" \
    || lease_bad "repeat POST: first '$first', then '$again'"
  cell=$(edge_curl -s -o /dev/null -D - -b "$jar" "$(edge_url "/orders/$id")" | tr -d '\r' | sed -n 's/^[Xx]-[Cc][Bb]-[Cc]ell: //p')
  cloud=${cell#cb-}; cloud=${cloud%-local}
  echo "     order lives in $cell; restarting its order-service, inventory-service and postgres pods"
  kc "$cloud" -n cb-app delete pod -l 'app in (order-service,inventory-service,postgres)' --wait=false >/dev/null
  sleep 5
  kc "$cloud" -n cb-app wait --for=condition=Ready pod -l 'app in (order-service,inventory-service,postgres)' --timeout=240s >/dev/null \
    && lease_ok "pods are back" || lease_bad "pods did not come back in 240 s"
  local deadline=$(( $(date +%s) + 120 ))
  until code=$(edge_curl -s -o "$TWIN_DIR/order-body" -w '%{http_code}' -b "$jar" "$(edge_url "/orders/$id")") && [ "$code" = 200 ]; do
    [ "$(date +%s)" -lt "$deadline" ] || break
    sleep 3
  done
  [ "$code" = 200 ] && grep -q "$id" "$TWIN_DIR/order-body" && lease_ok "the order survived the restart" \
    || lease_bad "order after the restart: status $code"
  again=$(place_order "$key" "$jar")
  [ "$again" = "$first" ] && lease_ok "the same key still returns the same order after the restart" \
    || lease_bad "after the restart the same key gave '$again'"
  rm -f "$jar"
}

check_no_oversell() { # far more orders than SKU-2 stock, on both cells at once, across several grant cycles
  local stock results sold=0 before=0 cloud accepted
  # 20 more than has ever been sold, so the check also works on a twin that ran it before.
  for cloud in $CELLS; do before=$(( before + $(report "$cloud" | lease_field SKU-2 soldQty) )); done
  stock=$(( before + 20 ))
  compose exec -T twin-cp-db psql -U allocator -d allocator -qc "UPDATE stock SET total_qty=$stock WHERE sku='SKU-2'" >/dev/null
  sleep $(( 2 * ${ALLOCATOR_INTERVAL:-20} ))
  results=$(mktemp)
  local round i
  for round in 1 2 3 4 5; do
    for i in $(seq 40); do
      (
        k=$(cat /proc/sys/kernel/random/uuid)
        edge_curl -s -m 15 -o /dev/null -w '%{http_code}\n' -X POST -H 'Content-Type: application/json' \
          -H "Idempotency-Key: $k" -H "CF-Connecting-IP: 203.0.113.$(( RANDOM % 250 + 1 ))" \
          -d "{\"customerId\":\"$k\",\"items\":[{\"sku\":\"SKU-2\",\"qty\":1,\"pricePaise\":129900}]}" "$(edge_url /orders)" >>"$results"
      ) &
      [ $(( i % 8 )) -eq 0 ] && wait
    done
    wait
    sleep "${ALLOCATOR_INTERVAL:-20}"
  done
  accepted=$(grep -c '^201' "$results" || true)
  for cloud in $CELLS; do sold=$(( sold + $(report "$cloud" | lease_field SKU-2 soldQty) )); done
  echo "     200 orders against 20 available (stock $stock, $before sold before): $accepted accepted, $(grep -c '^409' "$results" || true) out of stock, sold across cells $sold"
  [ "$sold" -le "$stock" ] && lease_ok "never oversold: sold $sold <= stock $stock" || lease_bad "OVERSOLD: sold $sold > stock $stock"
  [ "$accepted" -le 20 ] && lease_ok "accepted orders within the 20 added" || lease_bad "accepted $accepted orders against the 20 added"
  [ "$accepted" -ge 1 ] && lease_ok "orders were actually sold" || lease_bad "no order was accepted"
  rm -f "$results"
}

check_regrant_after_outage() { # gcp disappears: its quantity stays reserved until expires_at + margin
  local expires before during after t0 deadline epoch_before
  before=$(report aws | lease_field SKU-1 grantedQty)
  expires=$(report gcp | lease_field SKU-1 expiresAt)
  echo "     aws holds $before; pausing cell-gcp, whose lease runs to $expires"
  compose pause cell-gcp >/dev/null
  trap 'compose unpause cell-gcp >/dev/null 2>&1 || true' EXIT
  t0=$(date +%s)
  deadline=$(( t0 + 45 ))
  epoch_before=$(report aws | lease_field SKU-1 leaseEpoch)
  until [ "$(report aws | lease_field SKU-1 leaseEpoch)" -gt "$epoch_before" ] && compose logs --since "$(( $(date +%s) - t0 + 1 ))s" twin-allocator 2>/dev/null | grep -q "unreachable \['gcp'\]"; do
    [ "$(date +%s)" -lt "$deadline" ] || break
    sleep 3
  done
  during=$(report aws | lease_field SKU-1 grantedQty)
  [ "$during" -lt "$before" ] && lease_ok "while gcp may still sell, aws is not given its quantity ($before -> $during)" \
    || lease_bad "aws holds $during during the outage, had $before"
  # expiry + margin passes; aws's share then grows again from what gcp last reported.
  deadline=$(( $(date -u -d "$expires" +%s) + 60 + 3 * ${ALLOCATOR_INTERVAL:-20} + 20 ))
  until [ "$(report aws | lease_field SKU-1 grantedQty)" -gt "$during" ]; do
    [ "$(date +%s)" -lt "$deadline" ] || break
    sleep 5
  done
  after=$(report aws | lease_field SKU-1 grantedQty)
  local waited=$(( $(date +%s) - t0 ))
  [ "$after" -gt "$during" ] && lease_ok "after expiry + 60 s the quantity is re-granted ($during -> $after, $waited s into the outage)" \
    || lease_bad "aws still holds $after after expiry + margin"
  [ "$(date +%s)" -ge $(( $(date -u -d "$expires" +%s) + 60 )) ] && lease_ok "the re-grant came no earlier than expiry + 60 s" \
    || lease_bad "re-granted before expiry + 60 s"
  compose unpause cell-gcp >/dev/null; trap - EXIT
  deadline=$(( $(date +%s) + 180 ))
  local e0; e0=$(compose exec -T twin-cp-db psql -U allocator -d allocator -Atc "SELECT max(epoch) FROM lease_grants WHERE cell_id='gcp'" | tr -d '\r')
  until [ "$(compose exec -T twin-cp-db psql -U allocator -d allocator -Atc "SELECT max(epoch) FROM lease_grants WHERE cell_id='gcp'" | tr -d '\r')" -gt "$e0" ]; do
    [ "$(date +%s)" -lt "$deadline" ] || { lease_bad "gcp got no new grant within 180 s of returning"; return; }
    sleep 5
  done
  lease_ok "gcp is back and being granted again"
}

leases() {
  token_args
  ACCESS_ISSUER=$(access_issuer); ACCESS_AUD=$TWIN_ACCESS_AUD; ACCESS_CLIENT_ID=$TWIN_ALLOCATOR_ID
  wait_for_grants || exit 1
  check_grants_within_stock
  check_forged_grants
  check_grant_bounds
  check_orders
  check_no_oversell
  check_regrant_after_outage
  check_grants_within_stock
  if [ $LEASE_FAIL -eq 0 ]; then echo "LEASE CHECK PASSED"; else echo "LEASE CHECK FAILED"; exit 1; fi
}
