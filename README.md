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

CNPG runs continuous WAL archiving + nightly base backups to S3 (configured
in `pg-cluster.yaml` + `seal-secrets.sh`). Restore in disaster: scale netbox
to 0 → delete the cluster CR → recreate with `bootstrap.recovery.source` →
scale netbox back. See [CNPG docs](https://cloudnative-pg.io/documentation/current/recovery/).

## License

GNU GPL v3
