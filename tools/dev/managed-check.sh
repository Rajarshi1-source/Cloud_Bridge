#!/usr/bin/env bash
# Week 3's "done when" for an ephemeral managed cell: fetch credentials into a dedicated kubeconfig,
# wait until every node is Ready, and show when the TTL reaper will destroy it.
#   bash tools/dev/managed-check.sh gcp|aws
set -euo pipefail
cloud=${1:?usage: managed-check.sh aws|gcp}
stack="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/infra/live/$cloud-dev/10-foundation"
cluster=$(terraform -chdir="$stack" output -json cluster)
export KUBECONFIG="$HOME/.kube/cloudbridge-$cloud-dev"

case "$cloud" in
  gcp) gcloud container clusters get-credentials "$(jq -r .auth.cluster_name <<<"$cluster")" \
         --zone "$(jq -r .auth.location <<<"$cluster")" --project "$(jq -r .auth.project <<<"$cluster")" ;;
  aws) aws eks update-kubeconfig --name "$(jq -r .auth.cluster_name <<<"$cluster")" --region ap-south-1 ;;
  *) echo "cloud must be aws or gcp"; exit 2 ;;
esac

kubectl wait --for=condition=Ready nodes --all --timeout=600s
kubectl get nodes -o wide
expires=$(terraform -chdir="$stack" output -raw expires_at)
echo "Healthy. Reaped after $(date -u -d "@$expires" +%FT%TZ) (in $(( (expires - $(date -u +%s)) / 60 )) min). KUBECONFIG=$KUBECONFIG"
