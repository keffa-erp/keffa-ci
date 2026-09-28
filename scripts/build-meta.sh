#!/usr/bin/env bash
# GitHub build outputs: a moving line tag and a separate tag for each run and retry.
set -euo pipefail
: "${IMAGE:?IMAGE is required}" "${LINE:?LINE is required}"
: "${GITHUB_RUN_ID:?GITHUB_RUN_ID is required}" "${GITHUB_RUN_ATTEMPT:?GITHUB_RUN_ATTEMPT is required}"

echo "created=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "tags<<EOF"
echo "$IMAGE:$LINE"
echo "$IMAGE:$LINE-run-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT"
echo "EOF"
