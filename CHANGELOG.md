# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [2.0.0.37] - 2026-10-27

### Changed
- Updated the bundled alphaclaw from 0.10.144 to 0.10.145 (`6d7908191959b2a7ab6f47c7c200a67b9a6af052`), which moves the exact OpenClaw pin from 2026.10.7 to **2026.10.8**. There is no schema migration (state 20, agent 25 unchanged), and 2026.10.7 boots on state written by 2026.10.8, so rolling back is a plain pin revert.

## [2.0.0.36] - 2026-10-26

### Changed
- The image's baked Bun (`/usr/local/bin/{bun,bunx}`) moves from 1.4.2 to 1.4.4, the version Wintermute's gbrain processes run (1.4.4 fixes the #7644 memory leak). Each redeploy had been putting the box's servers that use the image's bun back on 1.4.2.

## [2.0.0.35] - 2026-10-26

### Changed
- Updated the bundled alphaclaw from 0.10.140 to 0.10.144 (`25f6ecc15ffb157a4a24308690800dc57e5357f4`). 0.10.141: the hourly sync cron.d job now carries TMPDIR, TMP and TEMP, so its scratch files land on the disk instead of the container's /tmp. 0.10.142: a model check (Models tab, `POST /api/models/check`) tests each configured model ref, and a `model_not_found` failure now tells the owner which model failed, what the provider answered, and the fix. 0.10.143: OpenClaw's file log moves from /tmp/openclaw to <root>/logs/openclaw on the disk. 0.10.144: the deploy-shutdown ask reserves time for OpenClaw to close slow-exiting stdio MCP servers, so they no longer push the shutdown into SIGKILL. OpenClaw stays at 2026.10.7.
- `start.sh` writes TMPDIR, TEMP and TMP (`/data/tmp`) to `/etc/environment` at boot, so every root crontab job gets them through pam_env too.

## [2.0.0.34] - 2026-10-26

### Changed
- Updated the bundled alphaclaw from 0.10.139 to 0.10.140 (`430157e822af3a1e0006a0616edace3c62ccd3f2`): on a platform SIGTERM, AlphaClaw asks OpenClaw for a drain sized to the time left in `ALPHACLAW_SHUTDOWN_GRACE_SECONDS` (default 25 s, inside Render's default 30 s shutdown delay) and SIGKILLs the gateway only at that deadline, instead of a fixed 6 s slice. OpenClaw stays at 2026.10.7.

## [2.0.0.33] - 2026-10-26

### Changed
- Updated the bundled alphaclaw from 0.10.137 to 0.10.139 (`fae0a5b4f388fc41cac0c5470942d1dbca6a8b7e`): restart history (20 boots or 14 days) with each boot's cause, including unclean exits such as a platform instance replacement (0.10.138), and the boot's Codex migration and plugin reconciliation run once per OpenClaw build instead of on every boot, with a redacted summary of their diagnostics (0.10.139). OpenClaw stays at 2026.10.7.

## [2.0.0.32] - 2026-10-26

### Changed
- Updated the bundled alphaclaw from 0.10.136 to 0.10.137 (`6a08099e44496d9f6987a5cbdbfc43cf5498afb8`): after a predecessor gateway was SIGKILLed in another container, the watchdog relaunches when OpenClaw's ownership heartbeat lapses (about 90 s) instead of waiting out the 300 s lease, and the boot shows a `lock_wait` step instead of failing. This ships with 2.0.0.31's graceful-stop fix: the first deploy replaces a container whose old start.sh still SIGKILLs the gateway, so the new container must be the one that handles the stale heartbeat. OpenClaw stays at 2026.10.7.

## [2.0.0.31] - 2026-10-26

### Fixed
- **Graceful shutdown on deploy.** `start.sh` now traps TERM/INT, forwards the signal to the running child (alphaclaw, the failure server or a backoff sleep), waits for it and exits with its code. The child runs under `setsid` in its own process group, so it gets exactly one TERM: `tini -g` already signals `start.sh`'s group, and a second TERM makes alphaclaw abandon its drain and SIGKILL the gateway. Before, bash died on the TERM that `tini -g` sends the whole group, tini exited with it, and the container ended before alphaclaw's graceful exit ran: no SIGTERM notice, no `/data/deploy-history.json` record (so no measured downtime on the next boot) and no gateway drain. The tee writing `/data/start.log` ignores TERM/INT so the last lines land, and gets 3 s to drain after the child exits so a descendant holding the output can't keep the container alive. `tini -g` is unchanged.

### Tests
- `supervise.bats`: a group TERM (what `tini -g` sends) reaches alphaclaw exactly once, TERM is forwarded and waited for, the exit code passes through, TERM during a backoff exits at once, and a lingering output holder can't block exit (all four fail on the old script). `scripts.bats` pins the trap wiring. New `tests/e2e/graceful-stop.bats` boots the image with a live gateway: SIGKILLed gateway and alphaclaw still recover inside the container, `docker stop -t 30` runs alphaclaw's shutdown (log lines, deploy-history record, a gateway stop that finishes without the hard kill), and the next boot measures the downtime.

## [2.0.0.30] - 2026-10-26

### Changed
- Updated the bundled alphaclaw from 0.10.134 to 0.10.136 (`95edebe279765f53c9cf963beba8e888886b0b54`): one-key env PATCH with a delete count in the PUT confirm (0.10.135), and the alphaclaw-admin skill split into a short index plus one reference file per domain (0.10.136). OpenClaw stays at 2026.10.7; no template runtime changes.

## [2.0.0.29] - 2026-10-26

### Changed
- Updated the bundled alphaclaw from 0.10.112 to 0.10.134 (`aca7e6643bab3ab3e928c2498776e463ee759493`): read-only box status views (processes, restart, schedules, disk, MCP) and the Watchdog Box card, honoring the operator box lock, operator sidecars, deploy announcements with measured downtime, an agent downtime note after outages, copy retention for backups and update captures, single-document `--json` CLI output, consistent agent git rules with a writer set, and git sync fixes for a symlinked state dir. OpenClaw stays at 2026.10.7; no template runtime changes.

## [2.0.0.28] - 2026-10-25

### Changed
- Updated the bundled alphaclaw from 0.10.110 to 0.10.112 (`ba9f2bc7eb80265a00119c608733ba6c3765635e`): `ALPHACLAW_GIT_SYNC=off` turns AlphaClaw's git sync off for a repository another writer owns (0.10.111), and the abandoned OpenClaw SQLite snapshot sweep now also runs every 30 minutes while the gateway runs (0.10.112). OpenClaw stays at 2026.10.7; no template runtime changes.

## [2.0.0.27] - 2026-10-25

### Changed
- Updated the bundled alphaclaw from 0.10.75 to 0.10.110 (`1ff3c8581f8110e36606e73099d9114c4b0e2e24`), bringing OpenClaw 2026.10.7. Highlights for this deploy: orphaned OpenClaw read-only SQLite copies are swept before each gateway launch (#245), a free-disk alert and disk-full notices (#247, #250), and the git-sync and watchdog fixes since 0.10.75. No template runtime changes: the Node `>=24.22.1 <25 || >=26.12.1` gate and the `node:24-slim` base are unchanged.

## [2.0.0.26] - 2026-10-23

### Changed
- Updated the bundled alphaclaw from 0.10.68 to 0.10.75 (`b6405c1e02a17c56e2398503f6633d28350e6b10`), the ALPH-22 memory-watchdog series written against the critique the deployed agent produced on a 100 GB host. `leak_critical` now judges a leak rather than load: on the verified gateway worker, held for three consecutive fresh evaluations, it needs a positive RSS slope, a real floor (worker private memory at 90% of the budget or the V8 heap at 70% of its limit) and a heap signal, so a burst of real work with many tool children stays a warning (0.10.71). With no operator budget the budget is 75% of min(container limit, host MemTotal) instead of configured heap + 192 MiB, which on that host moves it from 8.4 GB to 76.8 GB (0.10.72). An automatic memory restart needs a `restartAuthority` (heap at 85% of its V8 limit, the worker itself filling the container at 90%, or the operator's own budget); critical alone records one `mitigation_skipped` per episode and leaves the gateway alone (0.10.73). Notifications collapse to one message per episode tier after a five-minute hold, with a combined "spiked and recovered" message and a cleared follow-up, and the brake notice no longer advises a manual restart (0.10.74). The PSS sampler keeps its cached sample when the rescue session reads Resources without naming the gateway, which had been restarting collection every other tick (0.10.75). 0.10.69–0.10.70 are test-only. No runtime changes for the template: OpenClaw stays pinned at exactly 2026.10.6; the Node `>=24.22.1 <25 || >=26.12.1` gate and the `node:24-slim` base are unchanged.

## [2.0.0.25] - 2026-10-22

### Changed
- Updated the bundled alphaclaw from 0.10.7 to 0.10.68 (`2269d88afa15401045f3898b5099241d32e1c873`), 61 upstream releases. The one that touches the runtime contract is 0.10.48, which moves the exact OpenClaw pin from 2026.10.4 to **2026.10.6** (the stability patch for the 2026.10.5 line: recovery for held agent/system-agent databases after schema-changing upgrades, frozen startup owners) and raises the Node floor to `>=24.22.1 <25 || >=26.12.1` because 2026.10.6 requires the October 2026 Node security releases and exits 1 on anything older; alphaclaw's new `preinstall` check (0.10.12) refuses to install on such a runtime. The pin's agent schema moves 24 → 25 (state stays 20) and the upgrade is one-way: 2026.10.4 refuses the migrated state, so rolling back means restoring the pre-upgrade backup. The rest of the range: the ALPH-17/19 restart series (routine restarts let OpenClaw finish active work for up to 3 minutes with a Restart now override, every restart names its source and reason, a tool child can no longer make the gateway look like it is leaking, a post-relaunch wedge sweep resumes or alerts on stuck sessions, interrupted exec turns are resumed or reported to the owner, a cold restart always relaunches); the Control UI at `/openclaw` connects on every hostname instead of only the boot-time origin (0.10.14, which was breaking Render custom domains) and a signed-in admin can open it directly (0.10.15); team access enables again on OpenClaw 2026.10 (0.10.64) and a team transition no longer cuts off the running turn (0.10.66); constant-time secret comparisons everywhere (0.10.18); container memory pressure judged on the cgroup working set rather than page cache (0.10.19); GPT-6 under Codex OAuth and Claude 5.5 defaults in the model catalog (0.10.10); the installed-vs-pinned OpenClaw visible on status, General and Doctor (0.10.27); honest boot status with real stages and times (0.10.8); and the ALPH-15 refactor series (0.10.21–0.10.47, no behavior changes beyond the overseer dropping its "rollback" offer).
- `package.json` `engines.node` moves with the pin to `>=24.22.1 <25 || >=26.12.1`. The `node:24-slim` base already resolves to 24.22.1, so the image clears the new floor without a Dockerfile change; the base-image contract test's comment names the new gate.
- CI: `actions/setup-node` sets `check-latest: true` so the unit/contract job resolves the newest 24.x instead of a runner-cached Node that can sit below the floor the template now declares.

## [2.0.0.24] - 2026-10-16

### Changed
- Updated the bundled alphaclaw from 0.10.5 to 0.10.7 (`a297ae4941f10acd373e35dc6edfdd3f741c56b5`), which moves its exact OpenClaw pin from 2026.10.2 to **2026.10.4** (Doctor data-preservation fixes, gateway ownership that survives sleep and clock jumps, bounded shutdown waits; state schemas unchanged at `{ state: 20, agent: 24 }`). 0.10.6 fixes alphaclaw #144, which hits this image directly: OpenClaw 2026.10's atomic file writer refuses a parent directory that is a symlink, so on a symlinked state directory every `doctor --fix` and CLI config write failed with "Atomic replace parent must be a real directory", and since every pin bump reruns Doctor on boot, each 2026.10.x deploy started with a failed migration. alphaclaw now resolves only `OPENCLAW_CONFIG_PATH` to the symlink's target while `OPENCLAW_STATE_DIR` stays lexical. It also stops booking a slow gateway boot as an incident, records every Doctor run's outcome, and remembers deterministic boot-Doctor failures for 24 h instead of re-running them. 0.10.7 gives the data upgrade a home on the dashboard: an alert under the Gateway card while the installed pin's `doctor --fix` is unfinished, a Retry upgrade action that runs Doctor between stop and relaunch without restarting alphaclaw, an Enable snapshots action (`chmod +t` on exactly the directories OpenClaw's pre-repair snapshot check refuses), and a redacted Doctor transcript. No runtime changes for the template: the Node `>=24.16.0 <25 || >=26.1.0` gate and the `node:24-slim` base are unchanged.

## [2.0.0.23] - 2026-10-13

### Changed
- Updated the bundled alphaclaw from 0.10.4 to 0.10.5 (`3d980c1bd7e51d9ab20a73fa423ae091584150f2`), which moves its exact OpenClaw pin from 2026.9.8 to **2026.10.2** (2026.9.9 and 2026.10.1 shipped in between). 2026.10.1 moves the state database to schema 20; upstream notes that going back to 2026.9.x means restoring a verified backup, never reinstall-and-boot. 0.10.5 carries the compatibility fixes the new pin needs: the agent roster is written in 2026.10's canonical shape (keyed `agents.entries`, no `default` markers, explicit ownership past one agent — on 2026.10 the old shape left a config the gateway refuses with exit 78 on the next start), the shared auth store accepts schema 20 (otherwise every credential read was `AUTH_STORE_UNREADABLE`), `/readyz` phases are read as 2026.x actually reports them, the cross-container owner-lease refusal classifies as `owner_lease_held` instead of a crash loop, the gateway daemon launches with `OPENCLAW_DEBUG=1` so crash reasons are visible again, pairing/approvals/chat during warm-up return retryable 503s, and model prices come from OpenClaw's plugin manifests (86 priced models). The `openclaw` operator wrapper now exports the supervisor contract, so `openclaw update` from a shell refuses to replace the pinned package. No runtime changes for the template: the Node `>=24.16.0 <25 || >=26.1.0` gate and the `node:24-slim` base are unchanged, and nothing in the image, `start.sh` or the test suites names an OpenClaw version.

## [2.0.0.22] - 2026-10-12

### Changed
- Updated the bundled alphaclaw from 0.10.3 to 0.10.4 (`b54801ecb776cbe1b6ad9cd30c6caef231348341`), part 2 of alphaclaw issue #140: the dashboard's git-sync surfaces move onto the 0.10.3 engine. The General tab's Sync button and the models/Telegram/webhook settings saves now run `alphaclaw git-sync --json` through a server-side runner (shared writer lock, scoped commits, merge-tree integration, status file) instead of their own `add -A` / commit / push in the live tree, with the engine's sentence as the warning text and 409 + next step on a refusal. The scheduled sync moves off the `:00` minute to a per-install minute derived from a sha256 of the repo and managed path (1–59, never a quarter hour), labelled in the schedule presets; a stored schedule is never rewritten. The repo card shows last-run status from `.alphaclaw/git-sync-status.json` (redacted: code, headline, times, failure count, files behind GitHub). No runtime changes for the template: OpenClaw stays pinned at exactly 2026.9.8; the Node `>=24.16.0 <25 || >=26.1.0` gate and the `node:24-slim` base are unchanged.
- Tests: the `orphan sweep TERMs stragglers` supervise-harness stub now waits until its tagged orphan is visible to `pgrep -f` before exiting. Between fork and exec the child still carries the stub's argv, so on a slow CI runner the supervisor's sweep could run inside that window, find nothing, and the test failed without any change to `start.sh`.

## [2.0.0.21] - 2026-10-12

### Changed
- Updated the bundled alphaclaw from 0.10.2 to 0.10.3 (`577695a2e2912777e96cffea0998e971c22aa0c0`): `alphaclaw git-sync` now cooperates with other writers on the box (alphaclaw issue #140). Every sync holds an exclusive `flock` on `<git common dir>/alphaclaw-writer.lock` from preflight to the final fast-forward (120 s wait when scheduled, 15 s otherwise; a timeout exits 75 and names the holder), commits only paths with working-tree changes instead of `add -A`, and integrates with `merge-tree` + `commit-tree` pushed to origin followed by an `--ff-only` of the live tree, so there is no pull, rebase or stash in the live tree and another writer's staged-only entries stay staged. Refusals are loud: each run writes `.alphaclaw/git-sync-status.json`, failure episodes become one notification plus a `git_sync_refused` watchdog event, and Doctor shows episode-scoped cards. The hourly script now runs `git-sync --trigger scheduled` only (its own `git restore` of `cron/jobs.json` raced the gateway's writes). The image already ships `flock` from `util-linux`, so the lock is live from this deploy. OpenClaw stays pinned at exactly 2026.9.8; the Node `>=24.16.0 <25 || >=26.1.0` gate and the `node:24-slim` base are unchanged.

## [2.0.0.20] - 2026-10-11

### Changed
- Updated the bundled alphaclaw from 0.10.0 to 0.10.2 (`bf728c3d3373b5bf46b3a91ee047ac1d0f38efe6`), the two follow-ups to the 0.10.0 restart ladder. 0.10.1 fixes restarts ending in `stop_failed` while the gateway was already down (alphaclaw bug #137): process liveness is now read from `/proc/<pid>/stat` so a zombie counts as gone instead of a survivor, the graceful `openclaw gateway restart --wait` ask is skipped with a logged reason when it cannot work (no `lsof`, `OPENCLAW_NO_RESPAWN` pinned, no worker, no budget) instead of failing in milliseconds, a `/proc`-backed `lsof` shim is appended to the ask's PATH only (never the gateway's) where the binary is missing, the ladder records kill-set evidence (admin sessions only, behind the Watchdog tab's "Restart evidence" disclosure), and a failed restart hands the watchdog a note so recovery rechecks at 0/5/15/30/60 s instead of waiting for three 120 s health misses. 0.10.2 links the pieces: the restart-required banner no longer clears itself on a fresh unrecovered failed restart, the card says what brought the gateway back and whether the operator's changes are live, `gateway_down` incidents opened after a failed restart carry `cause: restart_<code>`, `doctor --fix` logs a heartbeat every 30 s, and the operation record keeps a bounded step timeline. OpenClaw stays pinned at exactly 2026.9.8; the Node `>=24.16.0 <25 || >=26.1.0` gate and the `node:24-slim` base are unchanged.
- Dockerfile: the runtime apt layer now installs `lsof`. The pinned OpenClaw CLI locates the gateway listener through it, so without it the graceful restart ask refuses ("No verified gateway process is listening") and every restart goes straight to SIGTERM; alphaclaw's shim covers the gap, but upstream's reference image ships the real binary and that is what its restart ladder is tested against. New contract test `Dockerfile: installs lsof` pins the decision the same way the tmux test does.

## [2.0.0.19] - 2026-10-07

### Changed
- Updated the bundled alphaclaw from 0.9.99 to 0.10.0 (`6bb457575ae2d647eab8f8156eb542b0858d063f`), which rebuilds the gateway restart. On OpenClaw 2026.9.8 every restart with agent work in flight failed the same way: OpenClaw drains a SIGTERMed gateway for up to ~315 s while the port stays open, alphaclaw waited 15 s, both `gateway stop --force` and `gateway --force` are refused on an alphaclaw box, and the managed child it signalled was the compile-cache launcher rather than the gateway. 0.10.0 replaces that with one stop ladder (ask OpenClaw to restart itself with `gateway restart --wait 30000ms`, then SIGTERM the gateway's process group for 10 s, then SIGKILL for 5 s), one `openclaw gateway run` launch spawned detached in its own process group, and one `/readyz` proof from the new child's tree; the card is one button and one server-timed progress line, and failures are one of `stop_refused | stop_failed | launch_failed | ready_timeout | aborted`. `OPENCLAW_NO_RESPAWN` is no longer pinned to `1` under the external supervisor, so the gateway's own restart exits 0 and alphaclaw relaunches it with a fresh environment. No runtime changes for the template: the exact OpenClaw 2026.9.8 pin, the Node `>=24.16.0 <25 || >=26.1.0` gate and the `node:24-slim` base are unchanged, and the supervisor's `exit 75` contract and the `openclaw gateway run` orphan-sweep pattern still match (the detached gateway's argv is unchanged).
- README: the gateway Restart description now matches 0.10.0 (ask → SIGTERM → SIGKILL ladder, `/readyz` proof) instead of the long-gone `gateway install --force` + `gateway restart` sequence.

## [2.0.0.18] - 2026-10-03

### Changed
- Updated the bundled alphaclaw from 0.9.95 to 0.9.99 (`c3c416764da2bc8f2d93fe74d5a978b7454d1456`), which moves its exact OpenClaw pin from 2026.9.5 to 2026.9.8. 0.9.98 carries the compatibility fixes the new pin needs (state schema 19 / agent schema 24 in the recovery probe and auth store, the quarantine registry no longer holding boot, owner-lease classification on the new log format, re-hashed transient SQLite producers). 0.9.99 removes the in-app Upgrade tab, release channels and alphaclaw's own backup/rollback layer, so the pin in code is now the only OpenClaw version control. It adds a "Back up now" card (OpenClaw's `openclaw backup create --verify`) and runs `openclaw doctor --fix` once on the first boot of each new pin. Upstream notes that 2026.9.6+ database formats cannot be opened by older builds, so going back to 2026.9.5 means restoring a pre-upgrade backup, not redeploying the old pin. No runtime changes for the template: the Node `>=24.16.0 <25 || >=26.1.0` gate and the `node:24-slim` base are unchanged.
- README: OpenClaw upgrades now land only by bumping the alphaclaw pin; the setup UI's Upgrade tab no longer exists.

## [2.0.0.17] - 2026-09-27

### Changed
- Updated the bundled alphaclaw from 0.9.94 to 0.9.95 (`0ecafe81a07efcc41776a4680601cdb4480b89b0`): database recovery recognizes the pinned OpenClaw's transient SQLite coordination/reindex artifacts without deleting them or treating them as application databases, Repair and Restart controls stay usable in every gateway state (with a human-confirmed Verify and start), and boot, recovery and CLI/API diagnosis share bounded database discovery and diagnostics. No runtime changes for the template: the Node `>=24.16.0 <25 || >=26.1.0` gate, the exact OpenClaw 2026.9.5 pin and the `node:24-slim` base are unchanged.

## [2.0.0.16] - 2026-09-26

### Changed
- Updated the bundled alphaclaw from 0.9.92 to 0.9.94 (`2ce650c658611d135966f29b15770802db93d6dc`): config-first upgrade recovery, explicit database migration protection, selective offline recovery, and fixes for dev preparation isolation and recovery lifecycle ownership. Includes guarded pre-onboarding config normalization, restoring stale usage-tracker plugin-path cleanup without bypassing recovery admission. No runtime changes for the template: the Node `>=24.16.0 <25 || >=26.1.0` gate, the exact OpenClaw 2026.9.5 pin and the `node:24-slim` base are unchanged.

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
