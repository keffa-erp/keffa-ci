#!/usr/bin/env bash
# usage: scripts/local-ci.sh IMAGE REPO_PATH [SITE_APPS]
#
# Runs a Keffa app's CI test steps inside a keffa-ci image the way a GitHub `container:` job
# does: the workspace under /__w, HOME=/github/home, the image user, every step a `docker exec`.
#
#   IMAGE      a keffa-ci image, e.g. keffa-ci:version-16
#   REPO_PATH  the app's repository; its committed HEAD is tested (like actions/checkout).
#              Its .github/workflows/ci.yml env block gives APP, DEPS, SOFT_APPS and SOFT_AXES.
#   SITE_APPS  the upstream apps of the test site, e.g. "erpnext hrms" (default: DEPS's bare
#              names, plus SOFT_APPS's when erpnext is among them: the job's own side).
#
# Keffa apps named in DEPS (and in SOFT_APPS on the erpnext side) are taken from the sibling
# checkouts next to REPO_PATH (../<repo>), mounted read-only, never fetched.
# Steps: checkout, services, get-app, Keffa deps, unit tests, site, install, assets, site tests
# (one module per run-tests call, 180 s each), uninstall and reinstall, .github/ci-extra.sh.
# Prints each step's time; the full output goes to $LOGS (default ${TMPDIR:-/tmp}/keffa-ci-logs).
set -uo pipefail

image=${1:?usage: scripts/local-ci.sh IMAGE REPO_PATH [SITE_APPS]}
repo_path=$(cd "${2:?usage: scripts/local-ci.sh IMAGE REPO_PATH [SITE_APPS]}" && pwd)
repo=$(basename "$repo_path")
workflow=$repo_path/.github/workflows/ci.yml
bench=/home/frappe/frappe-bench

ci_env() { sed -nE "s/^  $1: \"?([^\"]*)\"?\s*$/\1/p" "$workflow" | head -1; }
APP=$(ci_env APP)
DEPS=$(ci_env DEPS)
SOFT_APPS=$(ci_env SOFT_APPS)
SOFT_AXES=$(ci_env SOFT_AXES)
[ -n "$APP" ] || {
	echo "no APP in $workflow" >&2
	exit 2
}

bare_names() { for dep in "$@"; do case $dep in *=*) ;; *) echo "$dep" ;; esac; done; }
# shellcheck disable=SC2086  # word splitting of the space-separated lists is intended
if [ $# -ge 3 ]; then
	site_apps=$3
else
	site_apps=$(bare_names $DEPS | xargs)
	case " $site_apps " in *" erpnext "*) site_apps=$(echo "$site_apps $(bare_names $SOFT_APPS)" | xargs -n1 | awk '!seen[$0]++' | xargs) ;; esac
fi
with_erpnext=false
case " $site_apps " in *" erpnext "*) with_erpnext=true ;; esac

# Keffa apps to install before this one: DEPS's name=url entries, and SOFT_APPS's on the erpnext side.
keffa_deps=()
# shellcheck disable=SC2086
for dep in $DEPS $([ "$with_erpnext" = true ] && echo $SOFT_APPS); do
	case $dep in *=*) keffa_deps+=("$dep") ;; esac
done

label=$(echo "${image##*:}-${site_apps:-frappe}" | tr ' ' '+')
LOGS=${LOGS:-${TMPDIR:-/tmp}/keffa-ci-logs}
log=$LOGS/local-ci-$repo-$label.log
mkdir -p "$LOGS"
: >"$log"

name=keffa-ci-local-$$
tmp=$(mktemp -d)
# The workspace exists before the job, as on the runner (docker would create --workdir as root).
mkdir -p "$tmp/work/$repo/$repo" "$tmp/home" "$tmp/src"
# The runner's workspace and HOME belong to the job's user (uid 1001, the image user); world-
# writable directories stand in for that here.
chmod 777 "$tmp/work" "$tmp/work/$repo" "$tmp/work/$repo/$repo" "$tmp/home"
# shellcheck disable=SC2329  # run by the EXIT trap
cleanup() {
	docker rm --force "$name" >/dev/null 2>&1
	# Files the container wrote belong to uid 1001: remove them from inside.
	docker run --rm --user 0 --entrypoint rm -v "$tmp:/t" "$image" -rf /t/work /t/home >/dev/null 2>&1
	rm -rf "$tmp"
}
trap cleanup EXIT

# Committed HEADs only, cloned on the host first: the container user (uid 1001) may not be able to
# read a repository's own .git (a repack can leave it owner-only).
src() {
	git clone -q --no-local "$1" "$tmp/src/$2" && chmod -R a+rX "$tmp/src/$2"
}
src "$repo_path" "$repo" || exit 1
mounts=(-v "$tmp/src/$repo:/src/$repo:ro" -v "$tmp/work:/__w" -v "$tmp/home:/github/home")
for dep in "${keffa_deps[@]}"; do
	dep_repo=$(basename "${dep#*=}" .git)
	[ -d "$repo_path/../$dep_repo" ] || {
		echo "Keffa dependency $dep: no checkout at $repo_path/../$dep_repo" >&2
		exit 2
	}
	src "$repo_path/../$dep_repo" "$dep_repo" || exit 1
	mounts+=(-v "$tmp/src/$dep_repo:/src/$dep_repo:ro")
