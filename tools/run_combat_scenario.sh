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
    A|B|GRASS|PROMO|LOCKON|DODGE|PARRY|BACKSTAB|ESTUS|SOULS|MOVE|COMBO|PLAY|ARROW|ARCHER|RIVER|DRAGON|COOP|SKEL|POSTER|BOWSIM|REVIVE|MOBSIM|PALSIM|BLOCKSIM|ANIMSIM|GEARSIM) ;;
    *) echo "Scenario must be A, B, GRASS, PROMO, LOCKON, DODGE, PARRY, BACKSTAB, ESTUS, SOULS, MOVE, COMBO, PLAY, ARROW, ARCHER, RIVER, DRAGON, COOP, SKEL, POSTER, BOWSIM, REVIVE, MOBSIM, PALSIM, BLOCKSIM, ANIMSIM, or GEARSIM (got: $SCENARIO)"; exit 1 ;;
esac

DEFAULT_HEADLESS=1
if [ "$SCENARIO" = "PLAY" ] || [ "$SCENARIO" = "ARCHER" ] || [ "$SCENARIO" = "COOP" ]; then
    DEFAULT_HEADLESS=0
fi
HEADLESS="${LOB_HEADLESS:-$DEFAULT_HEADLESS}"
export GODOT_MCP_RUNTIME_ENABLED="${GODOT_MCP_RUNTIME_ENABLED:-0}"
TMP_HOME=""

cleanup() {
    if [ -n "$TMP_HOME" ]; then
        rm -rf "$TMP_HOME"
    fi
}
trap cleanup EXIT

LOG="/tmp/lob_combat_${SCENARIO}.log"
: > "$LOG"

# Wipe previous screenshots for a clean run.
rm -rf /tmp/combat_test
mkdir -p /tmp/combat_test

GODOT_ARGS=("--path" "$PWD")
GAME_ARGS=(--singleplayer "--combat-scenario=$SCENARIO")
case "${GODOT_MCP_RUNTIME_ENABLED,,}" in
    1|true|yes|on)
        GAME_ARGS+=("--mcp-runtime-port=${GODOT_MCP_RUNTIME_PORT:-7777}")
        ;;
    *)
        GAME_ARGS+=(--no-mcp-runtime)
        ;;
esac
case "${HEADLESS,,}" in
    1|true|yes|on)
        GODOT_ARGS+=("--headless")
        GAME_ARGS+=(--combat-no-screenshots)
        TMP_HOME="$(mktemp -d /tmp/lob-combat-home.XXXXXX)"
        mkdir -p "$TMP_HOME/.config" "$TMP_HOME/.local/share/godot/app_userdata" "$TMP_HOME/.cache"
        ;;
esac

echo "Launching scenario $SCENARIO (timeout ${TIMEOUT_SEC}s, headless ${HEADLESS}, log $LOG)"
if [ -n "$TMP_HOME" ]; then
    timeout --kill-after=5 "$TIMEOUT_SEC" \
        env HOME="$TMP_HOME" XDG_CONFIG_HOME="$TMP_HOME/.config" \
            XDG_DATA_HOME="$TMP_HOME/.local/share" XDG_CACHE_HOME="$TMP_HOME/.cache" \
        "$GODOT" "${GODOT_ARGS[@]}" -- "${GAME_ARGS[@]}" \
            > "$LOG" 2>&1 || true
else
    timeout --kill-after=5 "$TIMEOUT_SEC" \
        "$GODOT" "${GODOT_ARGS[@]}" -- "${GAME_ARGS[@]}" \
            > "$LOG" 2>&1 || true
fi

echo
echo "=== Outcome ==="
grep -E "\[CombatTest\]" "$LOG" || echo "(no CombatTest output — see $LOG)"
echo "=== Screenshots: $(ls /tmp/combat_test 2>/dev/null | wc -l) files ==="
