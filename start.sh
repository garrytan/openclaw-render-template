#!/bin/bash
# Boot supervisor: runs alphaclaw under a restart policy instead of one-shot.
#
# Why: AlphaClaw deliberately exits to request a relaunch (restartProcess();
# newer versions exit 75 / EX_TEMPFAIL, older ones exit 1). The old script ran
# alphaclaw once and exec'd the failure server forever — turning every exit,
# including intentional restarts, into a permanent outage (alphaclaw #22).
#
# Policy (see CLAUDE.md "Boot supervisor"):
#   exit 75                  -> relaunch immediately (never counts as failure;
#                               1s spin brake if the run lasted <5s)
#   any exit, run >60s       -> healthy-enough: reset counter, relaunch
#   exit within 60s          -> rapid failure: count, back off fails*5s
#                               (cumulative backoff capped so the failure page
#                               appears well inside Render's ~60s health-fail
#                               restart window), relaunch
#   5 consecutive rapid fails-> run failure-server.js as a LOOP CHILD (no
#                               exec); its exit (Restart button) resets the
#                               counter and retries alphaclaw. FAILURE_EPOCH
#                               anchors its health-grace clock and survives
#                               these cycles.
#
# Signals: the Dockerfile ENTRYPOINT is `tini -g`, which TERMs the entire
# process group. tini exits as soon as THIS script exits, and the container
# goes with it, so the script must outlive alphaclaw's graceful shutdown
# (SIGTERM notice, deploy-history record, gateway stop): it traps TERM/INT,
# forwards the signal to the running child, waits for it, and exits with the
# child's code. The tee that writes $LOGFILE ignores TERM/INT so alphaclaw's
# last lines still reach the log; it ends when alphaclaw closes its output.

LOGFILE="${LOGFILE:-/data/start.log}"
ALPHACLAW_BIN="${ALPHACLAW_BIN:-/app/node_modules/.bin/alphaclaw}"
FAILURE_SERVER="${FAILURE_SERVER:-/failure-server.js}"
# node resolves via the exported PATH in the container; the host-run test
# harness passes an absolute path since its node lives outside that PATH.
NODE_BIN="${NODE_BIN:-node}"
RAPID_WINDOW_SECS="${RAPID_WINDOW_SECS:-60}"
MAX_RAPID_FAILS="${MAX_RAPID_FAILS:-5}"
BACKOFF_STEP_SECS="${BACKOFF_STEP_SECS:-5}"
SPIN_BRAKE_SECS="${SPIN_BRAKE_SECS:-1}"
CUM_BACKOFF_CAP_SECS="${CUM_BACKOFF_CAP_SECS:-30}"
MAX_LOG_BYTES="${MAX_LOG_BYTES:-52428800}"
# ERE for pkill/pgrep -f: gateway argv can be `openclaw gateway run` or
# `node .../openclaw.mjs gateway run`, so the pattern allows a suffix after
# "openclaw" but requires the full "gateway run" phrase with an anchored left
# edge. Deliberately tight: pkill -f matches ANYWHERE in any process's argv,
# and tmux-hosted rescue panes are exactly where an operator types things
# like `grep "openclaw gateway" /data/start.log` mid-incident — a looser
# pattern would let the sweep kill the rescue session it must outlive
# (contract-tested in scripts.bats). Env-overridable so the test harness can
# point it at a tagged stub and never touch real host processes.
ORPHAN_SWEEP_PATTERN="${ORPHAN_SWEEP_PATTERN:-(^|[ /])openclaw[^ ]* gateway run( |$)}"

mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || true

log() {
  echo "[supervisor] $*" | tee -a "$LOGFILE" 2>/dev/null || echo "[supervisor] $*"
}

# Numeric knobs are operator-set env; a typo must not blow up loop arithmetic.
validate_num() {
  local name="$1" def="$2"
  local val="${!name}"
  if ! [[ "$val" =~ ^[0-9]+$ ]]; then
    log "WARNING: invalid $name='$val'; using default $def"
    printf -v "$name" '%s' "$def"
  fi
}
validate_num RAPID_WINDOW_SECS 60
validate_num MAX_RAPID_FAILS 5
validate_num BACKOFF_STEP_SECS 5
validate_num SPIN_BRAKE_SECS 1
validate_num CUM_BACKOFF_CAP_SECS 30
validate_num MAX_LOG_BYTES 52428800

