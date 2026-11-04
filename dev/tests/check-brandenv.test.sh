#!/usr/bin/env bash
# bin/check-brandenv and the Compose file must refuse a missing or invalid .brandenv.
set -uo pipefail
DEV=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; failed=0
ok()  { echo "  ok    $1"; pass=$((pass+1)); }
bad() { echo "  FAIL  $1"; failed=$((failed+1)); }
check() { "$DEV/bin/check-brandenv" "$T/brandenv" >/dev/null 2>"$T/err"; }
refuses() { cp "$DEV/.brandenv.example" "$T/brandenv"; sed -i.bak -E "$2" "$T/brandenv"; if check && [ -s "$T/brandenv" ]; then bad "$1"; else ok "$1"; fi; }

cp "$DEV/.brandenv.example" "$T/brandenv"
if check; then ok "example file is valid"; else bad "example file is valid: $(cat "$T/err")"; fi

rm -f "$T/brandenv"
if check; then bad "missing file refused"; else ok "missing file refused"; fi
: > "$T/brandenv"
if check; then bad "empty file refused"; else ok "empty file refused"; fi

refuses "blank BRAND_NAME refused"        's/^BRAND_NAME=.*/BRAND_NAME=/'
refuses "absent BRAND_DOMAIN refused"     '/^BRAND_DOMAIN=/d'
refuses "domain with scheme refused"      's#^BRAND_DOMAIN=.*#BRAND_DOMAIN=https://a.example.com#'
refuses "unquoted colour refused"         's/^BRAND_PRIMARY_COLOR=.*/BRAND_PRIMARY_COLOR=green/'
refuses "bad date format refused"         's#^BRAND_DATE_FORMAT=.*#BRAND_DATE_FORMAT=MM/DD/YYYY#'
refuses "bad financial year refused"      's/^BRAND_FINANCIAL_YEAR_START=.*/BRAND_FINANCIAL_YEAR_START=13-01/'
refuses "bad logo URL refused"            's#^BRAND_LOGO_URL=.*#BRAND_LOGO_URL=http://a.example.com/x.png#'

# The Compose file itself must stop without .brandenv. Skipped only if Compose is not installed.
if docker compose version >/dev/null 2>&1; then compose=(docker compose); elif command -v docker-compose >/dev/null; then compose=(docker-compose); else compose=(); fi
if [ "${#compose[@]}" -gt 0 ]; then
  P="$T/project"; mkdir -p "$P"; cp "$DEV/docker-compose.yml" "$P/"
  sed -e 's#<[^>]*>#placeholder@example.com#g' -E -e 's#^(POSTGRES_SUPERUSER_PASSWORD|DB_OWNER_PASSWORD|DB_APP_PASSWORD|REDIS_PASSWORD|DATA_ENCRYPTION_KEY)=.*#\1=test#' "$DEV/.env.example" > "$P/.env"
  printf 'BACKEND_TAG=sha-0000000\nFRONTEND_TAG=sha-0000000\n' > "$P/versions.env"
  run() { (cd "$P" && "${compose[@]}" --env-file .env --env-file versions.env config --quiet) >/dev/null 2>&1; }
  if run; then bad "compose config fails without .brandenv"; else ok "compose config fails without .brandenv"; fi
  cp "$DEV/.brandenv.example" "$P/.brandenv"
  if run; then ok "compose config passes with .brandenv"; else bad "compose config passes with .brandenv"; fi
else
  echo "  skip  compose checks: Compose not installed"
fi

echo "passed: $pass  failed: $failed"
[ "$failed" -eq 0 ]
