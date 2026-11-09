#!/usr/bin/env bats
#
# End-to-end tests for the baked tools: build the real image and prove, with
# the network DISABLED, that every pinned binary is present, runs, matches the
# pin manifest (baked-tools.env == /etc/baked-tools.env), resolves its shared
# libraries, and lives on the image PATH; that installing the tools enabled
# nothing (a credential-free boot reaches the setup UI with no tailscaled/
# caddy/monolith process and no tool port listening); that a reused /data
# volume is preserved (files intact, /data/tmp forced to 1777, boot log
# appended across a restart); that a corrupted checksum in baked-tools.env
# fails `docker build --target tools`; and that TERM teardown stays prompt.
#
# Overlaps docker.bats on boot/shutdown by design: those properties must hold
# against the tools-bearing image, and they are cheap.
#
# Negative checks use `run` + status: a bare non-final `! cmd` is exempt from
# bats errexit and asserts nothing.
#
# shellcheck disable=SC2016  # single-quoted Dockerfile/grep literals are intentional
#
# Slow (builds the image, boots two containers, runs one deliberately failing
# build). Run via `npm run test:e2e`. Skips cleanly when docker is unavailable.

IMAGE="openclaw-render-test:latest"
C_BOOT="openclaw-render-tools-e2e"
C_REUSE="openclaw-render-tools-reuse-e2e"
VOL_REUSE="openclaw-render-tools-reuse-data"
GATE_TAG="openclaw-render-tools-gate:tmp"
PORT_BOOT=13030
PORT_REUSE=13031

wait_health() { # port tries
  local port="$1" tries="${2:-60}"
  for _ in $(seq 1 "$tries"); do
    curl -fsS "http://127.0.0.1:${port}/health" >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

# Run a shell snippet in a throwaway container with NO network (tini runs sh,
# so the exit code propagates). Proves the tools need nothing at runtime.
offline() {
  docker run --rm --network none "$IMAGE" sh -c "$1"
}

setup_file() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export REPO IMAGE C_BOOT C_REUSE VOL_REUSE GATE_TAG PORT_BOOT PORT_REUSE

  command -v docker >/dev/null || skip "docker not installed"
  docker info >/dev/null 2>&1 || skip "docker daemon not running"

  docker build -t "$IMAGE" "$REPO" >&2
  echo "# tools e2e: image size $(docker image inspect -f '{{.Size}}' "$IMAGE") bytes" >&3

  # Pins come from the repo manifest, never hardcoded here.
  set -a
  # shellcheck disable=SC1091
  . "$REPO/baked-tools.env"
  set +a
  for k in CADDY_VERSION TAILSCALE_VERSION BUN_VERSION MONOLITH_VERSION PG_MAJOR; do
    [ -n "${!k}" ] || { echo "baked-tools.env is missing $k" >&2; return 1; }
  done
  ARCH="$(docker run --rm "$IMAGE" dpkg --print-architecture)"
  export ARCH

  docker rm -f "$C_BOOT" "$C_REUSE" >/dev/null 2>&1 || true
  docker volume rm -f "$VOL_REUSE" >/dev/null 2>&1 || true

  # --- credential-free boot: only the env vars render.yaml sets (SETUP_PASSWORD, the
  # two generated tokens, PORT), empty /data.
  docker run -d --name "$C_BOOT" \
    --tmpfs /data \
    -p "${PORT_BOOT}:3000" \
    -e PORT=3000 \
    -e SETUP_PASSWORD="tools-e2e" \
    -e OPENCLAW_GATEWAY_TOKEN="tools-e2e-token" \
    -e WEBHOOK_TOKEN="tools-e2e" \
    "$IMAGE" >&2
  wait_health "$PORT_BOOT" 60 || { echo "boot container never healthy; logs:" >&2; docker logs "$C_BOOT" >&2; return 1; }

  # --- reused /data: a named volume seeded like a disk from a previous deploy
  # (a file to keep, a non-sticky tmp dir, an existing boot log line).
  docker volume create "$VOL_REUSE" >/dev/null
  docker run --rm -v "$VOL_REUSE:/data" "$IMAGE" sh -c \
    'echo keep > /data/keep.txt && mkdir -p /data/tmp && chmod 0755 /data/tmp && echo "=== boot 1970-01-01T00:00:00Z (seeded) ===" > /data/start.log' >&2
  docker run -d --name "$C_REUSE" \
    -v "$VOL_REUSE:/data" \
    -p "${PORT_REUSE}:3000" \
    -e PORT=3000 \
    -e SETUP_PASSWORD="tools-e2e" \
    -e OPENCLAW_GATEWAY_TOKEN="tools-e2e-token" \
    -e WEBHOOK_TOKEN="tools-e2e" \
    "$IMAGE" >&2
  wait_health "$PORT_REUSE" 60 || { echo "reuse container never healthy; logs:" >&2; docker logs "$C_REUSE" >&2; return 1; }
}

