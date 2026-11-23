#!/usr/bin/env bash
# Deploy (or roll back) the dev installation on THIS host, from the installation directory
# (/opt/hrms/dev), after the workflow has synced the files, written .env and logged in to GHCR.
#   deploy-dev.sh              deploy the tags in versions.env
#   deploy-dev.sh --rollback   deploy the tags in versions.prev.env (the previous deployment)
# Exit code 0 only when the backend is ready and the frontend is healthy.
set -euo pipefail
cd "$(dirname "$0")"
MODE=${1:-deploy}
KEEP_IMAGES=${KEEP_IMAGES:-3}
log() { echo "[deploy-dev $(date -u +%H:%M:%S)] $*"; }
fail() { echo "::error::$*" >&2; exit 1; }

[ -f .env ] || fail ".env missing (written from the DEV_ENV_FILE_V2 secret)"
chmod 600 .env
[ -f .brandenv ] || fail ".brandenv missing (written from the DEV_BRANDENV variable)"
bin/check-brandenv || fail ".brandenv is not valid"
if [ "$MODE" = "--rollback" ]; then
  [ -f versions.prev.env ] || fail "no versions.prev.env to roll back to"
  cp versions.prev.env versions.env
  log "ROLLBACK to: $(tr '\n' ' ' < versions.env)"
fi
# shellcheck disable=SC1091
. ./versions.env
for t in "$BACKEND_TAG" "$FRONTEND_TAG"; do
  case "$t" in unset|latest|develop|"") fail "refusing tag '$t': use an immutable sha-<short> or vX.Y.Z tag" ;; esac
done
dc() { bin/dc "$@"; }
PROJECT=$(sed -n 's/^name: *//p' docker-compose.yml)
SITE=$(sed -n 's/^BRAND_DOMAIN=//p' .brandenv | tail -n 1 | tr -d ' "')

# Another installation holding 80/443 would make Caddy fail to start.
for port in 80 443; do
  other=$(docker ps --filter "publish=$port" --format '{{.Label "com.docker.compose.project"}}' | grep -vx "$PROJECT" || true)
  [ -z "$other" ] || fail "port $port is used by compose project '$other'. Stop it first (docker compose -p $other down); its volumes are kept."
done

log "deploying backend=$BACKEND_TAG frontend=$FRONTEND_TAG (project $PROJECT)"
dc pull --quiet

# Backup before migrating. A failed backup stops the deploy before the schema changes. On the first
# deploy after the cutover the database service is still "db"; the backup service works either way.
# No hrms database yet means a first install, with nothing to back up.
running() { docker ps -q --filter "label=com.docker.compose.project=$PROJECT" --filter "label=com.docker.compose.service=$1" --filter "status=running"; }
db_container=$(running postgres); [ -n "$db_container" ] || db_container=$(running db)
if [ -n "$db_container" ] && [ "$(docker exec "$db_container" psql -U postgres -tAc "SELECT 1 FROM pg_database WHERE datname = 'hrms'")" = "1" ]; then
  log "pre-migration backup"
  backup_container=$(running backup)
  [ -n "$backup_container" ] || { dc up -d --no-recreate backup; backup_container=$(running backup); }
  docker exec "$backup_container" /bin/sh /scripts/backup-loop.sh --now || fail "pre-migration backup failed; nothing was migrated"
fi

bin/stack-up

log "waiting for readiness"
ok=0
for _ in $(seq 1 30); do
  if dc exec -T backend wget -qO /dev/null http://127.0.0.1:4000/health/ready && dc exec -T frontend wget -qO /dev/null http://127.0.0.1:8080/healthz; then ok=1; break; fi
  sleep 4
done
[ "$ok" = 1 ] || { dc ps; dc logs --tail 50 backend worker frontend; fail "not ready after 120s"; }
if [ -n "$SITE" ] && ! curl -fsS --max-time 10 --resolve "$SITE:443:127.0.0.1" "https://$SITE/health/ready" >/dev/null; then
  log "warning: https://$SITE/health/ready not reachable through Caddy yet (DNS or certificate pending?)"
fi

log "pruning old images (keeping $KEEP_IMAGES per repository)"
for repo in $(dc config --images | grep -E '/hrms-(backend|frontend):' | sed 's/:.*//' | sort -u); do
  docker image ls "$repo" --format '{{.Repository}}:{{.Tag}}' | tail -n +"$((KEEP_IMAGES + 1))" | while read -r img; do
    docker image rm "$img" >/dev/null 2>&1 && log "removed $img" || true
  done
done
docker image prune -f >/dev/null
log "deployed backend=$BACKEND_TAG frontend=$FRONTEND_TAG"
