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

echo "✓ wrote netbox-secrets"
echo

# --- Backup destination + SMTP notifications -----------------------------------
# Drives the netbox-pg-dump + netbox-volume-backup Deployments in backup.yaml.
# Mirrors the cn-vaultwarden env shape (BACKUP_S3_*, BACKUP_WEBDAV_*, SMTP_*).
echo "Backup destination — AWS S3 (required):"
BACKUP_S3_BUCKET=$(prompt "" "S3 bucket name")
BACKUP_AWS_ACCESS_KEY_ID=$(prompt "" "S3 access key id" "" hidden)
BACKUP_AWS_SECRET_ACCESS_KEY=$(prompt "" "S3 secret access key" "" hidden)
BACKUP_AWS_REGION=$(prompt "" "S3 region" "us-east-1")
echo

echo "Backup destination — WebDAV (optional, press enter to skip):"
BACKUP_WEBDAV_URL=$(prompt "" "WebDAV URL" "")
BACKUP_WEBDAV_USER=$(prompt "" "WebDAV user" "")
if [[ -n "$BACKUP_WEBDAV_URL" ]]; then
  BACKUP_WEBDAV_PASSWORD=$(prompt "" "WebDAV password" "" hidden)
else
  BACKUP_WEBDAV_PASSWORD=""
fi
echo

echo "Notifications — SMTP (used for backup success/failure alerts):"
SMTP_HOST=$(prompt "" "SMTP host")
SMTP_PORT=$(prompt "" "SMTP port" "587")
SMTP_USERNAME=$(prompt "" "SMTP username")
SMTP_PASSWORD=$(prompt "" "SMTP password" "" hidden)
SMTP_FROM=$(prompt "" "SMTP from address")
ALERT_EMAIL=$(prompt "" "Alert recipient")
NOTIFICATION_URLS="smtp://${SMTP_USERNAME}:${SMTP_PASSWORD}@${SMTP_HOST}:${SMTP_PORT}/?from=${SMTP_FROM}&to=${ALERT_EMAIL}&starttls=yes"

{
  echo "---"
  kubectl create secret generic netbox-backup \
    --namespace netbox \
    --dry-run=client -o yaml \
    --from-literal=BACKUP_S3_BUCKET="$BACKUP_S3_BUCKET" \
    --from-literal=BACKUP_AWS_ACCESS_KEY_ID="$BACKUP_AWS_ACCESS_KEY_ID" \
    --from-literal=BACKUP_AWS_SECRET_ACCESS_KEY="$BACKUP_AWS_SECRET_ACCESS_KEY" \
    --from-literal=BACKUP_AWS_REGION="$BACKUP_AWS_REGION" \
    --from-literal=BACKUP_WEBDAV_URL="$BACKUP_WEBDAV_URL" \
    --from-literal=BACKUP_WEBDAV_USER="$BACKUP_WEBDAV_USER" \
    --from-literal=BACKUP_WEBDAV_PASSWORD="$BACKUP_WEBDAV_PASSWORD" \
    --from-literal=NOTIFICATION_URLS="$NOTIFICATION_URLS" \
    | kubeseal --format yaml --controller-namespace kube-system --controller-name sealed-secrets-controller
} >> k8s/sealed-secrets.yaml

echo "✓ wrote netbox-backup"
echo
echo "k8s/sealed-secrets.yaml now contains: netbox-secrets + netbox-backup"
echo "Next: git add k8s/sealed-secrets.yaml && git commit && git push"
