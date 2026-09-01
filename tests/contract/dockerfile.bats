#!/usr/bin/env bats
#
# Contract tests for the Dockerfile + render.yaml. Static assertions that the
# image-layer invariants documented in CLAUDE.md / AGENTS.md stay in place.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
}

# --- PATH fix (primary + belt-and-suspenders shims) ---------------------------

@test "Dockerfile: sets PATH so /app/node_modules/.bin wins" {
  grep -Eq 'ENV PATH="/app/node_modules/\.bin:\$PATH"' "$REPO/Dockerfile"
}

@test "Dockerfile: installs openclaw + alphaclaw shims into /usr/bin" {
  grep -q '/usr/bin/openclaw' "$REPO/Dockerfile"
  grep -q '/usr/bin/alphaclaw' "$REPO/Dockerfile"
}

# --- TMPDIR onto the persistent disk ------------------------------------------

@test "Dockerfile: sets TMPDIR/TEMP/TMP env to /data/tmp" {
  grep -q 'ENV TMPDIR=/data/tmp' "$REPO/Dockerfile"
  grep -q 'ENV TEMP=/data/tmp'   "$REPO/Dockerfile"
  grep -q 'ENV TMP=/data/tmp'    "$REPO/Dockerfile"
}

@test "Dockerfile: creates /data/tmp with the sticky bit" {
  grep -Eq 'mkdir -p /data/tmp && chmod 1777 /data/tmp' "$REPO/Dockerfile"
}

@test "Dockerfile: never redirects bare /tmp (mentions only in comments)" {
  # Only /data/tmp is added; bare /tmp must never be a build instruction target.
  while IFS= read -r line; do
    [[ "$line" =~ ^[0-9]+:[[:space:]]*# ]] || { echo "non-comment /tmp use: $line"; false; }
  done < <(grep -nw '/tmp' "$REPO/Dockerfile")
}

# --- tmux (rescue-session hosting) ---------------------------------------------

@test "Dockerfile: installs tmux (rescue-session hosting)" {
  # alphaclaw's local Claude Code rescue sessions probe for tmux (`tmux -V`);
  # without it they degrade to script(1) hosting and die with every alphaclaw
  # restart. Portable delimiters, no \b — BSD grep doesn't reliably support it.
  grep -Eq 'apt-get install[^&]* tmux( |$)' "$REPO/Dockerfile"
}

@test "CI workflow: installs tmux so the rescue-survival test can never silently skip" {
  # supervise.bats skips its tmux-survival test when the host lacks tmux, and
  # bats reports skips as green — so CI must install tmux explicitly or the
  # survival property goes unproven while CI stays green. Same delimiter
  # rationale as above (no \b).
  grep -Eq 'apt-get install[^&]* tmux( |$)' "$REPO/.github/workflows/test.yml"
}

@test "Dockerfile: pins @anthropic-ai/claude-code to an exact version" {
  # Unpinned, this install floats to latest whenever an earlier layer changes
  # (e.g. an apt edit), silently shipping an unreviewed claude-code — the same
  # failure mode the alphaclaw SHA pin exists to prevent.
  grep -Eq 'npm install -g @anthropic-ai/claude-code@[0-9]+\.[0-9]+\.[0-9]+' "$REPO/Dockerfile"
}

# --- Init + entrypoint --------------------------------------------------------

@test "Dockerfile: uses tini -g as PID 1 (group signaling)" {
  # -g is load-bearing: the supervise loop in start.sh is a plain foreground
  # loop with no traps; prompt TERM delivery to alphaclaw/tee/sleep relies on
  # tini signaling the whole process group.
  grep -Eq 'ENTRYPOINT \["/usr/bin/tini", "-g", "--"\]' "$REPO/Dockerfile"
}

@test "Dockerfile: CMD boots via start.sh" {
  grep -Eq 'CMD \["/start.sh"\]' "$REPO/Dockerfile"
}

@test "Dockerfile: exposes port 3000" {
  grep -q 'EXPOSE 3000' "$REPO/Dockerfile"
}

@test "Dockerfile: points ALPHACLAW_ROOT_DIR at the persistent disk" {
  grep -q 'ENV ALPHACLAW_ROOT_DIR=/data' "$REPO/Dockerfile"
}

# --- Render blueprint ---------------------------------------------------------

@test "render.yaml: health check is /health" {
  grep -q 'healthCheckPath: /health' "$REPO/render.yaml"
}

@test "render.yaml: mounts a persistent disk at /data" {
  grep -q 'mountPath: /data' "$REPO/render.yaml"
}
