#!/usr/bin/env bats
#
# Contract tests for the baked tools (Caddy, Tailscale, Bun, monolith, the
# PostgreSQL client, git-lfs, jq + support packages). Static assertions that
# lock in the pin manifest (baked-tools.env), the Dockerfile stage layout and
# layer order, the "verify every download / never ARG / never start a daemon"
# rules, the allowlist .dockerignore, and the doc invariants CLAUDE.md
# documents under "Baked tools". Runs in `npm test` (no Docker); the
# behavioral counterpart is tests/e2e/tools.bats.
#
# Negative checks use `run` + status: a bare non-final `! cmd` is exempt from
# bats errexit and asserts nothing.
#
# shellcheck disable=SC2016,SC1003  # single-quoted Dockerfile/grep literals (incl. trailing backslashes) are intentional

# Command-position launch of a daemon or tailnet: line start (with optional
# RUN), after ; & | ( {, or after exec/nohup/setsid/then/do/else/timeout N,
# optionally via a full path. Argument positions such as
# `install -m 0755 tailscaled …` or `test -x …/tailscaled` do not match.
# The static guard catches straightforward additions; the runtime property is
# proven by the e2e process checks.
DAEMON_ERE='(^[[:space:]]*(RUN[[:space:]]+)?|[;&|({][[:space:]]*|(exec|nohup|setsid|then|do|else|timeout[[:space:]]+[0-9smh.]+)[[:space:]]+)(/[^[:space:]]*/)?(tailscaled|tailscale[[:space:]]+(up|serve|funnel|set|login)|caddy[[:space:]]+(run|start|reverse-proxy|file-server))([[:space:];&|)]|$)'
# Command-position curl (a flagless `curl URL` counts; `apt-get install … curl` does not).
CURL_CMD_ERE='(^[[:space:]]*(RUN[[:space:]]+)?|[;&|({][[:space:]]*|(exec|nohup|then|do|else)[[:space:]]+)curl([[:space:]]|$)'

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  DF="$REPO/Dockerfile"
  ENVF="$REPO/baked-tools.env"
  IGN="$REPO/.dockerignore"
  DF_CODE="$(grep -vE '^[[:space:]]*#' "$DF")"
}

# Text of a named stage: from its `FROM … AS <name>` line up to the next FROM.
stage_text() {
  awk -v name="$1" '/^FROM /{ inst = ($0 ~ (" AS " name "$")) } inst' "$DF"
}
# Text of the final (unnamed) stage.
final_text() {
  awk '/^FROM /{ inst = ($0 !~ / AS /) } inst' "$DF"
}
# Line number of the first Dockerfile line matching an ERE.
line_of() {
  grep -nE -- "$1" "$DF" | head -1 | cut -d: -f1
}
env_value() { sed -nE "s/^$1=(.*)$/\1/p" "$ENVF"; }

# --- baked-tools.env: the pin manifest ----------------------------------------

@test "baked-tools.env: only comments, blank lines, and KEY=value lines" {
  run grep -vE '^(#|$|[A-Z][A-Z0-9_]*=[^[:space:]]+$)' "$ENVF"
  [ "$status" -ne 0 ]
}

@test "baked-tools.env: every *_VERSION is a concrete release, never latest" {
  n=0
  while IFS='=' read -r k v; do
    [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "$k=$v is not a concrete x.y.z version"; false; }
    n=$((n + 1))
  done < <(grep -E '^[A-Z0-9_]+_VERSION=' "$ENVF")
  [ "$n" -ge 4 ]
  run grep -i latest "$ENVF"
  [ "$status" -ne 0 ]
}

@test "baked-tools.env: checksums, the monolith rev and PG_MAJOR have the right shape" {
  while IFS='=' read -r k v; do
    [[ "$v" =~ ^[0-9a-f]{64}$ ]] || { echo "$k is not 64 hex"; false; }
  done < <(grep -E '^[A-Z0-9_]+_SHA256_[A-Z0-9]+=' "$ENVF")
  while IFS='=' read -r k v; do
    [[ "$v" =~ ^[0-9a-f]{128}$ ]] || { echo "$k is not 128 hex"; false; }
  done < <(grep -E '^[A-Z0-9_]+_SHA512_[A-Z0-9]+=' "$ENVF")
  [ "$(grep -cE '^[A-Z0-9_]+_SHA256_' "$ENVF")" -ge 4 ]
  [ "$(grep -cE '^[A-Z0-9_]+_SHA512_' "$ENVF")" -ge 2 ]
  [[ "$(env_value MONOLITH_REV)" =~ ^[0-9a-f]{40}$ ]]
  [[ "$(env_value PG_MAJOR)" =~ ^[0-9]+$ ]]
}

