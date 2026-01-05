#!/bin/bash
# Run multiplayer test: server + 2 clients side by side

cd "$(dirname "$0")"
GODOT=/home/talves/bin/godot

# Kill any existing instances
pkill -f "godot" 2>/dev/null
sleep 1

# Start server (headless, background)
echo "Starting server on port 7777..."
$GODOT --headless res://multiplayer/server.tscn > /tmp/mp_server.log 2>&1 &
SERVER_PID=$!
sleep 2

# Check server started
if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo "Server failed to start!"
    cat /tmp/mp_server.log
    exit 1
fi

echo "Server running (PID $SERVER_PID)"

# Launch two clients side by side
echo "Launching clients..."
$GODOT --position 0,0 > /tmp/mp_client1.log 2>&1 &
$GODOT --position 960,0 > /tmp/mp_client2.log 2>&1 &

echo ""
echo "All running. Clients auto-connect to server."
echo "Logs: /tmp/mp_server.log, /tmp/mp_client1.log, /tmp/mp_client2.log"
echo ""
