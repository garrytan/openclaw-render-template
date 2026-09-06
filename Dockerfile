# Image build pipeline (keep this diagram in sync with the stages below; see
# CLAUDE.md "Baked tools"):
#
#  baked-tools.env (repo; the single pin source: versions, checksums, MONOLITH_REV, PG_MAJOR)
#       │ COPY                                   │ COPY
#       ▼                                        ▼
#  ┌─ stage pins (node:22-slim) ─────────┐  ┌─ stage tools (node:22-slim) ──────────────────────┐
#  │ /monolith.env = MONOLITH_* lines     │  │ apt: ca-certificates curl unzip (build-only)      │
#  │ /pg.env       = PG_MAJOR line        │  │ . baked-tools.env → arch case → dl() + sha*sum -c │
#  │ (each file changes only when its own │  │  → /out/usr/local/bin/{caddy,tailscale,tailscaled,│
#  │  pins change, so downstream caches   │  │     bun,bunx→bun} ; /out/etc/baked-tools.env       │
#  │  survive unrelated pin bumps)        │  └─────────────────────────┬─────────────────────────┘
#  └──────┬─────────────────┬────────────┘                            │
#         │ /monolith.env   │ /pg.env                                  │
#         ▼                 │                                          │
#  ┌─ stage monolith-build (rust:<pinned digest>) ──┐                  │
#  │ apt: perl make ; cargo install --git Y2Z/monolith│                 │
#  │   --rev $MONOLITH_REV --locked → /opt/monolith  │                  │
#  └──────┬───────────────────────────────────────────┘                 │
#         │                 │                                          │
#  ┌─ final (node:22-slim) ─┼─ layer order is load-bearing ────────────┼──┐
#  │ 1 apt line (git curl … tmux)                UNCHANGED             │  │
#  │ 2 NEW apt/PGDG RUN (reads /pg.env): ca-certificates openssl gpg   │  │
#  │   jq git-lfs psmisc util-linux; PGDG key fingerprint check;       │  │
#  │   postgresql-client-$PG_MAJOR (client only);                      │  │
#  │   purge gpg; git lfs install --system; smoke   (ABOVE npm layers: │  │
#  │   alphaclaw pin bumps never re-fetch apt or move the PG minor)    │  │
#  │ 3 npm -g claude-code@pin                    UNCHANGED             │  │
#  │ 4 COPY package.json; npm install            UNCHANGED             │  │
#  │ 5 shims (/usr/bin, /usr/local/bin symlinks) UNCHANGED             │  │
#  │ 6 NEW COPY --from=tools bins + /etc/baked-tools.env  ◄────────────┼──┘
#  │       COPY --from=monolith-build monolith            ◄────────────┘
#  │   RUN . /etc/baked-tools.env; every tool --version == pin (fails the build)
#  │ 7 COPY start.sh, failure-server.js; ENV PATH/TMPDIR…; mkdir /data/tmp;
#  │   EXPOSE 3000; ENTRYPOINT tini -g; CMD /start.sh   UNCHANGED
#  └──────────────────────────────────────────────────────────────────────┘
#  Nothing in the image or start.sh launches tailscaled/caddy; no new ports, cron, or ENV.
#  Pins are a plain file, never ARG: Render turns every service env var into a
#  --build-arg, so an ARG default would be a dashboard-overridable pin.

# --- stage pins: split the manifest so each consumer's cache key depends only on its own pins
FROM node:22-slim AS pins
COPY baked-tools.env /baked-tools.env
RUN set -eu; \
    grep '^MONOLITH_' /baked-tools.env > /monolith.env; test -s /monolith.env; \
    grep '^PG_MAJOR=' /baked-tools.env > /pg.env; test -s /pg.env

