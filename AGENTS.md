# Agent notes for openclaw-render-template

This is a Docker-based one-click Render deploy of [`alphaclaw`](https://github.com/garrytan/alphaclaw) (the `garrytan/alphaclaw` fork), which wraps OpenClaw to run as a 24/7 service. Notes here are for AI agents (or future humans) who need to understand non-obvious behavior fast.

## Layout

- `Dockerfile` — image build. `CMD` is `/start.sh`; `tini -g` is PID 1 (`-g` signals the whole process group — load-bearing for prompt shutdown, see "Boot supervisor"). The apt line installs `tmux` on purpose: alphaclaw's local Claude Code rescue sessions probe for it (`tmux -V`), and without it they degrade to `script(1)` hosting that dies with every alphaclaw restart. Note the apt line sits *above* both npm layers, so editing it rebuilds them on the next deploy: the global `@anthropic-ai/claude-code` install is **version-pinned** (bump it deliberately and record it in `CHANGELOG.md` + `VERSION`, same discipline as the alphaclaw SHA — contract-tested), and the app `npm install` re-resolves its unlocked ranges (bounded — alphaclaw is SHA-pinned and pins `openclaw` exactly). Verify the alphaclaw version post-deploy.
- `render.yaml` — Render Blueprint config. Service is web, plan starter, port 3000, health check `/health`, `/data` 10 GB persistent disk.
- `package.json` — pins `alphaclaw` as a **git dependency** (`git+https://github.com/garrytan/alphaclaw.git#<commit-sha>`), not an npm-registry package. `openclaw` arrives as a transitive dep. Four non-obvious details, all load-bearing:
  - **Pin a full commit SHA, never `#main`.** The Dockerfile copies only `package.json` into a layer and runs `npm install` there. With a moving ref like `#main`, that layer's cache key never changes, so Docker (locally *and* on Render) keeps reusing the npm-install layer built when the ref was first resolved — alphaclaw updates silently never land in new images. This actually happened in the field: a config-migration fix was merged to the fork but deploys kept shipping the old alphaclaw. Pinning the SHA makes every alphaclaw update an explicit `package.json` edit, which changes the layer hash and forces a real reinstall. To update: `git ls-remote https://github.com/garrytan/alphaclaw.git main`, paste the new SHA, reinstall, run tests, and record the bump in `CHANGELOG.md` + `VERSION`.
  - **Explicit `git+https://`, not the `github:` shorthand.** npm's `hosted-git-info` canonicalizes GitHub deps to `git+ssh://git@github.com/…` (you'll see that in `package-lock.json`'s `resolved` — that's cosmetic). The `node:22-slim` Docker build has no SSH key, so the spec in `package.json` must force HTTPS or the build fails fetching the dep. (The Dockerfile does a fresh `npm install` from `package.json` and never copies the lockfile, so the `package.json` spec is what drives the fetch.)
  - **The dep key is `alphaclaw`.** npm uses the key as the install-folder alias, so it lands at `node_modules/alphaclaw/` even though the fork's internal `name` is still `@chrysb/alphaclaw`. The template only ever invokes the `alphaclaw`/`openclaw` *binaries* by name, never `require("@chrysb/alphaclaw")`, so the name mismatch is harmless.
  - **The fork carries a `prepare` script.** It builds the gitignored UI artifacts (`lib/public/dist/`, generated Tailwind CSS) at install time. npm skips `prepack` for git installs but *does* run `prepare`, so without it the setup UI ships blank.
- `start.sh` — boot **supervisor** (see "Boot supervisor" below). Not a one-shot launcher.
- `failure-server.js` — public failure-status page with a `POST /restart` escape hatch and a health-grace flip (see "Boot supervisor").
- `debug-start.sh` — diagnostic boot script (see "Debug path" below).
- `VERSION` + `CHANGELOG.md` — template release metadata; every alphaclaw pin bump gets a VERSION bump and a CHANGELOG entry.
- `TODOS.md` — deferred-work ledger (mostly items surfaced by ship reviews, with effort/priority and the context to pick them up cold); when a ship completes one, move it to the Completed section with the shipping version.

## Critical PATH detail (don't remove)

`alphaclaw start` spawns `openclaw` by **bare name** in two places inside `node_modules/alphaclaw/lib/server/gateway.js`:

- A preflight `execSync("openclaw plugins list --json", ...)`
- The gateway run: `spawn("openclaw", ["gateway", "run"], ...)`

Both inherit `process.env.PATH` from the alphaclaw process. The default `node:22-slim` PATH is `/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin` — `/app/node_modules/.bin` is **not** on it, and that's where `openclaw` lives. If PATH isn't fixed, alphaclaw crashes with `Error: spawn openclaw ENOENT` and the container restart-loops.

The Dockerfile addresses this two ways (both intentional, keep both):

