#!/bin/bash
# Bobba animation lab — browse and scrub every clip he has, including the
# ones composed at load time (HitReact, AxeAttack, the Axe* carries).
#
# The combat scenarios shoot at night from behind the player and the GEARSIM
# turntable only holds one clip at a fixed angle and rate, so neither could
# answer "is the blade actually moving when the hitbox goes live". This can:
# the damage window is drawn on the timeline.
#
# POSING
#   drag a blue JOINT   rotate that bone at the current frame
#   shift + drag        roll the bone about its own axis (wrist onto a shaft)
#   Del                 drop the key nearest the playhead
#   Export clip to file writes GDScript to the clipboard and to
#                       user://edited_poses.gd.txt
#
# Posing at a frame with no key INSERTS one there, seeded with whatever the
# clip is already showing — so it changes nothing until you drag, and the
# motion either side keeps interpolating. Green ticks on the timeline are
# keys; the red band is the damage window.
#
# CAMERA
#   drag empty space = orbit · wheel = zoom · W/S = raise/lower
#   space = play/pause · Esc = quit
#
# Usage: ./tools/run_anim_lab.sh
set -euo pipefail
cd "$(dirname "$0")/.."
GODOT="${GODOT:-/home/talves/bin/godot}"
exec "$GODOT" --singleplayer --scene res://tests/anim_lab/anim_lab.tscn "$@"
