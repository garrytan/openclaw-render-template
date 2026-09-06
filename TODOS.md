# TODOS

## Tests

### In-image tmux survival scenario in supervise-e2e.bats

**What:** Extend `tests/e2e/supervise-e2e.bats` (which already mounts an exit-75 stub into the real container) so the stub creates a detached tmux session inside the image, then assert the session and its pane PID survive the supervisor relaunch — the in-image analogue of the host-side survival test in `tests/contract/supervise.bats`.

**Why:** The contract-layer survival test uses the host's tmux; this would prove the same property with the image's packaged Debian tmux, the real container PATH, and the production `start.sh` wiring — closing the gap the v2.0.0.2 adversarial review noted ("image-level testing proves only that the executable starts").

**Context:** The stub-mounting mechanism already exists in `supervise-e2e.bats`. Reuse the two-tag design from `tests/contract/supervise.bats` (sweep-tagged decoy dies, tmux session on its own socket survives, same pane PID). Socket can live under the container's `/data`.

**Effort:** M
**Priority:** P2
**Depends on:** A Docker host

### Shared e2e helper

**What:** Extract the docker-available check, the `docker build -t openclaw-render-test:latest` call, and the `/health` wait loop into `tests/e2e/helpers.bash` and `load` it from the four suites.

**Why:** `docker.bats`, `stale-config.bats`, `supervise-e2e.bats` and `tools.bats` each carry a near-identical copy of that boilerplate; a change to the health-wait timeout or the image tag currently has to be made four times.

**Context:** The 2.0.0.3 plan deliberately kept `tools.bats` self-contained (review decision 9) so the new suite could be read in one file; the extraction is mechanical. Keep per-suite container names and host ports distinct so the suites can still run back to back, and keep the "skip cleanly when docker is unavailable" behavior.

**Effort:** S
**Priority:** P3
**Depends on:** None

### PGDG fingerprint-mismatch build gate

**What:** Add a negative build test to `tests/e2e/tools.bats` mirroring the checksum gate: copy the repo to a temp context, mutate the 40-hex fingerprint literal in the copy's Dockerfile apt/PGDG `RUN`, `docker build` it, and assert the build fails.

**Why:** The fingerprint path is only contract-checked (the literal and the `pub`-count/`fpr` comparisons are present in the RUN) but never exercised. The checksum gate proves `sha*sum -c` aborts the build; nothing yet proves the fingerprint `test` does.

**Context:** The apt/PGDG RUN lives in the final stage, so there is no cheap `--target` for it; the mutated build runs the full graph (mostly cache hits after the main build) and must fail at the fingerprint comparison. Assert on the exit status; a plain `test` failure prints no distinctive message, so consider adding an `echo … >&2` before the comparison in the Dockerfile if the assertion needs to match output.

**Effort:** S
**Priority:** P3
**Depends on:** None

## CI

### BuildKit layer cache in CI

**What:** Add `docker/setup-buildx-action` to the e2e job and pre-build the image with `--cache-from type=gha --cache-to type=gha,mode=max --load` before bats runs, so cold builds (which now include a Rust compile of monolith in the `monolith-build` stage) hit the GitHub Actions layer cache.

**Why:** Every push pays the full cold build (5+ minutes, more with the monolith compile). The `pins` stage isolates the monolith cache key, but that only helps once a cache exists between runs.

**Context:** The e2e suites each call `docker build -t openclaw-render-test:latest` directly in `setup_file`, so pre-build with the same builder and tag and those calls become cache hits (or fold the build into the shared e2e helper). `--load` is required because buildx's docker-container driver does not populate the local image store by default. Review decision 4B chose `timeout-minutes` over a cache for 2.0.0.3; this is the follow-up.

**Effort:** M
**Priority:** P2
**Depends on:** None

### arm64 build check in CI

**What:** Add a build-only CI step, `docker buildx build --platform linux/arm64` via QEMU (`docker/setup-qemu-action`), no run, so the arm64 branches of the `tools` stage (asset names and the `*_ARM64`/`*_AARCH64` checksums) and the source-built monolith are exercised.

**Why:** arm64 support is by construction only. CI and the dev sandbox are amd64, so a wrong arm64 checksum in `baked-tools.env` would first surface on an arm64 Render build.

**Context:** An emulated Rust compile of monolith is slow, so this needs the BuildKit layer cache first or CI time becomes unreasonable. `--target tools` is a cheap first step (downloads + checksums only) before a full-image arm64 build.

**Effort:** S
**Priority:** P2
**Depends on:** BuildKit layer cache in CI

## Infrastructure

### Persist Bun globals under `/data`

**What:** Export `BUN_INSTALL=/data/.bun` and append `/data/.bun/bin` to the PATH that `start.sh` forces, so `bun install -g` lands on the persistent disk.

