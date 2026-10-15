#!/usr/bin/env bash
# Installs what `make budget-up` runs on the operator's machine (WSL Ubuntu 24.04/26.04), pinned:
# terraform, AWS CLI v2 + Session Manager plugin, gcloud, make/jq, and ansible-core in a venv.
# Everything else (lint, tests) already runs in containers via tools/dev/iac-check.sh.
#   bash tools/dev/install-deploy-tools.sh
# Then, in every shell that deploys:  source ~/.venvs/cloudbridge/bin/activate
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
TERRAFORM_VERSION=1.15.9
ANSIBLE_CORE_VERSION=2.21.5
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUDO=$([ "$(id -u)" -eq 0 ] && echo "" || echo sudo)
ARCH=$(dpkg --print-architecture)               # amd64 | arm64
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

echo "== apt packages"
$SUDO apt-get update -qq
$SUDO apt-get install -y -qq make jq unzip curl ca-certificates gnupg python3-venv >/dev/null

echo "== terraform $TERRAFORM_VERSION (releases.hashicorp.com, checksum-verified)"
if ! terraform version 2>/dev/null | grep -q "v$TERRAFORM_VERSION"; then
  base="https://releases.hashicorp.com/terraform/$TERRAFORM_VERSION"
  zip="terraform_${TERRAFORM_VERSION}_linux_${ARCH}.zip"
  curl -fsSL -o "$tmp/$zip" "$base/$zip"
  curl -fsSL -o "$tmp/sums" "$base/terraform_${TERRAFORM_VERSION}_SHA256SUMS"
  (cd "$tmp" && grep " $zip\$" sums | sha256sum -c -)
  unzip -oq "$tmp/$zip" -d "$tmp" && $SUDO install -m 0755 "$tmp/terraform" /usr/local/bin/terraform
fi

echo "== AWS CLI v2 + Session Manager plugin"
if ! command -v aws >/dev/null; then
  a=$([ "$ARCH" = arm64 ] && echo aarch64 || echo x86_64)
  curl -fsSL -o "$tmp/awscli.zip" "https://awscli.amazonaws.com/awscli-exe-linux-$a.zip"
  unzip -q "$tmp/awscli.zip" -d "$tmp" && $SUDO "$tmp/aws/install" >/dev/null
fi
if ! command -v session-manager-plugin >/dev/null; then
  p=$([ "$ARCH" = arm64 ] && echo ubuntu_arm64 || echo ubuntu_64bit)
  curl -fsSL -o "$tmp/ssm.deb" "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/$p/session-manager-plugin.deb"
  $SUDO dpkg -i "$tmp/ssm.deb" >/dev/null
fi

echo "== Google Cloud CLI (apt repository)"
if ! command -v gcloud >/dev/null; then
  curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
    | $SUDO gpg --dearmor --yes -o /usr/share/keyrings/cloud.google.gpg
  echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
    | $SUDO tee /etc/apt/sources.list.d/google-cloud-sdk.list >/dev/null
  $SUDO apt-get update -qq && $SUDO apt-get install -y -qq google-cloud-cli >/dev/null
fi

echo "== ansible-core $ANSIBLE_CORE_VERSION + cloud SDKs in ~/.venvs/cloudbridge"
python3 -m venv ~/.venvs/cloudbridge
~/.venvs/cloudbridge/bin/pip install -q --upgrade pip
~/.venvs/cloudbridge/bin/pip install -q "ansible-core==$ANSIBLE_CORE_VERSION" boto3 botocore google-auth requests
~/.venvs/cloudbridge/bin/ansible-galaxy collection install --no-cache -r "$REPO/ansible/requirements.yml" >/dev/null

echo "== versions"
terraform version | head -1
aws --version
session-manager-plugin --version
gcloud version 2>/dev/null | head -1
~/.venvs/cloudbridge/bin/ansible --version | head -1
make --version | head -1; jq --version
echo "Done. In each deploy shell: source ~/.venvs/cloudbridge/bin/activate"
