#!/usr/bin/env bash
# One-time (and re-runnable) GitHub setup for the three HRMS repos, with the gh CLI.
# Creates the private repos if missing, pushes main/develop, sets repo + Actions settings,
# environments (dev, prod-<slug>, infra-<slug>) with their variables/secrets, and branch rulesets.
# Never prints secret values. Safe to re-run: every step is "create or update".
#
# Usage: scripts/setup-github.sh [--owner rgrishabh] [--repos-dir ..] [--skip-push]
# Optional inputs (environment variables; anything unset is skipped and reported):
#   DEV_EC2_HOST=<dev-host> DEV_EC2_USER=ubuntu DEV_SITE=dev.example.com
#   DEV_EC2_SSH_KEY_FILE=~/.ssh/id_ed25519     DEV_ENV_FILE_PATH=environments/dev/.env
#   DEPLOY_REPO_TOKEN (fine-grained PAT: hrms-deployment Contents RW + Pull requests RW; app repos read)
#   DEPLOY_APP_ID + DEPLOY_APP_PRIVATE_KEY_FILE (GitHub App alternative to the PAT; preferred)
#   GHCR_PULL_USER + GHCR_PULL_TOKEN (classic PAT, read:packages; only if you don't grant package access)
#   NOTIFY_WEBHOOK_URL (Slack/Teams incoming webhook)
set -euo pipefail
OWNER=rgrishabh; REPOS_DIR=$(cd "$(dirname "$0")/../.." && pwd); PUSH=1
while [ $# -gt 0 ]; do
  case "$1" in
    --owner) OWNER=$2; shift 2 ;;
    --repos-dir) REPOS_DIR=$(cd "$2" && pwd); shift 2 ;;
    --skip-push) PUSH=0; shift ;;
    *) echo "unknown argument $1" >&2; exit 2 ;;
  esac
done
command -v gh >/dev/null || { echo "install gh first: brew install gh" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "run: gh auth login (scopes: repo, workflow, admin:org not needed)" >&2; exit 1; }
DEPLOY_REPO=$REPOS_DIR/hrms-deployment
APP_REPOS=(hrms-backend hrms-frontend)
WARN=()
log() { echo "[setup] $*"; }
warn() { echo "[setup] WARNING: $*" >&2; WARN+=("$*"); }
api() { gh api -H "Accept: application/vnd.github+json" "$@"; }
OWNER_ID=$(api "users/$OWNER" --jq .id)

# ------------------------------------------------------------------ repos + push
for r in hrms-backend hrms-frontend hrms-deployment; do
  if ! gh repo view "$OWNER/$r" >/dev/null 2>&1; then
    log "creating private repo $OWNER/$r"
    gh repo create "$OWNER/$r" --private --description "HRMS ${r#hrms-}" >/dev/null
  fi
  if [ "$PUSH" = 1 ]; then
    git -C "$REPOS_DIR/$r" remote get-url origin >/dev/null 2>&1 || git -C "$REPOS_DIR/$r" remote add origin "git@github.com:$OWNER/$r.git"
    log "pushing $r main"
    git -C "$REPOS_DIR/$r" push -u origin main
    if [ "$r" != hrms-deployment ]; then
      git -C "$REPOS_DIR/$r" show-ref --verify --quiet refs/heads/develop || git -C "$REPOS_DIR/$r" branch develop main
      git -C "$REPOS_DIR/$r" push -u origin develop
    fi
  fi
  # App repos keep long-lived develop: auto-delete would remove it when develop -> main is merged.
  autodelete=true; [ "$r" = hrms-deployment ] || autodelete=false
  api -X PATCH "repos/$OWNER/$r" -F delete_branch_on_merge=$autodelete -F allow_merge_commit=false -F allow_squash_merge=true \
    -F allow_rebase_merge=true -F allow_auto_merge=true >/dev/null
  # Workflows get a read-only GITHUB_TOKEN by default; release-please/create-pull-request may open PRs.
  api -X PUT "repos/$OWNER/$r/actions/permissions/workflow" -f default_workflow_permissions=read -F can_approve_pull_request_reviews=true >/dev/null
  api -X PUT "repos/$OWNER/$r/vulnerability-alerts" >/dev/null 2>&1 || true
  # Public repos: workflows from fork PRs of any outside contributor wait for approval (secrets are never given to forks).
  api -X PUT "repos/$OWNER/$r/actions/permissions/fork-pr-contributor-approval" -f approval_policy=all_external_contributors >/dev/null 2>&1 \
    || warn "$r: could not require approval for fork PR workflows (Settings → Actions → General)"
  api -X PUT "repos/$OWNER/$r/private-vulnerability-reporting" >/dev/null 2>&1 || true
