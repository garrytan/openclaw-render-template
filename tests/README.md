# Tests

This template is mostly infrastructure (a Dockerfile, a boot script, a fallback
HTTP server, and Render config), so the tests are split by how much they cost to
run. All test files live here and are excluded from the image via `.dockerignore`.

| Layer        | What it checks                                                                 | Needs            | Command               |
|--------------|--------------------------------------------------------------------------------|------------------|-----------------------|
| **unit**     | `failure-server.js` routing + the "no secret leaks" property                   | node             | `npm run test:unit`   |
| **contract** | Static invariants in `start.sh` / `debug-start.sh` / `Dockerfile` / `render.yaml` / `package.json` / `.github/workflows/test.yml` (the "don't remove" items in `CLAUDE.md`) **plus the baked-tools contracts** (`tools.bats`: `baked-tools.env` pins, stages and layer order, no `ARG`, checksum/PGDG discipline, no-daemon guard, `.dockerignore` allowlist, `AGENTS.md == CLAUDE.md`) **plus the supervise harness** — the real `start.sh` run on the host with a stub alphaclaw | bash, `shellcheck`, `bats`, node | `npm run test:contract` |
| **e2e**      | Builds the image, runs it with an empty `/data` (like Render's disk), asserts it stays Live and every documented invariant holds at runtime; checks every baked tool offline against `baked-tools.env` and that the image starts none of them | docker, `bats`, curl | `npm run test:e2e`    |

```sh
npm test          # unit + contract (fast, no docker)
npm run test:e2e  # full image build + run (slow; ~minutes)
npm run test:all  # everything
```

## Why these layers

- **Unit** exercises the real `failure-server.js` artifact in a subprocess (no
  mocks). The security test plants sentinel secrets in the env and asserts they
  never appear in any HTTP response — the regression guard for "don't leak
  `/data/start.log` on the public failure page."
- **Contract** locks in the load-bearing config that, if removed, restart-loops
  the container or silently degrades it: the `PATH` prepend (alphaclaw spawns
  `openclaw` by bare name), the `TMPDIR=/data/tmp` routing, the sticky-bit
  `mkdir` on boot, the tini/CMD wiring, `tmux` in the apt line (alphaclaw's
  rescue-session hosting probes `tmux -V`; without it sessions degrade to
  script(1) and die with each alphaclaw restart), `tmux` in the CI workflow's
  apt line (the survival test skips without it, and bats reports skips as
  green — CI must never go green unproven), the default
  `ORPHAN_SWEEP_PATTERN` never matching tmux/rescue argv (including pane argv
  that merely mentions the gateway) while still matching real gateway argv,
  the exact `@anthropic-ai/claude-code` version pin, and the "never touch
  bare `/tmp`" rule.
- **Contract's baked-tools suite** (`tools.bats`) is derive-from-source: it
  parses `baked-tools.env` (concrete versions, hex checksums of the right
  length, every key referenced by the Dockerfile), checks the
  `pins`/`tools`/`monolith-build` stages and the layer order by line number
  (apt/PGDG above the npm layers; tool `COPY --from` lines between the shim
  RUN and `COPY start.sh`), forbids `ARG` and `latest`, requires one checksum
  check per download and the PGDG fingerprint/`signed-by`/client-only/purge-`gpg`
  steps, runs a no-daemon regex over the comment-stripped Dockerfile and
  `start.sh` with positive and negative controls, pins the `EXPOSE`/`CMD`/`COPY`
  surface, derives the `.dockerignore` allowlist from the Dockerfile's `COPY`
  sources, requires `timeout-minutes` on both CI jobs, and `cmp`s
  `AGENTS.md` against `CLAUDE.md`.
- **Contract's supervise harness** (`supervise.bats`) drives the real `start.sh`
  through its env knobs with a scenario-driven stub alphaclaw and a stub
  failure server: exit-75 immediate relaunch (+ spin brake and loop WARNING),
  the >window reset heuristic, backoff + the 5-failure threshold, cumulative
  backoff cap, `FAILURE_EPOCH` persistence/clearing, log rotation, the orphan
  sweep (via a tagged pattern so it can never touch real host processes),
  tmux rescue-session survival — a two-tag test where a sweep-tagged decoy
  dies while a detached tmux session on its own socket survives the exit-75
  relaunch with the same pane PID (skips if the host lacks tmux; CI installs
  it explicitly so the property is always proven there) — and
  numeric env validation. `tests/unit/failure-server-restart.test.mjs` covers
  the failure server's escape hatches: `POST /restart` exit (+ 429 dedupe,
  client-abort), the health-grace 200→503 flip, epoch anchoring, and
  EADDRINUSE bind retry.