@test "baked-tools.env: every key is consumed by the Dockerfile (no dead configuration)" {
  while IFS='=' read -r k _; do
    grep -Eq "\\\$\{?${k}([^A-Z0-9_]|\}|$)" "$DF" || { echo "$k is defined but never used"; false; }
  done < <(grep -E '^[A-Z][A-Z0-9_]*=' "$ENVF")
}

# --- Dockerfile stages ----------------------------------------------------------

@test "Dockerfile: stages pins, tools, monolith-build + a node:22-slim final stage" {
  grep -qxF 'FROM node:22-slim AS pins' "$DF"
  grep -qxF 'FROM node:22-slim AS tools' "$DF"
  grep -qE '^FROM rust:[0-9]+\.[0-9]+\.[0-9]+-slim-bookworm@sha256:[0-9a-f]{64} AS monolith-build$' "$DF"
  grep -qxF 'FROM node:22-slim' "$DF"
  [ "$(grep -c '^FROM ' "$DF")" -eq 4 ]
  # Node 22 stays the runtime: no other base sneaks in
  run grep -E '^FROM (node:(1[0-9]|2[013-9]|[3-9][0-9])|debian|ubuntu|alpine)' "$DF"
  [ "$status" -ne 0 ]
}

@test "Dockerfile: every stage consumes the pin manifest (whole or split) instead of hardcoding versions" {
  stage_text pins | grep -qF 'COPY baked-tools.env /baked-tools.env'
  stage_text pins | grep -qF "grep '^MONOLITH_' /baked-tools.env > /monolith.env"
  stage_text pins | grep -qF "grep '^PG_MAJOR=' /baked-tools.env > /pg.env"
  stage_text tools | grep -qF 'COPY baked-tools.env /opt/baked-tools.env'
  stage_text tools | grep -qF '. /opt/baked-tools.env;'
  stage_text tools | grep -qF 'install -m 0644 /opt/baked-tools.env /out/etc/baked-tools.env'
  stage_text monolith-build | grep -qF 'COPY --from=pins /monolith.env /monolith.env'
  stage_text monolith-build | grep -qF '. /monolith.env;'
  final_text | grep -qF 'COPY --from=pins /pg.env /opt/pg.env'
  final_text | grep -qF '. /opt/pg.env;'
  final_text | grep -qF '. /etc/baked-tools.env;'
}

@test "Dockerfile: monolith is built from the pinned git rev with --locked" {
  stage_text monolith-build | grep -qF 'cargo install --git https://github.com/Y2Z/monolith --rev "$MONOLITH_REV" --locked'
  stage_text monolith-build | grep -qF '= "monolith ${MONOLITH_VERSION}"'
}

@test "Dockerfile: the arch switch covers amd64 + arm64 and fails loudly otherwise" {
  stage_text tools | grep -qE '^[[:space:]]*amd64\) '
  stage_text tools | grep -qE '^[[:space:]]*arm64\) '
  stage_text tools | grep -qE '^[[:space:]]*\*\) echo "unsupported architecture: \$arch" >&2; exit 1 ;;'
}

@test "Dockerfile: every new RUN opens with set -eu (dash has no pipefail)" {
  # Join continuation lines, then: any RUN whose body relies on set -e — `;`
  # separators, pipelines, or $(…) captures — must open with set -eu. Plain
  # &&-chains (the pre-existing apt/npm/shim/chmod/mkdir RUNs) abort on their own.
  needs_set_eu() { grep -qE '[;|]|\$\(' <<<"$1"; }
  needs_set_eu 'RUN echo a; echo b'                       # controls
  needs_set_eu 'RUN x | y'
  needs_set_eu 'RUN v=$(cmd)'
  run needs_set_eu 'RUN apt-get update && apt-get install -y foo && rm -rf /var/lib/apt/lists/*'
  [ "$status" -ne 0 ]
  joined=$(sed -e ':a' -e '/\\$/N; s/\\\n//; ta' "$DF")
  n=0
  while IFS= read -r line; do
    if needs_set_eu "$line"; then
      n=$((n + 1))
      [[ "$line" == "RUN set -eu; "* ]] || { echo "RUN relies on set -e but does not open with it: ${line:0:80}"; false; }
    fi
  done < <(grep '^RUN ' <<<"$joined")
  [ "$n" -eq 5 ]
}

