#!/usr/bin/env bash
# shellcheck disable=SC2016 # the dollar in the entrypoint pattern is literal
# Compares what the backend reads with what the manifests provide. A variable missing from an allowlist
# silently does nothing, so this is checked. Needs a checkout of hrms-backend; CI has none, so run it by hand.
#   scripts/check-backend-env.sh [path/to/hrms-backend]
set -euo pipefail
cd "$(dirname "$0")/.."
BACKEND=${1:-../hrms-backend}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
[ -f "$BACKEND/src/config/env.ts" ] || { echo "error: no src/config/env.ts under $BACKEND" >&2; exit 2; }

# Two-space keys of the zod schema, and anything else read from the environment in application code.
sed -n '/^const schema = z.object({/,/^});/p' "$BACKEND/src/config/env.ts" | sed -n 's/^  \([A-Z][A-Z0-9_]*\):.*/\1/p' | sort -u > "$T/schema"
grep -rhoE '(process\.env|source|env)\.[A-Z][A-Z0-9_]+' "$BACKEND/src" --include='*.ts' --exclude='*.test.ts' | sed 's/.*\.//' | sort -u > "$T/reads"
grep -oE '\$\{?[A-Z][A-Z0-9_]+' "$BACKEND/docker/entrypoint.sh" | tr -d '${' | sort -u >> "$T/reads" || true
sort -u "$T/schema" "$T/reads" | grep -v '^FEATURE_' > "$T/backend"

# Set by the image, unused in a deployment, test-only or removed: not expected in either shape, each with its reason.
cat > "$T/not-expected" <<'LIST'
APP_VERSION
BASIC
DATABASE_CA_FILE
ENABLED_MODULES
MFA_ENFORCEMENT
MIGRATIONS_DIR
PERF_APP_URL
PERF_EMPLOYEES
PERF_OWNER_URL
VITEST
WEB_DIST_DIR
LIST
# Operator input on a one-off command, not part of the deployed environment.
cat >> "$T/not-expected" <<'LIST'
BOOTSTRAP_ADMIN_PASSWORD
BOOTSTRAP_LINK_HOURS
BOOTSTRAP_MAKE_OWNER
BOOTSTRAP_MODE
BOOTSTRAP_RESET_ADMIN
LIST
sort -u -o "$T/not-expected" "$T/not-expected"

names() { sed -n 's/^ *\([A-Z][A-Z0-9_]*\): .*/\1/p' "$@"; }
{ names dev/docker-compose.yml; sed -n 's/^\(BRAND_[A-Z_]*\)=.*/\1/p' dev/.brandenv.example; } | sort -u > "$T/compose"
{
  sed -n 's/^\([A-Z][A-Z0-9_]*\)=.*/\1/p' k8s/overlays/prod/app.env k8s/overlays/prod/brand.env
  names k8s/base/externalsecrets.yaml
  sed -n 's/.*secretKey: \([A-Z][A-Z0-9_]*\),.*/\1/p' k8s/base/externalsecrets.yaml
  sed -n 's/.*{ name: \([A-Z][A-Z0-9_]*\),.*/\1/p' k8s/base/*.yaml
} | sort -u > "$T/kustomize"
# Only in the other shape, by design.
cat > "$T/compose-only" <<'LIST'
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
DATA_ENCRYPTION_KEY
DATA_ENCRYPTION_KEY_PREVIOUS
DEMO_DATA_ALLOWED
STORAGE_PATH
LIST
sort -u -o "$T/compose-only" "$T/compose-only"

failed=0
report() { # label, names
  if [ -n "$2" ]; then echo "FAIL $1: $(echo "$2" | tr '\n' ' ')"; failed=1; else echo "ok   $1"; fi
}
echo "backend reads $(wc -l < "$T/backend" | tr -d ' ') variables, $(wc -l < "$T/schema" | tr -d ' ') of them in the schema (FEATURE_* are checked by check-config-parity.sh)"
report "read by the backend, missing from Compose" "$(comm -23 "$T/backend" "$T/not-expected" | comm -23 - "$T/compose")"
report "read by the backend, missing from Kustomize" "$(comm -23 "$T/backend" "$T/not-expected" | comm -23 - "$T/compose-only" | comm -23 - "$T/kustomize")"
echo "info provided by Compose, not read by the backend: $(grep -vE '^(FEATURE_|BRAND_)' "$T/compose" | comm -23 - "$T/backend" | tr '\n' ' ')"
echo "info provided by Kustomize, not read by the backend: $(grep -vE '^(FEATURE_|BRAND_)' "$T/kustomize" | comm -23 - "$T/backend" | tr '\n' ' ')"
echo "info deliberately not provided: $(tr '\n' ' ' < "$T/not-expected")"
exit "$failed"