teardown_file() {
  docker rm -f "$C_BOOT" "$C_REUSE" >/dev/null 2>&1 || true
  docker volume rm -f "$VOL_REUSE" >/dev/null 2>&1 || true
  docker image rm -f "$GATE_TAG" >/dev/null 2>&1 || true
}

# --- manifest ------------------------------------------------------------------

@test "manifest: /etc/baked-tools.env in the image is byte-identical to the repo's baked-tools.env" {
  run docker run --rm --network none "$IMAGE" cat /etc/baked-tools.env
  [ "$status" -eq 0 ]
  [ "$output" = "$(cat "$REPO/baked-tools.env")" ]
}

# --- each tool, offline ----------------------------------------------------------

@test "caddy: pinned version, validates a Caddyfile offline without serving anything" {
  run offline 'caddy version'
  [ "$status" -eq 0 ]
  [ "${output%% *}" = "v${CADDY_VERSION}" ]
  run offline 'printf ":8080\nrespond ok\n" > /c.caddyfile && caddy validate --adapter caddyfile --config /c.caddyfile'
  [ "$status" -eq 0 ]
  grep -q 'Valid configuration' <<<"$output"
}

@test "tailscale + tailscaled: pinned version, both on PATH" {
  run offline 'tailscale version | head -n1'
  [ "$status" -eq 0 ]
  [ "$output" = "$TAILSCALE_VERSION" ]
  run offline 'tailscaled --version 2>&1 | head -n1'
  [ "$status" -eq 0 ]
  [ "$output" = "$TAILSCALE_VERSION" ]
  run offline 'command -v tailscale && command -v tailscaled'
  [ "$status" -eq 0 ]
  [ "$output" = $'/usr/local/bin/tailscale\n/usr/local/bin/tailscaled' ]
}

@test "bun + bunx: pinned version, relative symlink, executes JavaScript offline" {
  run offline 'bun --version'
  [ "$status" -eq 0 ]
  [ "$output" = "$BUN_VERSION" ]
  run offline 'bunx --version'
  [ "$status" -eq 0 ]
  [ "$output" = "$BUN_VERSION" ]
  run offline 'readlink /usr/local/bin/bunx'
  [ "$output" = "bun" ]
  run offline "bun -e 'console.log(6*7)'"
  [ "$status" -eq 0 ]
  [ "$output" = "42" ]
}

@test "monolith: pinned version, archives a local page offline" {
  run offline 'monolith --version'
  [ "$status" -eq 0 ]
  [ "$output" = "monolith ${MONOLITH_VERSION}" ]
  run offline 'printf "<html><head><title>t</title></head><body><p>hello</p></body></html>" > /x.html && monolith -I -q /x.html'
  [ "$status" -eq 0 ]
  grep -q '<html' <<<"$output"
  grep -q 'hello' <<<"$output"
}

