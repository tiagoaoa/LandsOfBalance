#!/bin/bash
# Windowed frame-time benchmark: the WATCH showcase (two bots, full night
# world, a chase camera that roams) measured by autoload/perf_probe.gd.
#
#   tools/perf_probe.sh                  # 40 s, prints the PERF lines
#   LOB_PERF_SECONDS=90 tools/perf_probe.sh
#   LOB_EXTRA_ARGS=--performance-mode tools/perf_probe.sh   # phone settings
#   LOB_HEADLESS=1 tools/perf_probe.sh   # no GPU: frame time is pure CPU
#   LOB_ABLATE=1 / LOB_GPU=1             # per-system / per-effect A/B costs
#
# Full log in /tmp/lob_perf_probe.log.
set -euo pipefail
cd "$(dirname "$0")/.."
GODOT="${GODOT:-/home/talves/bin/godot}"
SECONDS_TO_RUN="${LOB_PERF_SECONDS:-40}"
LOG=/tmp/lob_perf_probe.log
# shellcheck disable=SC2206
EXTRA=(${LOB_EXTRA_ARGS:-})
GODOT_MCP_RUNTIME_ENABLED=0 LOB_PERF_SECONDS="$SECONDS_TO_RUN" \
    timeout --kill-after=5 $((SECONDS_TO_RUN + ${LOB_ABLATE:+300} + 90)) \
    "$GODOT" --path "$PWD" ${LOB_HEADLESS:+--headless} -- --singleplayer --combat-scenario=WATCH \
        --no-mcp-runtime --combat-no-screenshots --perf-probe ${LOB_ABLATE:+--perf-ablate} ${LOB_GPU:+--perf-gpu} "${EXTRA[@]}" \
    > "$LOG" 2>&1 || true
grep -E "^PERF" "$LOG" || { echo "(no PERF output — see $LOG)"; tail -30 "$LOG"; }
