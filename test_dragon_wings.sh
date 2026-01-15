#!/bin/bash
# Test dragon wing animation in isolation

echo "=== Dragon Wing Animation Test ==="
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
cd "$(dirname "$0")"
/home/talves/bin/godot --windowed --resolution 1400x900 tests/test_dragon_wings.tscn
