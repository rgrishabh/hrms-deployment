#!/usr/bin/env bash
# shellcheck disable=SC2016 # the backticks in these patterns are literal Markdown
# Keeps the three places that list settings in step: the contract (docs/CONFIGURATION.md), the Compose
# allowlist (dev/docker-compose.yml) and the Kustomize files (k8s/overlays/prod). A variable missing
# from the Compose allowlist silently does nothing, so this is checked rather than left to review.
set -euo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
failed=0
missing() { # label file-of-expected file-of-actual
  extra=$(comm -23 "$2" "$3")
  if [ -n "$extra" ]; then echo "FAIL $1: $(echo "$extra" | tr '\n' ' ')"; failed=1; else echo "ok   $1"; fi
}

grep -oE '^\| `FEATURE_[A-Z_]+`' docs/CONFIGURATION.md | grep -oE 'FEATURE_[A-Z_]+' | sort -u > "$T/contract-features"
sed -n 's/^  \(FEATURE_[A-Z_]*\): .*/\1/p' dev/docker-compose.yml | sort -u > "$T/compose-features"
sed -n 's/^\(FEATURE_[A-Z_]*\)=.*/\1/p' k8s/overlays/prod/app.env | sort -u > "$T/kustomize-features"
[ -s "$T/contract-features" ] || { echo "FAIL could not read flags from the contract"; exit 1; }
missing "contract flags are in Compose" "$T/contract-features" "$T/compose-features"
missing "Compose flags are in the contract" "$T/compose-features" "$T/contract-features"
missing "contract flags are in app.env" "$T/contract-features" "$T/kustomize-features"
missing "app.env flags are in the contract" "$T/kustomize-features" "$T/contract-features"

# Runtime wiring both deployment shapes must offer. Secret-backed values live in externalsecrets.yaml.
printf '%s\n' ORG_MANAGEMENT_MODE MFA_AVAILABLE MFA_ENFORCED MFA_METHODS DATABASE_URL DB_READ_HOST STORAGE_DRIVER \
  AWS_S3_BUCKET AWS_REGION S3_ENDPOINT CLAMAV_HOST CLAMAV_PORT SMTP_HOST SMTP_PORT SMTP_SECURE SMTP_USER SMTP_PASSWORD \
  TRUST_PROXY RATE_LIMIT_PER_MINUTE AUTH_RATE_LIMIT_PER_MINUTE AUTH_ACCOUNT_RATE_LIMIT_PER_MINUTE EXPORT_RATE_LIMIT_PER_MINUTE \
  JOBS_INTERVAL_SECONDS METRICS_TOKEN OTEL_EXPORTER_OTLP_ENDPOINT VAPID_PUBLIC_KEY VAPID_PRIVATE_KEY VAPID_SUBJECT \
  KMS_KEY_ID DATA_KEY_CIPHERTEXT DATA_KEY_CIPHERTEXT_PREVIOUS | sort -u > "$T/wiring"
sed -n 's/^ *\([A-Z][A-Z0-9_]*\): .*/\1/p' dev/docker-compose.yml | sort -u > "$T/compose-all"
{ sed -n 's/^\([A-Z][A-Z0-9_]*\)=.*/\1/p' k8s/overlays/prod/app.env; sed -n 's/^ *\([A-Z][A-Z0-9_]*\): .*/\1/p' k8s/base/externalsecrets.yaml; } | sort -u > "$T/kustomize-all"
missing "runtime wiring is in Compose" "$T/wiring" "$T/compose-all"
missing "runtime wiring is in Kustomize" "$T/wiring" "$T/kustomize-all"

# Brand variables: the example files and the contract must name the same set.
sed '/^## Layer 3/q' docs/CONFIGURATION.md | grep -oE '`BRAND_[A-Z_]+`' | tr -d '`' | sort -u > "$T/contract-brand"
sed -n 's/^\(BRAND_[A-Z_]*\)=.*/\1/p' dev/.brandenv.example | sort -u > "$T/brandenv"
sed -n 's/^\(BRAND_[A-Z_]*\)=.*/\1/p' k8s/overlays/prod/brand.env | sort -u > "$T/brand-kustomize"
missing "contract brand variables are in .brandenv.example" "$T/contract-brand" "$T/brandenv"
missing ".brandenv.example variables are in the contract" "$T/brandenv" "$T/contract-brand"
missing "contract brand variables are in brand.env" "$T/contract-brand" "$T/brand-kustomize"

# Removed settings must not come back.
if grep -nE '^\s*(ENABLED_MODULES|MFA_ENFORCEMENT|SMS_[A-Z_]+|JOBS_ENABLED|BRANDING_DIR|MAIL_TRANSPORT|APP_URL|ORGANIZATION_[A-Z_]+)\b' \
    dev/docker-compose.yml dev/.env.example dev/.brandenv.example k8s/overlays/prod/app.env k8s/overlays/prod/brand.env; then
  echo "FAIL removed variables are still set"; failed=1
else echo "ok   no removed variables"; fi
exit "$failed"
