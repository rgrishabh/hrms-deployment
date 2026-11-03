#!/usr/bin/env bash
# Release one image to ONE customer account (credentials for that account must
# already be active, e.g. via the hrms-release role). Steps:
#   1. RDS snapshot (skip with SKIP_SNAPSHOT=true, e.g. staging)
#   2. Register task definition revisions with the new image
#   3. provision (roles/database, idempotent) -> migrate -> bootstrap (one-off tasks; any failure stops the release)
#   4. Roll the API service; ECS circuit breaker rolls back automatically on failure
#   5. Verify https://<domain>/health/ready and the tenant branding
# Usage: scripts/deploy/release.sh <image-uri>
set -euo pipefail
IMAGE=${1:?image uri required (registry/hrms-api:tag)}
REGION=${AWS_REGION:-ap-south-1}
export AWS_REGION=$REGION AWS_PAGER=""

param() { aws ssm get-parameter --name "/hrms/release/$1" --query Parameter.Value --output text; }
log() { echo "[$(date -u +%H:%M:%S)] $*"; }

CLUSTER=$(param cluster); SERVICE=$(param service); SUBNETS=$(param subnets); OPS_SG=$(param ops_sg)
DOMAIN=$(param domain); DB_ID=$(param db_instance_id); OPS_LOGS=$(param ops_log_group); SLUG=$(param customer_slug)
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
TAG=${IMAGE##*:}
log "release $TAG -> account $ACCOUNT ($SLUG), cluster $CLUSTER"

# --- 1. snapshot before any schema change
if [ "${SKIP_SNAPSHOT:-false}" != "true" ]; then
  SNAP="hrms-pre-${TAG//[^a-zA-Z0-9-]/-}-$(date -u +%Y%m%d%H%M%S)"
  SNAP=${SNAP:0:63}
  log "creating RDS snapshot $SNAP"
  aws rds create-db-snapshot --db-instance-identifier "$DB_ID" --db-snapshot-identifier "$SNAP" --tags Key=release,Value="$TAG" >/dev/null
  aws rds wait db-snapshot-available --db-snapshot-identifier "$SNAP"
  log "snapshot available"
fi

# --- 2. new task definition revisions (same settings, new image)
register() {
  local family=$1
  aws ecs describe-task-definition --task-definition "$family" --query taskDefinition --output json > /tmp/td-$family.json
  python3 - "$IMAGE" /tmp/td-$family.json > /tmp/td-$family-new.json <<'PY'
import json, sys
image, path = sys.argv[1], sys.argv[2]
td = json.load(open(path))
for c in td["containerDefinitions"]:
    if c["name"] == "app":
        c["image"] = image
for k in ["taskDefinitionArn", "revision", "status", "requiresAttributes", "compatibilities", "registeredAt", "registeredBy", "deregisteredAt"]:
    td.pop(k, None)
print(json.dumps(td))
PY
  aws ecs register-task-definition --cli-input-json "file:///tmp/td-$family-new.json" --query taskDefinition.taskDefinitionArn --output text
}
API_TD=$(register hrms-api); OPS_TD=$(register hrms-ops); DBADMIN_TD=$(register hrms-dbadmin)
log "registered: $API_TD"

# --- 3. one-off tasks
run_task() {
  local name=$1 td=$2; shift 2
  local overrides
  overrides=$(python3 -c 'import json,sys; print(json.dumps({"containerOverrides":[{"name":"app","command":sys.argv[1:]}]}))' "$@")
  log "running $name"
  local arn
  arn=$(aws ecs run-task --cluster "$CLUSTER" --task-definition "$td" --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={subnets=[$SUBNETS],securityGroups=[$OPS_SG],assignPublicIp=DISABLED}" \
    --overrides "$overrides" --started-by "release-$TAG" --query 'tasks[0].taskArn' --output text)
  aws ecs wait tasks-stopped --cluster "$CLUSTER" --tasks "$arn"
  local code reason
  code=$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$arn" --query 'tasks[0].containers[0].exitCode' --output text)
  reason=$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$arn" --query 'tasks[0].stoppedReason' --output text)
  local stream="ops/app/${arn##*/}"
  aws logs get-log-events --log-group-name "$OPS_LOGS" --log-stream-name "$stream" --query 'events[].message' --output text 2>/dev/null | tr '\t' '\n' | tail -20 || true
  if [ "$code" != "0" ]; then log "FAILED: $name exit=$code reason=$reason"; exit 1; fi
  log "$name ok"
}
run_task provision "$DBADMIN_TD" node dist/src/db/provision.js
run_task migrate   "$OPS_TD"     node dist/src/db/migrate.js
run_task bootstrap "$OPS_TD"     node dist/src/db/bootstrap.js

# --- 4. roll the service
log "updating service $SERVICE"
aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" --task-definition "$API_TD" >/dev/null
if ! aws ecs wait services-stable --cluster "$CLUSTER" --services "$SERVICE"; then
  log "FAILED: service did not stabilize (circuit breaker may have rolled back)"; exit 1
fi
RUNNING=$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --query 'services[0].deployments[?status==`PRIMARY`].taskDefinition' --output text)
if [ "$RUNNING" != "$API_TD" ]; then log "FAILED: primary deployment is $RUNNING (rolled back)"; exit 1; fi

# --- 5. verify through the public endpoint
for i in $(seq 1 10); do
  if curl -fsS "https://$DOMAIN/health/ready" >/dev/null && curl -fsS "https://$DOMAIN/api/v1/public/branding" | grep -q '"kind":"tenant"'; then
    log "verified https://$DOMAIN — release $TAG complete"; exit 0
  fi
  sleep 6
done
log "FAILED: https://$DOMAIN did not pass verification"; exit 1