@test "Dockerfile: the final smoke compares every baked tool against the shipped manifest" {
  final=$(final_text)
  grep -qF '= "v${CADDY_VERSION}"' <<<"$final"
  grep -qF '= "${TAILSCALE_VERSION}"' <<<"$final"
  grep -qF 'test -x /usr/local/bin/tailscaled' <<<"$final"
  grep -qF 'test "$(bun --version)" = "${BUN_VERSION}"' <<<"$final"
  grep -qF 'test "$(bunx --version)" = "${BUN_VERSION}"' <<<"$final"
  grep -qF 'test "$(monolith --version)" = "monolith ${MONOLITH_VERSION}"' <<<"$final"
}

@test "Dockerfile: the header diagram names every package the apt/PGDG RUN installs" {
  # The header comment is the documented pipeline diagram ("keep in sync").
  header=$(awk '/^FROM /{exit} {print}' "$DF" | awk '/final \(node:22-slim\)/{f=1} f')
  [ -n "$header" ]
  pkgs=$(final_text | grep -oE 'apt-get install -y --no-install-recommends ca-certificates[^;&]*' | head -1 | sed 's/.*--no-install-recommends //')
  [ "$(wc -w <<<"$pkgs")" -ge 5 ]
  [ -n "$pkgs" ]
  for p in $pkgs; do
    grep -qw -- "$p" <<<"$header" || { echo "header diagram omits package $p"; false; }
  done
}

@test "Dockerfile: declares no ARG (Render turns every service env var into a --build-arg)" {
  run grep -E '^[[:space:]]*ARG[[:space:]]' "$DF"
  [ "$status" -ne 0 ]
}

@test "Dockerfile: no 'latest' anywhere outside comments" {
  run grep -i latest <<<"$DF_CODE"
  [ "$status" -ne 0 ]
}

# --- Layer order (load-bearing for cache behavior) ------------------------------

@test "Dockerfile: apt/PGDG layer sits above the npm layers; tool COPYs sit below npm and above the script COPYs" {
  apt1=$(line_of '^RUN apt-get update && apt-get install -y git curl')
  pgdg=$(line_of 'postgresql-client-\$\{PG_MAJOR\}')
  claude=$(line_of 'npm install -g @anthropic-ai/claude-code')
  shim=$(line_of '/usr/bin/claude --version')
  ctools=$(line_of '^COPY --from=tools /out/usr/local/bin/ /usr/local/bin/$')
  cenv=$(line_of '^COPY --from=tools /out/etc/baked-tools.env /etc/baked-tools.env$')
  cmono=$(line_of '^COPY --from=monolith-build /opt/monolith/bin/monolith /usr/local/bin/monolith$')
  start=$(line_of '^COPY start.sh /start.sh$')
  tmpdir=$(line_of '^ENV TMPDIR=/data/tmp$')
  mkd=$(line_of '^RUN mkdir -p /data/tmp')
  for v in apt1 pgdg claude shim ctools cenv cmono start tmpdir mkd; do
    [ -n "${!v}" ] || { echo "missing anchor: $v"; false; }
  done
  [ "$apt1" -lt "$pgdg" ]
  [ "$pgdg" -lt "$claude" ]
  [ "$shim" -lt "$ctools" ]
  [ "$shim" -lt "$cmono" ]
  [ "$ctools" -lt "$start" ]
  [ "$cenv" -lt "$start" ]
  [ "$cmono" -lt "$start" ]
  [ "$start" -lt "$tmpdir" ]
  [ "$tmpdir" -lt "$mkd" ]
}

# --- Downloads and signatures ---------------------------------------------------

