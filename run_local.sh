#!/bin/bash
# Local test loop: starts the C game_server on 127.0.0.1:7777 and launches
# one Godot client that auto-connects to it as a regular client.
#
# Usage:
#   ./run_local.sh             # launch server + 1 client
#   ./run_local.sh 2           # launch server + 2 clients (side-by-side)
#   ./run_local.sh --kill      # kill any running server/clients and exit
#
# The server is kept running as long as this script is alive — Ctrl+C here
# will shut everything down.

set -euo pipefail

cd "$(dirname "$0")"

GODOT=${GODOT:-/home/talves/bin/godot}
SERVER_BIN="server/game_server"
SERVER_LOG="/tmp/lob_game_server.log"
CLIENT_LOG_PREFIX="/tmp/lob_client"

kill_all() {
    pkill -f "server/game_server" 2>/dev/null || true
    pkill -f "$GODOT" 2>/dev/null || true
}

if [[ "${1:-}" == "--kill" ]]; then
    echo "Killing server and all Godot clients…"
    kill_all
    exit 0
fi

N_CLIENTS=${1:-1}
if ! [[ "$N_CLIENTS" =~ ^[0-9]+$ ]] || [[ "$N_CLIENTS" -lt 1 ]]; then
    echo "Usage: $0 [n_clients]"
    exit 1
fi

if [[ ! -x "$SERVER_BIN" ]]; then
    echo "Game server binary not found or not executable: $SERVER_BIN"
    echo "Build it first with: (cd server && make)"
    exit 1
fi

# Clean up any stale processes from a previous run
kill_all
sleep 0.3

echo "Starting game_server on 127.0.0.1:7777 (log: $SERVER_LOG)"
"./$SERVER_BIN" > "$SERVER_LOG" 2>&1 &
SERVER_PID=$!
sleep 0.5

if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "Game server failed to start. Last log lines:"
    tail -20 "$SERVER_LOG" || true
    exit 1
fi
echo "Game server running (PID $SERVER_PID)"

# Launch clients. The default config in protocol.gd / game_settings.gd
# already points at 127.0.0.1 and enables multiplayer by default, so no
# extra flags are needed — just start Godot.
CLIENT_PIDS=()
for ((i=1; i<=N_CLIENTS; i++)); do
    X_OFFSET=$(( (i-1) * 960 ))
    LOG="${CLIENT_LOG_PREFIX}${i}.log"
    echo "Launching client $i (log: $LOG)"
    "$GODOT" --position "${X_OFFSET},0" > "$LOG" 2>&1 &
    CLIENT_PIDS+=($!)
done

echo
echo "Server and $N_CLIENTS client(s) running."
echo "  Server log : $SERVER_LOG"
echo "  Client logs: ${CLIENT_LOG_PREFIX}1.log … ${CLIENT_LOG_PREFIX}${N_CLIENTS}.log"
echo
echo "Press Ctrl+C to stop everything."

# Wait for Ctrl+C, then clean up
trap 'echo; echo "Stopping…"; kill_all; exit 0' INT TERM
wait "$SERVER_PID"
