#!/usr/bin/env bash
# Test dragon wing animation in isolation
set -euo pipefail

PROJECT_DIR="/home/talves/mthings/LandsOfBalance"
GODOT="${GODOT:-/home/talves/bin/godot}"
MODE="${1:-gui}"

echo "=== Dragon Wing Animation Test ==="
if [[ "$MODE" == "--headless" || "$MODE" == "headless" ]]; then
    CAPTURE_DIR="${2:-/tmp/lob-dragon-wing-capture}"
    LOG="${LOG:-/tmp/lob-dragon-wing-capture.log}"
    TMP_HOME="$(mktemp -d /tmp/lob-dragon-home.XXXXXX)"
    cleanup() {
        rm -rf "$TMP_HOME"
    }
    trap cleanup EXIT
    rm -rf "$CAPTURE_DIR"
    mkdir -p "$CAPTURE_DIR" "$TMP_HOME/.config" "$TMP_HOME/.local/share/godot/app_userdata" "$TMP_HOME/.cache"
    echo "Running headless capture to $CAPTURE_DIR"
    set +e
    timeout --kill-after=5 "${TIMEOUT_SEC:-45}" \
        env HOME="$TMP_HOME" XDG_CONFIG_HOME="$TMP_HOME/.config" \
            XDG_DATA_HOME="$TMP_HOME/.local/share" XDG_CACHE_HOME="$TMP_HOME/.cache" \
            DRAGON_CAPTURE_DIR="$CAPTURE_DIR" \
        "$GODOT" --path "$PROJECT_DIR" --headless \
            --scene res://tests/test_dragon_wings.tscn \
            --singleplayer --performance-mode "--capture-dragon-frames=$CAPTURE_DIR" --no-mcp-runtime \
            > "$LOG" 2>&1
    STATUS=$?
    set -e
    echo "Log: $LOG"
    echo "Captured frames:"
    find "$CAPTURE_DIR" -maxdepth 1 -type f -name '*.png' -print | sort
    if [[ "$STATUS" -ne 0 ]]; then
        echo "Headless capture did not produce viewport frames; use GUI/windowed mode for visual PNG review." >&2
    fi
    exit "$STATUS"
fi

echo "Controls:"
echo "  Click      - Capture mouse for camera"
echo "  ESC        - Release mouse / Quit"
echo "  WASD/QE    - Move camera"
echo "  Scroll     - Zoom"
echo "  R          - Restart animation"
echo "  SPACE      - Pause/Resume"
echo "  M          - Toggle manual mode"
echo "  P          - Print bone values"
echo ""
echo "UI Panel: Adjust Min/Max range for each bone"
echo ""

# Run Godot with the test scene
cd "$PROJECT_DIR"
"$GODOT" --path "$PROJECT_DIR" --windowed --resolution 1400x900 \
    --scene res://tests/test_dragon_wings.tscn