@test "Dockerfile: every artifact download in the tools stage is checksum-verified" {
  code=$(stage_text tools | grep -vE '^[[:space:]]*#')
  [ "$(grep -c 'dl "https://' <<<"$code")" -eq 3 ]
  [ "$(grep -Ec 'sha(256|512)sum -c -' <<<"$code")" -eq 3 ]
  # the only command-position curl in the stage is the dl() definition itself
  [ "$(grep -Ec "$CURL_CMD_ERE" <<<"$code")" -eq 1 ]
}

@test "Dockerfile: the final stage fetches exactly one thing over curl — the PGDG signing key" {
  code=$(final_text | grep -vE '^[[:space:]]*#')
  [ "$(grep -Ec "$CURL_CMD_ERE" <<<"$code")" -eq 1 ]
  grep -E "$CURL_CMD_ERE" <<<"$code" | grep -qF 'https://www.postgresql.org/media/keys/ACCC4CF8.asc'
}

@test "Dockerfile: every curl retries and writes to a file; nothing is piped into a shell" {
  [ "$(grep -Ec "$CURL_CMD_ERE" <<<"$DF_CODE")" -eq 2 ]
  while IFS= read -r line; do
    grep -qE -- '--retry [0-9]+' <<<"$line"
    grep -qF -- '--retry-all-errors' <<<"$line"
    grep -qE -- ' -o ' <<<"$line"
  done < <(grep -E "$CURL_CMD_ERE" <<<"$DF_CODE")
  # controls: the guard sees a flagless curl in command position, not the apt package list
  grep -qE "$CURL_CMD_ERE" <<<'    curl https://example.invalid/x.tgz; \\'
  run grep -E "$CURL_CMD_ERE" <<<'RUN apt-get update && apt-get install -y git curl procps'
  [ "$status" -ne 0 ]
  run grep -E '\|[[:space:]]*(sudo[[:space:]]+)?(ba)?sh([[:space:]]|$)' <<<"$DF_CODE"
  [ "$status" -ne 0 ]
}

@test "Dockerfile: PGDG key is pinned by fingerprint (exactly one primary key) before apt trusts it" {
  final=$(final_text | grep -vE '^[[:space:]]*#')
  grep -qF 'B97B0AFCAA1A47F044F244A07FCC7D46ACCC4CF8' <<<"$final"
  grep -qF -- '--show-keys --with-colons' <<<"$final"
  grep -qF '$1=="pub"' <<<"$final"
  grep -qF -- '-eq 1' <<<"$final"
  grep -qF '$1=="fpr"' <<<"$final"
  grep -qF 'signed-by=/usr/share/keyrings/postgresql-archive-keyring.asc' <<<"$final"
  grep -qF 'apt-get purge -y --auto-remove gpg' <<<"$final"
}

@test "Dockerfile: installs only the PostgreSQL CLIENT of the pinned major, never the server" {
  grep -qF 'apt-get install -y --no-install-recommends "postgresql-client-${PG_MAJOR}"' "$DF"
  grep -qF 'test -x "/usr/lib/postgresql/${PG_MAJOR}/bin/psql"' "$DF"
  run grep -E 'postgresql-(server|[0-9]+|\$\{?PG_MAJOR)' <<<"$DF_CODE"
  [ "$status" -ne 0 ]
  # the major lives in baked-tools.env only — never hardcoded in the Dockerfile
  run grep -E 'postgresql(-client)?-1[0-9]|/postgresql/1[0-9]/' <<<"$DF_CODE"
  [ "$status" -ne 0 ]
}

@test "Dockerfile: never weakens apt signature checking" {
  run grep -E 'trusted=yes|--allow-unauthenticated|AllowInsecureRepositories|--allow-insecure-repositories|apt-key' <<<"$DF_CODE"
  [ "$status" -ne 0 ]
}

# --- Installing must not enable services -----------------------------------------

@test "Dockerfile + start.sh: never launch tailscaled/caddy or bring a tailnet up" {
  code=$(grep -vhE '^[[:space:]]*#' "$DF" "$REPO/start.sh")
  run grep -E "$DAEMON_ERE" <<<"$code"
  [ "$status" -ne 0 ]
  # positive controls: the guard must catch the obvious ways to start something
  grep -qE "$DAEMON_ERE" <<<'nohup tailscaled &'
  grep -qE "$DAEMON_ERE" <<<'tailscale up --authkey=x'
  grep -qE "$DAEMON_ERE" <<<'RUN caddy run --config /data/Caddyfile'
  grep -qE "$DAEMON_ERE" <<<'exec caddy start'
  grep -qE "$DAEMON_ERE" <<<'    tailscaled --tun=userspace-networking --state=/data/ts.state &'
  grep -qE "$DAEMON_ERE" <<<'foo && tailscaled'
  grep -qE "$DAEMON_ERE" <<<'/usr/local/bin/tailscaled --state=/data/x &'
  grep -qE "$DAEMON_ERE" <<<'if true; then tailscaled; fi'
  grep -qE "$DAEMON_ERE" <<<'timeout 30 caddy run'
  grep -qE "$DAEMON_ERE" <<<'RUN /usr/local/bin/tailscale up --authkey=x'
  # negative controls: presence checks and argument positions are legitimate
  run grep -E "$DAEMON_ERE" <<<'    install -m 0755 tailscaled /out/usr/local/bin/tailscaled; \'
  [ "$status" -ne 0 ]
  run grep -E "$DAEMON_ERE" <<<'    test -x /usr/local/bin/tailscaled; \'
  [ "$status" -ne 0 ]
  run grep -E "$DAEMON_ERE" <<<'    test "$(tailscale version | head -n1)" = "${TAILSCALE_VERSION}"; \'
  [ "$status" -ne 0 ]
}

@test "Dockerfile: exposes only 3000, boots via tini -g + start.sh, copies only allowlisted files" {
  [ "$(grep -c '^EXPOSE ' "$DF")" -eq 1 ]
  grep -qxF 'EXPOSE 3000' "$DF"
  grep -qxF 'ENTRYPOINT ["/usr/bin/tini", "-g", "--"]' "$DF"
  grep -qxF 'CMD ["/start.sh"]' "$DF"
  run grep -E '^ADD ' "$DF"
  [ "$status" -ne 0 ]
  run grep -E '^COPY (\./?|\.\.|\*)' "$DF"
  [ "$status" -ne 0 ]
  while read -r src; do
    case "$src" in
      package.json|start.sh|failure-server.js|baked-tools.env|debug-start.sh) ;;
      *) echo "unexpected COPY source: $src"; false ;;
    esac
  done < <(grep '^COPY ' "$DF" | grep -v -- '--from=' | awk '{print $2}')
}

