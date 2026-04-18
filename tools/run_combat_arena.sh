#!/bin/bash
# Launch the Paladin-vs-Bobba combat arena — a stripped-down scene for
# iterating on combat feel. Each death (yours or Bobba's) reloads the
# round; `GameSettings.arena_round` keeps the counter alive across
# reloads.
#
# Usage: ./tools/run_combat_arena.sh [--archer]

set -euo pipefail
cd "$(dirname "$0")/.."

GODOT="${GODOT:-/home/talves/bin/godot}"
CLASS="paladin"
if [[ "${1:-}" == "--archer" ]]; then
    CLASS="archer"
fi

echo "Launching combat arena as $CLASS…"
exec "$GODOT" --singleplayer "--character-class=$CLASS" \
    --scene res://tests/combat_arena/arena.tscn