done
flags=()
for axis in $SOFT_AXES; do
	for app in ${axis//,/ }; do
		app=${app#+}
		app=${app%%=*}
		flags+=(-e "WITH_${app^^}=false")
	done
done

failed=0
declare -a summary
record() { summary+=("$(printf '%-34s %6s s  %s' "$1" "$2" "$3")"); }

# step NAME SCRIPT: one `docker exec`, like one workflow step, in the bench directory.
step() {
	local title=$1 script=$2 started=$SECONDS rc
	echo "=== $title" >>"$log"
	docker exec --workdir "$bench" -e "SITE=${SITE:-}" "$name" bash -euo pipefail -c "$script" >>"$log" 2>&1
	rc=$?
	if [ $rc = 0 ]; then record "$title" $((SECONDS - started)) ok; else
		record "$title" $((SECONDS - started)) "FAILED (rc=$rc)"
		failed=1
	fi
	return $rc
}

started=$SECONDS
docker run --detach --name "$name" --entrypoint tail --workdir "/__w/$repo/$repo" \
	-e HOME=/github/home -e CI=true -e GITHUB_ACTIONS=true -e "GITHUB_WORKSPACE=/__w/$repo/$repo" \
	-e "APP=$APP" -e PYTHON_COLORS=0 -e NO_COLOR=1 "${flags[@]}" "${mounts[@]}" \
	"$image" -f /dev/null >>"$log" 2>&1 || {
	echo "docker run failed; see $log" >&2
	exit 1
}
record "container start" $((SECONDS - started)) ok

ws=/__w/$repo/$repo
run() {
	step "checkout" "git clone -q --no-local /src/$repo $ws && git -C $ws log --oneline -1" &&
		step "keffa-ci start" "keffa-ci start" &&
		step "get-app $APP" "timeout 180 bench get-app $APP $ws" || return 1

	local dep dep_name dep_repo names=()
	for dep in "${keffa_deps[@]}"; do
		dep_name=${dep%%=*}
		dep_repo=$(basename "${dep#*=}" .git)
		names+=("$dep_name")
		step "get-app $dep_name" "timeout 180 bench get-app $dep_name /src/$dep_repo" || return 1
	done

	step "unit tests (no site install)" "
		cd $ws
		if [ -d $APP/tests/unit ]; then $bench/env/bin/python -m unittest discover -v -s $APP/tests/unit -t .; else echo no $APP/tests/unit; fi"

	step "keffa-ci site ${site_apps:-(frappe)}" "keffa-ci site $site_apps >/tmp/site && cat /tmp/site" || return 1
	SITE=$(docker exec "$name" cat /tmp/site)

	for dep_name in "${names[@]}"; do
		step "install $dep_name" "timeout 180 bench --site \$SITE install-app $dep_name" || return 1
	done
	step "install $APP" "timeout 180 bench --site \$SITE install-app $APP" || return 1
	step "migrate" "timeout 180 bench --site \$SITE migrate" || return 1
	step "assets (package.json only)" "
		if [ -f apps/$APP/package.json ]; then
			yarn --cwd apps/$APP install --frozen-lockfile
			bench build --app $APP
		else echo no package.json; fi"

	local modules module mstart mrc passed=0 failed_modules=() tests_started=$SECONDS
	if ! modules=$(docker exec --workdir "$ws" "$name" find "$APP" -name 'test_*.py' -not -path '*/tests/unit/*' 2>>"$log" | sort); then
		record "discover site tests" $((SECONDS - tests_started)) "FAILED (see log)"
		return 1
	fi
	for module in $modules; do
		module=${module%.py}
		module=${module//\//.}
		mstart=$SECONDS
		echo "=== run-tests $module" >>"$log"
		docker exec --workdir "$bench" "$name" bash -c \
			"timeout -k 10 180 bench --site \$(cat /tmp/site) run-tests --app $APP --module $module" >"$tmp/test.log" 2>&1
		mrc=$?
		cat "$tmp/test.log" >>"$log"
		# v15's run-tests can exit 0 on a failed run: trust the unittest summary too.
		if [ $mrc = 0 ] && grep -qE '^OK' "$tmp/test.log" && ! grep -qE '^FAILED|^Traceback' "$tmp/test.log"; then
			passed=$((passed + 1))
		else
			[ $mrc = 124 ] && echo "TIMEOUT: $module ran over 180 s" >>"$log"
			failed_modules+=("$module")
		fi
		echo "--- $module: rc=$mrc $((SECONDS - mstart)) s $(grep -E '^Ran' "$tmp/test.log")" >>"$log"
	done
	local count
	count=$(echo "$modules" | grep -c . || true)
	if [ ${#failed_modules[@]} = 0 ]; then
		record "site tests ($count modules)" $((SECONDS - tests_started)) "ok ($passed passed)"
	else
		record "site tests ($count modules)" $((SECONDS - tests_started)) "FAILED: ${failed_modules[*]}"
		failed=1
	fi

	step "uninstall, check, reinstall" "
		timeout 180 bench --site \$SITE uninstall-app $APP --yes --no-backup --force
		if bench --site \$SITE list-apps | grep -qw $APP; then echo '$APP still installed'; exit 1; fi
		timeout 180 bench --site \$SITE install-app $APP"

	step ".github/ci-extra.sh" "
		if [ -f $ws/.github/ci-extra.sh ]; then bash -e $ws/.github/ci-extra.sh; else echo none; fi"
}
run || failed=1

total=$((SECONDS - started))
{
	echo "local-ci $repo ($APP) on $image, site apps: ${site_apps:-frappe only}${keffa_deps[*]:+, Keffa deps: ${keffa_deps[*]%%=*}}"
	printf '%s\n' "${summary[@]}"
	printf '%-34s %6s s  %s\n' "total" "$total" "$([ $failed = 0 ] && echo PASSED || echo FAILED)"
	echo "log: $log"
} | tee -a "$log"
exit $failed
