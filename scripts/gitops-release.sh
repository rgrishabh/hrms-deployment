#!/usr/bin/env bash
# Pins a release in a client's repository checkout and pushes it. Argo CD in the client's cluster does the
# rest. Used by deploy-prod.yml and rollback-prod.yml.
#   scripts/gitops-release.sh <checkout> <overlay-path> <backend-digest> <frontend-digest> <release-id> <message>
# Prints the commit to go back to, as before=<sha>, into GITHUB_OUTPUT when that is set.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=${1:?checkout}; OVERLAY=${2:?overlay path}; BACKEND=${3:?backend digest}; FRONTEND=${4:?frontend digest}; RELEASE=${5:?release id}; MESSAGE=${6:?message}
before=$(git -C "$REPO" rev-parse HEAD)
"$HERE/k8s-release.sh" "$REPO/$OVERLAY" "$BACKEND" "$FRONTEND" "$RELEASE"
[ -z "${GITHUB_OUTPUT:-}" ] || echo "before=$before" >> "$GITHUB_OUTPUT"
if [ -z "$(git -C "$REPO" status --porcelain -- "$OVERLAY")" ]; then
  echo "overlay already at release $RELEASE"
  exit 0
fi
git -C "$REPO" add -- "$OVERLAY"
git -C "$REPO" -c user.name=hrms-deploy-bot -c user.email=41898282+github-actions[bot]@users.noreply.github.com commit -qm "$MESSAGE"
for i in 1 2 3; do
  git -C "$REPO" push -q origin HEAD:main && { echo "pushed release $RELEASE"; exit 0; }
  git -C "$REPO" pull -q --rebase origin main
  sleep $((i * 3))
done
echo "error: could not push to the client's main branch" >&2
exit 1
