#!/usr/bin/env bats
#
# Image-level test of the boot supervisor — the actual fix for alphaclaw #22:
# rapid alphaclaw failures must land on the failure page (not a dead loop),
# POST /restart must resume supervision, /health must flip to 503 on the
# FAILURE_EPOCH-anchored schedule (so restart cycles can't reset it), and
# exit-75 must relaunch immediately without ever reaching the failure page —
# all through the real container wiring (tini -g, start.sh, failure-server).
#
# ALPHACLAW_BIN is env-overridable in start.sh precisely so this test can
# drive the supervisor with /bin/false (instant rapid failure) and a mounted
# exit-75 stub without faking anything else.
#
# Slow (builds an image, boots two containers). Run via `npm run test:e2e`.
# Skips cleanly when docker is unavailable.

IMAGE="openclaw-render-test:latest"
C_FAIL="openclaw-render-supervise-fail-e2e"
C_75="openclaw-render-supervise-75-e2e"
PORT_FAIL=13020

setup_file() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export REPO IMAGE C_FAIL C_75 PORT_FAIL

  command -v docker >/dev/null || skip "docker not installed"
  docker info >/dev/null 2>&1 || skip "docker daemon not running"

  docker build -t "$IMAGE" "$REPO" >&2
  docker rm -f "$C_FAIL" "$C_75" >/dev/null 2>&1 || true

  # --- rapid-failure container: alphaclaw is /bin/false --------------------
  # BACKOFF_STEP_SECS=0 + short window so the 5-failure threshold lands in
  # seconds; FAILURE_HEALTH_GRACE_MS=15000 so the epoch-anchored 503 flip is
  # observable within the test.
  docker run -d --name "$C_FAIL" \
    --tmpfs /data \
    -p "${PORT_FAIL}:3000" \
    -e PORT=3000 \
    -e ALPHACLAW_BIN=/bin/false \
    -e BACKOFF_STEP_SECS=0 \
    -e RAPID_WINDOW_SECS=5 \
    -e FAILURE_HEALTH_GRACE_MS=15000 \
    -e SETUP_PASSWORD="supervise-e2e" \
    -e OPENCLAW_GATEWAY_TOKEN="supervise-e2e-token" \
    -e WEBHOOK_TOKEN="supervise-e2e" \
    "$IMAGE" >&2

  # Wait for the failure server to answer (5 instant failures + overhead).
  for _ in $(seq 1 30); do
    if curl -fsS "http://127.0.0.1:${PORT_FAIL}/health" >/dev/null 2>&1; then break; fi
    sleep 2
  done

  # --- exit-75 container: mounted stub ---------------------------------------
  STUB_DIR="$(mktemp -d)"
  export STUB_DIR
  cat >"$STUB_DIR/stub75" <<'EOF'
#!/bin/sh
sleep 1
exit 75
EOF
  chmod +x "$STUB_DIR/stub75"
  docker run -d --name "$C_75" \
    --tmpfs /data \
    -v "$STUB_DIR:/stub:ro" \
    -e ALPHACLAW_BIN=/stub/stub75 \
    -e SPIN_BRAKE_SECS=1 \
    -e SETUP_PASSWORD="supervise-e2e" \
    -e OPENCLAW_GATEWAY_TOKEN="supervise-e2e-token" \
    -e WEBHOOK_TOKEN="supervise-e2e" \
    "$IMAGE" >&2
  # Let several 75-cycles elapse (1s run + 1s brake each).
  sleep 10
}

teardown_file() {
  docker rm -f "$C_FAIL" "$C_75" >/dev/null 2>&1 || true
  [ -n "$STUB_DIR" ] && rm -rf "$STUB_DIR" || true
}

# --- rapid-failure path -------------------------------------------------------

@test "5 rapid failures land on the failure page with the Restart button" {
  run docker logs "$C_FAIL"
  grep -q "rapid failure 1/5" <<<"$output"
  grep -q "threshold reached" <<<"$output"
  BODY=$(curl -fsS "http://127.0.0.1:${PORT_FAIL}/")
  grep -q "AlphaClaw failed to start" <<<"$BODY"
  grep -q 'action="/restart"' <<<"$BODY"
}

@test "POST /restart resumes supervision and relaunches alphaclaw" {
  BEFORE=$(docker logs "$C_FAIL" 2>&1 | grep -c "threshold reached")
  run curl -fsS -X POST "http://127.0.0.1:${PORT_FAIL}/restart"
  [ "$status" -eq 0 ]
  grep -q "Restarting AlphaClaw" <<<"$output"
  # Supervisor logs the server exit, retries /bin/false, and re-enters
  # failure mode (a second threshold entry).
  for _ in $(seq 1 30); do
    AFTER=$(docker logs "$C_FAIL" 2>&1 | grep -c "threshold reached")
    [ "$AFTER" -gt "$BEFORE" ] && break
    sleep 1
  done
  [ "$AFTER" -gt "$BEFORE" ]
  docker logs "$C_FAIL" 2>&1 | grep -q "failure server exited"
}

@test "FAILURE_EPOCH survives the restart cycle: /health flips 503 on schedule" {
  # Grace is 15s anchored at the FIRST threshold entry. By now (post-restart
  # cycle) the epoch is old, so the relaunched failure server must answer 503
  # — if the anchor reset per-process, it would answer 200 for another 15s.
  CODE=000
  for _ in $(seq 1 45); do
    CODE=$(curl -sS -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PORT_FAIL}/health" 2>/dev/null || echo 000)
    [ "$CODE" = "503" ] && break
    sleep 2
  done
  [ "$CODE" = "503" ]
  docker logs "$C_FAIL" 2>&1 | grep -q "health grace period expired"
}

# --- exit-75 path ---------------------------------------------------------------

@test "exit 75 relaunches immediately and never reaches the failure page" {
  LOGS=$(docker logs "$C_75" 2>&1)
  [ "$(grep -c 'intentional restart' <<<"$LOGS")" -ge 3 ]
  # run + status: a bare non-final `! grep` is exempt from bats errexit and
  # would assert nothing.
  run grep -q "threshold reached" <<<"$LOGS"
  [ "$status" -ne 0 ]
  run grep -q "rapid failure" <<<"$LOGS"
  [ "$status" -ne 0 ]
  RUNNING=$(docker inspect -f '{{.State.Running}}' "$C_75")
  [ "$RUNNING" = "true" ]
}
