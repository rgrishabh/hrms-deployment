#!/usr/bin/env bash
# Optional dev deploy over AWS SSM Run Command (no inbound SSH). Called by deploy-dev.yml with AWS
# credentials from OIDC. Ships the active stack as a bundle via S3, passes .env and the GHCR token
# through SSM SecureString parameters (deleted afterwards), runs deploy-dev.sh on the instance.
# Env: BUCKET, INSTANCE, ENV_FILE, GHCR_USER, GHCR_TOKEN, STACK_DIR, BRANDENV, ROLLBACK=1 (optional)
# Arg: path of the previous versions.env (for rollback on the host)
set -euo pipefail
PREV=${1:?previous versions.env path required}
: "${BUCKET:?}" "${INSTANCE:?}" "${ENV_FILE:?}" "${GHCR_USER:?}" "${GHCR_TOKEN:?}"
DIR=/opt/hrms/dev
KEY="hrms-dev/bundle-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}.tgz"
export AWS_PAGER=""
TMP=$(mktemp -d); trap 'rm -rf "$TMP"; aws ssm delete-parameter --name /hrms/dev/ghcr-token >/dev/null 2>&1 || true' EXIT

cp -R "${STACK_DIR:-environments/dev}" "$TMP/dev"; rm -rf "$TMP/dev/.env.example" "$TMP/dev/.brandenv.example" "$TMP/dev/tests"
if [ -n "${BRANDENV:-}" ]; then printf '%s\n' "$BRANDENV" > "$TMP/dev/.brandenv"; fi
[ -f "$TMP/dev/deploy-dev.sh" ] || cp scripts/deploy-dev.sh "$TMP/dev/deploy-dev.sh"
cp scripts/bootstrap-ec2.sh "$TMP/dev/bootstrap-ec2.sh"; cp "$PREV" "$TMP/dev/versions.prev.env"
tar -C "$TMP/dev" -czf "$TMP/bundle.tgz" .
aws s3 cp "$TMP/bundle.tgz" "s3://$BUCKET/$KEY" --sse aws:kms --only-show-errors
aws ssm put-parameter --name /hrms/dev/env --type SecureString --overwrite --value "$ENV_FILE" >/dev/null
aws ssm put-parameter --name /hrms/dev/ghcr-token --type SecureString --overwrite --value "$GHCR_TOKEN" >/dev/null

MODE=""; [ "${ROLLBACK:-0}" = 1 ] && MODE="--rollback"
read -r -d '' REMOTE <<SH || true
set -euo pipefail
U=\$(stat -c %U /home/ubuntu 2>/dev/null || echo ubuntu)
mkdir -p $DIR && cd $DIR
aws s3 cp s3://$BUCKET/$KEY /tmp/hrms-bundle.tgz --only-show-errors && tar -xzf /tmp/hrms-bundle.tgz -C $DIR && rm -f /tmp/hrms-bundle.tgz
bash $DIR/bootstrap-ec2.sh "\$U"
umask 077; aws ssm get-parameter --name /hrms/dev/env --with-decryption --query Parameter.Value --output text > $DIR/.env
chown -R "\$U":"\$U" $DIR
aws ssm get-parameter --name /hrms/dev/ghcr-token --with-decryption --query Parameter.Value --output text | docker login ghcr.io -u '$GHCR_USER' --password-stdin >/dev/null
trap 'docker logout ghcr.io >/dev/null 2>&1 || true' EXIT
$DIR/deploy-dev.sh $MODE
SH
PARAMS=$(python3 -c 'import json,sys; print(json.dumps({"commands": [sys.argv[1]], "executionTimeout": ["1500"]}))' "$REMOTE")
CMD=$(aws ssm send-command --instance-ids "$INSTANCE" --document-name AWS-RunShellScript --comment "hrms dev deploy ${GITHUB_RUN_ID:-}" \
  --parameters "$PARAMS" --query Command.CommandId --output text)
echo "SSM command $CMD on $INSTANCE"
status=Pending
for _ in $(seq 1 180); do
  status=$(aws ssm get-command-invocation --command-id "$CMD" --instance-id "$INSTANCE" --query Status --output text 2>/dev/null || echo Pending)
  case "$status" in Pending|InProgress|Delayed) sleep 10 ;; *) break ;; esac
done
aws ssm get-command-invocation --command-id "$CMD" --instance-id "$INSTANCE" --query StandardOutputContent --output text | grep -v 'setup#token=' || true
aws ssm get-command-invocation --command-id "$CMD" --instance-id "$INSTANCE" --query StandardErrorContent --output text | tail -30 >&2 || true
aws s3 rm "s3://$BUCKET/$KEY" --only-show-errors || true
[ "$status" = Success ] || { echo "::error::SSM deploy finished with status $status"; exit 1; }
