#!/usr/bin/env bats
#
# End-to-end regression test for the "invalid OpenClaw config" boot failure —
# Render-style: boot the real image against a persistent /data carrying broken
# state, and assert OpenClaw actually reaches a WORKING state (gateway ready,
# usage-tracker plugin loaded), not merely that a config file looks right.
#
# The breakage being reproduced: after switching the alphaclaw dependency from
# the @chrysb npm package (installed at /app/node_modules/@chrysb/alphaclaw/...)
# to the garrytan git fork (installed at /app/node_modules/alphaclaw/...), the
# persistent disk's openclaw.json still referenced the OLD usage-tracker plugin
# path. OpenClaw rejects the whole config:
#
#   plugins.load.paths: plugin: plugin path not found:
#     /app/node_modules/@chrysb/alphaclaw/lib/plugin/usage-tracker
#   ...
#   [gateway] Gateway failed to start: Invalid config at /data/.openclaw/openclaw.json
#
# Two containers cover both boot paths, because the prune must NOT be gated
# behind onboarding:
#   - onboarded: /data has onboarded.json + a realistic onboarded config
#     (gateway.mode=local, as `openclaw onboard --mode local` writes). The
#     gateway must start: logs show "[gateway] ready" and the usage-tracker
#     plugin initialized — proof the pruned config is genuinely valid.
#   - NOT onboarded: no marker, so alphaclaw won't launch the gateway; the
#     unconditional reconcile in bin/alphaclaw.js must still prune the path
#     (this is the variant that regressed in the field).
#
# Slow (builds an image, boots two containers). Run via `npm run test:e2e`.
# Skips cleanly when docker is unavailable.

IMAGE="openclaw-render-test:latest"
C_ONB="openclaw-render-stale-onboarded-e2e"
C_NOO="openclaw-render-stale-not-onboarded-e2e"
PORT_ONB=13001
PORT_NOO=13002
STALE_PATH="/app/node_modules/@chrysb/alphaclaw/lib/plugin/usage-tracker"
CANONICAL_PATH="/app/node_modules/alphaclaw/lib/plugin/usage-tracker"
GATEWAY_READY_MARKER="[gateway] ready"

_seed_data_dir() {
  # $1 = dir, $2 = "onboarded" | "not-onboarded"
  local dir="$1"
  mkdir -p "$dir/.openclaw"
  if [ "$2" = "onboarded" ]; then
    printf '{"onboarded":true}\n' >"$dir/onboarded.json"
    # Realistic onboarded config: gateway.mode=local is what `openclaw onboard
    # --mode local` writes; without it the gateway refuses to start for an
    # unrelated reason and the test would prove nothing about the plugin path.
    cat >"$dir/.openclaw/openclaw.json" <<JSON
{
  "gateway": { "mode": "local" },
  "plugins": {
    "allow": ["usage-tracker"],
    "load": { "paths": ["$STALE_PATH"] },
    "entries": { "usage-tracker": { "enabled": true } }
  }
}
JSON
  else
    cat >"$dir/.openclaw/openclaw.json" <<JSON
{
  "plugins": {
    "allow": ["usage-tracker"],
    "load": { "paths": ["$STALE_PATH"] },
    "entries": { "usage-tracker": { "enabled": true } }
  }
}
JSON
  fi
}

_run_seeded() {
  # $1 = container name, $2 = host port, $3 = seed dir
  docker rm -f "$1" >/dev/null 2>&1 || true
  docker run -d --name "$1" \
    -v "$3:/data" \
    -p "$2:3000" \
    -e PORT=3000 \
    -e SETUP_PASSWORD="stale-config-test" \
    -e OPENCLAW_GATEWAY_TOKEN="stale-config-test-token" \
    -e WEBHOOK_TOKEN="stale-config-test" \
    "$IMAGE" >&2
  # Express /health comes up early; the gateway takes longer (gog install etc.).
  for _ in $(seq 1 60); do
    if curl -fsS "http://127.0.0.1:$2/health" >/dev/null 2>&1; then break; fi
    sleep 2
  done
}

_wait_for_gateway_ready() {
  # $1 = container name. Render marks the service Live on /health, but "working"
  # means OpenClaw's gateway came up — wait for its ready line in the logs.
  for _ in $(seq 1 60); do
    if docker logs "$1" 2>&1 | grep -qF "$GATEWAY_READY_MARKER"; then return 0; fi
    sleep 2
  done
  echo "gateway never became ready; logs follow:" >&2
  docker logs "$1" >&2 || true
  return 1
}