done
# The app repos call reusable workflows in hrms-deployment (private): allow repos of the same owner.
if [ "$(gh repo view "$OWNER/hrms-deployment" --json visibility -q .visibility)" != PUBLIC ]; then
  api -X PUT "repos/$OWNER/hrms-deployment/actions/permissions/access" -f access_level=user >/dev/null \
    || warn "could not allow other repos to use hrms-deployment workflows (Settings → Actions → General → Access)"
fi
gh label create release --repo "$OWNER/hrms-deployment" --color 0E8A16 --description "Production release PR" >/dev/null 2>&1 || true

# ------------------------------------------------------------------ dispatch credentials (app repos)
for r in "${APP_REPOS[@]}"; do
  if [ -n "${DEPLOY_APP_ID:-}" ] && [ -n "${DEPLOY_APP_PRIVATE_KEY_FILE:-}" ]; then
    gh variable set DEPLOY_APP_ID --repo "$OWNER/$r" --body "$DEPLOY_APP_ID"
    gh secret set DEPLOY_APP_PRIVATE_KEY --repo "$OWNER/$r" < "$DEPLOY_APP_PRIVATE_KEY_FILE"
  elif [ -n "${DEPLOY_REPO_TOKEN:-}" ]; then
    printf '%s' "$DEPLOY_REPO_TOKEN" | gh secret set DEPLOY_REPO_TOKEN --repo "$OWNER/$r"
  else
    warn "$r: no DEPLOY_APP_ID/DEPLOY_APP_PRIVATE_KEY_FILE or DEPLOY_REPO_TOKEN; builds will publish but cannot trigger deployments"
  fi
done
D="$OWNER/hrms-deployment"
if [ -n "${DEPLOY_APP_ID:-}" ] && [ -n "${DEPLOY_APP_PRIVATE_KEY_FILE:-}" ]; then
  gh variable set DEPLOY_APP_ID --repo "$D" --body "$DEPLOY_APP_ID"; gh secret set DEPLOY_APP_PRIVATE_KEY --repo "$D" < "$DEPLOY_APP_PRIVATE_KEY_FILE"
elif [ -n "${DEPLOY_REPO_TOKEN:-}" ]; then
  printf '%s' "$DEPLOY_REPO_TOKEN" | gh secret set DEPLOY_REPO_TOKEN --repo "$D"
fi
if [ -n "${GHCR_PULL_TOKEN:-}" ]; then
  gh variable set GHCR_PULL_USER --repo "$D" --body "${GHCR_PULL_USER:-$OWNER}"
  printf '%s' "$GHCR_PULL_TOKEN" | gh secret set GHCR_PULL_TOKEN --repo "$D"
fi
[ -z "${NOTIFY_WEBHOOK_URL:-}" ] || printf '%s' "$NOTIFY_WEBHOOK_URL" | gh secret set NOTIFY_WEBHOOK_URL --repo "$D"