# Render's runtime container env can strip PATH down to a narrow set that
# excludes /usr/bin and /app/node_modules/.bin, which breaks alphaclaw's
# spawning of openclaw, curl, etc. Force a sensible PATH explicitly.
export PATH="/app/node_modules/.bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Route temp onto the persistent /data disk instead of ephemeral /tmp. The disk
# is mounted over /data at runtime, so the Dockerfile's build-time mkdir is
# hidden — (re)create /data/tmp here on every boot. Re-export the standard temp
# trio too (same belt-and-suspenders reasoning as PATH above: Render's runtime
# can munge the env even though the Dockerfile sets these via ENV).
export TMPDIR=/data/tmp TEMP=/data/tmp TMP=/data/tmp
mkdir -p "$TMPDIR" 2>/dev/null || true
chmod 1777 "$TMPDIR" 2>/dev/null || true

{
  echo "=== boot $(date -u +%FT%TZ) ==="
  echo "PATH=$PATH"
  echo "TMPDIR=$TMPDIR"
  echo "supervisor: window=${RAPID_WINDOW_SECS}s max_fails=$MAX_RAPID_FAILS backoff_step=${BACKOFF_STEP_SECS}s cap=${CUM_BACKOFF_CAP_SECS}s"
} | tee -a "$LOGFILE" 2>/dev/null || true

set -o pipefail

STOP_SIGNAL=""
child_pid=""
on_stop_signal() {
  STOP_SIGNAL="$1"
  if [ -n "$child_pid" ]; then
    kill -s "$1" "$child_pid" 2>/dev/null || true
  fi
}
trap 'on_stop_signal TERM' TERM
trap 'on_stop_signal INT' INT

# Waits for child_pid to exit, staying responsive to TERM/INT (a trap
# interrupts `wait` while the child still runs). Sets CODE.
wait_child() {
  local status
  while :; do
    wait "$child_pid"
    status=$?
    kill -0 "$child_pid" 2>/dev/null || break
  done
  child_pid=""
  CODE=$status
}

exit_if_stopping() { # code
  [ -z "$STOP_SIGNAL" ] && return 0
  log "received SIG$STOP_SIGNAL; supervisor exiting with code $1"
  exit "$1"
}

# Runs "$@" with stdout+stderr appended to $LOGFILE through a tee that
# ignores TERM/INT, and waits for it. Sets CODE.
run_logged() {
  local fifo tee_pid
  fifo=$(mktemp -u "$(dirname "$LOGFILE")/.start-log.XXXXXX")
  if ! mkfifo -m 600 "$fifo" 2>/dev/null; then
    "$@" 2>&1 | tee -a "$LOGFILE"
    CODE=${PIPESTATUS[0]}
    return
  fi
  (trap '' TERM INT; exec tee -a "$LOGFILE" <"$fifo") &
  tee_pid=$!
  # setsid: the child gets its own process group, so tini -g's group TERM
  # doesn't reach it and on_stop_signal's forward is the only one. A second
  # TERM makes alphaclaw abandon its drain and SIGKILL the gateway.
  if command -v setsid >/dev/null 2>&1; then
    setsid "$@" >"$fifo" 2>&1 &
  else
    "$@" >"$fifo" 2>&1 &
  fi
  child_pid=$!
  if [ -n "$STOP_SIGNAL" ]; then
    kill -s "$STOP_SIGNAL" "$child_pid" 2>/dev/null || true
  fi
  wait_child
  # tee ends when the last writer closes the fifo. A descendant that kept
  # alphaclaw's stdout must not hold the supervisor (and the container) open:
  # give tee 3s to drain, then stop it (it ignores TERM).
  local i
  for i in $(seq 1 30); do
    kill -0 "$tee_pid" 2>/dev/null || break
    sleep 0.1
  done
  kill -KILL "$tee_pid" 2>/dev/null || true
  wait "$tee_pid" 2>/dev/null
  rm -f "$fifo"
}

pause() { # seconds
  sleep "$1" &
  child_pid=$!
  wait_child
}

# The failure page can't fill the 10GB disk: rotate an oversized boot log
# (single .1 generation) before each launch.
rotate_log() {
  local size
  size=$(($(wc -c <"$LOGFILE" 2>/dev/null || echo 0)))
  if [ "$size" -gt "$MAX_LOG_BYTES" ]; then
    mv -f "$LOGFILE" "$LOGFILE.1" 2>/dev/null || true
    log "rotated oversized log to $LOGFILE.1 (${size} bytes > ${MAX_LOG_BYTES})"
  fi
}

# A crashed alphaclaw can orphan its gateway child, which would hold ports
# across the relaunch. TERM, wait up to ~5s, then KILL stragglers.
sweep_orphans() {
  pgrep -f "$ORPHAN_SWEEP_PATTERN" >/dev/null 2>&1 || return 0
  log "sweeping orphaned processes matching '$ORPHAN_SWEEP_PATTERN' (TERM)"
  pkill -TERM -f "$ORPHAN_SWEEP_PATTERN" 2>/dev/null || true
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if ! pgrep -f "$ORPHAN_SWEEP_PATTERN" >/dev/null 2>&1; then
      log "orphan sweep complete (${i}00ms-ish)"
      return 0
    fi
    sleep 0.5
  done
  log "orphans survived TERM; escalating to KILL"
  pkill -KILL -f "$ORPHAN_SWEEP_PATTERN" 2>/dev/null || true
}

