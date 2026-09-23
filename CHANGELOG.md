# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [2.0.0.15] - 2026-09-23

### Changed
- Updated the bundled alphaclaw from 0.9.90 to 0.9.92: the gateway's boot startup is tracked and automatic lease recovery preserved (0.9.91), and OpenClaw's state-path identity is preserved on symlinked installs such as this image's `/root/.openclaw -> /data/.openclaw` (0.9.92). No runtime changes for the template: the Node `>=24.16.0 <25 || >=26.1.0` gate, the exact OpenClaw 2026.9.5 pin and the `node:24-slim` base are unchanged.

## [2.0.0.14] - 2026-09-23

### Changed
- Bumped the baked `@anthropic-ai/claude-code` pin from 2.1.252 to 2.1.281 (npm `latest` as of 2026-09-23). Rebuilds the pinned claude-code layer and the bounded app `npm install` below it; no other image change.

## [2.0.0.13] - 2026-09-23

### Changed
- Updated the bundled alphaclaw from 0.9.88 to 0.9.90, picking up two upstream releases: live-tier drift fixes on the OpenClaw 2026.9.5 pin (narrowed backup veto, upgrade round-trip gate, return-to-pin activation, vanished-entry backups, medic failure detail; 0.9.89) and the consolidated live-bug reliability wave (auth store, cron run store, medic admission, backup readiness/progress; 0.9.90). No runtime changes for the template: the Node `>=24.16.0 <25 || >=26.1.0` gate, the exact OpenClaw 2026.9.5 pin and the `node:24-slim` base are unchanged.

## [2.0.0.12] - 2026-09-22

### Changed
- Updated the bundled alphaclaw from 0.9.87 to 0.9.88, which moves its exact OpenClaw pin from 2026.9.3 to 2026.9.5 and ships the three compatibility fixes the new OpenClaw needs (owner lease, schema versions, codex migration runtime). No runtime changes for the template: the Node `>=24.16.0 <25 || >=26.1.0` gate and the `node:24-slim` base are unchanged.

