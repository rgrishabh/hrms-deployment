#!/usr/bin/env bash
# Both stacks share the db-data volume under different service names (db, postgres). This checks,
# with a stub docker, that each deploy removes the other stack's database container before it
# starts its own, and that the new stack backs up before migrating.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
pass=0; failed=0
ok()  { echo "  ok    $1"; pass=$((pass+1)); }
bad() { echo "  FAIL  $1"; failed=$((failed+1)); }
first() { grep -n -m1 -- "$1" "$T/calls" | cut -d: -f1; }
before() { # label pattern-a pattern-b
  a=$(first "$2"); b=$(first "$3")
  if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then ok "$1"; else bad "$1 (lines '$a' and '$b')"; fi
}
stub_docker() { # other-db-service exit-code-of-backup
  mkdir -p "$T/stubs"
  cat > "$T/stubs/docker" <<STUB
#!/bin/sh
echo "docker \$*" >> "$T/calls"
case "\$*" in
  *service=$1*) echo $1-container ;;
  *service=backup*status=running*) echo backup-container ;;
  "exec $1-container psql"*) echo 1 ;;
  "exec backup-container"*) exit $2 ;;
  *"config --format json"*) echo '{"name":"hrms-dev"}' ;;
  *"run --rm --no-deps -T bootstrap"*) echo '{"event":"bootstrap"}' ;;
esac
exit 0
STUB
  printf '#!/bin/sh\nexit 0\n' > "$T/stubs/curl"; printf '#!/bin/sh\nexit 0\n' > "$T/stubs/sleep"
  chmod +x "$T/stubs/"*
}

# Leaves out a real stack's settings: they don't belong in a temp directory, and a local .brandenv would
# make "missing .brandenv" pass through to a deploy.
copy_dev() {
  mkdir -p "$T/app"
  tar -C "$ROOT/dev" --exclude=./.env --exclude=./.brandenv --exclude=./docker-compose.override.yml -cf - . | tar -xf - -C "$T/app"
}

echo "== dev/ stack, first deploy after the old stack"
T=$(mktemp -d); stub_docker db 0
copy_dev; cd "$T/app" || exit 1
cp .brandenv.example .brandenv; : > .env; printf 'BACKEND_TAG=sha-0000000\nFRONTEND_TAG=sha-0000000\n' > versions.env
PATH="$T/stubs:$PATH" ./deploy-dev.sh > "$T/out" 2>&1; rc=$?
if [ "$rc" = 0 ]; then ok "deploy succeeds"; else bad "deploy succeeds: $(tail -3 "$T/out")"; fi
before "backup runs before the db container is removed" 'exec backup-container' 'stop --time 60 db-container'
before "old db container is removed before postgres starts" 'rm db-container' 'up -d --wait postgres'
before "postgres starts before provision" 'up -d --wait postgres' 'run --rm --no-deps -T provision'
before "provision runs before migrate" 'T provision' 'T migrate'
before "migrate runs before bootstrap" 'T migrate' 'T bootstrap'
before "bootstrap runs before the app starts" 'T bootstrap' 'up -d --remove-orphans --wait'
rm -rf "$T"

echo "== dev/ stack, failed pre-migration backup"
T=$(mktemp -d); stub_docker postgres 1
copy_dev; cd "$T/app" || exit 1
cp .brandenv.example .brandenv; : > .env; printf 'BACKEND_TAG=sha-0000000\nFRONTEND_TAG=sha-0000000\n' > versions.env
if PATH="$T/stubs:$PATH" ./deploy-dev.sh > "$T/out" 2>&1; then bad "deploy stops"; else ok "deploy stops"; fi
if grep -q 'T migrate' "$T/calls"; then bad "nothing is migrated"; else ok "nothing is migrated"; fi
rm -rf "$T"

echo "== dev/ stack, missing .brandenv"
T=$(mktemp -d); stub_docker postgres 0
copy_dev; cd "$T/app" || exit 1
: > .env; printf 'BACKEND_TAG=sha-0000000\nFRONTEND_TAG=sha-0000000\n' > versions.env
if PATH="$T/stubs:$PATH" ./deploy-dev.sh > "$T/out" 2>&1; then bad "deploy refuses"; else ok "deploy refuses"; fi
if grep -q 'compose' "$T/calls" 2>/dev/null; then bad "docker compose never ran"; else ok "docker compose never ran"; fi
rm -rf "$T"

echo "== environments/dev stack, rollback after the dev/ stack"
T=$(mktemp -d); stub_docker postgres 0
cp -R "$ROOT/environments/dev" "$T/app"; cp "$ROOT/scripts/deploy-dev.sh" "$T/app/"; cd "$T/app" || exit 1
printf 'SITE_ADDRESS=dev.example.com\n' > .env; printf 'BACKEND_TAG=sha-0000000\nFRONTEND_TAG=sha-0000000\n' > versions.env
PATH="$T/stubs:$PATH" ./deploy-dev.sh > "$T/out" 2>&1; rc=$?
if [ "$rc" = 0 ]; then ok "deploy succeeds"; else bad "deploy succeeds: $(tail -3 "$T/out")"; fi
before "postgres container is removed before db starts" 'rm postgres-container' 'up -d --wait db'
rm -rf "$T"

echo "== environments/dev stack, no new containers: unchanged sequence"
T=$(mktemp -d); stub_docker none 0
cp -R "$ROOT/environments/dev" "$T/app"; cp "$ROOT/scripts/deploy-dev.sh" "$T/app/"; cd "$T/app" || exit 1
printf 'SITE_ADDRESS=dev.example.com\n' > .env; printf 'BACKEND_TAG=sha-0000000\nFRONTEND_TAG=sha-0000000\n' > versions.env
PATH="$T/stubs:$PATH" ./deploy-dev.sh > "$T/out" 2>&1; rc=$?
if [ "$rc" = 0 ]; then ok "deploy succeeds"; else bad "deploy succeeds: $(tail -3 "$T/out")"; fi
if grep -q 'docker stop\|docker rm' "$T/calls"; then bad "stops nothing"; else ok "stops nothing"; fi
rm -rf "$T"

echo "passed: $pass  failed: $failed"
[ "$failed" -eq 0 ]
