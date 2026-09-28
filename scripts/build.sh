#!/usr/bin/env bash
# usage: scripts/build.sh LINE [docker buildx build options...]
#   LINE: version-15, version-16 or develop. Builds keffa-ci:LINE (or $IMAGE:LINE) locally:
#   resolves the upstream commits (git ls-remote), builds, then adds the version labels in a
#   second, cached pass. Uses the buildx builder $BUILDER (default: "default", the local docker
#   engine), never pushes.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/lines.sh
. "$here/scripts/lines.sh"

line=${1:?usage: scripts/build.sh LINE [docker buildx build options...]}
shift
python=$(line_python "$line") || {
	echo "unknown line $line (one of: $LINES)" >&2
	exit 2
}
node=$(line_node "$line")
image=${IMAGE:-keffa-ci}:$line

args=(
	--builder "${BUILDER:-default}"
	--platform linux/amd64
	--build-arg "LINE=$line"
	--build-arg "PYTHON_VERSION=$python"
	--build-arg "NODE_VERSION=$node"
	--build-arg "BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
)
for app in $UPSTREAM_APPS; do
	commit=$(upstream_commit "$app" "$line")
	echo "$app $line $commit"
	args+=(--build-arg "${app^^}_COMMIT=$commit")
done

started=$SECONDS
docker buildx build "${args[@]}" --tag "$image" "$@" "$here"
echo "built $image in $((SECONDS - started)) s"

labels=()
while IFS= read -r label; do labels+=(--label "$label"); done < <("$here/scripts/version-labels.sh" "$image")
docker buildx build "${args[@]}" "${labels[@]}" --tag "$image" --quiet "$@" "$here" >/dev/null
docker image inspect "$image" --format '{{.Size}}' | awk -v i="$image" '{printf "%s: %.2f GB\n", i, $1 / 1e9}'
