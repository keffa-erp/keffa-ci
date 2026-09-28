#!/usr/bin/env bash
# usage: scripts/plan.sh
# Plans the build jobs of .github/workflows/build.yml. Reads:
#   EVENT   the triggering event (schedule skips a line whose published image is current)
#   LINES   the lines to consider (default: all of scripts/lines.sh)
#   IMAGE   the published image, e.g. ghcr.io/keffa-erp/keffa-ci
# Prints `matrix=<json>` and `count=<n>` for $GITHUB_OUTPUT. One row per line to build, with its
# Python, Node and the exact upstream commits (resolved once here, so every job of a run and
# the labels agree).
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/lines.sh
. "$here/scripts/lines.sh"

event=${EVENT:-push}
lines=${LINES_INPUT:-$LINES}
image=${IMAGE:-}

# The commit labels of the published LINE image, as "app=commit" lines (empty when none).
published_commits() {
	[ -n "$image" ] || return 0
	docker buildx imagetools inspect "$image:$1" --format '{{json .Image}}' 2>/dev/null |
		jq -r 'if has("config") then . else (.["linux/amd64"] // {}) end
			| .config.Labels // {} | to_entries[]
			| select(.key | test("^et\\.keffa\\.ci\\.[a-z]+\\.commit$"))
			| "\(.key | split(".")[3])=\(.value)"' |
		sort || true
}

rows=()
for line in $lines; do
	python=$(line_python "$line") || {
		echo "unknown line $line" >&2
		exit 2
	}
	row=$(jq -nc --arg line "$line" --arg python "$python" --arg node "$(line_node "$line")" \
		'{line: $line, python: $python, node: $node}')
	wanted=""
	for app in $UPSTREAM_APPS; do
		commit=$(upstream_commit "$app" "$line")
		row=$(jq -c --arg app "$app" --arg commit "$commit" '. + {($app): $commit}' <<<"$row")
		wanted+="$app=$commit"$'\n'
	done
	if [ "$event" = schedule ] && [ "$(sort <<<"${wanted%$'\n'}")" = "$(published_commits "$line")" ]; then
		echo "$line: the published image has these commits already; skipping" >&2
		continue
	fi
	echo "$line: build $(tr '\n' ' ' <<<"$wanted")" >&2
	rows+=("$row")
done

echo "matrix=$(printf '%s\n' "${rows[@]}" | jq -sc '{include: .}')"
echo "count=${#rows[@]}"
