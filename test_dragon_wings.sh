#!/bin/bash
# Test dragon wing animation in isolation

echo "=== Dragon Wing Animation Test ==="
echo "Controls:"
echo "  ESC   - Quit"
echo "  R     - Restart animation"
echo "  SPACE - Pause/Resume"
echo ""

# Run Godot with the test scene
/home/talves/bin/godot --windowed --resolution 1280x720 res://tests/test_dragon_wings.tscn
