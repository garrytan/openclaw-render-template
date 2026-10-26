#!/usr/bin/env bats
#
# Graceful stop, Render-style: a deploy sends TERM to PID 1 (tini -g) and waits
# out the grace period. tini exits the moment start.sh exits, taking the
# container with it, so start.sh has to wait for alphaclaw's own shutdown:
# the SIGTERM notice, the deploy-history record that lets the next boot report
# measured downtime, and the gateway stop. This boots the real image with a
# live gateway on a named volume, checks that crashes still recover inside the
# container, then stops it with Render's 30 s grace and reads what alphaclaw
# left on /data. A second boot on the same volume must measure the downtime.
#
# Slow (builds the image, boots twice). Run via 'npm run test:e2e'.

IMAGE="openclaw-render-test:latest"
C="openclaw-render-graceful-e2e"
V="openclaw-render-graceful-e2e-data"
PORT=13005
GATEWAY_READY_MARKER="[gateway] ready"

_run() {
  docker rm -f "$C" >/dev/null 2>&1 || true
  docker run -d --name "$C" -v "$V:/data" -p "$PORT:3000" \
    -e PORT=3000 -e SETUP_PASSWORD=graceful-test \
    -e OPENCLAW_GATEWAY_TOKEN=graceful-test-token -e WEBHOOK_TOKEN=graceful-test \
    "$IMAGE" >&2
}

_ready_count() { docker logs "$C" 2>&1 | grep -cF "$GATEWAY_READY_MARKER" || true; }

_wait_ready_count() { # target
  for _ in $(seq 1 90); do
    [ "$(_ready_count)" -ge "$1" ] && return 0
    sleep 2
  done
  echo "gateway ready count never reached $1; logs follow:" >&2
  docker logs "$C" 2>&1 | tail -80 >&2
  return 1
}

_data() { docker run --rm -v "$V:/data" --entrypoint sh "$IMAGE" -c "$1"; }

setup_file() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export REPO IMAGE C V PORT GATEWAY_READY_MARKER
  command -v docker >/dev/null || skip "docker not installed"
  docker info >/dev/null 2>&1 || skip "docker daemon not running"
  docker build -t "$IMAGE" "$REPO" >&2
  docker volume rm -f "$V" >/dev/null 2>&1 || true
  docker volume create "$V" >/dev/null
  docker run --rm -v "$V:/data" --entrypoint sh "$IMAGE" -c \
    'mkdir -p /data/.openclaw && echo "{\"onboarded\":true}" >/data/onboarded.json && echo "{\"gateway\":{\"mode\":\"local\"}}" >/data/.openclaw/openclaw.json' >&2
  _run
  _wait_ready_count 1
}

teardown_file() {
  docker rm -f "$C" >/dev/null 2>&1 || true
  docker volume rm -f "$V" >/dev/null 2>&1 || true
}

@test "a SIGKILLed gateway is relaunched by alphaclaw; the container keeps running" {
  before=$(_ready_count)
  gw=$(docker exec "$C" sh -c "pgrep -f 'openclaw-gateway' | head -1")
  [ -n "$gw" ]
  docker exec "$C" kill -KILL "$gw"
  _wait_ready_count $((before + 1))
  [ "$(docker inspect -f '{{.State.Running}}' "$C")" = "true" ]
}

@test "a SIGKILLed alphaclaw is relaunched by start.sh; the container keeps running" {
  before=$(docker logs "$C" 2>&1 | grep -c '=== boot\|\[supervisor\] exit' || true)
  ac=$(docker exec "$C" sh -c "pgrep -f 'alphaclaw start' | head -1")
  [ -n "$ac" ]
  docker exec "$C" kill -KILL "$ac"
  for _ in $(seq 1 30); do
    docker exec "$C" grep -q "exit 137 after" /data/start.log && break
    sleep 2
  done
  docker exec "$C" grep -q "exit 137 after" /data/start.log
  [ "$(docker inspect -f '{{.State.Running}}' "$C")" = "true" ]
  for _ in $(seq 1 60); do
    curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break
    sleep 2
  done
  curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null
  # Let the relaunched alphaclaw bring its gateway back before the stop test.
  sleep 60
}

@test "docker stop with Render's 30 s grace runs alphaclaw's graceful shutdown" {
  START=$(date +%s)
  docker stop -t 30 "$C"
  DUR=$(( $(date +%s) - START ))
  EC=$(docker inspect -f '{{.State.ExitCode}}' "$C")
  echo "stop took ${DUR}s, exit code $EC" >&2
  [ "$EC" != "137" ]
  [ "$DUR" -lt 29 ]
  LOG=$(_data 'tail -n 60 /data/start.log')
  echo "$LOG" >&2
  grep -qF "[alphaclaw] Shutting down: SIGTERM" <<<"$LOG"
  grep -qF "[deploy] SIGTERM with no announcement" <<<"$LOG"
  grep -qE "restart op=[^ ]+ requested source=shutdown" <<<"$LOG"
  grep -qF "received SIGTERM; supervisor exiting with code" <<<"$LOG"
  HIST=$(_data 'cat /data/deploy-history.json')
  echo "$HIST" >&2
  grep -q '"reason": *"SIGTERM"' <<<"$HIST"
  run docker exec "$C" true
  [ "$status" -ne 0 ]
}

@test "the next boot on the same volume measures the downtime" {
  # docker logs keeps the previous run's output, so wait for one more ready line.
  before=$(_ready_count)
  docker start "$C" >&2
  _wait_ready_count $((before + 1))
  for _ in $(seq 1 30); do
    HIST=$(docker exec "$C" cat /data/deploy-history.json 2>/dev/null || true)
    grep -q '"seconds"' <<<"$HIST" && break
    sleep 2
  done
  echo "$HIST" >&2
  grep -q '"seconds"' <<<"$HIST"
  grep -q '"lastShutdown": *null' <<<"$HIST"
}
