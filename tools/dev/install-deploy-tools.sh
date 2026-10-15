#!/usr/bin/env bash
# Installs what `make budget-up` runs on the operator's machine (WSL Ubuntu 24.04/26.04), pinned and
# integrity-checked (Terraform SHA256SUMS, AWS CLI + Session Manager plugin GPG signatures, signed apt repo):
# terraform, AWS CLI v2 + Session Manager plugin, gcloud + GKE auth plugin, kubectl, make/jq, and
# ansible-core in a venv.
# Everything else (lint, tests) already runs in containers via tools/dev/iac-check.sh.
#   bash tools/dev/install-deploy-tools.sh
# Then, in every shell that deploys:  source ~/.venvs/cloudbridge/bin/activate
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
TERRAFORM_VERSION=1.15.9
ANSIBLE_CORE_VERSION=2.21.5
AWS_CLI_VERSION=2.38.1
SSM_PLUGIN_VERSION=1.2.896.0
KUBECTL_VERSION=v1.36.5        # same minor as the cells (EKS, GKE, k3s)
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

# Verify a detached signature with a key committed in tools/dev/keys/ (copied from AWS's install docs),
# in a throwaway keyring, and require that exact signing key: a valid signature from any other key fails.
verify_sig() { # verify_sig <key.asc> <expected primary fingerprint> <file.sig> <file>
  local home; home=$(mktemp -d)
  gpg --homedir "$home" --batch --quiet --import "$1" 2>/dev/null
  if ! gpg --homedir "$home" --batch --status-fd 1 --verify "$3" "$4" 2>/dev/null \
      | grep -Eq "^\[GNUPG:\] VALIDSIG .* $2\$"; then
    echo "SIGNATURE CHECK FAILED for $(basename "$4"): not installing"; rm -rf "$home"; exit 1
  fi
  rm -rf "$home"; echo "signature OK: $(basename "$4")"
}

echo "== AWS CLI $AWS_CLI_VERSION + Session Manager plugin $SSM_PLUGIN_VERSION (signatures verified)"
if ! aws --version 2>/dev/null | grep -q "aws-cli/$AWS_CLI_VERSION "; then
  a=$([ "$ARCH" = arm64 ] && echo aarch64 || echo x86_64)
  url="https://awscli.amazonaws.com/awscli-exe-linux-$a-$AWS_CLI_VERSION.zip"
  curl -fsSL -o "$tmp/awscli.zip" "$url" && curl -fsSL -o "$tmp/awscli.zip.sig" "$url.sig"
  verify_sig "$REPO/tools/dev/keys/aws-cli.asc" FB5DB77FD5C118B80511ADA8A6310ACC4672475C "$tmp/awscli.zip.sig" "$tmp/awscli.zip"
  unzip -q "$tmp/awscli.zip" -d "$tmp" && $SUDO "$tmp/aws/install" --update >/dev/null
fi
if ! session-manager-plugin --version 2>/dev/null | grep -qx "$SSM_PLUGIN_VERSION"; then
  p=$([ "$ARCH" = arm64 ] && echo ubuntu_arm64 || echo ubuntu_64bit)
  url="https://s3.amazonaws.com/session-manager-downloads/plugin/$SSM_PLUGIN_VERSION/$p/session-manager-plugin.deb"
  curl -fsSL -o "$tmp/ssm.deb" "$url" && curl -fsSL -o "$tmp/ssm.deb.sig" "$url.sig"
  verify_sig "$REPO/tools/dev/keys/session-manager-plugin.asc" 7959637124CE093AD501D47A2C4D4AFF6F6757EE "$tmp/ssm.deb.sig" "$tmp/ssm.deb"
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

echo "== kubectl $KUBECTL_VERSION (dl.k8s.io, checksum-verified) + GKE auth plugin"
if ! kubectl version --client 2>/dev/null | grep -q "$KUBECTL_VERSION"; then
  base="https://dl.k8s.io/release/$KUBECTL_VERSION/bin/linux/$ARCH"
  curl -fsSL -o "$tmp/kubectl" "$base/kubectl"
  echo "$(curl -fsSL "$base/kubectl.sha256")  $tmp/kubectl" | sha256sum -c -
  $SUDO install -m 0755 "$tmp/kubectl" /usr/local/bin/kubectl
fi
$SUDO apt-get install -y -qq google-cloud-cli-gke-gcloud-auth-plugin >/dev/null

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
kubectl version --client | head -1
gke-gcloud-auth-plugin --version 2>/dev/null | head -1
~/.venvs/cloudbridge/bin/ansible --version | head -1
make --version | head -1; jq --version
echo "Done. In each deploy shell: source ~/.venvs/cloudbridge/bin/activate"