@test "PostgreSQL client: psql/pg_dump/pg_restore are major \$PG_MAJOR in the Debian layout, no server" {
  for b in psql pg_dump pg_restore; do
    run offline "$b --version"
    [ "$status" -eq 0 ]
    grep -qF "(PostgreSQL) ${PG_MAJOR}." <<<"$output"
    run offline "test -x /usr/lib/postgresql/${PG_MAJOR}/bin/$b"
    [ "$status" -eq 0 ]
  done
  run offline 'command -v psql'
  [ "$output" = "/usr/bin/psql" ]
  # dpkg -s (not dpkg-query -W): -W exits 0 for any name the database has
  # heard of, and postgresql-client-N *Suggests* the server package.
  run offline "dpkg -s postgresql-client-${PG_MAJOR}"
  [ "$status" -eq 0 ]
  run offline "test -e /usr/lib/postgresql/${PG_MAJOR}/bin/postgres"
  [ "$status" -ne 0 ]
  run offline "dpkg -s postgresql-${PG_MAJOR}"
  [ "$status" -ne 0 ]
}

@test "git-lfs: installed system-wide and functional (a tracked file lands in .git/lfs/objects)" {
  run offline 'git lfs version'
  [ "$status" -eq 0 ]
  grep -q 'git-lfs/' <<<"$output"
  run offline 'git config --system filter.lfs.process'
  [ "$output" = "git-lfs filter-process" ]
  run offline 'set -e; mkdir /r; cd /r; { git init -q; git lfs track "*.bin"; head -c 64 /dev/urandom > a.bin; git add .; git -c user.email=t@e -c user.name=t commit -qm x; } >/dev/null 2>&1; find .git/lfs/objects -type f | wc -l'
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "support tools: jq, openssl, ca-certificates, flock (util-linux), fuser (psmisc) work offline" {
  run offline "echo '{\"a\":1}' | jq -e .a"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  run offline 'openssl rand -hex 4'
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9a-f]{8}$ ]]
  run offline 'openssl version'
  [ "$status" -eq 0 ]
  grep -q '^OpenSSL 3' <<<"$output"
  run offline 'test -s /etc/ssl/certs/ca-certificates.crt'
  [ "$status" -eq 0 ]
  run offline 'flock -n /e2e.lock true && flock --version'
  [ "$status" -eq 0 ]
  grep -q 'util-linux' <<<"$output"
  run offline 'fuser -V 2>&1'
  [ "$status" -eq 0 ]
  grep -qi 'psmisc' <<<"$output"
}

@test "PDF tools and CJK fonts: pdftotext, pdfinfo and Noto Sans CJK work offline" {
  run offline 'pdftotext -v 2>&1 && pdfinfo -v 2>&1'
  [ "$status" -eq 0 ]
  grep -q 'pdftotext version' <<<"$output"
  grep -q 'pdfinfo version' <<<"$output"
  run offline 'fc-list :lang=ja family'
  [ "$status" -eq 0 ]
  grep -qF 'Noto Sans CJK JP' <<<"$output"
}

@test "ffmpeg and ffprobe encode and probe audio offline" {
  run offline 'ffmpeg -hide_banner -version | head -1; ffprobe -hide_banner -version | head -1'
  [ "$status" -eq 0 ]
  grep -q '^ffmpeg version ' <<<"$output"
  grep -q '^ffprobe version ' <<<"$output"
  for pair in libmp3lame:mp3 libopus:opus aac:aac; do
    enc="${pair%%:*}" want="${pair##*:}"
    run offline "d=\$(mktemp -d) && ffmpeg -hide_banner -loglevel error -f lavfi -i sine=frequency=440:duration=1 -c:a $enc \$d/a.mka && ffprobe -v error -show_entries stream=codec_name -of csv=p=0 \$d/a.mka"
    [ "$status" -eq 0 ] || { echo "$enc encode failed: $output"; false; }
    [ "$output" = "$want" ] || { echo "$enc probed as: $output"; false; }
  done
}

