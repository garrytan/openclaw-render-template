#!/usr/bin/env bats
#
# End-to-end test: build the real image, run it the way Render does, and assert
# the container actually stays Live and satisfies every documented invariant.
#
# Key trick: we mount a tmpfs over /data so it starts EMPTY, exactly like
# Render's runtime disk mount — which shadows the Dockerfile's build-time
# `mkdir /data/tmp`. If /data/tmp still exists afterwards, start.sh recreated it
# on boot (the load-bearing behavior in CLAUDE.md).
#
# Slow (builds an image, pulls alphaclaw). Not part of `npm test`; run via
# `npm run test:e2e`. Skips cleanly when docker is unavailable.

IMAGE="openclaw-render-test:latest"
CONTAINER="openclaw-render-e2e"
HOST_PORT=13000
SENTINEL="SENTINEL-SECRET-DO-NOT-LEAK-9f3a2b"

setup_file() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export REPO IMAGE CONTAINER HOST_PORT SENTINEL

  command -v docker >/dev/null || skip "docker not installed"
  docker info >/dev/null 2>&1 || skip "docker daemon not running"

  docker build -t "$IMAGE" "$REPO" >&2
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true

  # --tmpfs /data => empty /data at runtime, mimicking Render's disk mount.
  docker run -d --name "$CONTAINER" \
    --tmpfs /data \
    -p "${HOST_PORT}:3000" \
    -e PORT=3000 \
    -e SETUP_PASSWORD="$SENTINEL" \
    -e OPENCLAW_GATEWAY_TOKEN="$SENTINEL" \
    -e WEBHOOK_TOKEN="$SENTINEL" \
    "$IMAGE" >&2

  # Wait up to ~120s for /health to answer 200 (alphaclaw OR the failure server).
  for _ in $(seq 1 60); do
    if curl -fsS "http://127.0.0.1:${HOST_PORT}/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  echo "container never became healthy; logs follow:" >&2
  docker logs "$CONTAINER" >&2 || true
  return 1
}

teardown_file() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
}

# Helper: run a command inside the running container. Non-login shell on
# purpose — a login shell re-sources /etc/profile and resets PATH, which would
# mask the image's ENV PATH (the very thing alphaclaw inherits and we test).
in_container() {
  docker exec "$CONTAINER" sh -c "$1"
}

@test "container stays Live: /health returns 200" {
  run curl -fsS "http://127.0.0.1:${HOST_PORT}/health"
  [ "$status" -eq 0 ]
}

@test "openclaw resolves on PATH and runs" {
  in_container 'command -v openclaw && openclaw --version'
}

@test "alphaclaw and claude resolve on PATH" {
  in_container 'command -v alphaclaw'
  in_container 'command -v claude'
}

@test "PATH includes /app/node_modules/.bin" {
  in_container 'echo "$PATH"' | grep -q '/app/node_modules/.bin'
}

@test "TMPDIR env points at /data/tmp" {
  run in_container 'printenv TMPDIR'
  [ "$status" -eq 0 ]
  [ "$output" = "/data/tmp" ]
}

@test "start.sh recreated /data/tmp (sticky bit) despite empty disk mount" {
  in_container 'test -d /data/tmp'
  in_container 'test -k /data/tmp'
}

@test "debug/runtime tooling is baked in" {
  # tmux is executed (not just located): alphaclaw's rescue-session probe is
  # `tmux -V` succeeding, so presence alone isn't the property that matters.
  in_container 'command -v git && command -v curl && command -v vim && command -v screen && tmux -V'
}

@test "tini is PID 1" {
  in_container 'cat /proc/1/comm' | grep -q tini
}

@test "SECURITY: landing page settles to 200 and never leaks env secrets" {
  # alphaclaw 0.9.36+ answers / with a brief 503 ("AlphaClaw is updating")
  # right after /health comes up, then a 302 to /login.html in steady state.
  # The invariant is about the publicly reachable landing surface: it must
  # settle to 200 (following redirects) and no response along the way —
  # 503 body, redirect target, or final page — may contain env secrets.
  BODY="$BATS_TEST_TMPDIR/root-body"
  CODE="000"
  for _ in $(seq 1 30); do
    CODE=$(curl -sSL -o "$BODY" -w "%{http_code}" "http://127.0.0.1:${HOST_PORT}/" || echo 000)
    # Enforcing form — a bare non-final `! grep` is exempt from bats errexit
    # and would let an intermediate (503/redirect) leak slip through silently.
    if grep -q "$SENTINEL" "$BODY"; then
      echo "secret sentinel leaked in response (code $CODE)"; false
    fi
    [ "$CODE" = "200" ] && break
    sleep 2
  done
  [ "$CODE" = "200" ]
  ! grep -q "$SENTINEL" "$BODY"
}

# Keep this LAST: it stops the shared container.
@test "TERM stops the container promptly (tini -g reaches every process)" {
  # With tini -g, a TERM to PID 1 hits the whole process group directly. If
  # any process ignored it, docker would SIGKILL at t=15 and the container's
  # exit code would be 137 — so fast stop + non-137 proves teardown.
  START=$(date +%s)
  docker stop -t 15 "$CONTAINER"
  DUR=$(( $(date +%s) - START ))
  [ "$DUR" -lt 14 ]
  EC=$(docker inspect -f '{{.State.ExitCode}}' "$CONTAINER")
  [ "$EC" != "137" ]
}
