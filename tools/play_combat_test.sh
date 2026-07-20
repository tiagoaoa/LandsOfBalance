#!/bin/bash
# Playable combat test: you are the Paladin, spawned in the test arena a few
# strides from Bobba, full controls, no scripted driver and no timeout.
#
#   LMB / F  attack (mash = 3-hit combo)     RMB  block
#   G  parry     X  roll     T  lock-on      H    estus
#   Space jump   Shift run   L  day/night
#
# Usage: tools/play_combat_test.sh

set -euo pipefail
cd "$(dirname "$0")/.."

GODOT="${GODOT:-/home/talves/bin/godot}"

exec "$GODOT" --singleplayer --combat-scenario=PLAY
