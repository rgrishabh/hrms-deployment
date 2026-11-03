#!/usr/bin/env bash
# Deploy one release to ONE customer account (credentials for that account must already be
# active, e.g. the hrms-release role via GitHub OIDC). Order, any failure stops the release:
#   1. RDS snapshot (skip: --skip-snapshot)
#   2. register task definition revisions with the new images (backend: api, ops, dbadmin; frontend: web)
#   3. one-off tasks: provision -> migrate -> bootstrap (skip all: --skip-migrations, used by rollbacks)
#   4. roll both services; ECS circuit breaker rolls back a deployment that never becomes healthy
#   5. smoke test through the public domain (scripts/smoke-test.sh)
#   6. on failure after step 4: put both services back on their previous task definitions
# Usage: scripts/deploy-prod.sh --backend <image> --frontend <image> [--skip-snapshot] [--skip-migrations]
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
BACKEND="" FRONTEND="" SNAPSHOT=1 MIGRATE=1
while [ $# -gt 0 ]; do
  case "$1" in
    --backend) BACKEND=$2; shift 2 ;;
    --frontend) FRONTEND=$2; shift 2 ;;
    --skip-snapshot) SNAPSHOT=0; shift ;;
    --skip-migrations) MIGRATE=0; shift ;;
    *) echo "unknown argument $1" >&2; exit 2 ;;
  esac
done
[ -n "$BACKEND" ] && [ -n "$FRONTEND" ] || { echo "usage: deploy-prod.sh --backend <image> --frontend <image>" >&2; exit 2; }
for img in "$BACKEND" "$FRONTEND"; do
  case "$img" in *:latest|*:latest@*) echo "refusing mutable tag: $img" >&2; exit 2 ;; esac
done
export AWS_REGION=${AWS_REGION:-ap-south-1} AWS_PAGER=""
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

param() { aws ssm get-parameter --name "/hrms/release/$1" --query Parameter.Value --output text; }
log() { echo "[$(date -u +%H:%M:%S)] $*"; }
summary() { if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then echo "$*" >> "$GITHUB_STEP_SUMMARY"; fi; }

CLUSTER=$(param cluster); API_SVC=$(param service); WEB_SVC=$(param web_service); SUBNETS=$(param subnets); OPS_SG=$(param ops_sg)
DOMAIN=$(param domain); DB_ID=$(param db_instance_id); OPS_LOGS=$(param ops_log_group); SLUG=$(param customer_slug)
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
# image refs may carry a digest: repo:tag@sha256:… — strip it before taking the tag
tag_of() { local r=${1%%@*}; echo "${r##*:}"; }
TAG=$(tag_of "$BACKEND")
log "release backend=$BACKEND frontend=$FRONTEND -> $SLUG (account $ACCOUNT, cluster $CLUSTER)"

current_td() { aws ecs describe-services --cluster "$CLUSTER" --services "$1" --query 'services[0].taskDefinition' --output text; }
PREV_API=$(current_td "$API_SVC"); PREV_WEB=$(current_td "$WEB_SVC")
log "previous: $PREV_API | $PREV_WEB"

# --- 1. snapshot before any schema change
if [ "$SNAPSHOT" = 1 ] && [ "$MIGRATE" = 1 ]; then
  SNAP="hrms-pre-${TAG//[^a-zA-Z0-9-]/-}-$(date -u +%Y%m%d%H%M%S)"; SNAP=${SNAP:0:63}
  log "creating RDS snapshot $SNAP"
  aws rds create-db-snapshot --db-instance-identifier "$DB_ID" --db-snapshot-identifier "$SNAP" --tags Key=release,Value="$TAG" >/dev/null
  aws rds wait db-snapshot-available --db-snapshot-identifier "$SNAP"
fi

# --- 2. new task definition revisions (same settings, new image)
register() {
  local family=$1 container=$2 image=$3
  aws ecs describe-task-definition --task-definition "$family" --query taskDefinition --output json > "$TMP/$family.json"
  python3 - "$container" "$image" "$TMP/$family.json" > "$TMP/$family-new.json" <<'PY'
import json, sys
container, image, path = sys.argv[1:4]
td = json.load(open(path))
hit = [c for c in td["containerDefinitions"] if c["name"] == container]
if not hit: sys.exit(f"container {container} not in task definition")
hit[0]["image"] = image
for k in ["taskDefinitionArn", "revision", "status", "requiresAttributes", "compatibilities", "registeredAt", "registeredBy", "deregisteredAt"]:
    td.pop(k, None)
print(json.dumps(td))
PY
  aws ecs register-task-definition --cli-input-json "file://$TMP/$family-new.json" --query taskDefinition.taskDefinitionArn --output text
}
API_TD=$(register hrms-api app "$BACKEND"); OPS_TD=$(register hrms-ops app "$BACKEND")
DBADMIN_TD=$(register hrms-dbadmin app "$BACKEND"); WEB_TD=$(register hrms-web web "$FRONTEND")
log "registered: $API_TD $WEB_TD"

