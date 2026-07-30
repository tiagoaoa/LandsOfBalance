#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="/home/talves/mthings/LandsOfBalance"
GODOT="/home/talves/bin/godot"
SERVER_DIR="$PROJECT_DIR/server"
RUN_SECONDS="${LOB_RUN_SECONDS:-18}"
HEADLESS="${LOB_HEADLESS:-1}"
GAME_PORT="${LOB_GAME_PORT:-7777}"
MCP_RUNTIME_ENABLED="${GODOT_MCP_RUNTIME_ENABLED:-0}"
CLIENT1_MCP_PORT="${GODOT_MCP_RUNTIME_PORT_CLIENT1:-7777}"
CLIENT2_MCP_PORT="${GODOT_MCP_RUNTIME_PORT_CLIENT2:-7778}"

SERVER_LOG="/tmp/lob_perf_server.log"
CLIENT1_LOG="/tmp/lob_perf_client1.log"
CLIENT2_LOG="/tmp/lob_perf_client2.log"

cleanup() {
    pkill -9 -f "/home/talves/bin/godot --path $PROJECT_DIR" 2>/dev/null || true
    pkill -9 -f game_server 2>/dev/null || true
}
trap cleanup EXIT INT TERM

cleanup
rm -f "$SERVER_LOG" "$CLIENT1_LOG" "$CLIENT2_LOG"

cd "$SERVER_DIR"
./game_server "$GAME_PORT" >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!
sleep 1
if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "Server failed to start. Last log lines:"
    tail -40 "$SERVER_LOG" || true
    exit 1
fi

cd "$PROJECT_DIR"
CLIENT1_ARGS=("--path" "$PROJECT_DIR" \
    --scene res://game.tscn \
    --print-fps)
CLIENT2_ARGS=("${CLIENT1_ARGS[@]}")
case "${HEADLESS,,}" in
    1|true|yes|on)
        CLIENT1_ARGS+=("--headless")
        CLIENT2_ARGS+=("--headless")
        ;;
    *)
        CLIENT1_ARGS+=("--position" "0,100")
        CLIENT2_ARGS+=("--position" "960,100")
        ;;
esac

echo "Profiling multiplayer for ${RUN_SECONDS}s (headless ${HEADLESS}, game port ${GAME_PORT})"
GODOT_MCP_RUNTIME_ENABLED="$MCP_RUNTIME_ENABLED" \
GODOT_MCP_RUNTIME_PORT="$CLIENT1_MCP_PORT" \
timeout "$RUN_SECONDS" "$GODOT" "${CLIENT1_ARGS[@]}" -- \
    --multiplayer \
    --performance-mode \
    --server-host=127.0.0.1 \
    "--server-port=$GAME_PORT" \
    --character-class=archer \
    >"$CLIENT1_LOG" 2>&1 &
CLIENT1_PID=$!

sleep 2

GODOT_MCP_RUNTIME_ENABLED="$MCP_RUNTIME_ENABLED" \
GODOT_MCP_RUNTIME_PORT="$CLIENT2_MCP_PORT" \
timeout "$RUN_SECONDS" "$GODOT" "${CLIENT2_ARGS[@]}" -- \
    --multiplayer \
    --performance-mode \
    --server-host=127.0.0.1 \
    "--server-port=$GAME_PORT" \
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