### Fixed
- `tests/e2e/stale-config.bats` now seeds `/data` into a Docker **named volume** (ext4, like Render's disk) instead of a macOS host bind mount. OpenClaw 2026.9.5 snapshots its state database under `/data/.cache/openclaw` for shared-state discovery and treats a failed snapshot cleanup as fatal (gateway exit 78); on Docker Desktop's file-shared bind mount that cleanup fails with `ERR_SQLITE_ERROR` (unreliable cross-process SQLite locks) while alphaclaw reads the same database, so the suite failed locally for a reason Render cannot hit. The identical image boots to `[gateway] ready` on a named volume, on a direct gateway run, and on Render's ext4 disk. `docker-compose.yml` already used a named volume, so local `npm run dev` was never affected.

## [2.0.0.11] - 2026-09-21

### Changed
- Updated the bundled alphaclaw from 0.9.86 to 0.9.87: backups are preflighted before an upgrade takes the gateway down, with a preflight card in the Upgrade tab. No runtime changes for the template: the Node `>=24.16.0 <25 || >=26.1.0` gate, the exact OpenClaw 2026.9.3 pin and the `node:24-slim` base are unchanged.

## [2.0.0.10] - 2026-09-20

### Changed
- Updated the bundled alphaclaw from 0.9.85 to 0.9.86: backups stay reliable around oversized scratch directories — a backup policy with inventory, retention, verification and fallback, editable from the Upgrade tab. No runtime changes for the template: the Node `>=24.16.0 <25 || >=26.1.0` gate, the exact OpenClaw 2026.9.3 pin and the `node:24-slim` base are unchanged.

## [2.0.0.9] - 2026-09-15

### Changed
- Updated the bundled alphaclaw from 0.9.84 to 0.9.85: intent and recovery are preserved across the reliability flows — managed update attempts, watchdog crash recovery, update repair, Gmail watch lifecycle and Google disconnect are now explicit, ledgered operations. No runtime changes for the template: the Node `>=24.16.0 <25 || >=26.1.0` gate, the exact OpenClaw 2026.9.3 pin and the `node:24-slim` base are unchanged.

## [2.0.0.8] - 2026-09-14

### Changed
- Updated the bundled alphaclaw from 0.9.83 to 0.9.84: the watchdog no longer raises false readiness incidents, and the upgrade overseer no longer pages after a recovery; doctor gains advisory findings. No runtime changes for the template: the Node `>=24.16.0 <25 || >=26.1.0` gate, the exact OpenClaw 2026.9.3 pin and the `node:24-slim` base are unchanged.

## [2.0.0.7] - 2026-09-10

### Changed
- Updated the bundled alphaclaw from 0.9.82 to 0.9.83: the OpenClaw Control UI is now served at `/openclaw` for real — a basePath mount, a verbatim proxy, and no more "Styles failed to load". No runtime changes for the template: the Node `>=24.16.0 <25 || >=26.1.0` gate, the exact OpenClaw 2026.9.3 pin and the `node:24-slim` base are unchanged.

## [2.0.0.6] - 2026-09-09

### Changed
- Updated the bundled alphaclaw from 0.9.81 to 0.9.82: accurate gateway memory reporting — per-process attribution (PSS-based), container-level memory monitoring and alerts, a memory-details view in the Watchdog tab, and a doctor card for container memory. No runtime changes for the template: the Node `>=24.16.0 <25 || >=26.1.0` gate, the exact OpenClaw 2026.9.3 pin and the `node:24-slim` base are unchanged.

## [2.0.0.5] - 2026-09-08

### Changed
- Updated the bundled alphaclaw from 0.9.80 to 0.9.81: Upgrade tab fixes — live release catalog, declared apply intent, a bounded backup rung, and a "Back up now" action. No runtime changes for the template: the Node `>=24.16.0 <25 || >=26.1.0` gate, the exact OpenClaw 2026.9.3 pin and the `node:24-slim` base are unchanged.

## [2.0.0.4] - 2026-09-07

### Changed
- Migrated the image runtime from `node:22-slim` to `node:24-slim` (all three node stages: `pins`, `tools`, and the final image). Required by the new alphaclaw pin: alphaclaw 0.9.80 and its exactly-pinned OpenClaw 2026.9.3 both gate installs on Node `>=24.16.0 <25 || >=26.1.0` (enforced by OpenClaw's preinstall check, which fails the Docker build loudly on an old base). `package.json` `engines` now mirrors that range, CI runs unit/contract on Node 24, and the contract greps lock the `node:24-slim` stages in.
- Updated the bundled alphaclaw from 0.9.77 to 0.9.80, picking up three upstream releases: the live-tier downgrade re-stamp (0.9.78), hardened upgrade recovery / chat delivery / status reporting (0.9.79), and the Node 24.16 runtime + OpenClaw 2026.9.3 pin (0.9.80).

## [2.0.0.3] - 2026-09-06

### Added
- Baked a fixed toolset into the image so operators and the agent no longer hand-install it into the ephemeral container layer after every deploy: Caddy 2.11.4 (GitHub release tarball, SHA-512 verified against the upstream `checksums.txt`), Tailscale 1.102.3 `tailscale` + `tailscaled` (pkgs.tailscale.com static tarball, SHA-256 verified against the `.sha256` sidecar), Bun 1.4.2 `bun` + `bunx` (GitHub release zip, SHA-256 verified against `SHASUMS256.txt`), monolith 2.10.1 built from source at git rev `47affd5f9070eb01a94045ce31923e577f9a9162` with `cargo install --locked` in a digest-pinned `rust:1.98.0-slim-bookworm` stage (the upstream aarch64 prebuilt links `libssl1.1`, which bookworm lacks), PostgreSQL client 17 (`psql`, `pg_dump`, `pg_restore` from the signed PGDG apt repo, key verified by fingerprint `B97B0AFCAA1A47F044F244A07FCC7D46ACCC4CF8`; installs to `/usr/lib/postgresql/17/bin` with the Debian `pg_wrapper` layout; no server package), `git-lfs`, `jq`, plus the support packages `ca-certificates`, `openssl`, `util-linux` (`flock`) and `psmisc` (`fuser`). Nothing is started: the image launches no `tailscaled` or `caddy`, opens no new port, and a fresh deploy reaches the setup UI exactly as before.
- New `baked-tools.env` pin manifest at the repo root — the single source of versions, checksums, `MONOLITH_REV` and `PG_MAJOR` for every build stage, shipped verbatim in the image at `/etc/baked-tools.env` so a live box can `cat` its exact pins.
- New tests. `tests/contract/tools.bats` (runs in `npm test`) statically locks in the manifest format and that every pin is referenced, the `pins`/`tools`/`monolith-build` stages and the load-bearing layer order, the no-`ARG` rule, downloads == checksum checks, the PGDG fingerprint/`signed-by`/client-only/purge-`gpg` discipline, a no-daemon guard over the Dockerfile and `start.sh` (with positive and negative controls), the `EXPOSE`/`CMD`/`COPY`-source surface, the `.dockerignore` allowlist, CI `timeout-minutes`, and `AGENTS.md == CLAUDE.md`. `tests/e2e/tools.bats` (runs in `npm run test:e2e`) checks every baked binary offline with `docker run --network none` (version == pin, `ldd` shared-library resolution, arch consistency, PATH/shim precedence), proves the checksum gate fails the build on a mutated manifest, boots the image credential-free and asserts `/health` 200 with no `tailscaled`/`caddy`/`monolith` process and no tool port listening, boots against a reused `/data` volume, asserts prompt shutdown, and exercises the tools functionally (a `git lfs` commit lands an object in `.git/lfs/objects`, `caddy validate`, `jq`, `openssl`, `flock`).

### Changed
- `.dockerignore` is now an allowlist: `*` followed by a `!` line for each Dockerfile `COPY` source (plus `debug-start.sh` for the documented debug detour). Nothing unlisted can enter the build context, and a future `COPY` of an unlisted file fails the build loudly (contract-tested against the Dockerfile's actual `COPY` sources).
- The new apt/PGDG layer sits directly below the original apt line and above both npm layers, so alphaclaw pin bumps never re-fetch apt indexes or move the PostgreSQL minor; the pinned claude-code install and the app `npm install` are unchanged.
- `git lfs install --system` runs at build time: the LFS filter lives in `/etc/gitconfig` and is inert for any repo whose `.gitattributes` has no `filter=lfs` entries (alphaclaw's workspace repo has none).
- CI jobs gained `timeout-minutes` (20 for unit + contract, 60 for docker e2e) so a stalled download or build is bounded instead of running to GitHub's cap.
- Converted the latent no-op bare `!` assertions in `tests/e2e/stale-config.bats` and `tests/e2e/supervise-e2e.bats` to enforcing `run` + status checks, capturing `docker logs`/`docker exec` output into a variable first so the nested `run grep` cannot clobber `$output` (closes the `TODOS.md` P1 item ledgered in 2.0.0.2).
- Image size grows by about 236 MB: 1,375,861,315 → 1,611,978,214 bytes (+17%), measured on linux/amd64 with Docker 25 — inside the +300 MB soft budget over the 2.0.0.2 image (see the README's maintenance policy).
- Updated the bundled alphaclaw from 0.9.56 to 0.9.76 (pin 3f9b27b → 01d3b66), which landed on main as six pin-bump commits after 2.0.0.2 (0.9.66, 0.9.67, 0.9.68, 0.9.69, 0.9.75, 0.9.76); OpenClaw moves to the 2026.9.2 stable line. This release was built and e2e-tested against 01d3b66.

### Security
- Pins live in a plain file (`baked-tools.env`), never Dockerfile `ARG`: Render turns every service env var into a `--build-arg`, so an `ARG` default would be a dashboard-overridable pin.
- Every download is checksum-verified before it is unpacked (`sha512sum -c` / `sha256sum -c`, always as the last pipeline stage because dash has no `pipefail`), and every apt source is signed — the PGDG key must contain exactly one primary key with the pinned fingerprint before apt ever sees it. Any upstream change fails the build by design and is bumped deliberately.
- The image starts no daemon, opens no new port, adds no cron job, and requires no credentials to reach the setup UI; installing a tool does not enable it.
- Build tooling (`unzip`, `gpg`, the Rust toolchain) never lands in the runtime image: downloads and the monolith compile happen in throwaway stages, and `gpg` is purged (`apt-get purge --auto-remove`) in the same `RUN` once the PGDG client package is installed, so it never reaches a committed layer.

## [2.0.0.2] - 2026-09-01

### Changed
- Tightened the default `ORPHAN_SWEEP_PATTERN` from `openclaw[^ ]* gateway` to `(^|[ /])openclaw[^ ]* gateway run( |$)`: the post-exit orphan sweep matches full process argv, and rescue panes are exactly where operators type commands mentioning the gateway mid-incident — the old pattern could kill the operator's own debugging commands. Both real gateway argv shapes stay matched (contract-tested, including rescue-pane argv that merely mentions the gateway).
- Pinned the global `@anthropic-ai/claude-code` install to an exact version (2.1.252) so image rebuilds can no longer silently float it to latest — the same deliberate-bump discipline as the alphaclaw SHA pin (contract-tested). Hardened test enforcement along the way: converted silent no-op `! command` assertions (exempt from bats errexit when non-final) to enforcing `run` + status checks across the contract suites and the Docker e2e suite (the remaining e2e occurrences are ledgered in `TODOS.md`), including the public-page secret-leak check's intermediate responses, and made the supervise harness leak-free (stub and decoy processes now forward TERM to their children).

### Added
- Install `tmux` in the image so alphaclaw's local Claude Code rescue sessions (shipped in 2.0.0.1) use tmux hosting and survive alphaclaw restarts, instead of the degraded `script(1)` hosting that dies with the process ("tmux is not installed — sessions use script(1) hosting and die with AlphaClaw"). Sessions still end on a full container restart/redeploy — tmux servers are in-memory by nature. Guarded at three layers: contract tests pin `tmux` in the apt line (image and CI) and prove the default `ORPHAN_SWEEP_PATTERN` cannot match a rescue session's typical tmux argv (payload argv that itself contains "openclaw … gateway", and runtime pattern overrides, remain a documented accepted risk), a supervise-harness test proves a tmux session (same pane PID) survives an exit-75 supervisor relaunch while a sweep-tagged decoy dies, and the Docker e2e executes `tmux -V` inside the built image. CI installs tmux explicitly so the survival test can never silently skip.

## [2.0.0.1] - 2026-08-31

### Changed
- Updated the bundled alphaclaw from 0.9.49 to 0.9.56, picking up seven upstream releases: chat reliability rework (protocol v2 bridge, durable run outcomes, resumable streams), gateway memory-leak detection with opt-in pre-OOM auto-restart, one-click authenticated OpenClaw dashboards (appears once the bundled OpenClaw is upgraded to 2026.8.1+ from the Upgrade tab — this release still pins OpenClaw 2026.7.1-2), local Claude Code rescue sessions, Drift Doctor delivery fixes, actionable error messages, and a verbose notification toggle.
