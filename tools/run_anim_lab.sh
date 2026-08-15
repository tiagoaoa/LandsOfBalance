#!/bin/bash
# Bobba animation lab — browse and scrub every clip he has, including the
# ones composed at load time (HitReact, AxeAttack, the Axe* carries).
#
# The combat scenarios shoot at night from behind the player and the GEARSIM
# turntable only holds one clip at a fixed angle and rate, so neither could
# answer "is the blade actually moving when the hitbox goes live". This can:
# the damage window is drawn on the timeline.
#
#   drag = orbit · wheel = zoom · W/S = raise/lower · space = play/pause
#   Esc = quit
#
# Usage: ./tools/run_anim_lab.sh
set -euo pipefail
cd "$(dirname "$0")/.."
GODOT="${GODOT:-/home/talves/bin/godot}"
exec "$GODOT" --singleplayer --scene res://tests/anim_lab/anim_lab.tscn "$@"
