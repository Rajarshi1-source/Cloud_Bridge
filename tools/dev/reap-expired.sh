#!/usr/bin/env bash
# Destroy ephemeral cells whose TTL has passed. One implementation for `make reap` (laptop) and
# ttl-reaper.yml (hourly): the expiry is read from each stack's own state (output expires_at), so
# both clouds work the same way and nothing depends on tag-search APIs.
#   bash tools/dev/reap-expired.sh aws gcp      # needs credentials for the clouds named
# Only *-dev stacks are ever considered; prod has no expiry and the facade refuses to give it one.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
now=$(date -u +%s)
status=0

for cloud in "$@"; do
  case "$cloud" in aws|gcp) ;; *) echo "skip unknown cloud: $cloud"; continue ;; esac
  stack="$REPO/infra/live/$cloud-dev/10-foundation"
  echo "== $cloud-dev"
  if ! terraform -chdir="$stack" init -input=false -no-color -lockfile=readonly >/dev/null; then
    echo "   init failed (credentials or state bucket?)"; status=1; continue
  fi
  expires=$(terraform -chdir="$stack" output -json 2>/dev/null | jq -r '.expires_at.value // empty')
  if [ -z "$expires" ]; then
    echo "   nothing deployed"; continue
  fi
  if [ "$expires" -gt "$now" ]; then
    echo "   alive for another $(( (expires - now) / 60 )) min (expires $(date -u -d "@$expires" +%FT%TZ))"; continue
  fi
  echo "   expired $(( (now - expires) / 60 )) min ago: destroying"
  # Destroy needs the stack's required variables; their values don't matter for a destroy plan.
  if TF_VAR_expires_at="$expires" TF_VAR_admin_cidrs='["192.0.2.1/32"]' \
       terraform -chdir="$stack" plan -destroy -input=false -no-color -lock-timeout=5m -out=reap.tfplan >/dev/null \
     && terraform -chdir="$stack" apply -input=false -no-color reap.tfplan; then
    echo "   destroyed"
  else
    echo "   DESTROY FAILED: the cell is still running and billing"; status=1
  fi
  rm -f "$stack/reap.tfplan"
done
exit $status