# ------------------------------------------------------------------ environments
env_put() {  # name, reviewers(true/false)
  local name=$1 reviewers=$2 body
  body=$(jq -n --argjson rev "$reviewers" --argjson id "$OWNER_ID" \
    '{deployment_branch_policy: {protected_branches: false, custom_branch_policies: true}}
     + (if $rev then {reviewers: [{type: "User", id: $id}], prevent_self_review: false} else {} end)')
  if ! api -X PUT "repos/$D/environments/$name" --input - <<<"$body" >/dev/null 2>&1; then
    warn "environment $name: required reviewers need GitHub Pro/Team for private repos; created WITHOUT approval gate"
    api -X PUT "repos/$D/environments/$name" --input - <<<'{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}' >/dev/null
  fi
  api -X POST "repos/$D/environments/$name/deployment-branch-policies" -f name=main -f type=branch >/dev/null 2>&1 || true
}
env_var() { gh variable set "$2" --repo "$D" --env "$1" --body "$3"; }

env_put dev false
[ -z "${DEV_EC2_HOST:-}" ] || {
  env_var dev DEV_EC2_HOST "$DEV_EC2_HOST"; env_var dev DEV_EC2_USER "${DEV_EC2_USER:-ubuntu}"
  hk=$(ssh-keyscan -T 10 -t ed25519,ecdsa,rsa "$DEV_EC2_HOST" 2>/dev/null | sort)
  if [ -n "$hk" ]; then
    env_var dev DEV_EC2_HOST_KEY "$hk"
    log "pinned dev host keys — verify the fingerprints against the EC2 console/serial log:"; ssh-keygen -lf <(echo "$hk") || true
  else warn "could not read the SSH host key of $DEV_EC2_HOST"; fi
}
[ -z "${DEV_SITE:-}" ] || env_var dev DEV_SITE "$DEV_SITE"
[ -z "${DEV_EC2_SSH_KEY_FILE:-}" ] || gh secret set DEV_EC2_SSH_KEY --repo "$D" --env dev < "$DEV_EC2_SSH_KEY_FILE"
if [ -n "${DEV_ENV_FILE_PATH:-}" ]; then
  grep -q '<' <(grep -v '^[[:space:]]*#' "$DEV_ENV_FILE_PATH") && warn "$DEV_ENV_FILE_PATH still contains <placeholders>"
  gh secret set DEV_ENV_FILE --repo "$D" --env dev < "$DEV_ENV_FILE_PATH"
else warn "DEV_ENV_FILE not set (see environments/dev/.env.example)"; fi

jq -c '.customers[]' "$DEPLOY_REPO/environments/prod/customers.json" | while read -r c; do
  slug=$(jq -r .slug <<<"$c"); acct=$(jq -r .account_id <<<"$c")
  env_put "prod-$slug" true
  env_var "prod-$slug" AWS_DEPLOY_ROLE_ARN "arn:aws:iam::$acct:role/hrms-release"
  env_put "infra-$slug" true
  log "environments prod-$slug / infra-$slug ready (account $acct)"
done

# ------------------------------------------------------------------ branch rulesets
ruleset() {  # repo, name, branch, checks-json, bypass-json
  local repo=$1 name=$2 branch=$3 checks=$4 bypass=$5 body id
  body=$(jq -n --arg name "$name" --arg ref "refs/heads/$branch" --argjson checks "$checks" --argjson bypass "$bypass" '{
    name: $name, target: "branch", enforcement: "active",
    conditions: {ref_name: {include: [$ref], exclude: []}},
    bypass_actors: $bypass,
    rules: ([{type: "deletion"}, {type: "non_fast_forward"}, {type: "required_linear_history"},
      {type: "pull_request", parameters: {required_approving_review_count: 0, dismiss_stale_reviews_on_push: true,
        require_code_owner_review: false, require_last_push_approval: false, required_review_thread_resolution: true}}]
      + (if ($checks | length) > 0 then [{type: "required_status_checks", parameters: {strict_required_status_checks_policy: false,
          required_status_checks: [$checks[] | {context: .}]}}] else [] end))}')
  if ! api "repos/$OWNER/$repo/rulesets" >/dev/null 2>&1; then
    warn "$repo: rulesets on private repos need GitHub Pro/Team (or a public repo); '$name' not applied"; return 0
  fi
  id=$(api "repos/$OWNER/$repo/rulesets" --jq ".[] | select(.name == \"$name\") | .id" 2>/dev/null || true)
  if [ -n "$id" ]; then api -X PUT "repos/$OWNER/$repo/rulesets/$id" --input - <<<"$body" >/dev/null 2>&1 || warn "$repo: could not update ruleset $name"
  else
    local err
    err=$(api -X POST "repos/$OWNER/$repo/rulesets" --input - <<<"$body" 2>&1 >/dev/null) || warn "$repo: ruleset '$name' not applied: ${err:0:200}"
  fi
}
ADMIN='[{"actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always"}]'
APP_CHECKS='["ci / Lint, test, build", "ci / Image build + Trivy", "ci / gitleaks"]'
for r in "${APP_REPOS[@]}"; do
  ruleset "$r" "protect-main" main "$APP_CHECKS" "$ADMIN"
  ruleset "$r" "protect-develop" develop "$APP_CHECKS" "$ADMIN"
done
# hrms-deployment main: bots commit versions.env directly (dev deploys, prod reverts). Personal repos cannot let the
# GitHub Actions integration bypass rulesets, so the bot must use DEPLOY_REPO_TOKEN (an admin's PAT) or the GitHub App.
BOT_BYPASS=$ADMIN
if [ -n "${DEPLOY_APP_ID:-}" ]; then BOT_BYPASS=$(jq -c --argjson id "$DEPLOY_APP_ID" '. + [{actor_id: $id, actor_type: "Integration", bypass_mode: "always"}]' <<<"$BOT_BYPASS"); fi
ruleset hrms-deployment "protect-main" main '["lint", "secrets"]' "$BOT_BYPASS"

echo
log "done."
if [ "${#WARN[@]}" -gt 0 ]; then echo; echo "Needs attention:"; printf '  - %s\n' "${WARN[@]}"; fi
cat <<EOF

Manual steps that have no API (once per package, after the first image is pushed):
  github.com/users/$OWNER/packages/container/hrms-backend/settings  and  …/hrms-frontend/settings
  → "Manage Actions access" → Add repository hrms-deployment (Read)
  (or set GHCR_PULL_USER/GHCR_PULL_TOKEN and re-run).
EOF
