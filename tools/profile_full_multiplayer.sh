#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="/home/talves/mthings/LandsOfBalance"
GODOT="/home/talves/bin/godot"
SERVER_DIR="$PROJECT_DIR/server"

SERVER_LOG="/tmp/lob_perf_server.log"
CLIENT1_LOG="/tmp/lob_perf_client1.log"
CLIENT2_LOG="/tmp/lob_perf_client2.log"

cleanup() {
    pkill -9 -f "/home/talves/bin/godot --path $PROJECT_DIR" 2>/dev/null || true
    pkill -9 -f game_server 2>/dev/null || true
}

cleanup
rm -f "$SERVER_LOG" "$CLIENT1_LOG" "$CLIENT2_LOG"

cd "$SERVER_DIR"
./game_server >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!
sleep 1

cd "$PROJECT_DIR"
timeout 18 "$GODOT" --path "$PROJECT_DIR" \
    --position 0,100 \
    --scene res://game.tscn \
    --print-fps \
    -- \
    --multiplayer \
    --performance-mode \
    --server-host=127.0.0.1 \
    --character-class=archer \
    >"$CLIENT1_LOG" 2>&1 &
CLIENT1_PID=$!

sleep 2

timeout 18 "$GODOT" --path "$PROJECT_DIR" \
    --position 960,100 \
    --scene res://game.tscn \
    --print-fps \
    -- \
    --multiplayer \
    --performance-mode \
    --server-host=127.0.0.1 \
    --character-class=paladin \
    >"$CLIENT2_LOG" 2>&1 &
CLIENT2_PID=$!

wait "$CLIENT1_PID" || true
wait "$CLIENT2_PID" || true

kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true

echo "Server log: $SERVER_LOG"
echo "Client 1 log: $CLIENT1_LOG"
echo "Client 2 log: $CLIENT2_LOG"