- **e2e** has four suites:
  - `docker.bats` mounts a **tmpfs over `/data`** so the dir starts empty at
    runtime, reproducing how Render's disk mount shadows the Dockerfile's
    build-time `mkdir`. If `/data/tmp` exists with its sticky bit afterwards,
    `start.sh` recreated it — the exact behavior `CLAUDE.md` says must survive
    every boot.
  - `stale-config.bats` seeds a real `/data` with an `openclaw.json` that still
    references the **old `@chrysb/alphaclaw` usage-tracker plugin path** (the
    breakage from switching the dependency to the git fork), boots the real
    container Render-style, and asserts OpenClaw reaches a **working state**:
    the dead path is pruned, `openclaw config validate` accepts the config, and
    — for the onboarded variant (seeded with `gateway.mode=local`, as
    `openclaw onboard` writes) — the logs show **`[gateway] ready`** with the
    usage-tracker plugin actually loaded. Covers **both** onboarded and
    not-onboarded `/data`, because the prune must run on every boot (in
    `bin/alphaclaw.js`), not only the onboarded boot sequence. Its final test
    stops the gateway-running container and asserts TERM teardown is prompt.
  - `supervise-e2e.bats` proves the supervisor through the real container
    wiring: `ALPHACLAW_BIN=/bin/false` drives 5 rapid failures onto the
    failure page (Restart button present), `POST /restart` relaunches
    alphaclaw, `/health` flips to 503 on the epoch-anchored schedule, and a
    mounted exit-75 stub shows immediate relaunches with no failure page.
  - `tools.bats` covers the baked tools. Offline (`docker run --network none`)
    it checks every baked binary against the repo's `baked-tools.env`
    (version == pin, the shipped `/etc/baked-tools.env` byte-equals the repo
    copy), `ldd`/arch consistency for each binary, PATH/shim precedence
    (`/app/node_modules/.bin/openclaw` still wins), functional checks
    (`git lfs` commit lands an object under `.git/lfs/objects`, `caddy
    validate`, `jq`, `openssl`, `flock`), and the negatives (no `postgres`
    server binary, no `unzip`/`gpg`, no systemd units for tailscaled). It
    proves the **checksum-mismatch build gate** by mutating the Caddy
    checksums in a throwaway build context holding only `Dockerfile`,
    `.dockerignore` and `baked-tools.env`, and asserting `docker build
    --target tools` fails. Then it boots the image **credential-free**
    (only the env vars `render.yaml` sets: `SETUP_PASSWORD`, the two generated tokens, `PORT`) and asserts `/health` 200 with no
    `tailscaled`/`caddy`/`monolith` process, no tool port listening (80,
    443, 2019, 41641, 5432; `:3000` present as the positive control), one
    supervisor and at most one alphaclaw, and no tool names in cron; boots
    against a **reused `/data` volume** (seeded file kept, `/data/tmp`
    re-stickied, old `start.log` line retained, restart appends a boot);
    and finishes with the prompt-shutdown check.

  Assertion rule across the e2e suites (applied to `stale-config.bats` and
  `supervise-e2e.bats` in 2.0.0.3): negatives are `run <probe>` +
  `[ "$status" -ne 0 ]`, never a non-final bare `! cmd` (exempt from bats
  errexit, so it asserts nothing). Because a nested `run grep` clobbers
  `$output`, capture `docker logs`/`docker exec` output into a variable
  first and grep that.

## Local prerequisites

```sh
brew install bats-core shellcheck tmux   # macOS
```

Node's built-in test runner (`node --test`) needs no extra packages.
