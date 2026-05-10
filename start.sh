#!/bin/bash
# Boot script: runs alphaclaw, but if alphaclaw exits/crashes, falls back to
# a tiny HTTP failure-status server so the container stays Live and the
# Render Shell tab remains accessible for debugging.

LOGFILE=/data/start.log
mkdir -p /data

# Render's runtime container env can strip PATH down to a narrow set that
# excludes /usr/bin and /app/node_modules/.bin, which breaks alphaclaw's
# spawning of openclaw, curl, etc. Force a sensible PATH explicitly.
export PATH="/app/node_modules/.bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

{
  echo "=== boot $(date -u +%FT%TZ) ==="
  echo "PATH=$PATH"
  echo "Starting alphaclaw..."
} | tee -a "$LOGFILE"

set -o pipefail
/app/node_modules/.bin/alphaclaw start 2>&1 | tee -a "$LOGFILE"
CODE=${PIPESTATUS[0]}

echo "=== alphaclaw exited with code $CODE at $(date -u +%FT%TZ) ===" | tee -a "$LOGFILE"
echo "=== falling back to failure-status server ===" | tee -a "$LOGFILE"

exec node /failure-server.js
