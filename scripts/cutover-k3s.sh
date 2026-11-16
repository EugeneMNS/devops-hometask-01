#!/usr/bin/env bash
# Run only after internal ingress and PVC checks pass.
set -euo pipefail
[[ "$EUID" -eq 0 && "${SUDO_USER:-root}" != root ]] || {
  echo 'Run with sudo from the deploy account.' >&2
  exit 1
}
deploy_user="$SUDO_USER"
deploy_home="$(getent passwd "$deploy_user" | cut -d: -f6)"
export KUBECONFIG="$deploy_home/.kube/config"
cd "$deploy_home/myapp"
compose=(docker compose --env-file .env.development.compose)

kubectl wait --for=condition=Ready node/vps-3b85fc4f --timeout=30s
kubectl rollout status statefulset/postgres --timeout=60s
kubectl rollout status deployment/backend --timeout=60s
kubectl rollout status deployment/frontend --timeout=60s
kubectl rollout status deployment/legacy-proxy --timeout=60s
kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=60s
kubectl get clusterissuer letsencrypt-prod
systemctl is-active --quiet nginx

backup_dir="$deploy_home/backups/hw6-cutover-$(date -u +%Y%m%dT%H%M%SZ)"
install -d -m 700 -o "$deploy_user" -g "$(id -gn "$deploy_user")" "$backup_dir"
umask 077
old_back_stopped=false
backend_paused=false
traffic_switched=false

rollback() {
  trap - ERR INT TERM
  set +e
  echo 'Cutover check failed; restoring the previous web stack.' >&2
  if $traffic_switched; then
    kubectl -n ingress-nginx patch service ingress-nginx-controller \
      --type=merge -p '{"spec":{"type":"ClusterIP"}}'
    kubectl -n kube-system wait --for=delete pod \
      -l svccontroller.k3s.cattle.io/svcname=ingress-nginx-controller --timeout=60s
    systemctl enable --now nginx
    systemctl enable --now certbot.timer
  fi
  if $backend_paused; then
    kubectl scale deployment/backend --replicas=2
  fi
  if $old_back_stopped; then
    "${compose[@]}" start db front back
  fi
  echo "Backup retained: $backup_dir" >&2
}
trap 'rollback; exit 1' ERR INT TERM

# Stop writes on the old backend, then take the final consistent dump.
old_back_stopped=true
"${compose[@]}" stop back
"${compose[@]}" exec -T db sh -c \
  'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists --no-owner --no-privileges' \
  < /dev/null > "$backup_dir/todo.sql"
test -s "$backup_dir/todo.sql"
old_count="$("${compose[@]}" exec -T db sh -c \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "SELECT count(*) FROM todos"' < /dev/null)"

# Restore with the new backend paused so schema synchronization cannot race it.
backend_paused=true
kubectl scale deployment/backend --replicas=0
kubectl wait --for=delete pod -l app=backend --timeout=90s
kubectl exec -i postgres-0 -- sh -c \
  'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < "$backup_dir/todo.sql"
new_count="$(kubectl exec postgres-0 -- sh -c \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "SELECT count(*) FROM todos"')"
[[ "$old_count" == "$new_count" ]]
printf 'Migrated todos: %s\n' "$new_count"
printf '%s\n' "$new_count" > "$backup_dir/todo-count.txt"
chown -R "$deploy_user:$(id -gn "$deploy_user")" "$backup_dir"
kubectl scale deployment/backend --replicas=2
kubectl rollout status deployment/backend --timeout=180s
backend_paused=false

# Restore normal HTTPS redirects before opening the ingress to public traffic.
kubectl annotate ingress app-ingress legacy-bot legacy-grafana apex-redirect \
  nginx.ingress.kubernetes.io/ssl-redirect-
traffic_switched=true
systemctl disable --now nginx
systemctl disable --now certbot.timer
kubectl -n ingress-nginx patch service ingress-nginx-controller \
  --type=merge -p '{"spec":{"type":"LoadBalancer"}}'
timeout 360 kubectl wait --for=condition=Ready \
  certificate/app-tls certificate/bot-tls certificate/grafana-tls certificate/apex-tls \
  --timeout=300s

# Certificate Ready can precede the ingress controller's certificate cache update.
# Wait for strict TLS/SNI verification and the expected backend, not just the CRD.
tls_ready=false
for attempt in {1..18}; do
  if curl --fail --silent --show-error --max-time 10 https://hw3.novik.tech/api/health -o "$backup_dir/health-check.json" && \
     python3 -c 'import json,sys; h=json.load(open(sys.argv[1])); assert h["status"]=="ok" and h["version"]=="manual-3e814ec"' "$backup_dir/health-check.json" 2>/dev/null && \
     curl --fail --silent --show-error --max-time 10 https://bot.novik.tech/developer/api/health -o /dev/null && \
     curl --fail --silent --show-error --max-time 10 https://grafana.hw3.novik.tech/api/health -o /dev/null && \
     curl --fail --silent --show-error --max-time 10 https://novik.tech/ -o /dev/null; then
    tls_ready=true
    break
  fi
  echo "Waiting for ingress TLS and routes ($attempt/18)"
  sleep 5
done
[[ "$tls_ready" == true ]]
echo 'Public TLS and backend version verified'
curl --fail --silent --show-error --max-time 15 https://hw3.novik.tech/api/ready | \
  python3 -c 'import json,sys; assert json.load(sys.stdin)["status"]=="ready"'
curl --fail --silent --show-error --max-time 15 https://hw3.novik.tech/ -o "$backup_dir/front-check.html"
grep -qi '<title' "$backup_dir/front-check.html"

check_status() {
  local actual
  actual="$(curl --silent --show-error --max-time 15 -o /dev/null -w '%{http_code}' "$1")"
  [[ "$actual" == "$2" ]] || { echo "Unexpected HTTP $actual at $1" >&2; return 1; }
}
check_status https://bot.novik.tech/developer/api/health 200
check_status https://bot.novik.tech/profile2/api/health 200
# profile3 was already offline before migration; preserve its route as well.
check_status https://bot.novik.tech/profile3/api/health 502
check_status https://grafana.hw3.novik.tech/api/health 200
check_status 'https://novik.tech/hw6-check?x=1' 301

# Keep the old database volume for rollback; only application containers stop.
"${compose[@]}" stop front db
chown -R "$deploy_user:$(id -gn "$deploy_user")" "$backup_dir"
trap - ERR INT TERM
echo "Cutover complete. Backup: $backup_dir"
echo 'Application, TLS, bot routes and Grafana verified; old DB volume retained.'
