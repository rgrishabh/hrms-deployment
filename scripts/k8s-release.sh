#!/usr/bin/env bash
# Pins a release in a client's overlay: both image digests and the release id that names its Jobs.
# Commit the result to the client's repository; Argo CD does the rest.
#   scripts/k8s-release.sh <overlay-dir> <backend-digest> <frontend-digest> <release-id>
#   release-id: lower case letters, digits and dots only, for example 1.2.0 or abc1234
set -euo pipefail
DIR=${1:?usage: k8s-release.sh <overlay-dir> <backend-digest> <frontend-digest> <release-id>}
BACKEND=${2:?backend digest required}; FRONTEND=${3:?frontend digest required}; RELEASE=${4:?release id required}
for d in "$BACKEND" "$FRONTEND"; do
  [[ "$d" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "error: '$d' is not a sha256 digest" >&2; exit 1; }
  [ "$d" != "sha256:$(printf '0%.0s' {1..64})" ] || { echo "error: placeholder digest" >&2; exit 1; }
done
[[ "$RELEASE" =~ ^[a-z0-9][a-z0-9.]{0,30}$ ]] || { echo "error: release id must match [a-z0-9.], at most 31 characters" >&2; exit 1; }
cd "$DIR"
# Edited in place: `kustomize edit` would rewrite the file and drop its comments, including the tier note.
set_digest() { # image digest
  awk -v image="$1" -v digest="$2" '
    $0 ~ "name: " image "$" { print; found = 1; next }
    found && /digest:/ { sub(/sha256:[0-9a-f]+/, digest); found = 0 }
    { print }' kustomization.yaml > kustomization.yaml.new
  mv kustomization.yaml.new kustomization.yaml
  grep -q "$2" kustomization.yaml || { echo "error: $1 not found under images:" >&2; exit 1; }
}
set_digest ghcr.io/rgrishabh/hrms-backend "$BACKEND"
set_digest ghcr.io/rgrishabh/hrms-frontend "$FRONTEND"
printf 'RELEASE=%s\n' "$RELEASE" > release.env
kustomize build . > /dev/null
echo "pinned release $RELEASE in $DIR"