@test ".dockerignore: is an allowlist that matches the Dockerfile's COPY sources exactly" {
  first=$(grep -vE '^[[:space:]]*(#|$)' "$IGN" | head -1)
  [ "$first" = '*' ]
  expected=$( { grep '^COPY ' "$DF" | grep -v -- '--from=' | awk '{print $2}'; echo debug-start.sh; } | sort -u)
  actual=$(grep -E '^!' "$IGN" | sed 's/^!//' | sort -u)
  [ "$expected" = "$actual" ]
  # nothing but `*`, `!` exceptions, comments and blanks
  run grep -vE '^[[:space:]]*(#|$|!|\*$)' "$IGN"
  [ "$status" -ne 0 ]
}

@test "render.yaml: no dockerCommand override (the runtime contract lives in the Dockerfile)" {
  run grep -E '^[[:space:]]*dockerCommand:' "$REPO/render.yaml"
  [ "$status" -ne 0 ]
}

@test "Dockerfile: installs the git-lfs filter system-wide (recorded decision)" {
  grep -qF 'git lfs install --system --skip-repo' "$DF"
}

@test "CI workflow: every job is bounded by timeout-minutes" {
  wf="$REPO/.github/workflows/test.yml"
  jobs=$(awk '/^jobs:/{j=1; next} j && /^  [a-z0-9_-]+:$/' "$wf" | wc -l)
  [ "$jobs" -ge 2 ]
  [ "$(grep -cE '^    timeout-minutes: [0-9]+$' "$wf")" -eq "$jobs" ]
}

@test "docs: AGENTS.md and CLAUDE.md are identical" {
  cmp -s "$REPO/AGENTS.md" "$REPO/CLAUDE.md"
}