@test "archive, search and database tools work offline" {
  run offline 'set -e; d=$(mktemp -d); cd "$d"; printf "hello baked tools\n" > a.txt
    zstd -q a.txt -o a.zst && zstd -dqc a.zst | grep -qx "hello baked tools"
    xz -kc a.txt > a.xz && xz -dc a.xz | grep -qx "hello baked tools"
    zip -q a.zip a.txt && mkdir x && unzip -q a.zip -d x && cmp a.txt x/a.txt
    rg -q "baked" a.txt
    sqlite3 db.sqlite "create table t(v); insert into t values (40),(2); select sum(v) from t;"'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = "42" ]
}

@test "imagemagick converts PNG to JPEG offline and its policy still refuses PDF" {
  run offline 'set -e; d=$(mktemp -d); convert -size 8x8 xc:red "$d/a.png" && convert "$d/a.png" "$d/a.jpg" && identify -format "%m" "$d/a.jpg"'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = "JPEG" ]
  # Debian's policy.xml forbids the PDF/PS coders (Ghostscript attack surface); keep it.
  run offline 'd=$(mktemp -d); printf "%%PDF-1.4\n" > "$d/a.pdf"; convert "$d/a.pdf" "$d/a.png"'
  [ "$status" -ne 0 ]
  grep -qF 'not allowed by the security policy `PDF'"'" <<<"$output" || { echo "$output"; false; }
}

@test "Chrome's runtime libraries are installed and every shared object they ship resolves" {
  run offline 'for p in libatk1.0-0 libatk-bridge2.0-0 libcups2 libxcomposite1 libxdamage1 libatspi2.0-0 libnss3 libnspr4 libgbm1 libxkbcommon0 libxrandr2 libasound2 libpango-1.0-0 libcairo2; do dpkg -s "$p" 2>/dev/null | grep -qx "Status: install ok installed" || echo "missing $p"; done'
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { echo "$output"; false; }
  run offline 'for p in libatk1.0-0 libatk-bridge2.0-0 libcups2 libxcomposite1 libxdamage1 libatspi2.0-0 libnss3 libnspr4 libgbm1 libxkbcommon0 libxrandr2 libasound2 libpango-1.0-0 libcairo2; do dpkg -L "$p" | grep -E "[.]so([.][0-9]+)*$" | while read -r f; do [ -f "$f" ] && [ ! -L "$f" ] && ldd "$f" 2>&1 | sed "s|^|$f: |"; done; done; true'
  [ "$status" -eq 0 ]
  [ "$(grep -c '=>' <<<"$output")" -gt 0 ] || { echo "no libraries checked: $output"; false; }
  run grep 'not found' <<<"$output"
  [ "$status" -ne 0 ] || { echo "unresolved: $output"; false; }
}

@test "retained utilities: the original toolset is still present and tmux runs" {
  run offline 'for b in git curl python3 make g++ cron vim screen node npm claude openclaw alphaclaw; do command -v "$b" >/dev/null || { echo "missing $b"; exit 1; }; done; tmux -V'
  [ "$status" -eq 0 ]
  grep -q '^tmux ' <<<"$output"
}

@test "build tooling and service scaffolding never reach the runtime image" {
  for p in gpg cargo rustc; do
    run offline "command -v $p"
    [ "$status" -ne 0 ]
  done
  for f in /root/.gnupg /etc/systemd/system/tailscaled.service /lib/systemd/system/tailscaled.service \
           /etc/default/tailscaled /etc/caddy /var/lib/tailscale /opt/pg.env /opt/baked-tools.env /out; do
    run offline "test -e $f"
    [ "$status" -ne 0 ]
  done
}

# --- architecture + shared libraries -------------------------------------------------

