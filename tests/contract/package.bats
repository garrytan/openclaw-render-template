#!/usr/bin/env bats
#
# Contract tests for package.json's alphaclaw git dependency. Static assertions
# that the dependency-spec invariants documented in CLAUDE.md / AGENTS.md stay
# in place.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  ALPHACLAW_SPEC="$(node -e 'console.log(require(process.argv[1]).dependencies.alphaclaw)' "$REPO/package.json")"
}

@test "package.json: alphaclaw is a git+https dependency on garrytan/alphaclaw" {
  # https (not ssh, not the github: shorthand): the node:24-bookworm-slim Docker build
  # has no SSH key, so the spec must fetch anonymously over HTTPS.
  [[ "$ALPHACLAW_SPEC" =~ ^git\+https://github\.com/garrytan/alphaclaw\.git# ]]
}

@test "package.json: alphaclaw is pinned to a full commit SHA, not a branch" {
  # A moving ref like #main never changes package.json, so the Docker layer
  # cache (locally and on Render) keeps reusing the stale npm-install layer and
  # alphaclaw updates silently never ship. Pinning the SHA makes every update
  # an explicit edit that busts the cache.
  [[ "$ALPHACLAW_SPEC" =~ \#[0-9a-f]{40}$ ]]
}
