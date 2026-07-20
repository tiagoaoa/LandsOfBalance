#!/bin/bash
# Launch an automated Paladin-vs-Bobba combat scenario and print the outcome.
#
# Usage:
#   tools/run_combat_scenario.sh A        # Paladin expected to win
#   tools/run_combat_scenario.sh B        # Paladin expected to lose
#   tools/run_combat_scenario.sh A 45     # override max wall-clock seconds
#
# Screenshots land in /tmp/combat_test/, the full client log in
# /tmp/lob_combat_<scenario>.log.

set -euo pipefail
cd "$(dirname "$0")/.."

SCENARIO="${1:-A}"
# PLAY, ARCHER and COOP are human-driven: long leash unless the caller overrides.
if [ "$SCENARIO" = "PLAY" ] || [ "$SCENARIO" = "ARCHER" ] || [ "$SCENARIO" = "COOP" ]; then
    TIMEOUT_SEC="${2:-3600}"
else
    TIMEOUT_SEC="${2:-75}"
fi
GODOT="${GODOT:-/home/talves/bin/godot}"

case "$SCENARIO" in
    A|B|GRASS|PROMO|LOCKON|DODGE|PARRY|BACKSTAB|ESTUS|SOULS|MOVE|COMBO|PLAY|ARROW|ARCHER|RIVER|DRAGON|COOP|SKEL|POSTER|BOWSIM|REVIVE) ;;
    *) echo "Scenario must be A, B, GRASS, PROMO, LOCKON, DODGE, PARRY, BACKSTAB, ESTUS, SOULS, MOVE, COMBO, PLAY, ARROW, ARCHER, RIVER, DRAGON, COOP, SKEL, POSTER, BOWSIM, or REVIVE (got: $SCENARIO)"; exit 1 ;;
esac

LOG="/tmp/lob_combat_${SCENARIO}.log"
: > "$LOG"

# Wipe previous screenshots for a clean run.
rm -rf /tmp/combat_test
mkdir -p /tmp/combat_test

echo "Launching scenario $SCENARIO (timeout ${TIMEOUT_SEC}s, log $LOG)"
timeout --kill-after=5 "$TIMEOUT_SEC" \
    "$GODOT" --singleplayer "--combat-scenario=$SCENARIO" \
        > "$LOG" 2>&1 || true

echo
echo "=== Outcome ==="
grep -E "\[CombatTest\]" "$LOG" || echo "(no CombatTest output — see $LOG)"
echo "=== Screenshots: $(ls /tmp/combat_test 2>/dev/null | wc -l) files ==="
