#!/bin/bash
# Test multiplayer with two player windows side-by-side

PROJECT_DIR="/home/talves/mthings/LandsOfBalance"
GODOT="/home/talves/bin/godot"

# Window settings (adjust for your screen resolution)
WINDOW_WIDTH=960
WINDOW_HEIGHT=540

echo "=== Multiplayer Test (Full Combat Mode) ==="

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

echo "Starting game server..."
cd "$PROJECT_DIR/server"
./game_server > /tmp/mp_server.log 2>&1 &
SERVER_PID=$!
sleep 0.5

# Check server started
if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo "Server failed to start!"
    cat /tmp/mp_server.log
    exit 1
fi

echo "Server running (PID $SERVER_PID)"

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
echo "  - Bobba AI: ENABLED (will chase and attack!)"
echo ""
echo "Server log: tail -f /tmp/mp_server.log"
echo "Press Ctrl+C or run 'pkill godot' to stop"
echo ""

# Wait for user to stop
wait
