# shellcheck shell=bash
# The Frappe lines keffa-ci builds, and their Python and Node. Sourced by the other scripts.

# shellcheck disable=SC2034  # used by the scripts that source this file
LINES="version-15 version-16 develop"
# Upstream apps, in the order the image installs them (all from github.com/frappe, on the line's branch).
# shellcheck disable=SC2034
UPSTREAM_APPS="frappe erpnext payments hrms"

line_python() {
	case $1 in
	version-15) echo 3.11 ;;
	version-16 | develop) echo 3.14 ;;
	*) return 1 ;;
	esac
}

line_node() {
	case $1 in
	version-15) echo 18 ;;
	version-16 | develop) echo 24 ;;
	*) return 1 ;;
	esac
}

# The commit at the tip of an upstream app's branch: anonymous ls-remote, or the REST API when
# git over HTTPS to github.com is not answering.
upstream_commit() {
	local commit="" try
	for try in 1 2 3; do
		commit=$(timeout 60 git ls-remote "https://github.com/frappe/$1" "refs/heads/$2" | cut -f1) || true
		[ -n "$commit" ] && break
		echo "ls-remote frappe/$1 failed (try $try)" >&2
		commit=$(curl -fsS --max-time 30 -H "Accept: application/vnd.github.sha" \
			"https://api.github.com/repos/frappe/$1/commits/$2" 2>/dev/null) || true
		[ -n "$commit" ] && break
	done
	if [ -z "$commit" ]; then
		echo "no branch $2 in frappe/$1" >&2
		return 1
	fi
	echo "$commit"
}
