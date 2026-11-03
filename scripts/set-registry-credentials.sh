#!/usr/bin/env bash
# Store GHCR pull credentials in ONE customer account's Secrets Manager secret
# hrms/registry-credentials (created empty by Terraform; read by ECS via repositoryCredentials).
# The token is read from stdin so it never appears in shell history or process lists.
# Usage: printf '%s' "$TOKEN" | AWS_PROFILE=<customer> scripts/set-registry-credentials.sh <github-username>
#   TOKEN: classic personal access token (or machine user token) with only read:packages.
set -euo pipefail
USERNAME=${1:?usage: set-registry-credentials.sh <github-username>  (token on stdin)}
[ -t 0 ] && { echo "pipe the token on stdin" >&2; exit 2; }
TOKEN=$(cat)
[ -n "$TOKEN" ] || { echo "empty token" >&2; exit 2; }
export AWS_PAGER=""
VALUE=$(USERNAME="$USERNAME" TOKEN="$TOKEN" python3 -c 'import json,os; print(json.dumps({"username": os.environ["USERNAME"], "password": os.environ["TOKEN"]}))')
aws secretsmanager put-secret-value --secret-id hrms/registry-credentials --secret-string "$VALUE" --query VersionId --output text >/dev/null
echo "stored registry credentials for $USERNAME in $(aws sts get-caller-identity --query Account --output text)/hrms/registry-credentials"