fails=0
cum_backoff=0
brake_streak=0     # consecutive sub-5s exit-75 runs
longrun_fail_streak=0
FAILURE_EPOCH=""   # unix seconds; set on entering failure mode, cleared by a >window run

while :; do
  rotate_log
  exit_if_stopping 0
  start_ts=$(date +%s)
  run_logged "$ALPHACLAW_BIN" start
  dur=$(($(date +%s) - start_ts))
  if [ -n "$STOP_SIGNAL" ]; then
    log "alphaclaw exited $CODE after ${dur}s after SIG$STOP_SIGNAL"
    exit_if_stopping "$CODE"
  fi

  sweep_orphans

  if [ "$CODE" -eq 75 ]; then
    # Intentional restart (EX_TEMPFAIL contract): relaunch immediately,
    # never counted toward the failure threshold.
    if [ "$dur" -lt 5 ]; then
      brake_streak=$((brake_streak + 1))
      log "exit 75 after ${dur}s — intentional restart; relaunching (spin brake ${SPIN_BRAKE_SECS}s; sub-5s streak $brake_streak)"
      if [ "$brake_streak" -ge 10 ]; then
        log "WARNING: $brake_streak consecutive sub-5s exit-75 runs — possible exit-75 loop; check for a wedged rollback/update"
      fi
      pause "$SPIN_BRAKE_SECS"
    else
      brake_streak=0
      log "exit 75 after ${dur}s — intentional restart; relaunching immediately"
    fi
    if [ "$dur" -gt "$RAPID_WINDOW_SECS" ]; then
      fails=0; cum_backoff=0; FAILURE_EPOCH=""
    fi
    continue
  fi
  brake_streak=0

  if [ "$dur" -gt "$RAPID_WINDOW_SECS" ]; then
    # Ran long enough to count as healthy; an exit now is a restart request
    # (older alphaclaw exits 1 for this) or a one-off. Reset everything.
    if [ "$CODE" -ne 0 ]; then
      longrun_fail_streak=$((longrun_fail_streak + 1))
      if [ "$longrun_fail_streak" -ge 3 ]; then
        log "WARNING: $longrun_fail_streak consecutive non-zero long-run exits — recurring crash after the rapid window; check $LOGFILE"
      fi
    else
      longrun_fail_streak=0
    fi
    log "exit $CODE after ${dur}s (> ${RAPID_WINDOW_SECS}s window) — treating as restart request/one-off; counter reset"
    fails=0; cum_backoff=0; FAILURE_EPOCH=""
    continue
  fi
  longrun_fail_streak=0

  fails=$((fails + 1))
  if [ "$fails" -lt "$MAX_RAPID_FAILS" ]; then
    backoff=$((fails * BACKOFF_STEP_SECS))
    remaining=$((CUM_BACKOFF_CAP_SECS - cum_backoff))
    [ "$remaining" -lt 0 ] && remaining=0
    [ "$backoff" -gt "$remaining" ] && backoff=$remaining
    cum_backoff=$((cum_backoff + backoff))
    log "exit $CODE after ${dur}s — rapid failure $fails/$MAX_RAPID_FAILS; backing off ${backoff}s (cumulative ${cum_backoff}s, cap ${CUM_BACKOFF_CAP_SECS}s)"
    pause "$backoff"
    continue
  fi

  # Threshold: hold on the failure-status server as a LOOP CHILD (no exec) so
  # its exit (Restart button, or its own bind failure) resumes supervision.
  # FAILURE_EPOCH anchors its health-grace clock; it survives these cycles so
  # /restart spam can't keep a broken box "healthy" forever.
  if [ -z "$FAILURE_EPOCH" ]; then
    FAILURE_EPOCH=$(date +%s)
  fi
  log "exit $CODE after ${dur}s — rapid failure $fails/$MAX_RAPID_FAILS; threshold reached, starting failure-status server (FAILURE_EPOCH=$FAILURE_EPOCH)"
  run_logged env FAILURE_EPOCH="$FAILURE_EPOCH" "$NODE_BIN" "$FAILURE_SERVER"
  SCODE=$CODE
  exit_if_stopping "$SCODE"
  log "failure server exited with code $SCODE — resetting counter; retrying alphaclaw"
  fails=0
  cum_backoff=0
done
