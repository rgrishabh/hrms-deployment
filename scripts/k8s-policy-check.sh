#!/usr/bin/env bash
# Runs the Kyverno policies offline against a built tier, and proves they block known-bad workloads.
#   scripts/k8s-policy-check.sh [build-dir]    needs the kyverno CLI, and k8s-build-all.sh output
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BUILD=${1:-$ROOT/k8s/build}
POL=$ROOT/k8s/policies/kyverno
status=0
for tier in low mid high; do
  # The summary line decides, not the exit code, which older CLI versions leave at 0 on failures.
  out=$(kyverno apply "$POL" --resource "$BUILD/tier-$tier.yaml" 2>&1)
  summary=$(echo "$out" | grep -E '^pass: [0-9]+' | tail -1)
  if echo "$summary" | grep -Eq '^pass: [1-9][0-9]*, fail: 0, warn: 0, error: 0'; then
    echo "tier-$tier: $summary"
  else
    echo "$out" | tail -30; echo "tier-$tier: FAILS ($summary)"; status=1
  fi
done
out=$(kyverno apply "$POL" --resource "$ROOT/k8s/policies/tests/bad-workloads.yaml" 2>&1)
for name in uses-latest runs-as-root no-limits; do
  if echo "$out" | grep -q "$name"; then echo "blocked: $name"; else echo "NOT blocked: $name"; status=1; fi
done
exit "$status"
