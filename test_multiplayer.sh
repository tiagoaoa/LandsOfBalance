#!/bin/bash
# Test multiplayer with two player windows side-by-side

PROJECT_DIR="/home/talves/mthings/LandsOfBalance"
GODOT="/home/talves/bin/godot"

# Window settings (adjust for your screen resolution)
WINDOW_WIDTH=960
WINDOW_HEIGHT=540

echo "=== Multiplayer Test ==="
echo "Stopping existing processes..."
pkill -9 game_server 2>/dev/null
pkill -9 bot_client 2>/dev/null
pkill -9 godot 2>/dev/null
sleep 0.5

echo "Starting game server..."
cd "$PROJECT_DIR/server"
./game_server &
sleep 0.3

echo "Launching Player 1 (left window)..."
cd "$PROJECT_DIR"
$GODOT --path "$PROJECT_DIR" \
    --resolution ${WINDOW_WIDTH}x${WINDOW_HEIGHT} \
    --position 0,100 \
    game.tscn &
sleep 1

echo "Launching Player 2 (right window)..."
$GODOT --path "$PROJECT_DIR" \
    --resolution ${WINDOW_WIDTH}x${WINDOW_HEIGHT} \
    --position ${WINDOW_WIDTH},100 \
    game.tscn &

echo ""
echo "=== Two players launched side-by-side ==="
echo "  - Player 1: Left window"
echo "  - Player 2: Right window"
echo ""
echo "Press Ctrl+C or run 'pkill godot' to stop"
echo ""

# Wait for user to stop
wait
