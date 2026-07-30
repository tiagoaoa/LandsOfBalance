#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-/home/talves/mthings/LandsOfBalance}"
GODOT_BIN="${GODOT_BIN:-/home/talves/bin/godot}"
RUNTIME_PORT="${GODOT_MCP_RUNTIME_PORT:-${GODOT_RUNTIME_PORT:-7777}}"
RUN_SECONDS="${LOB_MCP_RUNTIME_SECONDS:-600}"
LOG="${LOB_MCP_RUNTIME_LOG:-/tmp/lob-mcp-runtime.log}"
PERFORMANCE_MODE="${LOB_PERFORMANCE_MODE:-1}"

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Missing required command: $1" >&2
        exit 1
    fi
}

wait_for_runtime_ping() {
    local attempts="${1:-60}"
    local delay="${2:-0.25}"
    local i
    for ((i = 0; i < attempts; i += 1)); do
        if node "$PROJECT_DIR/tools/godot_runtime_probe.mjs" --port "$RUNTIME_PORT" --timeout 1000 ping >/dev/null 2>&1; then
            return 0
        fi
        sleep "$delay"
    done
    return 1
}

cleanup() {
    if [[ -n "${GODOT_PID:-}" ]] && kill -0 "$GODOT_PID" 2>/dev/null; then
        kill "$GODOT_PID" 2>/dev/null || true
        wait "$GODOT_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

require_cmd node
require_cmd timeout

if [[ ! -x "$GODOT_BIN" ]]; then
    echo "Godot binary not found at $GODOT_BIN" >&2
    exit 1
fi

GODOT_ARGS=("--path" "$PROJECT_DIR" "--headless" "--log-file" "$LOG")
USER_ARGS=("--singleplayer")
case "${PERFORMANCE_MODE,,}" in
    1|true|yes|on) USER_ARGS+=("--performance-mode") ;;
esac

echo "Starting headless Godot MCP runtime on 127.0.0.1:${RUNTIME_PORT}"
echo "Log: $LOG"
if [[ "$RUN_SECONDS" != "0" ]]; then
    GODOT_MCP_RUNTIME_ENABLED=1 \
    GODOT_MCP_RUNTIME_PORT="$RUNTIME_PORT" \
    timeout --kill-after=5 "$RUN_SECONDS" "$GODOT_BIN" "${GODOT_ARGS[@]}" -- "${USER_ARGS[@]}" >"$LOG.stdout" 2>&1 &
else
    GODOT_MCP_RUNTIME_ENABLED=1 \
    GODOT_MCP_RUNTIME_PORT="$RUNTIME_PORT" \
    "$GODOT_BIN" "${GODOT_ARGS[@]}" -- "${USER_ARGS[@]}" >"$LOG.stdout" 2>&1 &
fi
GODOT_PID=$!

if ! wait_for_runtime_ping; then
    echo "Runtime port ${RUNTIME_PORT} did not answer MCP ping" >&2
    cat "$LOG" >&2 || true
    cat "$LOG.stdout" >&2 || true
    exit 1
fi

echo "MCP runtime is ready (PID $GODOT_PID)"
if [[ "$RUN_SECONDS" != "0" ]]; then
    echo "It will stop automatically after ${RUN_SECONDS}s."
else
    echo "Press Ctrl+C to stop it."
fi

wait "$GODOT_PID" || true
