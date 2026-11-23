#!/usr/bin/env bash
# Builds the prod overlay once per tier into <out>/tier-<name>.yaml, by changing the overlay's one
# tier line in a temporary copy. Used by CI and by anyone checking a change locally.
#   scripts/k8s-build-all.sh [out-dir]
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-$ROOT/k8s/build}
mkdir -p "$OUT"
for tier in low mid high; do
  T=$(mktemp -d)
  cp -R "$ROOT/k8s" "$T/k8s"
  rm -rf "$T/k8s/build"
  sed -i.bak -E "s#\.\./\.\./components/tier-[a-z]+#../../components/tier-$tier#" "$T/k8s/overlays/prod/kustomization.yaml"
  grep -q "components/tier-$tier" "$T/k8s/overlays/prod/kustomization.yaml" || { echo "tier line not found" >&2; exit 1; }
  kustomize build "$T/k8s/overlays/prod" > "$OUT/tier-$tier.yaml"
  rm -rf "$T"
  echo "built $OUT/tier-$tier.yaml"
done
