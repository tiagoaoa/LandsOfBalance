#!/bin/bash
#Repeatable arena profile and collision regression checks.
set -euo pipefail
cd "$(dirname "$0")/.."
MODE="${1:-perf}"
LABEL="${2:-$MODE}"
OUT="$PWD/docs/presentation/arena-performance"
mkdir -p "$OUT"
export GODOT_MCP_RUNTIME_ENABLED=0
export XDG_DATA_HOME=/tmp/lob-arena-profile
export XDG_CONFIG_HOME=/tmp/lob-arena-profile
export LOB_ARENA_AREA="${LOB_ARENA_AREA:-6}"
export LOB_BOSS_PROFILE=0
export LOB_PERF_SHOT="$OUT/$LABEL.png"
SCENE=performance
ARGS=()
case "$MODE" in
    perf|gpu) ARGS+=(--resolution 1280x720 --windowed) ;;
    cpu) export LOB_BOSS_PROFILE=1; ARGS+=(--headless) ;;
    terrain) SCENE=terrain_review; ARGS+=(--headless) ;;
    climb) SCENE=climb_review; ARGS+=(--headless) ;;
    climb-visual) SCENE=climb_review; ARGS+=(--resolution 1382x720 --windowed) ;;
    attack) SCENE=attack_review; ARGS+=(--headless) ;;
    attack-visual) SCENE=attack_review; ARGS+=(--resolution 1382x720 --windowed) ;;
    animation) SCENE=animation_review; ARGS+=(--headless) ;;
    skin) SCENE=skin_review; ARGS+=(--headless) ;;
    terrain-small) SCENE=terrain_review; export LOB_ARENA_AREA=1; ARGS+=(--headless) ;;
    bots)
        SCENE=boss_arena
        export LOB_BOSS_MATCHES=1
        export LOB_BOSS_LOG="$OUT/$LABEL.ndjson"
        ARGS+=(--headless)
        ;;
    import) exec /home/talves/bin/godot --path "$PWD" --headless --editor --import --quit > "$OUT/$LABEL.log" 2>&1 ;;
    *) echo "usage: $0 [perf|gpu|cpu|terrain|terrain-small|animation|climb|climb-visual|attack|attack-visual|skin|bots|import] [label]" >&2; exit 2 ;;
esac
if [ "$MODE" = gpu ]; then export LOB_GPU_REVIEW=1; fi
exec /home/talves/bin/godot --path "$PWD" "${ARGS[@]}" \
    --scene "res://tests/boss_arena/$SCENE.tscn" -- \
    --singleplayer --spectate --no-mcp-runtime > "$OUT/$LABEL.log" 2>&1
