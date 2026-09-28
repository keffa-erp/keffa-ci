#!/usr/bin/env bash
# usage: scripts/version-labels.sh IMAGE
# Prints the OCI labels only a built image knows (the exact Python, Node, MariaDB, Redis, bench
# and app versions), one key=value per line, read from the image's /etc/keffa-ci/info.json.
# scripts/build.sh and the workflow add them in a second, fully cached build pass.
set -euo pipefail
image=$1
docker run --rm --entrypoint cat "$image" /etc/keffa-ci/info.json | jq -r '
	(.versions | to_entries[] | "et.keffa.ci.\(.key).version=\(.value)"),
	(.apps | to_entries[] | "et.keffa.ci.\(.key).version=\(.value.version)"),
	"et.keffa.ci.sites=\(.sites | keys | join(" "))"
'