1. `ENV PATH="/app/node_modules/.bin:$PATH"` — primary fix
2. `RUN ln -sf /app/node_modules/.bin/{openclaw,alphaclaw} /usr/local/bin/...` — belt-and-suspenders so even a future refactor that drops the ENV line still works

## Temp dir on the persistent disk (`/data/tmp`)

Temp is routed to `/data/tmp` (the persistent disk) instead of the container's ephemeral `/tmp`, so a 24/7 service doesn't churn/fill the ephemeral layer. OpenClaw is mid-migration from hardcoded `/tmp` callsites to `TMPDIR`-aware APIs ([openclaw#11587](https://github.com/openclaw/openclaw/issues/11587)); the env-var route covers everything that respects the standard temp APIs.

Set in **two** places (same belt-and-suspenders reasoning as PATH — keep both):

1. `ENV TMPDIR/TEMP/TMP=/data/tmp` in the Dockerfile — primary.
2. `export TMPDIR=… ` + `mkdir -p /data/tmp && chmod 1777` in `start.sh` — load-bearing. `/data` is a **runtime-mounted disk**, so the Dockerfile's build-time `mkdir /data/tmp` is shadowed at runtime; `start.sh` must (re)create the dir on every boot. The re-export also survives Render runtime env munging.

**`/tmp` itself is deliberately left untouched** — never symlinked, bind-mounted, or moved. We only *add* `/data/tmp` as the `TMPDIR` preference; that's the whole mechanism. Any code that still hardcodes `/tmp` keeps using the container's ephemeral `/tmp`, which is fine and intended. Do **not** redirect `/tmp` wholesale: Render containers aren't privileged (`mount --bind` fails anyway), and pointing all of `/tmp` at the 10 GB disk risks filling it and adds disk I/O for every process's scratch. Leave `/tmp` be.

## Boot supervisor (`start.sh` → `failure-server.js`)

`start.sh` supervises `alphaclaw start` in a loop; it is NOT a one-shot launcher (the old one-shot + `exec failure-server` turned every alphaclaw exit — including intentional restarts — into a permanent outage parked on a forever-200 failure page; alphaclaw #22).

Restart policy (env-overridable knobs in parentheses; numerics are validated with logged fallback):

- **exit 75** (EX_TEMPFAIL — newer alphaclaw's `restartProcess()` contract) → relaunch immediately; never counts toward the failure threshold. Sub-5s runs get a 1s spin brake (`SPIN_BRAKE_SECS`); 10 consecutive sub-5s 75s log a possible-loop WARNING.
- **any exit after a run > 60s** (`RAPID_WINDOW_SECS`) → healthy-enough: counter and `FAILURE_EPOCH` reset, relaunch. Covers older alphaclaw that exits 1 to request a restart. Repeated non-zero long-run exits log a WARNING streak.
- **exit within 60s** → rapid failure: `fails*5s` backoff (`BACKOFF_STEP_SECS`), cumulative backoff capped at 30s (`CUM_BACKOFF_CAP_SECS`) — Render restarts an instance after ~60s of failed health checks, so the failure page must be reachable well before that.
- **5 consecutive rapid failures** (`MAX_RAPID_FAILS`) → run `failure-server.js` as a **loop child** (never `exec`). Its exit (Restart button) resets the counter and retries alphaclaw.

Other load-bearing details:

- **`FAILURE_EPOCH`** (unix seconds) is set on first entry into failure mode and passed to the failure server; it survives Restart-button cycles and clears only on a >60s run. The failure server anchors its health-grace clock to it — `/health` 200s for `FAILURE_HEALTH_GRACE_MS` (default 5 min, Shell-tab debugging window) then 503s so Render restarts the container. The epoch anchor is what stops `/restart` spam from keeping a broken box "healthy" forever.
- **`POST /restart`** on the failure page exits the server (code 0) so the supervisor relaunches alphaclaw. It reads nothing from the request and shells out to nothing; repeat requests within 30s get 429 (dedupe, not cross-cycle rate limiting). The failure server also retries `listen()` on `EADDRINUSE` — a dying alphaclaw can hold :3000 for a few seconds.
- **Orphan sweep**: after every alphaclaw exit the supervisor TERM→wait→KILLs stragglers matching `ORPHAN_SWEEP_PATTERN` (default ERE `(^|[ /])openclaw[^ ]* gateway run( |$)` — matches `openclaw gateway run` and `node .../openclaw.mjs gateway run`). The pattern is deliberately tight: `pkill -f` matches anywhere in any argv, and rescue panes are where operators type things like `grep "openclaw gateway" start.log` mid-incident — requiring the anchored full "gateway run" phrase keeps the sweep off them (contract-tested in `scripts.bats`; argv containing the literal "…openclaw … gateway run" phrase remains a documented accepted risk). The env knob exists so the test harness can use a tagged stub and never touch real host processes. Surviving the sweep is how tmux rescue sessions outlive alphaclaw restarts (not container restarts/redeploys — tmux servers are in-memory).
- **Log hygiene**: `/data/start.log` rotates to `.1` above ~50MB (`MAX_LOG_BYTES`); every exit code, duration, and decision is logged there.
- **Signals**: the Dockerfile's `tini -g` TERMs the whole process group, so the supervisor needs no traps/job control and `docker stop` stays prompt. Don't drop `-g`.

## Render-specific gotchas

- **`dockerCommand` in `render.yaml` may not be honored** on this service. Blueprint sync has been unreliable — runtime behavior must come from Dockerfile `CMD`/`ENTRYPOINT`, not `render.yaml` overrides.
- **Shell tab requires a healthy container.** If PID 1 is crashing, the Shell tab is unavailable. Use the debug path below to break the loop.
- **No output for >2 min after `Setting WEB_CONCURRENCY=8`** in deploy logs almost always means the container crashed before producing stdout, or Render is still pulling the image. Don't assume "stuck" means "hanging."
- **Health check is `/health`** — must return 2xx on port 3000.

## Debug path

When the container won't stay up, swap `CMD` to use `debug-start.sh`:

```dockerfile
COPY debug-start.sh /debug-start.sh
RUN chmod +x /debug-start.sh
CMD ["/debug-start.sh"]
```

What it does:
- Binds port 3000 with a tiny Node HTTP server → Render goes Live → Shell tab unlocks
- `tail -f /dev/null` keeps PID 1 alive forever → no restart loop
- `set -x`, full env dump, listings of all candidate `openclaw` binary locations
- Tees everything to `/data/debug.log` so the record survives even if Render drops log lines

Once Live, in the Shell tab:
```sh
cat /data/debug.log
echo $PATH
ls /app/node_modules/.bin | grep -i claw
alphaclaw start          # reproduce the real failure
```

Restore `CMD ["/start.sh"]` after diagnosis.

## Tests

Three layers (details in `tests/README.md`); CI runs all three on push via `.github/workflows/test.yml`.

- `npm test` — fast unit + contract, no Docker. Unit exercises `failure-server.js` routing, the no-secret-leak property, and the restart/health-grace behavior; contract statically locks in the load-bearing invariants in this doc (PATH prepend, `TMPDIR=/data/tmp`, sticky-bit `mkdir` on boot, tini `-g`/CMD wiring, tmux in the apt lines (image and CI workflow), the exact `@anthropic-ai/claude-code` version pin, the sweep-pattern-vs-rescue-argv safety, the supervisor policy knobs, and "never operate on bare `/tmp`") and runs the **supervise harness** — the real `start.sh` on the host with a stub alphaclaw, covering exit-75, the 60s reset heuristic, backoff + threshold, epoch persistence, rotation, orphan sweep, tmux rescue-session survival across an exit-75 relaunch, and env validation.
- `npm run test:e2e` — builds the image and runs it with an **empty `/data`** (tmpfs, mimicking Render's disk mount) to prove `start.sh` recreates `/data/tmp` at boot and the container stays Live. Needs Docker; slow.

After touching `start.sh`, `Dockerfile`, `render.yaml`, or `failure-server.js`, run `npm test` (and `npm run test:e2e` for image-level changes).

## What NOT to do

- Don't patch `node_modules/alphaclaw/` — gets blown away on every `npm install`. Fix at the Dockerfile/env layer instead (or, for changes to alphaclaw itself, in the `garrytan/alphaclaw` fork).
- Don't rely on `dockerCommand` in `render.yaml` to override `CMD` — Blueprint sync may silently ignore it. Use Dockerfile `CMD`.
- Don't drop `ENV PATH="/app/node_modules/.bin:$PATH"` — it's load-bearing for alphaclaw's spawn behavior.
- Don't move the `/data/tmp` creation to Dockerfile-only — the disk mount hides it; `start.sh` must `mkdir` it at boot.
- Don't touch `/tmp` — no symlink, bind-mount, or move. Only set `TMPDIR` and leave `/tmp` be (see "Temp dir" section).
- Don't turn `start.sh` back into a one-shot launcher or `exec` the failure server — the supervise loop and its escape hatches are the fix for alphaclaw #22.
- Don't drop `-g` from the tini ENTRYPOINT — prompt shutdown of the supervised tree depends on group signaling.
- Don't drop `tmux` from the Dockerfile's apt line — alphaclaw's local Claude Code rescue sessions probe for it (`tmux -V`); without it they fall back to `script(1)` hosting and die with every alphaclaw restart. Relatedly, never change `ORPHAN_SWEEP_PATTERN` to anything that could match tmux/rescue argv — the sweep would kill the session tmux exists to keep alive. Both are contract-tested.
- Don't force-push or amend on `main` after a debug detour. Add a new commit on top.
