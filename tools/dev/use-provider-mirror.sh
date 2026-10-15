#!/usr/bin/env bash
# For networks that can't download GitHub release assets: install the Cloudflare provider from the
# provider-mirror workflow's artifact and point Terraform at it. Every other provider still comes
# straight from the registry. Needs gh (authenticated) and the workflow run once:
#   gh workflow run provider-mirror.yml && sleep 60
#   bash tools/dev/use-provider-mirror.sh
set -euo pipefail
MIRROR="$HOME/.terraform.d/provider-mirror"
run=$(gh run list --workflow provider-mirror.yml --status success --limit 1 --json databaseId --jq '.[0].databaseId')
[ -n "$run" ] || { echo "No successful provider-mirror run yet: gh workflow run provider-mirror.yml"; exit 1; }
rm -rf "$MIRROR" && mkdir -p "$MIRROR"
gh run download "$run" -n terraform-provider-mirror -D "$MIRROR"

rc="$HOME/.terraformrc"
if [ -f "$rc" ] && ! grep -q "provider-mirror" "$rc"; then
  echo "$rc exists and wasn't written by this script; add this block yourself:"; rc=/dev/stdout
fi
cat > "$rc" <<EOF
# Written by tools/dev/use-provider-mirror.sh: cloudflare/cloudflare from the local mirror
# (provider-mirror workflow artifact), everything else from the registry as usual.
provider_installation {
  filesystem_mirror {
    path    = "$MIRROR"
    include = ["registry.terraform.io/cloudflare/cloudflare"]
  }
  direct {
    exclude = ["registry.terraform.io/cloudflare/cloudflare"]
  }
}
EOF
echo "Mirror ready in $MIRROR:"; find "$MIRROR" -name '*.zip' | sed "s|$MIRROR/||"