# --- stage tools: download + checksum-verify the static release binaries (build tooling stays here)
FROM node:22-slim AS tools
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl unzip && rm -rf /var/lib/apt/lists/*
COPY baked-tools.env /opt/baked-tools.env
# dash has no pipefail: every pipeline below ends in the command whose failure
# must abort the build (the sha*sum -c), so set -e catches it.
RUN set -eu; \
    . /opt/baked-tools.env; \
    dl() { curl -fsSL --retry 5 --retry-all-errors --retry-max-time 180 --connect-timeout 20 -o "$2" "$1"; }; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) caddy_sha="$CADDY_SHA512_AMD64"; ts_sha="$TAILSCALE_SHA256_AMD64"; bun_arch=x64;     bun_sha="$BUN_SHA256_X64" ;; \
      arm64) caddy_sha="$CADDY_SHA512_ARM64"; ts_sha="$TAILSCALE_SHA256_ARM64"; bun_arch=aarch64; bun_sha="$BUN_SHA256_AARCH64" ;; \
      *) echo "unsupported architecture: $arch" >&2; exit 1 ;; \
    esac; \
    work="$(mktemp -d)"; cd "$work"; \
    mkdir -p /out/usr/local/bin /out/etc; \
    dl "https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/caddy_${CADDY_VERSION}_linux_${arch}.tar.gz" caddy.tgz; \
    echo "${caddy_sha}  caddy.tgz" | sha512sum -c -; \
    tar -xzf caddy.tgz caddy; \
    install -m 0755 caddy /out/usr/local/bin/caddy; \
    dl "https://pkgs.tailscale.com/stable/tailscale_${TAILSCALE_VERSION}_${arch}.tgz" tailscale.tgz; \
    echo "${ts_sha}  tailscale.tgz" | sha256sum -c -; \
    tar -xzf tailscale.tgz --strip-components=1 "tailscale_${TAILSCALE_VERSION}_${arch}/tailscale" "tailscale_${TAILSCALE_VERSION}_${arch}/tailscaled"; \
    install -m 0755 tailscale /out/usr/local/bin/tailscale; \
    install -m 0755 tailscaled /out/usr/local/bin/tailscaled; \
    dl "https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}/bun-linux-${bun_arch}.zip" bun.zip; \
    echo "${bun_sha}  bun.zip" | sha256sum -c -; \
    unzip -q bun.zip; \
    install -m 0755 "bun-linux-${bun_arch}/bun" /out/usr/local/bin/bun; \
    ln -s bun /out/usr/local/bin/bunx; \
    install -m 0644 /opt/baked-tools.env /out/etc/baked-tools.env; \
    cd /; rm -rf "$work"

# --- stage monolith-build: the upstream aarch64 prebuilt links libssl1.1 (absent from
# bookworm), so monolith is compiled from the pinned git commit on every arch. Default
# features = cli + vendored OpenSSL, so the binary links only glibc/libgcc_s.
FROM rust:1.98.0-slim-bookworm@sha256:1469a27c125cb5a3aebfa4f4e4665d935b02fb72cc093b2c974b3d740e43f157 AS monolith-build
COPY --from=pins /monolith.env /monolith.env
RUN apt-get update && apt-get install -y --no-install-recommends perl make && rm -rf /var/lib/apt/lists/*
RUN set -eu; \
    . /monolith.env; \
    cargo install --git https://github.com/Y2Z/monolith --rev "$MONOLITH_REV" --locked --root /opt/monolith monolith; \
    test "$(/opt/monolith/bin/monolith --version)" = "monolith ${MONOLITH_VERSION}"

# --- final image
FROM node:22-slim

RUN apt-get update && apt-get install -y git curl procps python3 make g++ cron tini vim screen tmux && rm -rf /var/lib/apt/lists/*

# Support packages + the PostgreSQL CLIENT (never the server) from the signed PGDG
# repo. Sits ABOVE the npm layers on purpose: alphaclaw pin bumps are frequent and
# must not re-fetch apt indexes or move the PostgreSQL minor; editing this RUN is
# rare and costs a rebuild of the pinned claude-code layer and the bounded app
# `npm install` (the same trade-off the apt line above already accepts).
# The PGDG key is verified by fingerprint (exactly one primary key, and it must be
# the pinned one) before apt ever sees it. TMPDIR is unset at this point, so the
# scratch dir lands in the build container's ephemeral temp (no literal path here;
# the /data disk does not exist at build time).
COPY --from=pins /pg.env /opt/pg.env
RUN set -eu; \
    . /opt/pg.env; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates openssl gpg jq git-lfs psmisc util-linux; \
    scratch="$(mktemp -d)"; \
    curl -fsSL --retry 5 --retry-all-errors --retry-max-time 180 --connect-timeout 20 -o "$scratch/pgdg.asc" https://www.postgresql.org/media/keys/ACCC4CF8.asc; \
    listing="$(GNUPGHOME="$scratch" gpg --batch --show-keys --with-colons "$scratch/pgdg.asc")"; \
    test "$(printf '%s\n' "$listing" | awk -F: '$1=="pub"' | wc -l)" -eq 1; \
    test "$(printf '%s\n' "$listing" | awk -F: '$1=="fpr"{print $10; exit}')" = "B97B0AFCAA1A47F044F244A07FCC7D46ACCC4CF8"; \
    install -D -m 0644 "$scratch/pgdg.asc" /usr/share/keyrings/postgresql-archive-keyring.asc; \
    . /etc/os-release; \
    echo "deb [signed-by=/usr/share/keyrings/postgresql-archive-keyring.asc] https://apt.postgresql.org/pub/repos/apt ${VERSION_CODENAME}-pgdg main" > /etc/apt/sources.list.d/pgdg.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends "postgresql-client-${PG_MAJOR}"; \
    apt-get purge -y --auto-remove gpg; \
    rm -rf /var/lib/apt/lists/* "$scratch" /opt/pg.env; \
    git lfs install --system --skip-repo; \
    psql --version | grep -qF "(PostgreSQL) ${PG_MAJOR}."; \
    pg_dump --version | grep -qF "(PostgreSQL) ${PG_MAJOR}."; \
    pg_restore --version | grep -qF "(PostgreSQL) ${PG_MAJOR}."; \
    test -x "/usr/lib/postgresql/${PG_MAJOR}/bin/psql"; \
    jq --version; git lfs version; flock --version; fuser -V; openssl version; \
    test -s /etc/ssl/certs/ca-certificates.crt

# Pinned exactly, same discipline as the alphaclaw SHA pin: an unpinned
# install floats to latest whenever an earlier layer changes, silently
# shipping an unreviewed claude-code. Bump deliberately and record it.
RUN npm install -g @anthropic-ai/claude-code@2.1.252 && npm cache clean --force

WORKDIR /app

COPY package.json ./
RUN npm install --omit=dev --prefer-online && npm cache clean --force

RUN printf '#!/bin/sh\nexec /app/node_modules/.bin/openclaw "$@"\n' > /usr/bin/openclaw \
 && printf '#!/bin/sh\nexec /app/node_modules/.bin/alphaclaw "$@"\n' > /usr/bin/alphaclaw \
 && printf '#!/bin/sh\nexec /usr/local/bin/claude "$@"\n' > /usr/bin/claude \
 && chmod +x /usr/bin/openclaw /usr/bin/alphaclaw /usr/bin/claude \
 && ln -sf /app/node_modules/.bin/openclaw /usr/local/bin/openclaw \
 && ln -sf /app/node_modules/.bin/alphaclaw /usr/local/bin/alphaclaw \
 && /usr/bin/openclaw --version \
 && /usr/bin/claude --version

# Baked static tools land BELOW the npm layers (a tool bump never re-resolves app
# deps) and ABOVE the script COPYs (a start.sh hotfix never re-downloads tools).
# The smoke compares every binary against the shipped manifest so a mismatch
# fails the build. tailscaled is only checked for presence here: it is a daemon
# and the image must never invoke it (its --version is exercised by the e2e suite).
COPY --from=tools /out/usr/local/bin/ /usr/local/bin/
COPY --from=tools /out/etc/baked-tools.env /etc/baked-tools.env
COPY --from=monolith-build /opt/monolith/bin/monolith /usr/local/bin/monolith
RUN set -eu; \
    . /etc/baked-tools.env; \
    test "$(caddy version | cut -d' ' -f1)" = "v${CADDY_VERSION}"; \
    test "$(tailscale version | head -n1)" = "${TAILSCALE_VERSION}"; \
    test -x /usr/local/bin/tailscaled; \
    test "$(bun --version)" = "${BUN_VERSION}"; \
    test "$(bunx --version)" = "${BUN_VERSION}"; \
    test "$(monolith --version)" = "monolith ${MONOLITH_VERSION}"

COPY start.sh /start.sh
COPY failure-server.js /failure-server.js
RUN chmod +x /start.sh

ENV PATH="/app/node_modules/.bin:$PATH"
ENV ALPHACLAW_ROOT_DIR=/data

# Route temp onto the persistent disk instead of the container's ephemeral /tmp.
# OpenClaw is migrating hardcoded /tmp callsites to TMPDIR-aware APIs; any code
# that respects the standard temp env vars will land under /data/tmp.
# NOTE: /data is a runtime-mounted disk, so this build-time mkdir is shadowed at
# runtime — start.sh recreates /data/tmp on boot. Kept here for image self-consistency.
ENV TMPDIR=/data/tmp
ENV TEMP=/data/tmp
ENV TMP=/data/tmp

RUN mkdir -p /data/tmp && chmod 1777 /data/tmp

EXPOSE 3000

# -g: tini signals the ENTIRE process group, so a TERM to PID 1 reaches
# alphaclaw, tee, and any backoff sleep directly from the kernel. This is what
# lets start.sh's supervise loop stay a plain foreground loop with no trap /
# job-control machinery — bash's default TERM disposition is fine because no
# process depends on bash forwarding anything.
ENTRYPOINT ["/usr/bin/tini", "-g", "--"]
CMD ["/start.sh"]
