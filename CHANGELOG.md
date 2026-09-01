# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [2.0.0.2] - 2026-09-01

### Changed
- Tightened the default `ORPHAN_SWEEP_PATTERN` from `openclaw[^ ]* gateway` to `(^|[ /])openclaw[^ ]* gateway run( |$)`: the post-exit orphan sweep matches full process argv, and rescue panes are exactly where operators type commands mentioning the gateway mid-incident — the old pattern could kill the operator's own debugging commands. Both real gateway argv shapes stay matched (contract-tested, including rescue-pane argv that merely mentions the gateway).
- Pinned the global `@anthropic-ai/claude-code` install to an exact version (2.1.252) so image rebuilds can no longer silently float it to latest — the same deliberate-bump discipline as the alphaclaw SHA pin (contract-tested). Hardened test enforcement along the way: converted silent no-op `! command` assertions (exempt from bats errexit when non-final) to enforcing `run` + status checks across the contract suites and the Docker e2e suite (the remaining e2e occurrences are ledgered in `TODOS.md`), including the public-page secret-leak check's intermediate responses, and made the supervise harness leak-free (stub and decoy processes now forward TERM to their children).

### Added
- Install `tmux` in the image so alphaclaw's local Claude Code rescue sessions (shipped in 2.0.0.1) use tmux hosting and survive alphaclaw restarts, instead of the degraded `script(1)` hosting that dies with the process ("tmux is not installed — sessions use script(1) hosting and die with AlphaClaw"). Sessions still end on a full container restart/redeploy — tmux servers are in-memory by nature. Guarded at three layers: contract tests pin `tmux` in the apt line (image and CI) and prove the default `ORPHAN_SWEEP_PATTERN` cannot match a rescue session's typical tmux argv (payload argv that itself contains "openclaw … gateway", and runtime pattern overrides, remain a documented accepted risk), a supervise-harness test proves a tmux session (same pane PID) survives an exit-75 supervisor relaunch while a sweep-tagged decoy dies, and the Docker e2e executes `tmux -V` inside the built image. CI installs tmux explicitly so the survival test can never silently skip.

## [2.0.0.1] - 2026-08-31

### Changed
- Updated the bundled alphaclaw from 0.9.49 to 0.9.56, picking up seven upstream releases: chat reliability rework (protocol v2 bridge, durable run outcomes, resumable streams), gateway memory-leak detection with opt-in pre-OOM auto-restart, one-click authenticated OpenClaw dashboards (appears once the bundled OpenClaw is upgraded to 2026.8.1+ from the Upgrade tab — this release still pins OpenClaw 2026.7.1-2), local Claude Code rescue sessions, Drift Doctor delivery fixes, actionable error messages, and a verbose notification toggle.
