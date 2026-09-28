#!/usr/bin/env bash
# The steps are scripts that run inside the image: their single quotes are deliberate.
# shellcheck disable=SC2016
# usage: scripts/smoke-test.sh IMAGE
# Checks a built image before it is pushed: the services start, every baked site lists its
# apps, a migrate is a no-op, `keffa-ci site` picks and extends sites, a tiny generated app
# installs and uninstalls, and one short Frappe test module passes. Prints each step's time.
set -euo pipefail
image=${1:?usage: scripts/smoke-test.sh IMAGE}
name=keffa-ci-smoke-$$
bench=/home/frappe/frappe-bench

docker run --detach --name "$name" "$image" sleep infinity >/dev/null
trap 'docker rm --force "$name" >/dev/null' EXIT

in_image() { docker exec --workdir "$bench" "$name" bash -euo pipefail -c "$1"; }
step() {
	local started=$SECONDS
	echo "::group::$1"
	in_image "$2"
	echo "::endgroup::"
	echo "ok $1 ($((SECONDS - started)) s)"
}

step "services" 'keffa-ci start'
step "info" 'keffa-ci info'

sites=$(in_image "python3 -c 'import json; print(*json.load(open(\"/etc/keffa-ci/info.json\"))[\"sites\"])'")
for site in $sites; do
	step "list-apps $site" "
		bench --site $site list-apps --format json | python3 -c '
import json, sys
info = json.load(open(\"/etc/keffa-ci/info.json\"))
got = json.load(sys.stdin)[\"$site\"]
print(\"$site:\", *got)
assert sorted(got) == sorted([\"frappe\", *info[\"sites\"][\"$site\"]]), got
'"
done

# The largest site, with every app: nothing to migrate, so this is fast and changes nothing.
step "no-op migrate" 'timeout 600 bench --site erpnext-payments-hrms.localhost migrate'

step "site selection" '
	test "$(keffa-ci site)" = frappe.localhost
	test "$(keffa-ci site frappe erpnext hrms)" = erpnext-hrms.localhost
	test "$(keffa-ci site hrms erpnext payments)" = erpnext-payments-hrms.localhost
	if keffa-ci site no_such_app 2>/dev/null; then exit 1; fi'

step "tiny app: install and uninstall" '
	app=/tmp/smoke_app
	mkdir -p $app/smoke_app/smoke_app
	cat >$app/pyproject.toml <<EOF
[project]
name = "smoke_app"
authors = [{ name = "keffa-ci" }]
description = "keffa-ci smoke test"
requires-python = ">=3.10"
dynamic = ["version"]

[build-system]
requires = ["flit_core >=3.4,<4"]
build-backend = "flit_core.buildapi"
EOF
	echo "__version__ = \"0.0.1\"" >$app/smoke_app/__init__.py
	printf "%s\n" "app_name = \"smoke_app\"" "app_title = \"Smoke App\"" "app_publisher = \"keffa-ci\"" \
		"app_description = \"keffa-ci smoke test\"" "app_email = \"ci@example.com\"" "app_license = \"MIT\"" \
		>$app/smoke_app/hooks.py
	echo "Smoke App" >$app/smoke_app/modules.txt
	: >$app/smoke_app/patches.txt
	: >$app/smoke_app/smoke_app/__init__.py
	git -C $app init -q
	git -C $app add -A
	git -C $app -c user.name=keffa-ci -c user.email=ci@example.com commit -qm smoke
	bench get-app smoke_app $app
	timeout 180 bench --site frappe.localhost install-app smoke_app
	bench --site frappe.localhost list-apps | grep -qw smoke_app
	timeout 180 bench --site frappe.localhost uninstall-app smoke_app --yes --no-backup --force
	if bench --site frappe.localhost list-apps | grep -qw smoke_app; then exit 1; fi'

step "frappe test module" '
	timeout 180 bench --site frappe.localhost run-tests --module frappe.tests.test_formatter 2>&1 | tee /tmp/test.log
	grep -qE "^OK" /tmp/test.log'

echo "smoke test passed: $image"
