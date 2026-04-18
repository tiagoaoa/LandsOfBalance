#!/bin/bash
# Test multiplayer with full game (enemy AI enabled)

PROJECT_DIR="/home/talves/mthings/LandsOfBalance"
GODOT="/home/talves/bin/godot"

# Window settings (adjust for your screen resolution)
WINDOW_WIDTH=960
WINDOW_HEIGHT=540

echo "=== Full Game Test (Enemy AI ENABLED) ==="

# Kill any existing processes before starting
echo "Checking for existing processes..."

kill_if_running() {
    local process_name="$1"
    local pids=$(pgrep -f "$process_name" 2>/dev/null)
    if [ -n "$pids" ]; then
        echo "  Killing existing $process_name (PIDs: $pids)"
        pkill -9 -f "$process_name" 2>/dev/null
        return 0
    fi
    return 1
}

killed_something=false

if kill_if_running "game_server"; then killed_something=true; fi
if kill_if_running "bot_client"; then killed_something=true; fi
if kill_if_running "godot"; then killed_something=true; fi

if [ "$killed_something" = true ]; then
    echo "  Waiting for processes to terminate..."
    sleep 0.5
else
    echo "  No existing processes found"
fi

echo "Starting game server (AI ENABLED)..."
cd "$PROJECT_DIR/server"
./game_server > /tmp/game_server.log 2>&1 &
SERVER_PID=$!
sleep 0.5

# Check server started
if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo "Server failed to start!"
    cat /tmp/game_server.log
    exit 1
fi

echo "Server running (PID $SERVER_PID)"

echo "Launching Player 1 (left window)..."
cd "$PROJECT_DIR"
$GODOT --path "$PROJECT_DIR" \
    --resolution ${WINDOW_WIDTH}x${WINDOW_HEIGHT} \
    --position 0,100 \
    --scene res://game.tscn \
    -- \
    --multiplayer \
    --performance-mode \
    --server-host=127.0.0.1 \
    --character-class=archer &
sleep 1

echo "Launching Player 2 (right window)..."
$GODOT --path "$PROJECT_DIR" \
    --resolution ${WINDOW_WIDTH}x${WINDOW_HEIGHT} \
    --position ${WINDOW_WIDTH},100 \
    --scene res://game.tscn \
    -- \
    --multiplayer \
    --performance-mode \
    --server-host=127.0.0.1 \
    --character-class=paladin &

echo ""
echo "=== Two players launched - FULL GAME MODE ==="
echo "  - Bobba will chase and attack players!"
echo "  - Server log: tail -f /tmp/game_server.log"
echo ""
echo "Press Ctrl+C or run 'pkill godot' to stop"
echo ""

# Wait for user to stop
wait
