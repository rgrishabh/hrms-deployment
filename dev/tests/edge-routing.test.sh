#!/usr/bin/env bash
# Runs dev/Caddyfile in the pinned Caddy image against two stub upstreams. /metrics must stop at the edge,
# and everything else must reach the same upstream as k8s/base/ingress.yaml. Needs a Docker daemon.
set -uo pipefail
DEV=$(cd "$(dirname "$0")/.." && pwd)
IMAGE=$(sed -n 's/^x-caddy-image: &caddy-image //p' "$DEV/docker-compose.yml")
[ -n "$IMAGE" ] || { echo "no Caddy image found in docker-compose.yml" >&2; exit 2; }
ID="hrms-edge-test-$$"
pass=0; failed=0
cleanup() { docker rm -f "$ID-edge" "$ID-backend" "$ID-frontend" >/dev/null 2>&1; docker network rm "$ID" >/dev/null 2>&1; }
trap cleanup EXIT

docker network create "$ID" >/dev/null || exit 2
for up in backend:4000 frontend:8080; do
  docker run -d --name "$ID-${up%:*}" --network "$ID" --network-alias "${up%:*}" "$IMAGE" \
    caddy respond --listen ":${up#*:}" --status 200 --body "${up%:*}" >/dev/null || exit 2
done
# Copied in rather than mounted, so the test works from a path the Docker VM does not share.
docker create --name "$ID-edge" --network "$ID" -e SITE_ADDRESS=:8088 -e BRAND_DOMAIN=localhost "$IMAGE" >/dev/null || exit 2
docker cp "$DEV/Caddyfile" "$ID-edge:/etc/caddy/Caddyfile" >/dev/null || exit 2
docker start "$ID-edge" >/dev/null || exit 2
for _ in $(seq 1 30); do
  docker exec "$ID-edge" wget -qO /dev/null http://127.0.0.1:2019/config/ 2>/dev/null && break
  sleep 1
done

# "<status> <body>". Two requests, because wget's headers and an unterminated body interleave on one stream.
fetch() {
  local status body
  status=$(docker exec "$ID-edge" wget -S -O /dev/null "http://127.0.0.1:8088$1" 2>&1 | sed -n 's/^ *HTTP\/[0-9.]* \([0-9]*\).*/\1/p' | tail -1)
  body=$(docker exec "$ID-edge" wget -qO - "http://127.0.0.1:8088$1" 2>/dev/null)
  echo "$status $body"
}
expect() {
  local got; got=$(fetch "$1")
  if [ "$got" = "$2" ]; then echo "  ok    $1 -> $2"; pass=$((pass+1)); else echo "  FAIL  $1 -> '$got', expected '$2'"; failed=$((failed+1)); fi
}

for p in /metrics /metrics/ /metrics/anything /METRICS '/metrics?x=1'; do expect "$p" "404 "; done
for p in /api/v1/x /health /health/ready /ready /brand/logo.png; do expect "$p" "200 backend"; done
for p in / /login /metricsfoo; do expect "$p" "200 frontend"; done

echo "edge routing: $pass passed, $failed failed"
[ "$failed" -eq 0 ]
