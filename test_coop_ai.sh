#!/usr/bin/env bash
# One human player plus the AI companion, in the FULL game (game.tscn via the
# character-select menu), no server, no second window.
#
# The menu opens in "AI co-op" mode by default: pick Archer or Paladin and the
# AI companion (player/companion_ai.gd) takes the other class. Pass a class to
# skip the menu.
#
# Usage:
#   ./test_coop_ai.sh                # menu picks the class
#   ./test_coop_ai.sh archer         # you are the Archer, AI is the Paladin
#   ./test_coop_ai.sh paladin        # you are the Paladin, AI is the Archer
#   ./test_coop_ai.sh --kill         # stop any running Godot instance
#
# Env: GODOT (binary), WINDOW (WxH, default 1280x720), LOB_EXTRA_ARGS
# (extra game flags, e.g. --performance-mode). Log: /tmp/lob_coop_ai.log.
#
# For the same thing inside the combat arena, use:
#   tools/run_combat_scenario.sh COOP

set -euo pipefail
cd "$(dirname "$0")"

GODOT="${GODOT:-/home/talves/bin/godot}"
WINDOW="${WINDOW:-1280x720}"
LOG="/tmp/lob_coop_ai.log"

if [[ "${1:-}" == "--kill" ]]; then
    pkill -f "$GODOT" 2>/dev/null || true
    exit 0
fi

CLASS="${1:-}"
GAME_ARGS=(--singleplayer --coop)
case "${CLASS,,}" in
    "") ;;
    archer|paladin) GAME_ARGS+=("--character-class=${CLASS,,}") ;;
    *) echo "Usage: $0 [archer|paladin|--kill]"; exit 1 ;;
esac
if [[ -n "${LOB_EXTRA_ARGS:-}" ]]; then
    # shellcheck disable=SC2206
    GAME_ARGS+=(${LOB_EXTRA_ARGS})
fi

# A stale client would grab the same window slot and confuse the log.
pkill -f "$GODOT" 2>/dev/null || true
sleep 0.3

echo "=== Co-op AI test: 1 human + AI companion (full game) ==="
echo "  class : ${CLASS:-menu picks}"
echo "  log   : $LOG"
: > "$LOG"
"$GODOT" --path "$PWD" --resolution "$WINDOW" --position 0,0 \
    -- "${GAME_ARGS[@]}" > "$LOG" 2>&1 &
PID=$!
echo "Godot running (PID $PID). Ctrl+C stops it."

trap 'echo; echo "Stopping…"; kill "$PID" 2>/dev/null || true; exit 0' INT TERM
wait "$PID"
echo "=== Mode lines from the log ==="
grep -E "GameSettings:|Companion|companion" "$LOG" | head -20 || true
