#!/usr/bin/env bash
# Generate / prompt for NetBox secrets and write a sealed-secrets manifest.
# Idempotent — re-running prompts again with the existing values as defaults.
#
# Flags:
#   --core   Prompt only for NetBox-specific creds (superuser password + API
#            token). Backup destination + SMTP values are harvested over SSH
#            from passwords.lan:~/cn-vaultwarden/.env (the .env is the canonical
#            source for the shared S3 bucket + SMTP smarthost — same variable
#            names as cn-netbox already uses).
set -euo pipefail

cd "$(dirname "$0")"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-rpid}"

CORE_ONLY=0
case "${1:-}" in
  --core) CORE_ONLY=1 ;;
  -h|--help)
    sed -n '/^#!/d; /^[^#]/q; s/^# \{0,1\}//p' "$0"
    exit 0
    ;;
  "" ) ;;
  *)
    echo "unknown argument: $1 (try --help)" >&2
    exit 2
    ;;
esac

harvest_backup_smtp_from_vault() {
  local tmp keys
  tmp=$(mktemp)
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" RETURN

  keys='^(BACKUP_S3_BUCKET|BACKUP_AWS_ACCESS_KEY_ID|BACKUP_AWS_SECRET_ACCESS_KEY|BACKUP_AWS_REGION|BACKUP_WEBDAV_URL|BACKUP_WEBDAV_USER|BACKUP_WEBDAV_PASSWORD|SMTP_HOST|SMTP_PORT|SMTP_USERNAME|SMTP_PASSWORD|SMTP_FROM|ALERT_EMAIL)='

  echo "Harvesting backup + SMTP values from passwords.lan:~/cn-vaultwarden/.env …"
  if ! ssh -o BatchMode=yes -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
        -l gonzalo -i ~/.ssh/gonzalo_main_private_key.pem passwords.lan \
        "grep -E '${keys}' ~/cn-vaultwarden/.env" > "$tmp"; then
    echo "ERROR: ssh to passwords.lan failed (is the Pi up + key authorized?)" >&2
    return 1
  fi

  if [[ ! -s "$tmp" ]]; then
    echo "ERROR: no matching keys in passwords.lan:~/cn-vaultwarden/.env" >&2
    return 1
  fi

  # shellcheck disable=SC1090
  set -a; . "$tmp"; set +a

  # Sanity check — verify all required keys arrived.
  local missing=()
  for v in BACKUP_S3_BUCKET BACKUP_AWS_ACCESS_KEY_ID BACKUP_AWS_SECRET_ACCESS_KEY BACKUP_AWS_REGION SMTP_HOST SMTP_PORT SMTP_USERNAME SMTP_PASSWORD SMTP_FROM ALERT_EMAIL; do
    [[ -n "${!v:-}" ]] || missing+=("$v")
  done
  if (( ${#missing[@]} > 0 )); then
    echo "ERROR: missing/empty in source .env: ${missing[*]}" >&2
    return 1
  fi

  echo "✓ harvested: S3=${BACKUP_S3_BUCKET} region=${BACKUP_AWS_REGION} webdav=${BACKUP_WEBDAV_URL:-<unset>} smtp=${SMTP_HOST}:${SMTP_PORT} from=${SMTP_FROM} to=${ALERT_EMAIL}"
}

prompt() {
  local var="$1" prompt_text="$2" default="${3:-}" hidden="${4:-}"
  local value
  if [[ -n "$hidden" ]]; then
    # `echo >&2` keeps the trailing newline on stderr (where read -p's prompt
    # also lives) so it doesn't pollute the value captured via $(prompt ...).
    read -rsp "${prompt_text}: " value; echo >&2
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

# Authentik OIDC credentials — created by `cn-authentik/setup-netbox-oidc.sh`,
# which prints the two values once. Re-run that script if you don't have them.
# Both keys must exist in the sealed secret because the extraConfig YAML
# references them via `secretKeyRef` (kubelet fails the projected-volume
# mount on a missing key, even if the env var isn't read).
echo "Authentik OIDC for NetBox (from cn-authentik/setup-netbox-oidc.sh):"
SOCIAL_AUTH_OIDC_KEY=$(prompt "" "Authentik client_id (SOCIAL_AUTH_OIDC_KEY)" "" hidden)
SOCIAL_AUTH_OIDC_SECRET=$(prompt "" "Authentik client_secret (SOCIAL_AUTH_OIDC_SECRET)" "" hidden)
echo

# Chart 5.x projects multiple keys from netbox-secrets, some lowercase and some
# UPPERCASE — and a couple for SMTP that must exist even when unused (kubelet
# fails the projected-volume mount on a missing key, not just on a referenced
# env var). Emit every variant the chart looks up, with empty defaults for SMTP.
kubectl create secret generic netbox-secrets \
  --namespace netbox \
  --dry-run=client -o yaml \
  --from-literal=SECRET_KEY="$SECRET_KEY" \
  --from-literal=secret_key="$SECRET_KEY" \
  --from-literal=SUPERUSER_PASSWORD="$SUPERUSER_PASSWORD" \
  --from-literal=superuser_password="$SUPERUSER_PASSWORD" \
  --from-literal=password="$SUPERUSER_PASSWORD" \
  --from-literal=SUPERUSER_API_TOKEN="$SUPERUSER_API_TOKEN" \
  --from-literal=api_token="$SUPERUSER_API_TOKEN" \
  --from-literal=REDIS_PASSWORD="$REDIS_PASSWORD" \
  --from-literal=redis_password="$REDIS_PASSWORD" \
  --from-literal=SOCIAL_AUTH_OIDC_KEY="$SOCIAL_AUTH_OIDC_KEY" \
  --from-literal=SOCIAL_AUTH_OIDC_SECRET="$SOCIAL_AUTH_OIDC_SECRET" \
  --from-literal=username="admin" \
  --from-literal=email="admin@netbox.lab.gn.al" \
  --from-literal=email_password="" \
  | kubeseal --format yaml --controller-namespace kube-system --controller-name sealed-secrets-controller \
  > k8s/sealed-secrets.yaml

echo "✓ wrote netbox-secrets (incl. SOCIAL_AUTH_OIDC_{KEY,SECRET})"
echo

# --- Backup destination + SMTP notifications -----------------------------------
# Drives the netbox-pg-dump + netbox-volume-backup Deployments in backup.yaml.
# Mirrors the cn-vaultwarden env shape (BACKUP_S3_*, BACKUP_WEBDAV_*, SMTP_*).
if [[ $CORE_ONLY -eq 1 ]]; then
  harvest_backup_smtp_from_vault
  : "${BACKUP_WEBDAV_URL:=}"
  : "${BACKUP_WEBDAV_USER:=}"
  : "${BACKUP_WEBDAV_PASSWORD:=}"
else
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
fi
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
