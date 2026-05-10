#!/usr/bin/env bash
# Generate / prompt for NetBox secrets and write a sealed-secrets manifest.
# Idempotent — re-running prompts again with the existing values as defaults.
set -euo pipefail

cd "$(dirname "$0")"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-rpid}"

prompt() {
  local var="$1" prompt_text="$2" default="${3:-}" hidden="${4:-}"
  local value
  if [[ -n "$hidden" ]]; then
    read -rsp "${prompt_text}: " value; echo
  else
    if [[ -n "$default" ]]; then
      read -rp "${prompt_text} [${default}]: " value
      value="${value:-$default}"
    else
      read -rp "${prompt_text}: " value
    fi
  fi
  printf '%s' "$value"
}

generate_random() { python3 -c 'import secrets,string; print("".join(secrets.choice(string.ascii_letters+string.digits) for _ in range(50)))'; }

echo "Sealing NetBox secrets — values stored encrypted in k8s/sealed-secrets.yaml"
echo "(safe to commit; the cluster's sealed-secrets controller decrypts in-place)"
echo

SECRET_KEY=$(generate_random)
echo "✓ generated SECRET_KEY (50 chars)"

SUPERUSER_PASSWORD=$(prompt "" "Initial NetBox superuser password (admin)" "" hidden)
SUPERUSER_API_TOKEN=$(prompt "" "Initial NetBox API token" "" hidden)
REDIS_PASSWORD=$(generate_random)

kubectl create secret generic netbox-secrets \
  --namespace netbox \
  --dry-run=client -o yaml \
  --from-literal=SECRET_KEY="$SECRET_KEY" \
  --from-literal=SUPERUSER_PASSWORD="$SUPERUSER_PASSWORD" \
  --from-literal=SUPERUSER_API_TOKEN="$SUPERUSER_API_TOKEN" \
  --from-literal=REDIS_PASSWORD="$REDIS_PASSWORD" \
  | kubeseal --format yaml --controller-namespace kube-system --controller-name sealed-secrets-controller \
  > k8s/sealed-secrets.yaml

echo "✓ k8s/sealed-secrets.yaml written"
echo
echo "Next: git add k8s/sealed-secrets.yaml && git commit && git push"
