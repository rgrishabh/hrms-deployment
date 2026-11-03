#!/usr/bin/env bash
# End-to-end smoke test against ONE running installation with the synthetic dev seed
# (npm run seed). Exercises runtime config, auth, CSRF, permissions and attendance.
# Usage: scripts/e2e-seeded.sh [base_url] [host_header]
#   default: http://127.0.0.1:5173 (Vite dev proxy) with Host localhost:5173
set -euo pipefail
BASE=${1:-http://127.0.0.1:5173}
HOST=${2:-localhost:5173}
DOMAIN=${SMOKE_USER_DOMAIN:-example.test}
PW=${SMOKE_PASSWORD:-'Dev-Password-123!'}
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
# Evaluate a Python expression over the JSON body; on any error print the raw body so failures are visible.
j() { python3 -c "
import sys,json
raw=sys.stdin.read()
try:
    d=json.loads(raw); print($1)
except Exception:
    print('UNEXPECTED_RESPONSE: '+raw[:200])"; }
req() { curl -sS -H "Host: $HOST" "$@"; }
login() { req -c "$TMP/$1" -H 'content-type: application/json' -d "{\"email\":\"$2@$DOMAIN\",\"password\":\"$PW\"}" "$BASE/api/v1/auth/login" | j 'd["csrfToken"]'; }
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok   $1"; pass=$((pass+1)); else echo "  FAIL $1 (expected '$3', got '$2')"; fail=$((fail+1)); fi; }

echo "Installation"
check "readiness" "$(curl -sS "$BASE/health/ready" | j 'd["status"]')" ready
# Set SMOKE_SKIP_SPA=1 when targeting a dev API without WEB_DIST_DIR (deployed images always serve the SPA).
[ "${SMOKE_SKIP_SPA:-0}" = "1" ] || check "SPA served" "$(req "$BASE/" | grep -c 'id="root"')" 1
check "runtime config has branding" "$(req "$BASE/api/v1/public/config" | j 'bool(d["brand"]["name"]) and d["organization"]["currency"]=="INR"')" True
check "runtime config has no secrets" "$(req "$BASE/api/v1/public/config" | grep -ci 'postgres\|password\|secret\|encryption' || true)" 0
# 404 from the API, or 403 when a dev proxy (Vite allowedHosts) refuses the host first.
check "unknown host rejected" "$(curl -sS -H 'Host: evil.example.com' -o /dev/null -w '%{http_code}' "$BASE/api/v1/public/config" | sed -E 's/^(403|404)$/rejected/')" rejected
check "no platform console" "$(req -o /dev/null -w '%{http_code}' "$BASE/api/v1/platform/tenants")" 404

echo "Employee self-service"
CE=$(login e employee)
check "web attendance usable" "$(req -b "$TMP/e" "$BASE/api/v1/auth/me" | j 'd["capabilities"]["attendance.web"]')" True
KEY="smoke-$(date +%s)"
check "web punch recorded" "$(req -b "$TMP/e" -H "x-csrf-token: $CE" -H 'content-type: application/json' -d "{\"channel\":\"web\",\"idempotencyKey\":\"$KEY\"}" "$BASE/api/v1/attendance/punch" | j 'd["duplicate"]')" False
check "retry is idempotent" "$(req -b "$TMP/e" -H "x-csrf-token: $CE" -H 'content-type: application/json' -d "{\"channel\":\"web\",\"idempotencyKey\":\"$KEY\"}" "$BASE/api/v1/attendance/punch" | j 'd["duplicate"]')" True
check "punch without CSRF refused" "$(req -b "$TMP/e" -o /dev/null -w '%{http_code}' -H 'content-type: application/json' -d '{"channel":"web","idempotencyKey":"nocsrf-1"}' "$BASE/api/v1/attendance/punch")" 403
check "employee cannot open settings" "$(req -b "$TMP/e" -o /dev/null -w '%{http_code}' "$BASE/api/v1/tenant/settings")" 403

echo "Leave"
check "employee sees leave balances" "$(req -b "$TMP/e" "$BASE/api/v1/leave/balances" | j 'any(i["code"]=="CL" for i in d["items"])')" True
FROM=$(python3 -c "import datetime as t;d=t.date.today()+t.timedelta(days=30);d+=t.timedelta(days=(7-d.weekday())%7);print(d)")
check "leave preview counts working days" "$(req -b "$TMP/e" -H "x-csrf-token: $CE" -H 'content-type: application/json' -d "{\"leaveTypeId\":\"$(req -b "$TMP/e" "$BASE/api/v1/leave/types" | j '[t for t in d["items"] if t["code"]=="CL"][0]["id"]')\",\"startDate\":\"$FROM\",\"endDate\":\"$FROM\"}" "$BASE/api/v1/leave/requests/preview" | j 'd["days"]')" 1.00

echo "Administration"
login h hr >/dev/null
check "HR sees 40 employees" "$(req -b "$TMP/h" "$BASE/api/v1/employees?pageSize=1" | j 'd["total"]')" 40
login a admin >/dev/null
check "installation is read-only for admins" "$(req -b "$TMP/a" "$BASE/api/v1/tenant/installation" | j 'd["managedBy"]')" deployment
check "admin cannot read bank details" "$(req -b "$TMP/a" -o /dev/null -w '%{http_code}' "$BASE/api/v1/employees/$(req -b "$TMP/h" "$BASE/api/v1/employees?pageSize=1" | j 'd["items"][0]["id"]')/bank-account")" 403

echo; echo "passed: $pass  failed: $fail"; [ "$fail" -eq 0 ]