**Why:** Bun globals go to `/root/.bun`, which is ephemeral and vanishes on every redeploy; the README's "Baked-in tools" section documents this as a manual workaround today.

**Context:** `start.sh`'s forced PATH string is contract-tested in `tests/contract/scripts.bats` — append the new entry, do not reorder the existing ones (`/app/node_modules/.bin` must stay first). Export `BUN_INSTALL` before alphaclaw is spawned so the agent's shells inherit it, and `mkdir -p` the dir next to the `/data/tmp` creation.

**Effort:** S
**Priority:** P3
**Depends on:** None

### Evaluate lockfile-driven app install (`npm ci`) for the image build

**What:** Decide whether the Dockerfile's app install should copy `package-lock.json` and use `npm ci` instead of a fresh unlocked `npm install`, so image rebuilds resolve identical transitive dependency trees.

**Why:** The v2.0.0.2 ship pinned `@anthropic-ai/claude-code` exactly, but the app install still floats `^`-ranged transitive deps (express, ws, compression via alphaclaw) on every layer-busting rebuild. Both adversarial review models flagged the unlocked install as the image's remaining supply-chain surface.

**Context:** This is a deliberate current design — CLAUDE.md documents that only `package.json` is copied (the SHA pin is the cache-busting mechanism, and the git-dep `prepare` build must run). Switching to `npm ci` needs care: the lockfile records the git dep's resolved SHA, so alphaclaw pin bumps must regenerate it, and the fork's `prepare` script behavior under `npm ci` should be verified. Weigh reproducibility against the added lockfile-maintenance step in the pin-bump workflow.

**Effort:** M
**Priority:** P2
**Depends on:** None

### Boot-time :3000 ownership check and rescue-session resource notes

**What:** Two operational hardenings from the v2.0.0.2 adversarial review: (1) have `start.sh` log a warning (or optionally kill) when something other than alphaclaw already owns :3000 at launch — a process started inside a tmux rescue pane that binds :3000 now survives alphaclaw restarts and would force an EADDRINUSE rapid-fail loop until Render restarts the container; (2) document the memory ceiling: `render.yaml` pins `plan: starter` (512 MB) and each surviving rescue session hosts a Node-heavy process, so lingering sessions can OOM the box and present as confusing exit-137 rapid failures.

**Why:** tmux hosting (v2.0.0.2) deliberately makes rescue sessions outlive alphaclaw restarts; these are the two failure modes that durability newly makes reachable.

**Context:** The :3000 check belongs near the top of `start.sh`'s loop (it already logs every boot decision to `/data/start.log`); the memory note belongs in CLAUDE.md's Render gotchas section. Session count is bounded upstream (alphaclaw hosts a single named `alphaclaw-rescue` session), which is why this is documentation/logging, not a session reaper.

**Effort:** S
**Priority:** P2
**Depends on:** None

## Docs

### CHANGELOG backfill for alphaclaw 0.9.66–0.9.76

**What:** Add one `CHANGELOG.md` entry per alphaclaw pin bump that landed on main after 2.0.0.2 without one: 0.9.66 (5ee146b), 0.9.67 (292f120), 0.9.68 (4e537e1), 0.9.69 (d02a6e8), 0.9.75 (ff23cfd), 0.9.76 (01d3b66).

**Why:** CLAUDE.md's discipline is that every alphaclaw pin bump gets a VERSION bump and a CHANGELOG entry; these six shipped as bare pin-bump commits, and 2.0.0.3 carries only a roll-up bullet.

**Context:** `git log --oneline -- package.json` has the one-line summaries; the release notes in `garrytan/alphaclaw` have the detail. Decide whether to expand the 2.0.0.3 roll-up into per-bump sub-bullets or to add retroactive entries under the versions they would have received.

**Effort:** S
**Priority:** P3
**Depends on:** None

## Completed

### Convert remaining latent no-op `!` assertions in the e2e suites

**Shipped in 2.0.0.3.**

**What:** In `tests/e2e/stale-config.bats` (lines ~153-192) and `tests/e2e/supervise-e2e.bats` (lines ~128-129), non-final `! grep …` assertions are exempt from bats errexit and silently assert nothing. Convert each to the enforcing `run grep …` + `[ "$status" -ne 0 ]` form.

**Why:** The same defect class was found and fixed in the contract suites and `docker.bats` during the v2.0.0.2 ship (a mutation test proved the bare form passes even when the assertion should fail). The e2e occurrences remain because they can't be executed on a Docker-less host — shipping untested edits to them was riskier than deferring.

**Context:** See the v2.0.0.2 ship review (testing-specialist finding, confirmed by live mutation on bats 1.13.0). Rule of thumb now used in the contract suites: a `!`-prefixed command only fails a bats test when it is the test's final statement. Fix on a machine with Docker, then run `npm run test:e2e` to verify the suites still pass.

**Effort:** S
**Priority:** P1
**Depends on:** A Docker host to run `npm run test:e2e`
