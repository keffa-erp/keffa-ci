# keffa-ci: a ready Frappe bench for CI jobs, one image per Frappe line.
#
# Frappe, ERPNext, HRMS and Payments on the line's branch, their Python and Node dependencies
# (with the dev ones), MariaDB and Redis, and three migrated test sites baked into the MariaDB
# datadir. `keffa-ci start` brings the services up in a second or two.
#
# Build it with scripts/build.sh LINE: it resolves the exact upstream commits and passes the
# arguments below. The GitHub workflow (.github/workflows/build.yml) does the same.
#   version-15: PYTHON_VERSION=3.11 NODE_VERSION=18
#   version-16 and develop: PYTHON_VERSION=3.14 NODE_VERSION=24

ARG PYTHON_VERSION=3.14
ARG NODE_VERSION=24
ARG DEBIAN_RELEASE=bookworm

FROM node:${NODE_VERSION}-${DEBIAN_RELEASE}-slim AS node

FROM python:${PYTHON_VERSION}-slim-${DEBIAN_RELEASE}

ARG DEBIAN_RELEASE
ARG WKHTMLTOPDF_VERSION=0.12.6.1-3
ARG BENCH_VERSION=

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never \
    KEFFA_CI_BENCH=/home/frappe/frappe-bench

# System packages. The list follows frappe_docker's images and Frappe's own CI setup:
# a compiler and the MariaDB headers (mysqlclient builds from source on v16+), MariaDB 10.11
# (Debian bookworm; every line supports 10.6 to 11.8), Redis, git, and the pango libraries for
# PDF rendering. Then wkhtmltopdf with patched Qt, from its own release (as frappe_docker does).
# The package downloads stay in BuildKit cache mounts, out of the image and shared by the lines.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        file \
        git \
        less \
        libffi-dev \
        libharfbuzz0b \
        libmariadb-dev \
        libpango-1.0-0 \
        libpangocairo-1.0-0 \
        libpangoft2-1.0-0 \
        mariadb-client \
        mariadb-server \
        media-types \
        pkg-config \
        redis-server \
        tini \
        xz-utils \
    && rm -rf /var/lib/mysql/* /var/log/mysql/* \
    # A CI image: git may work in any checkout, whoever owns it (a mounted repository, the
    # GitHub workspace).
    && git config --system --add safe.directory '*' \
    && git config --system advice.detachedHead false \
    && git config --system init.defaultBranch main

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    curl -fsSL --retry 5 --retry-all-errors --connect-timeout 20 -o /tmp/wkhtmltox.deb \
        "https://github.com/wkhtmltopdf/packaging/releases/download/${WKHTMLTOPDF_VERSION}/wkhtmltox_${WKHTMLTOPDF_VERSION}.${DEBIAN_RELEASE}_amd64.deb" \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends /tmp/wkhtmltox.deb \
    && rm -f /tmp/wkhtmltox.deb

# Node and npm from the official image, then yarn 1 (what bench and Frappe use).
COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN --mount=type=cache,target=/root/.npm \
    ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
    && ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx \
    && npm install --global --no-fund --no-audit yarn@1

# The image user is frappe with uid 1001, the uid of GitHub's hosted runner user: under a
# `container:` job the workspace, HOME (/github/home) and the runner's command files belong to
# 1001, so actions/checkout and every step work without root. Root works too: keffa-ci drops
# to frappe for the services, and bench drops to frappe_user.
# The bench CLI lives in its own venv, with uv (which bench uses to install apps).
RUN --mount=type=cache,target=/root/.cache/pip \
    groupadd --gid 1001 frappe \
    && useradd --uid 1001 --gid 1001 --create-home --shell /bin/bash frappe \
    && python -m venv /opt/bench \
    && /opt/bench/bin/pip install "frappe-bench${BENCH_VERSION:+==${BENCH_VERSION}}" \
    && ln -s /opt/bench/bin/bench /opt/bench/bin/uv /usr/local/bin/ \
    && mkdir -p /run/mysqld /var/lib/mysql /var/log/keffa-ci /etc/keffa-ci \
    && chown frappe:frappe /run/mysqld /var/lib/mysql /var/log/keffa-ci /etc/keffa-ci

COPY rootfs/etc/mysql/mariadb.conf.d/99-keffa-ci.cnf /etc/mysql/mariadb.conf.d/99-keffa-ci.cnf
COPY rootfs/usr/local/lib/keffa-ci/get-app /usr/local/lib/keffa-ci/get-app

USER frappe
WORKDIR /home/frappe

# One layer per upstream app, most stable first, so a new hrms commit rebuilds only the hrms
# layer and the sites. Each ARG is declared just before the layer that uses it.
ARG LINE=version-16
ARG FRAPPE_COMMIT=
RUN --mount=type=cache,target=/home/frappe/.cache,uid=1001,gid=1001,sharing=locked \
    /usr/local/lib/keffa-ci/get-app frappe "$LINE" "$FRAPPE_COMMIT"

ARG ERPNEXT_COMMIT=
RUN --mount=type=cache,target=/home/frappe/.cache,uid=1001,gid=1001,sharing=locked \
    /usr/local/lib/keffa-ci/get-app erpnext "$LINE" "$ERPNEXT_COMMIT"

ARG PAYMENTS_COMMIT=
RUN --mount=type=cache,target=/home/frappe/.cache,uid=1001,gid=1001,sharing=locked \
    /usr/local/lib/keffa-ci/get-app payments "$LINE" "$PAYMENTS_COMMIT"

# hrms's postinstall installs its PWA and roster front ends (about 740 MB of node_modules),
# which only hrms's own asset build needs.
ARG HRMS_COMMIT=
RUN --mount=type=cache,target=/home/frappe/.cache,uid=1001,gid=1001,sharing=locked \
    YARN_IGNORE_SCRIPTS=true /usr/local/lib/keffa-ci/get-app hrms "$LINE" "$HRMS_COMMIT" \
    && cd "$KEFFA_CI_BENCH" \
    && bench setup requirements --dev

# The test sites, baked into the MariaDB datadir (a plain directory of the image, not a volume,
# so the data ships with it).
COPY --chown=frappe:frappe rootfs/usr/local/lib/keffa-ci/bake /usr/local/lib/keffa-ci/bake
COPY --chown=frappe:frappe rootfs/usr/local/bin/keffa-ci /usr/local/bin/keffa-ci
RUN /usr/local/lib/keffa-ci/bake "$LINE"

WORKDIR /home/frappe/frappe-bench
EXPOSE 8000 9000

ARG SOURCE=https://github.com/keffa-erp/keffa-ci
ARG BUILD_DATE=
LABEL org.opencontainers.image.title="keffa-ci" \
      org.opencontainers.image.description="A ready Frappe bench with ERPNext, HRMS and Payments, migrated test sites, MariaDB and Redis, for CI jobs" \
      org.opencontainers.image.source="${SOURCE}" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.vendor="Keffa ERP" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.version="${LINE}" \
      et.keffa.ci.line="${LINE}" \
      et.keffa.ci.frappe.commit="${FRAPPE_COMMIT}" \
      et.keffa.ci.erpnext.commit="${ERPNEXT_COMMIT}" \
      et.keffa.ci.hrms.commit="${HRMS_COMMIT}" \
      et.keffa.ci.payments.commit="${PAYMENTS_COMMIT}"

# `docker run IMAGE CMD` starts the services, then runs CMD. A GitHub `container:` job replaces
# the entrypoint, so its first step runs `keffa-ci start`.
ENTRYPOINT ["tini", "--", "keffa-ci", "run"]
CMD ["bash"]
