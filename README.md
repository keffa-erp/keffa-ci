# keffa-ci

[![Build](https://github.com/keffa-erp/keffa-ci/actions/workflows/build.yml/badge.svg)](https://github.com/keffa-erp/keffa-ci/actions/workflows/build.yml)

A container image for testing Frappe apps in CI: a ready bench with Frappe, ERPNext, HRMS and
Payments, three migrated test sites, MariaDB and Redis, one image per Frappe line. A job starts the
container, runs `keffa-ci start`, and has a working bench and sites in seconds, with no Python,
Node, bench, app or site setup of its own.

Every Keffa ERP app's CI uses it as its test base, and anyone testing a Frappe app can use it too.
It is public, MIT-licensed, and not affiliated with or endorsed by Frappe Technologies.

## Contents

- [Why](#why)
- [Tags](#tags)
- [What's inside](#whats-inside)
- [Sites and passwords](#sites-and-passwords)
- [Using it in a GitHub workflow](#using-it-in-a-github-workflow)
- [Using it with docker run](#using-it-with-docker-run)
- [The keffa-ci command](#the-keffa-ci-command)
- [Users and permissions](#users-and-permissions)
- [How it is built](#how-it-is-built)
- [Testing an app locally the way CI does](#testing-an-app-locally-the-way-ci-does)
- [License](#license)

## Why

A Frappe app's test job usually spends most of its time getting ready: setup-python, setup-node,
apt packages, `pip install frappe-bench`, `bench init`, `bench get-app` for every dependency,
`bench setup requirements`, then a site with ERPNext and HRMS installed. Measured for the Keffa
apps (their CI before this image):

| Step | Before (per job) | With keffa-ci |
|---|---|---|
| Python, Node, apt packages, bench CLI | about 1 min | none (in the image) |
| Bench with Frappe, ERPNext, HRMS, Payments | about 8 min on a cache miss; a restore on a hit | none (in the image) |
| Site with the upstream apps | about 200 s to install, or about 40 s from a cached snapshot | none (baked; `keffa-ci start` takes 0-2 s) |
| Whole job for the template app (Frappe-only / ERPNext site) | several minutes before any test | 26-34 s / 31-76 s, tests included |

The image itself is about 3 GB (see [How it is built](#how-it-is-built)); GitHub's hosted runners
pull it in well under a minute.

## Tags

`ghcr.io/keffa-erp/keffa-ci:<tag>`, amd64 only:

| Tag | Moves | Example |
|---|---|---|
| `<line>` | on every rebuild | `version-16` |
| `<line>-<YYYYMMDD>` | never (the build of that day) | `version-16-20260928` |
| `<line>-<frappe commit, 12 chars>` | never (the Frappe commit it holds) | `version-16-012667b9c4e7` |

The lines, with the Python and Node Frappe's own CI uses for each:

| Line | Frappe, ERPNext, HRMS, Payments branch | Python | Node | MariaDB | Redis |
|---|---|---|---|---|---|
| `version-15` | `version-15` | 3.11 | 18 | 10.11 | 7.0 |
| `version-16` | `version-16` | 3.14 | 24 | 10.11 | 7.0 |
| `develop` | `develop` | 3.14 | 24 | 10.11 | 7.0 |

Pin a dated tag when a job must not change under you; use the line tag to follow upstream.

## What's inside

- Debian bookworm (the official `python:<version>-slim-bookworm` image), with a compiler and the
  MariaDB headers (for Python packages that build from source), git, and wkhtmltopdf 0.12.6.1 with
  patched Qt.
- Node from the official Node image, with yarn 1.
- MariaDB 10.11 (Debian's), configured for throwaway test data: utf8mb4 with
  `utf8mb4_unicode_ci` and no client charset handshake (what Frappe requires), no binary log, no
  flush on commit, no doublewrite buffer. Listening on 127.0.0.1:3306 only.
- Two Redis servers on 127.0.0.1: cache on 13000, queue (and socket.io) on 11000.
- The bench CLI (`frappe-bench`, with `uv`) in its own venv, on `PATH`.
- A bench at `/home/frappe/frappe-bench` with `frappe`, `erpnext`, `payments` and `hrms` cloned
  shallow on the line's branch at the commits the image's labels name, their Python dependencies
  including the dev ones (`bench setup requirements --dev`), and Frappe's `node_modules`, so
  `bench build --app <your app>` works. Core assets are not built (tests do not need them), and
  HRMS's front-end `node_modules` are left out (only HRMS's own asset build needs them).
- The test sites below, baked into the MariaDB datadir (a plain directory of the image, not a
  volume, so the data ships with the image).
- `keffa-ci`, the helper command.

`keffa-ci info` prints the exact commits and versions. The image labels carry them too:
`et.keffa.ci.<app>.commit` and `et.keffa.ci.<app>.version` for frappe, erpnext, hrms and
payments, `et.keffa.ci.{python,node,mariadb,redis,bench,wkhtmltopdf,debian}.version`,
`et.keffa.ci.line`, and the standard `org.opencontainers.image.*` ones.

## Sites and passwords

| Site | Apps (in install order) |
|---|---|
| `frappe.localhost` | frappe |
| `erpnext-hrms.localhost` | frappe, erpnext, hrms |
| `erpnext-payments-hrms.localhost` | frappe, erpnext, payments, hrms |

Each is a fresh install (the setup wizard has not run), migrated, with `allow_tests` on.

This is a CI image, so the passwords are fixed and public: **Administrator `admin`**, **MariaDB
root `root`** (`root@localhost` and `root@%`, reachable only from inside the container). The
bench's `common_site_config.json` holds them (`root_login`, `root_password`, `admin_password`),
so `bench new-site`, `install-app`, `restore` and `drop-site` never prompt. Never use the image
for real data.

## Using it in a GitHub workflow

A minimal job for any Frappe app (replace `my_app` and the apps its site needs):

```yaml
jobs:
  test:
    runs-on: ubuntu-latest
    container: ghcr.io/keffa-erp/keffa-ci:version-16
    defaults:
      run:
        working-directory: /home/frappe/frappe-bench
    steps:
      - uses: actions/checkout@v6
      - run: keffa-ci start
      - run: bench get-app my_app "$GITHUB_WORKSPACE"
      - run: echo "SITE=$(keffa-ci site erpnext hrms)" >> "$GITHUB_ENV"
      - run: bench --site "$SITE" install-app my_app
      - run: bench --site "$SITE" run-tests --app my_app
```

- A `container:` job replaces the image's entrypoint, so start the services with `keffa-ci start`
  (idempotent) before anything that needs them.
- `keffa-ci site` prints a site name; with an app set no baked site has, it installs the missing
  apps on the closest smaller site first (see below).
- Another app your app needs: `bench get-app <url>` first, then `keffa-ci site <upstream apps>`
  and `bench --site "$SITE" install-app <it>`.
- No `services:`, `setup-python`, `setup-node`, apt packages or caches are needed.

## Using it with docker run

The entrypoint starts the services, then runs the command (default `bash`):

```sh
docker run --rm -it ghcr.io/keffa-erp/keffa-ci:version-16
docker run --rm -v "$PWD:/src/my_app:ro" ghcr.io/keffa-erp/keffa-ci:version-16 bash -c '
  bench get-app my_app /src/my_app &&
  bench --site frappe.localhost install-app my_app &&
  bench --site frappe.localhost run-tests --app my_app'
```

`bench get-app` clones the mounted repository's committed state; git in the image trusts any
checkout's owner (`safe.directory = *`).

## The keffa-ci command

| Command | What it does |
|---|---|
| `keffa-ci start` | Starts MariaDB and both Redis servers in the background and waits until they answer (0-2 s in practice). Does nothing when they already run. |
| `keffa-ci site [APP ...]` | Prints the baked site whose installed apps, besides frappe, are exactly `APP ...` (any order). When none is, it takes the largest site whose apps are a subset, installs the missing ones there (they must be on the bench), and prints that site. Progress goes to stderr, so `SITE=$(keffa-ci site erpnext hrms)` works. |
| `keffa-ci info [--json]` | The line, build date, commits, versions, sites and passwords. |
| `keffa-ci status` | Which services answer (exit 1 when one does not). |
| `keffa-ci stop` | Stops the services. |
| `keffa-ci run [CMD ...]` | Starts the services, then runs `CMD` (the entrypoint). |

Service logs are in `/var/log/keffa-ci/`.

## Users and permissions

The image runs as `frappe`, **uid and gid 1001**, which owns the bench and the MariaDB datadir.
1001 is the uid of the user GitHub's hosted runners run as, and that is the point:

- Under a `container:` job, GitHub mounts the workspace (`/__w`), `HOME` (`/github/home`) and its
  command files (`GITHUB_ENV`, `GITHUB_OUTPUT`) from the runner, owned by uid 1001. As the same
  uid, `actions/checkout`, `>> "$GITHUB_ENV"` and every step work without root and without
  `options: --user`.
- `HOME` is `/github/home` there, not `/home/frappe`. Nothing in the image depends on `HOME`: the
  bench CLI and `uv` are on `PATH` from `/opt/bench`, git's settings are system-wide, and uv's and
  yarn's caches simply start empty in the job's `HOME`.
- Root works too (`docker run --user root`, `options: --user root`, or a self-hosted runner that
  runs jobs as root): `keffa-ci start` runs MariaDB and Redis as `frappe`, and bench drops to
  `frappe_user` (`frappe`, set in `common_site_config.json`) for every command.
- Any other uid cannot write the bench or the datadir; `keffa-ci start` stops with a message
  saying so. Run as 1001 (the default) or root.

## How it is built

- One `Dockerfile`, parameterised by build arguments: `LINE`, `PYTHON_VERSION`, `NODE_VERSION`,
  and the exact commits `FRAPPE_COMMIT`, `ERPNEXT_COMMIT`, `PAYMENTS_COMMIT` and `HRMS_COMMIT`.
  Each upstream app is its own layer, most stable first, so a new HRMS commit rebuilds only the
  HRMS layer and the sites. `rootfs/` holds the MariaDB settings, the build helpers and
  `keffa-ci`.
- `.github/workflows/build.yml` runs on every push to `main`, on demand (`workflow_dispatch`,
  choosing the lines), and daily. A plan job resolves the upstream commits of each line
  (`git ls-remote`); on the daily run it skips a line whose published `<line>` image already has
  those commits in its labels, without building anything. Each line then builds with buildx and
  the GitHub Actions cache, is smoke-tested (`scripts/smoke-test.sh`: services, `list-apps` on
  every site, a no-op migrate, site selection, a generated app installed and uninstalled, and
  one Frappe test module), and only then is pushed with its three tags, in a second, fully cached
  build pass that adds the version labels.
- Locally: `scripts/build.sh <line>` does the same without pushing. It uses the buildx builder
  named `default` (the local engine) unless `BUILDER` says otherwise.

Measured on a local machine (2026-09-28):

| Line | Build from scratch | Of which: baking the three sites (in parallel) | Image size |
|---|---|---|---|
| version-15 | 462 s | 250 s | 2.75 GB |
| version-16 | about 420 s | 237 s | 3.03 GB |
| develop | 371 s | 270 s | 3.20 GB |

A rebuild after an upstream commit reuses every layer above the app that changed.

## Testing an app locally the way CI does

`scripts/local-ci.sh IMAGE REPO_PATH [SITE_APPS]` runs a Keffa app's CI steps inside the image
the way the GitHub job runs them (workspace under `/__w`, `HOME=/github/home`, one `docker exec`
per step): checkout of the committed HEAD, `keffa-ci start`, `get-app`, the site-independent unit
tests, the app's Keffa dependencies (from the sibling checkouts, mounted read-only), `keffa-ci
site`, install and migrate, assets when there is a `package.json`, the site tests one module per
`run-tests` call (180 s each at most), uninstall and reinstall, and `.github/ci-extra.sh`. It
prints each step's time; the full output goes to `$LOGS` (default `${TMPDIR:-/tmp}/keffa-ci-logs`).

```sh
scripts/local-ci.sh keffa-ci:version-16 ../my-app "erpnext hrms"
```

Measured with `scripts/local-ci.sh` (2026-09-28) on the Keffa apps, whole job including tests:

| App (site) | version-15 | version-16 | develop |
|---|---|---|---|
| the app template (Frappe only) | 27 s | 34 s | 26 s |
| the app template (ERPNext + HRMS) | 31 s | 76 s | 34 s |
| an app with 4 site-test modules (Frappe only) | | 56 s | |
| an app with 6 modules (ERPNext + Payments + HRMS) | 101 s | | |
| an app with 11 modules (ERPNext + Payments + HRMS) | | 155 s | |
| an app with 21 modules (ERPNext + HRMS) | 266 s | 275 s | 284 s |

Setup before the first test (checkout, services, get-app, site pick, install) is 10-25 s.

## License

MIT, © 2026 Keffa ERP. See [LICENSE](LICENSE). The image bundles Frappe, ERPNext, HRMS and
Payments (their own licences: MIT for Frappe and Payments, GPL-3.0 for ERPNext and HRMS), MariaDB
(GPL-2.0), Redis and other Debian packages under their own licences. "Frappe", "ERPNext" and
"Frappe HR" are marks of Frappe Technologies; this project is independent of it.