@test "architecture is consistent and every baked binary's shared libraries resolve" {
  [[ "$ARCH" =~ ^(amd64|arm64)$ ]]
  run offline 'uname -m'
  case "$ARCH:$output" in
    amd64:x86_64|arm64:aarch64) ;;
    *) echo "arch mismatch: dpkg=$ARCH uname=$output"; false ;;
  esac
  for bin in /usr/local/bin/bun /usr/local/bin/monolith /usr/local/bin/caddy /usr/local/bin/tailscale \
             /usr/local/bin/tailscaled "/usr/lib/postgresql/${PG_MAJOR}/bin/psql" \
             "/usr/lib/postgresql/${PG_MAJOR}/bin/pg_dump" "/usr/lib/postgresql/${PG_MAJOR}/bin/pg_restore" \
             /usr/bin/git-lfs /usr/bin/jq /usr/bin/ffmpeg /usr/bin/ffprobe /usr/bin/zstd /usr/bin/unzip \
             /usr/bin/zip /usr/bin/xz /usr/bin/sqlite3 /usr/bin/rg /usr/bin/convert; do
    run offline "test -x $bin"
    [ "$status" -eq 0 ] || { echo "$bin is missing or not executable"; false; }
    run offline "ldd $bin 2>&1; true"
    out="$output"
    if grep -q 'not a dynamic executable' <<<"$out"; then
      continue   # static Go binary — nothing to resolve
    fi
    run grep 'not found' <<<"$out"
    [ "$status" -ne 0 ] || { echo "$bin has unresolved libraries: $out"; false; }
  done
}

@test "PATH and shims: the app bin dir still wins and the belt-and-suspenders shims are intact" {
  run offline 'command -v openclaw'
  [ "$output" = "/app/node_modules/.bin/openclaw" ]
  run offline 'readlink /usr/local/bin/openclaw'
  [ "$output" = "/app/node_modules/.bin/openclaw" ]
  run offline 'readlink /usr/local/bin/alphaclaw'
  [ "$output" = "/app/node_modules/.bin/alphaclaw" ]
  run offline 'test -x /usr/bin/openclaw && test -x /usr/bin/alphaclaw && test -x /usr/bin/claude'
  [ "$status" -eq 0 ]
  run offline 'echo "$PATH"'
  [[ "$output" == /app/node_modules/.bin:* ]]
}

# --- the checksum gate really fails the build --------------------------------------

@test "checksum gate: a corrupted pin in baked-tools.env fails docker build --target tools" {
  ctx="$BATS_TEST_TMPDIR/gate-ctx"
  mkdir -p "$ctx"
  cp "$REPO/Dockerfile" "$REPO/.dockerignore" "$ctx/"
  # Flip the last hex digit of BOTH arch checksums so the gate trips on any
  # build host. No `sed -i`: GNU takes an optional suffix but BSD/macOS sed
  # consumes the next arg (-E) as the suffix and falls back to BRE, silently
  # corrupting nothing — write the mutated copy to the context instead.
  sed -E \
    -e 's/^(CADDY_SHA512_(AMD64|ARM64)=[0-9a-f]{127})0$/\1__Z__/' \
    -e 's/^(CADDY_SHA512_(AMD64|ARM64)=[0-9a-f]{127})[1-9a-f]$/\10/' \
    -e 's/__Z__$/1/' "$REPO/baked-tools.env" >"$ctx/baked-tools.env"
  run cmp -s "$REPO/baked-tools.env" "$ctx/baked-tools.env"
  [ "$status" -ne 0 ]
  run docker build --progress=plain --target tools -t "$GATE_TAG" "$ctx"
  [ "$status" -ne 0 ]
  # The specific verifier line, not just "sha512sum" (which BuildKit echoes
  # from the RUN text on ANY failure of that step).
  grep -qF 'caddy.tgz: FAILED' <<<"$output"
  run grep -q 'curl: (' <<<"$output"                 # …and not a download error in disguise
  [ "$status" -ne 0 ]
}

# --- credential-free boot: installing enabled nothing -----------------------------

@test "credential-free boot: /health 200, setup UI settles to 200, no Tailscale/Caddy env" {
  run curl -fsS "http://127.0.0.1:${PORT_BOOT}/health"
  [ "$status" -eq 0 ]
  CODE=000
  for _ in $(seq 1 30); do
    CODE=$(curl -sSL -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PORT_BOOT}/" || echo 000)
    [ "$CODE" = "200" ] && break
    sleep 2
  done
  [ "$CODE" = "200" ]
  run docker exec "$C_BOOT" printenv
  [ "$status" -eq 0 ]
  ENV_OUT="$output"
  run grep -E '^(TS_AUTHKEY|TAILSCALE_AUTHKEY|TS_[A-Z_]+|CADDY_[A-Z_]*)=' <<<"$ENV_OUT"
  [ "$status" -ne 0 ]
}

