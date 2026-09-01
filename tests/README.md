# Tests

This template is mostly infrastructure (a Dockerfile, a boot script, a fallback
HTTP server, and Render config), so the tests are split by how much they cost to
run. All test files live here and are excluded from the image via `.dockerignore`.

| Layer        | What it checks                                                                 | Needs            | Command               |
|--------------|--------------------------------------------------------------------------------|------------------|-----------------------|
| **unit**     | `failure-server.js` routing + the "no secret leaks" property                   | node             | `npm run test:unit`   |
| **contract** | Static invariants in `start.sh` / `debug-start.sh` / `Dockerfile` / `render.yaml` / `package.json` / `.github/workflows/test.yml` (the "don't remove" items in `CLAUDE.md`) **plus the supervise harness** — the real `start.sh` run on the host with a stub alphaclaw | bash, `shellcheck`, `bats`, node | `npm run test:contract` |
| **e2e**      | Builds the image, runs it with an empty `/data` (like Render's disk), asserts it stays Live and every documented invariant holds at runtime | docker, `bats`, curl | `npm run test:e2e`    |

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
- **e2e** has three suites:
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

## Local prerequisites

```sh
brew install bats-core shellcheck tmux   # macOS
```

Node's built-in test runner (`node --test`) needs no extra packages.