# --- 3. one-off tasks
run_task() {
  local name=$1 td=$2; shift 2
  local overrides arn code reason
  overrides=$(python3 -c 'import json,sys; print(json.dumps({"containerOverrides":[{"name":"app","command":sys.argv[1:]}]}))' "$@")
  log "running $name"
  arn=$(aws ecs run-task --cluster "$CLUSTER" --task-definition "$td" --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={subnets=[$SUBNETS],securityGroups=[$OPS_SG],assignPublicIp=DISABLED}" \
    --overrides "$overrides" --started-by "release-$TAG" --query 'tasks[0].taskArn' --output text)
  aws ecs wait tasks-stopped --cluster "$CLUSTER" --tasks "$arn"
  code=$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$arn" --query 'tasks[0].containers[0].exitCode' --output text)
  reason=$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$arn" --query 'tasks[0].stoppedReason' --output text)
  aws logs get-log-events --log-group-name "$OPS_LOGS" --log-stream-name "ops/app/${arn##*/}" --query 'events[].message' --output text 2>/dev/null \
    | tr '\t' '\n' | grep -v 'setup#token=' | tail -20 || true
  if [ "$code" != "0" ]; then
    log "FAILED: $name exit=$code reason=$reason"
    summary "❌ $SLUG: $name failed (exit $code), nothing was rolled out"
    exit 1
  fi
  log "$name ok"
}
if [ "$MIGRATE" = 1 ]; then
  run_task provision "$DBADMIN_TD" provision
  run_task migrate   "$OPS_TD"     migrate
  run_task bootstrap "$OPS_TD"     bootstrap
fi

# --- 4. roll both services (from here on, failures restore the previous task definitions)
restore() {
  log "ROLLING BACK services to $PREV_API | $PREV_WEB"
  aws ecs update-service --cluster "$CLUSTER" --service "$API_SVC" --task-definition "$PREV_API" >/dev/null
  aws ecs update-service --cluster "$CLUSTER" --service "$WEB_SVC" --task-definition "$PREV_WEB" >/dev/null
  aws ecs wait services-stable --cluster "$CLUSTER" --services "$API_SVC" "$WEB_SVC" || log "warning: services not stable after rollback"
  summary "⚠️ $SLUG: release $TAG failed; services restored to the previous task definitions"
  exit 1
}
log "updating services"
aws ecs update-service --cluster "$CLUSTER" --service "$API_SVC" --task-definition "$API_TD" >/dev/null
aws ecs update-service --cluster "$CLUSTER" --service "$WEB_SVC" --task-definition "$WEB_TD" >/dev/null
aws ecs wait services-stable --cluster "$CLUSTER" --services "$API_SVC" "$WEB_SVC" || { log "services did not stabilize"; restore; }
for pair in "$API_SVC=$API_TD" "$WEB_SVC=$WEB_TD"; do
  # shellcheck disable=SC2016 # JMESPath backticks, not shell
  running=$(aws ecs describe-services --cluster "$CLUSTER" --services "${pair%%=*}" --query 'services[0].deployments[?status==`PRIMARY`].taskDefinition' --output text)
  [ "$running" = "${pair#*=}" ] || { log "${pair%%=*}: circuit breaker rolled back to $running"; restore; }
done

# --- 5. verify through the public endpoint
FRONT_TAG=$(tag_of "$FRONTEND")
ok=0
for _ in $(seq 1 10); do
  if "$HERE/smoke-test.sh" "https://$DOMAIN" --expect-version "$FRONT_TAG"; then ok=1; break; fi
  sleep 10
done
[ "$ok" = 1 ] || { log "smoke test failed"; restore; }
log "release $TAG live at https://$DOMAIN"
summary "✅ $SLUG: backend \`${BACKEND##*/}\`, frontend \`${FRONTEND##*/}\` live at https://$DOMAIN"