@test "no tool daemon runs and no tool port listens after boot" {
  run docker exec "$C_BOOT" pgrep -x tini        # positive control: pgrep sees PID 1
  [ "$status" -eq 0 ]
  for p in tailscaled caddy monolith; do
    run docker exec "$C_BOOT" pgrep -x "$p"
    [ "$status" -ne 0 ]
  done
  # Listening sockets (state 0A) from both stacks, hex ports decoded here.
  run docker exec "$C_BOOT" awk '$4=="0A"{split($2,a,":"); print a[2]}' /proc/net/tcp /proc/net/tcp6
  [ "$status" -eq 0 ]
  ports=""
  for h in $output; do ports="$ports $((16#$h))"; done
  echo "listening ports:$ports" >&2
  grep -qw 3000 <<<"$ports"                       # positive control: the parse works
  for p in 80 443 2019 41641 5432; do              # tool ports must be silent
    run grep -qw "$p" <<<"$ports"
    [ "$status" -ne 0 ]
  done
}

@test "no duplicate services: exactly one supervisor and at most one alphaclaw" {
  run docker exec "$C_BOOT" pgrep -fc '^/bin/bash /start.sh$'
  [ "$output" = "1" ]
  count=$(docker exec "$C_BOOT" pgrep -fc 'alphaclaw start' || true)
  [ "${count:-0}" -le 1 ]
}

@test "cron: alphaclaw's own cron is untouched and references none of the baked tools" {
  # alphaclaw installs /etc/cron.d/openclaw-hourly-sync itself and starts cron —
  # expected. What must not exist is any schedule for the tools we baked.
  run docker exec "$C_BOOT" sh -c 'cat /etc/crontab /etc/cron.d/* 2>/dev/null; crontab -l 2>/dev/null; true'
  [ "$status" -eq 0 ]
  CRON="$output"
  run grep -Ew 'caddy|tailscale|tailscaled|monolith|bun|bunx|psql|pg_dump|pg_restore' <<<"$CRON"
  [ "$status" -ne 0 ]
}

# --- reused /data ------------------------------------------------------------------

@test "reused /data: existing files survive, /data/tmp is forced to 1777, the boot log is appended" {
  run docker exec "$C_REUSE" cat /data/keep.txt
  [ "$output" = "keep" ]
  run docker exec "$C_REUSE" stat -c '%a' /data/tmp
  [ "$output" = "1777" ]
  run docker exec "$C_REUSE" grep -c '=== boot' /data/start.log
  [ "$output" -ge 2 ]
  run docker exec "$C_REUSE" grep -c '(seeded)' /data/start.log
  [ "$output" = "1" ]
}

@test "reused /data: a restart appends another boot and keeps the state" {
  before=$(docker exec "$C_REUSE" grep -c '=== boot' /data/start.log)
  docker restart "$C_REUSE" >/dev/null
  wait_health "$PORT_REUSE" 60
  run docker exec "$C_REUSE" grep -c '=== boot' /data/start.log
  [ "$output" -gt "$before" ]
  run docker exec "$C_REUSE" cat /data/keep.txt
  [ "$output" = "keep" ]
  run docker exec "$C_REUSE" stat -c '%a' /data/tmp
  [ "$output" = "1777" ]
}

# Keep this LAST: it stops the boot container.
@test "TERM stops the tools-bearing container promptly (tini -g reaches every process)" {
  START=$(date +%s)
  docker stop -t 15 "$C_BOOT"
  DUR=$(( $(date +%s) - START ))
  [ "$DUR" -lt 14 ]
  EC=$(docker inspect -f '{{.State.ExitCode}}' "$C_BOOT")
  [ "$EC" != "137" ]
}
