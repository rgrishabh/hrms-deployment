#!/usr/bin/env bash
# Waits for a pushed release to be live, then runs the smoke test. The pipeline has no access to the
# cluster, so it watches what the site reports. Fails after WAIT_MINUTES (default 30). /health does not
# report the backend's version yet: while it doesn't, this waits SETTLE_MINUTES (default 10) instead.
#   scripts/k8s-wait-release.sh https://<domain> <backend-version> <frontend-version> [--expect-brand <name>]
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
BASE=${1:?site url}; BACKEND=${2:?backend version}; FRONTEND=${3:?frontend version}; shift 3
start=$(date +%s)
deadline=$(( start + ${WAIT_MINUTES:-30} * 60 ))
settled=$(( start + ${SETTLE_MINUTES:-10} * 60 ))
while :; do
  web=$(curl -fsS --max-time 10 "$BASE/env.js" 2>/dev/null | sed -n 's/.*"version":"\([^"]*\)".*/\1/p' || true)
  api=$(curl -fsS --max-time 10 "$BASE/health" 2>/dev/null | sed -n 's/.*"version":"\([^"]*\)".*/\1/p' || true)
  echo "frontend=$web backend=$api; waiting for $FRONTEND and $BACKEND"
  if [ "$web" = "$FRONTEND" ]; then
    if [ "$api" = "$BACKEND" ]; then break; fi
    if [ -z "$api" ] && [ "$(date +%s)" -ge "$settled" ]; then break; fi
  fi
  [ "$(date +%s)" -lt "$deadline" ] || { echo "error: not live after ${WAIT_MINUTES:-30} minutes" >&2; exit 1; }
  sleep 20
done
"$HERE/smoke-test.sh" "$BASE" --expect-version "$FRONTEND" "$@"
