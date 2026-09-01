# TODOS

## Tests

### Convert remaining latent no-op `!` assertions in the e2e suites

**What:** In `tests/e2e/stale-config.bats` (lines ~153-192) and `tests/e2e/supervise-e2e.bats` (lines ~128-129), non-final `! grep …` assertions are exempt from bats errexit and silently assert nothing. Convert each to the enforcing `run grep …` + `[ "$status" -ne 0 ]` form.

**Why:** The same defect class was found and fixed in the contract suites and `docker.bats` during the v2.0.0.2 ship (a mutation test proved the bare form passes even when the assertion should fail). The e2e occurrences remain because they can't be executed on a Docker-less host — shipping untested edits to them was riskier than deferring.

**Context:** See the v2.0.0.2 ship review (testing-specialist finding, confirmed by live mutation on bats 1.13.0). Rule of thumb now used in the contract suites: a `!`-prefixed command only fails a bats test when it is the test's final statement. Fix on a machine with Docker, then run `npm run test:e2e` to verify the suites still pass.

**Effort:** S
**Priority:** P1
**Depends on:** A Docker host to run `npm run test:e2e`

### In-image tmux survival scenario in supervise-e2e.bats

**What:** Extend `tests/e2e/supervise-e2e.bats` (which already mounts an exit-75 stub into the real container) so the stub creates a detached tmux session inside the image, then assert the session and its pane PID survive the supervisor relaunch — the in-image analogue of the host-side survival test in `tests/contract/supervise.bats`.

**Why:** The contract-layer survival test uses the host's tmux; this would prove the same property with the image's packaged Debian tmux, the real container PATH, and the production `start.sh` wiring — closing the gap the v2.0.0.2 adversarial review noted ("image-level testing proves only that the executable starts").

**Context:** The stub-mounting mechanism already exists in `supervise-e2e.bats`. Reuse the two-tag design from `tests/contract/supervise.bats` (sweep-tagged decoy dies, tmux session on its own socket survives, same pane PID). Socket can live under the container's `/data`.

**Effort:** M
**Priority:** P2
**Depends on:** A Docker host

## Infrastructure

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

## Completed