setup_file() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export REPO IMAGE C_ONB C_NOO PORT_ONB PORT_NOO STALE_PATH CANONICAL_PATH GATEWAY_READY_MARKER

  command -v docker >/dev/null || skip "docker not installed"
  docker info >/dev/null 2>&1 || skip "docker daemon not running"

  docker build -t "$IMAGE" "$REPO" >&2

  SEED_ONB="$(mktemp -d)"; SEED_NOO="$(mktemp -d)"
  export SEED_ONB SEED_NOO
  _seed_data_dir "$SEED_ONB" onboarded
  _seed_data_dir "$SEED_NOO" not-onboarded

  _run_seeded "$C_ONB" "$PORT_ONB" "$SEED_ONB"
  _run_seeded "$C_NOO" "$PORT_NOO" "$SEED_NOO"

  _wait_for_gateway_ready "$C_ONB"
  # The not-onboarded container never starts a gateway; give its boot reconcile
  # a moment to write the migrated config.
  sleep 5
}

teardown_file() {
  docker rm -f "$C_ONB" "$C_NOO" >/dev/null 2>&1 || true
  [ -n "$SEED_ONB" ] && rm -rf "$SEED_ONB" || true
  [ -n "$SEED_NOO" ] && rm -rf "$SEED_NOO" || true
}

# --- onboarded: OpenClaw must reach a working state --------------------------

@test "onboarded: container stays Live with seeded stale plugin path" {
  run curl -fsS "http://127.0.0.1:${PORT_ONB}/health"
  [ "$status" -eq 0 ]
}

@test "onboarded: gateway logs '[gateway] ready' — OpenClaw started properly" {
  run docker logs "$C_ONB"
  grep -qF "$GATEWAY_READY_MARKER" <<<"$output"
}

@test "onboarded: usage-tracker plugin actually loaded in the gateway" {
  # Loading is the strongest proof the pruned path is valid: the gateway only
  # initializes the plugin after resolving plugins.load.paths successfully.
  run docker logs "$C_ONB"
  grep -qE "\[usage-tracker\] initialized|plugin: usage-tracker" <<<"$output"
}

@test "onboarded: logs contain no invalid-config or plugin-path failures" {
  # Enforcing form: a bare non-final `! grep` is exempt from bats errexit and
  # asserts nothing. Capture the logs into a named variable first — a nested
  # `run grep` would clobber $output from a prior `run docker logs`.
  LOGS=$(docker logs "$C_ONB" 2>&1)
  run grep -qF "OpenClaw config is invalid" <<<"$LOGS"
  [ "$status" -ne 0 ]
  run grep -qiF "plugin path not found" <<<"$LOGS"
  [ "$status" -ne 0 ]
  run grep -qF "Gateway failed to start" <<<"$LOGS"
  [ "$status" -ne 0 ]
}

@test "onboarded: boot pruned the stale @chrysb usage-tracker path" {
  run docker exec "$C_ONB" cat /data/.openclaw/openclaw.json
  [ "$status" -eq 0 ]
  echo "config: $output" >&2
  CFG="$output"
  run grep -qF "$STALE_PATH" <<<"$CFG"
  [ "$status" -ne 0 ]
  grep -qF "$CANONICAL_PATH" <<<"$CFG"
}

@test "onboarded: openclaw config validate accepts the migrated config" {
  run docker exec "$C_ONB" sh -c "openclaw config validate 2>&1 || true"
  echo "validate: $output" >&2
  VALIDATE="$output"
  run grep -qF "$STALE_PATH" <<<"$VALIDATE"
  [ "$status" -ne 0 ]
  run grep -qiF "plugin path not found" <<<"$VALIDATE"
  [ "$status" -ne 0 ]
}

# --- NOT onboarded: prune must still run (the field regression) --------------

@test "not-onboarded: container stays Live with seeded stale plugin path" {
  run curl -fsS "http://127.0.0.1:${PORT_NOO}/health"
  [ "$status" -eq 0 ]
}

@test "not-onboarded: boot pruned the stale @chrysb usage-tracker path" {
  run docker exec "$C_NOO" cat /data/.openclaw/openclaw.json
  [ "$status" -eq 0 ]
  echo "config: $output" >&2
  CFG="$output"
  run grep -qF "$STALE_PATH" <<<"$CFG"
  [ "$status" -ne 0 ]
  grep -qF "$CANONICAL_PATH" <<<"$CFG"
}

@test "not-onboarded: openclaw config validate accepts the migrated config" {
  run docker exec "$C_NOO" sh -c "openclaw config validate 2>&1 || true"
  echo "validate: $output" >&2
  VALIDATE="$output"
  run grep -qF "$STALE_PATH" <<<"$VALIDATE"
  [ "$status" -ne 0 ]
  run grep -qiF "plugin path not found" <<<"$VALIDATE"
  [ "$status" -ne 0 ]
}

# Keep this LAST: it stops the onboarded container — the one with a LIVE
# gateway in its process tree, so TERM teardown is proven against real
# children, not just an idle setup server.
@test "TERM stops the gateway-running container promptly (tini -g)" {
  START=$(date +%s)
  docker stop -t 15 "$C_ONB"
  DUR=$(( $(date +%s) - START ))
  [ "$DUR" -lt 14 ]
  EC=$(docker inspect -f '{{.State.ExitCode}}' "$C_ONB")
  [ "$EC" != "137" ]
}
