#!/bin/bash
# The Chained Colossus — co-op boss arena.
#
#   tools/run_boss_arena.sh            # you play the archer, a bot plays the paladin
#   tools/run_boss_arena.sh --paladin  # you play the paladin, a bot plays the archer
#   tools/run_boss_arena.sh --watch    # both bots, spectator camera (TAB switches)
#   LOB_BOSS_CAMERA_CYCLE=18 tools/run_boss_arena.sh --watch  # adds overview
#
# Falling off the platform, or the whole party dying, restarts the match.
set -euo pipefail
cd "$(dirname "$0")/.."
GODOT="${GODOT:-/home/talves/bin/godot}"
CLASS=archer
EXTRA=()
case "${1:-}" in
    --paladin) CLASS=paladin ;;
    --watch) EXTRA+=(--spectate) ;;
esac
export GODOT_MCP_RUNTIME_ENABLED="${GODOT_MCP_RUNTIME_ENABLED:-0}"
exec "$GODOT" --path "$PWD" --scene res://tests/boss_arena/boss_arena.tscn -- \
    --singleplayer --no-mcp-runtime "--character-class=$CLASS" "${EXTRA[@]}"
