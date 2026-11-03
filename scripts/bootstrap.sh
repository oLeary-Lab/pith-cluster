#!/bin/bash
# Run from a machine with a kubeconfig for the cluster and GITHUB_TOKEN from an
# account with admin on the repo — bootstrap manages the deploy key and pushes.
# It COMMITS the regenerated clusters/staging/flux-system/ manifests to $BRANCH;
# that commit is the record, and it lands outside PR review.
set -euo pipefail

OWNER="${OWNER:-oLeary-Lab}"
REPOSITORY="${REPOSITORY:-pith-cluster}"
BRANCH="${BRANCH:-main}"
SYNC_PATH="${SYNC_PATH:-./clusters/staging}"
# Pin to the toolkit the cluster runs, so a path fix doesn't also upgrade
# controllers. Unset deliberately to take the CLI's own version.
FLUX_VERSION="${FLUX_VERSION:-v2.8.7}"

: "${GITHUB_TOKEN:?set GITHUB_TOKEN to a token with admin on ${OWNER}/${REPOSITORY}}"

# --path is relative to the repository root. A path relative to the clone's
# parent (./pith-cluster/clusters/staging) commits the manifests to a nested
# directory and then aborts the sync step, leaving gotk-sync.yaml untouched.
first_segment="${SYNC_PATH#./}"
first_segment="${first_segment%%/*}"
if [ "$first_segment" = "$REPOSITORY" ]; then
  echo "SYNC_PATH is relative to the repository root, not its parent: $SYNC_PATH" >&2
  exit 1
fi

echo "==> cluster: $(kubectl config current-context)"
echo "==> repo:    https://github.com/${OWNER}/${REPOSITORY}  ${BRANCH}:${SYNC_PATH}"
echo "==> toolkit: ${FLUX_VERSION}"

# --private=false because the flag defaults to true.
flux bootstrap github \
  --owner="$OWNER" \
  --repository="$REPOSITORY" \
  --branch="$BRANCH" \
  --path="$SYNC_PATH" \
  --private=false \
  --version="$FLUX_VERSION"

echo "==> sources"
flux get sources git -A
echo "==> kustomizations"
flux get kustomizations -A
echo
echo "Pull the bootstrap commit before making further changes:"
echo "  git pull --ff-only origin ${BRANCH}"
