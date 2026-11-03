#!/usr/bin/env bash
# Deploy (or roll back) the dev installation on THIS host. Run from the installation directory
# (e.g. /opt/hrms/dev) after the workflow has synced the files, written .env and logged in to GHCR.
#   deploy-dev.sh              deploy the tags in versions.env
#   deploy-dev.sh --rollback   deploy the tags in versions.prev.env (the previous deployment)
# Exit code 0 only when the backend is ready and the frontend is healthy.
set -euo pipefail
cd "$(dirname "$0")"
MODE=${1:-deploy}
KEEP_IMAGES=${KEEP_IMAGES:-3}
log() { echo "[deploy-dev $(date -u +%H:%M:%S)] $*"; }
fail() { echo "::error::$*" >&2; exit 1; }

[ -f .env ] || fail ".env missing (written from the DEV_ENV_FILE secret)"
[ "$(stat -c %a .env)" = "600" ] || chmod 600 .env
if [ "$MODE" = "--rollback" ]; then
  [ -f versions.prev.env ] || fail "no versions.prev.env to roll back to"
  cp versions.prev.env versions.env
  log "ROLLBACK to: $(tr '\n' ' ' < versions.env)"
fi
# shellcheck disable=SC1091
. ./versions.env
for t in "$BACKEND_TAG" "$FRONTEND_TAG"; do
  case "$t" in unset|latest|"") fail "refusing tag '$t': use an immutable sha-<short> or vX.Y.Z tag" ;; esac
done
dc() { docker compose --env-file .env --env-file versions.env "$@"; }
PROJECT=$(dc config --format json | python3 -c 'import sys,json; print(json.load(sys.stdin)["name"])')
SITE=$(grep -E '^SITE_ADDRESS=' .env | cut -d= -f2- | cut -d, -f1 | tr -d ' "')

# Another installation (e.g. an older demo) holding 80/443 would make Caddy fail to start.
for port in 80 443; do
  other=$(docker ps --filter "publish=$port" --format '{{.Label "com.docker.compose.project"}}' | grep -vx "$PROJECT" || true)
  [ -z "$other" ] || fail "port $port is used by compose project '$other'. Stop it first (docker compose -p $other down) — its volumes are kept."
done

log "deploying backend=$BACKEND_TAG frontend=$FRONTEND_TAG (project $PROJECT)"
dc pull --quiet db backend frontend caddy backup
dc up -d --wait db
log "provision + migrate"
dc run --rm --no-deps provision
dc run --rm --no-deps migrate
dc up -d --remove-orphans --wait --wait-timeout 180

# First administrator: idempotent; prints a setup link only when the admin is created.
OUT=$(dc --profile tools run --rm --no-deps -T bootstrap 2>&1) || { echo "$OUT" | grep -v 'setup#token=' >&2; fail "bootstrap failed"; }
echo "$OUT" | grep '^{' || true
if echo "$OUT" | grep -q 'setup#token='; then
  umask 077; echo "$OUT" | grep 'setup#token=' > setup-link.txt
  log "first administrator created: one-time setup link saved to $(pwd)/setup-link.txt (mode 600). Read it over SSH, then delete it."
fi

log "waiting for readiness"
ok=0
for _ in $(seq 1 30); do
  if dc exec -T backend wget -qO /dev/null http://127.0.0.1:4000/ready && dc exec -T frontend wget -qO /dev/null http://127.0.0.1:8080/healthz; then ok=1; break; fi
  sleep 4
done
[ "$ok" = 1 ] || { dc ps; dc logs --tail 50 backend frontend; fail "not ready after 120s"; }
if [ -n "$SITE" ] && ! curl -fsS --max-time 10 --resolve "$SITE:443:127.0.0.1" "https://$SITE/ready" >/dev/null; then
  log "warning: https://$SITE/ready not reachable through Caddy yet (DNS or certificate pending?)"
fi

log "pruning old images (keeping $KEEP_IMAGES per repository)"
for repo in $(dc config --images | grep -E '/hrms-(backend|frontend):' | sed 's/:.*//' | sort -u); do
  docker image ls "$repo" --format '{{.Repository}}:{{.Tag}}' | tail -n +"$((KEEP_IMAGES + 1))" | while read -r img; do
    docker image rm "$img" >/dev/null 2>&1 && log "removed $img" || true
  done
done
docker image prune -f >/dev/null
log "deployed backend=$BACKEND_TAG frontend=$FRONTEND_TAG"
