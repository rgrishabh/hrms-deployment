#!/usr/bin/env bash
# Non-destructive smoke test for ANY installation (dev or a customer's prod). Needs no data or credentials.
# Usage: scripts/smoke-test.sh <https://host> [--resolve <ip>] [--expect-version <tag>] [--expect-brand <name>]
#   --resolve: connect to <ip> while keeping the hostname (TLS + Host header), e.g. before DNS is switched.
#   --expect-brand: the public config must carry this brand, so blank or default branding fails the test.
set -euo pipefail
BASE=${1:?usage: smoke-test.sh <https://host> [--resolve ip] [--expect-version tag] [--expect-brand name]}; shift
HOST=$(printf '%s' "$BASE" | sed -E 's#^https?://([^/:]+).*#\1#')
RESOLVE=(); EXPECT_VERSION=""; EXPECT_BRAND=""
while [ $# -gt 0 ]; do
  case "$1" in
    --resolve) RESOLVE=(--resolve "$HOST:443:$2" --resolve "$HOST:80:$2"); shift 2 ;;
    --expect-version) EXPECT_VERSION=$2; shift 2 ;;
    --expect-brand) EXPECT_BRAND=$2; shift 2 ;;
    *) echo "unknown argument $1" >&2; exit 2 ;;
  esac
done
# Never abort on a failed request: every check reports its own result.
c() { curl -sS --max-time 15 ${RESOLVE[@]+"${RESOLVE[@]}"} "$@" || true; }
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok   $1"; pass=$((pass+1)); else echo "  FAIL $1 (expected '$3', got '$2')"; fail=$((fail+1)); fi; }
has() { if grep -qiE "$2" <<<"$3"; then echo "  ok   $1"; pass=$((pass+1)); else echo "  FAIL $1 (missing /$2/)"; fail=$((fail+1)); fi; }

echo "Smoke test: $BASE"
# A fresh installation may still be obtaining its TLS certificate: wait for readiness first (WAIT_SECONDS, default 180).
for _ in $(seq 1 $(( ${WAIT_SECONDS:-180} / 5 ))); do
  [ "$(c -o /dev/null -w '%{http_code}' "$BASE/ready")" = 200 ] && break
  sleep 5
done
check "liveness /health" "$(c -o /dev/null -w '%{http_code}' "$BASE/health")" 200
check "readiness /ready" "$(c -o /dev/null -w '%{http_code}' "$BASE/ready")" 200
INDEX=$(c -D - "$BASE/")
has "SPA served" 'id="root"' "$INDEX"
has "branded title (runtime-rendered)" '<title>[^<]*·' "$INDEX"
has "CSP on SPA" 'content-security-policy: .*script-src .self.' "$INDEX"
has "HSTS" 'strict-transport-security: max-age=' "$INDEX"
has "nosniff" 'x-content-type-options: nosniff' "$INDEX"
check "deep link falls back to the SPA" "$(c "$BASE/leave/some/deep/link" | grep -c 'id="root"')" 1
ENVJS=$(c "$BASE/env.js")
has "env.js served" '__HRMS_ENV__' "$ENVJS"
[ -z "$EXPECT_VERSION" ] || has "frontend version $EXPECT_VERSION" "\"version\":\"$EXPECT_VERSION\"" "$ENVJS"
# The backend moves this endpoint in the revamp. Try the new path, then the old one, until the old
# stack and its images are gone.
if [ "$(c -o /dev/null -w '%{http_code}' "$BASE/api/v1/config/public")" = 200 ]; then
  CFG=$(c "$BASE/api/v1/config/public")
  has "runtime config served by the backend" '"brand"' "$CFG"
else
  CFG=$(c "$BASE/api/v1/public/config")
  has "runtime config served by the backend" '"organization"' "$CFG"
fi
[ -z "$EXPECT_BRAND" ] || has "brand $EXPECT_BRAND" "$EXPECT_BRAND" "$CFG"
check "runtime config has no secrets" "$(grep -ciE 'postgres|password|secret|encryption' <<<"$CFG" || true)" 0
check "API never falls back to the SPA" "$(c -o /dev/null -w '%{http_code}' "$BASE/api/v1/does-not-exist")" 404
check "unauthenticated API call refused" "$(c -o /dev/null -w '%{http_code}' "$BASE/api/v1/auth/me")" 401
check "HTTP redirects to HTTPS" "$(c -o /dev/null -w '%{http_code}' "http://$HOST/" | sed -E 's/^30[178]$/redirect/')" redirect

echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
