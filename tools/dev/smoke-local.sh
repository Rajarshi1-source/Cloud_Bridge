#!/usr/bin/env bash
# End-to-end check of the local cell started with `docker compose up --build -d --wait`.
# Uses the `local` profile seed: SKU-1 (lease 100), SKU-2 (lease 20).
#   wsl -d Ubuntu-D -- bash tools/dev/smoke-local.sh        (from the repo root inside WSL)
set -euo pipefail
GW="${GW:-http://localhost:8080}"
pass=0
check() { # name, expected status, actual status
  if [ "$2" = "$3" ]; then echo "ok   $1 ($3)"; pass=$((pass + 1)); else echo "FAIL $1: expected $2, got $3"; cat /tmp/cb-body; echo; exit 1; fi
}
status() { curl -s -o /tmp/cb-body -w '%{http_code}' "$@"; }

check "cell health"            200 "$(status "$GW/healthz/cell")"
grep -q '"status":"UP"' /tmp/cb-body
curl -sI "$GW/healthz/cell" | grep -qi '^x-cb-cell: cb-local-dev' && echo "ok   X-CB-Cell header"

customer=$(cat /proc/sys/kernel/random/uuid)
key=$(cat /proc/sys/kernel/random/uuid)
order="{\"customerId\":\"$customer\",\"items\":[{\"sku\":\"SKU-1\",\"qty\":2,\"pricePaise\":49900}]}"

check "order without key"      400 "$(status -X POST -H 'Content-Type: application/json' -d "$order" "$GW/orders")"
check "create order"           201 "$(status -X POST -H 'Content-Type: application/json' -H "Idempotency-Key: $key" -d "$order" "$GW/orders")"
order_id=$(sed -E 's/.*"orderId":"([^"]+)".*/\1/' /tmp/cb-body)
check "replay same key"        201 "$(status -X POST -H 'Content-Type: application/json' -H "Idempotency-Key: $key" -d "$order" "$GW/orders")"
grep -q "$order_id" /tmp/cb-body && echo "ok   replay returned the same order $order_id"
check "same key, other body"   422 "$(status -X POST -H 'Content-Type: application/json' -H "Idempotency-Key: $key" \
  -d "{\"customerId\":\"$customer\",\"items\":[{\"sku\":\"SKU-1\",\"qty\":3,\"pricePaise\":49900}]}" "$GW/orders")"
check "read order"             200 "$(status "$GW/orders/$order_id")"
check "customer history"       200 "$(status "$GW/orders?customerId=$customer")"
check "inventory read model"   200 "$(status "$GW/inventory/SKU-1")"
check "more than the lease"    409 "$(status -X POST -H 'Content-Type: application/json' -H "Idempotency-Key: $(cat /proc/sys/kernel/random/uuid)" \
  -d "{\"customerId\":\"$customer\",\"items\":[{\"sku\":\"SKU-2\",\"qty\":21,\"pricePaise\":129900}]}" "$GW/orders")"
check "admin hidden"           404 "$(status -X POST "$GW/admin/leases/grant")"
echo "$pass checks passed"
