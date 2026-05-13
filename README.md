# cn-netbox

NetBox 4.x deployed onto the [amun-kubernetes](https://github.com/GonzaloAlvarez/amun-kubernetes) cluster.

Reachable as:
- **`http://netbox.k8s.lan`** — LAN, via pfSense Domain Override + ingress-nginx
- **`https://netbox.lab.gn.al`** — over the tailnet, via VPS Traefik wildcard + the k8s-router subnet route

## Architecture

| Component | Mode | Resource |
|---|---|---|
| `netbox` (web) | Deployment, gunicorn workers=1 threads=8 | 1Gi RAM cap |
| `netbox-worker` (rqworker) | Deployment | 512Mi cap |
| `netbox-housekeeping` | CronJob daily 03:00 | minimal |
| Postgres | CloudNativePG `Cluster` CR (3 replicas, primary + 2 standby) | Longhorn 20Gi |
| Redis | bundled in netbox-chart | Longhorn 1Gi |

Multi-host support via env vars: `ALLOWED_HOSTS=netbox.k8s.lan netbox.lab.gn.al localhost` and matching `CSRF_TRUSTED_ORIGINS`.

## Deploy

```sh
# 1. Seal the secrets (interactive)
./seal-secrets.sh

# 2. Append to amun-kubernetes/deployment/deployment.yml:
#      - github.com/GonzaloAlvarez/cn-netbox//k8s?ref=main
# 3. Apply
kubectl apply -k /Users/galvarez/dev/amun-kubernetes/deployment/
```

## Health

```sh
kubectl -n netbox get pods,cluster.postgresql.cnpg.io,svc,ingress
curl -sS http://netbox.k8s.lan/api/status/ | jq .
curl -sk https://netbox.lab.gn.al/api/status/ | jq .   # after Phase 5
kubectl -n netbox port-forward svc/netbox 8000:80
```

## Storage backup

Mirrors the cn-vaultwarden model: `prodrigestivill/postgres-backup-local` dumps
Postgres into an RWX PVC every 12h; `offen/docker-volume-backup` tars the
dumps + `netbox-media` PVC weekly (Sun 03:00) and ships the archive to S3 +
(optional) WebDAV, with SMTP alerts on success/failure. 56-day retention.
Defined in `k8s/backup.yaml`; secrets in `netbox-backup` (sealed). Redis is
intentionally not backed up (it's cache + RQ queue).

### One-time setup

1. Provision an S3 bucket and an IAM user limited to it
   (`s3:PutObject,GetObject,DeleteObject,ListBucket` on the bucket ARN +
   `arn:aws:s3:::<bucket>/*`). Consider versioning + a lifecycle rule to
   transition to Glacier after ~90 days.
2. Run `./seal-secrets.sh` and answer the new backup + SMTP prompts.
3. `kubectl apply -k /Users/galvarez/dev/amun-kubernetes/deployment/`
4. Confirm the media PVC is named `netbox-media`:
   ```sh
   kubectl -n netbox get pvc
   ```
   If different, edit `claimName` in `k8s/backup.yaml`.

### Health & smoke

```sh
# Both backup deployments healthy
kubectl -n netbox get deploy/netbox-pg-dump deploy/netbox-volume-backup pvc/netbox-pg-dumps

# Force an immediate pg dump (don't wait 12h)
kubectl -n netbox exec deploy/netbox-pg-dump -- /backup.sh
kubectl -n netbox exec deploy/netbox-pg-dump -- ls -lh /backups/last/

# Force an immediate offen run (override schedule)
kubectl -n netbox exec deploy/netbox-volume-backup -- kill -SIGUSR1 1
kubectl -n netbox logs deploy/netbox-volume-backup --tail=50

# Confirm S3 object lands
aws s3 ls s3://<bucket>/netbox/
```

### Restore drill

Run this end-to-end at least once against a throwaway namespace to confirm
the dump format round-trips before declaring done.

```sh
# 1. Pull latest archive
aws s3 ls s3://<bucket>/netbox/ | tail -5
aws s3 cp s3://<bucket>/netbox/netbox-<timestamp>.tar.gz /tmp/
mkdir -p /tmp/restore && tar -xzf /tmp/netbox-<timestamp>.tar.gz -C /tmp/restore/

# 2. Restore Postgres (scale NetBox to 0 first so nothing writes mid-restore)
kubectl -n netbox scale deploy netbox netbox-worker --replicas=0
kubectl -n netbox exec -i netbox-pg-1 -- \
  pg_restore -U netbox -d netbox --clean --if-exists \
  < /tmp/restore/backup/pg-dumps/last/netbox-*.sql.custom
kubectl -n netbox scale deploy netbox netbox-worker --replicas=1

# 3. Restore media via a temporary pod that mounts the media PVC
kubectl -n netbox apply -f - <<'YAML'
apiVersion: v1
kind: Pod
metadata: { name: restore-media }
spec:
  restartPolicy: Never
  containers:
  - name: restore
    image: alpine:3.20
    command: ["sleep", "3600"]
    volumeMounts: [{ name: media, mountPath: /media }]
  volumes:
  - name: media
    persistentVolumeClaim: { claimName: netbox-media }
YAML
kubectl -n netbox cp /tmp/restore/backup/media/. restore-media:/media/
kubectl -n netbox delete pod restore-media
```

### Future: CNPG-native PITR

The current `pg_dump` approach gives nightly point-in-time-of-dump recovery.
If NetBox grows load-bearing, swap `netbox-pg-dump` for CNPG's `spec.backup`
(Barman → S3 with continuous WAL archiving) to get true PITR. Same bucket,
different layout. See [CNPG backup docs](https://cloudnative-pg.io/documentation/current/backup/).

## License

GNU GPL v3
