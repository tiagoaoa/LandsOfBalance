#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-/home/talves/mthings/LandsOfBalance}"
GOPEAK_ENTRY="${GOPEAK_ENTRY:-/home/talves/.local/lib/gopeak/node_modules/gopeak/build/index.js}"
GODOT_BIN="${GODOT:-${GODOT_BIN:-/home/talves/bin/godot}}"
BRIDGE_PORT="${GODOT_BRIDGE_PORT:-6505}"
RUNTIME_PORT="${GODOT_RUNTIME_PORT:-7777}"
TMP_HOME="$(mktemp -d /tmp/lob-godot-mcp-home.XXXXXX)"
RUN_ID="${LOB_MCP_RUN_ID:-$$}"
BRIDGE_LOG="${LOB_MCP_BRIDGE_LOG:-/tmp/lob-godot-mcp-bridge-${RUN_ID}.log}"
EDITOR_LOG="${LOB_MCP_EDITOR_LOG:-/tmp/lob-godot-mcp-editor-${RUN_ID}.log}"
RUNTIME_LOG="${LOB_MCP_RUNTIME_LOG:-/tmp/lob-godot-mcp-runtime-${RUN_ID}.log}"
BRIDGE_PID=""
EDITOR_PID=""
RUNTIME_PID=""

cleanup() {
    for pid in "$RUNTIME_PID" "$EDITOR_PID" "$BRIDGE_PID"; do
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
    done
    rm -rf "$TMP_HOME"
}
trap cleanup EXIT

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Missing required command: $1" >&2
        exit 1
    fi
}

wait_for_http_ok() {
    local url="$1"
    local attempts="${2:-40}"
    local delay="${3:-0.25}"
    local i
    for ((i = 0; i < attempts; i += 1)); do
        if curl --max-time 1 -fsS "$url" >/dev/null 2>&1; then
            return 0
        fi
        sleep "$delay"
    done
    return 1
}

wait_for_health_value() {
    local expected="$1"
    local attempts="${2:-40}"
    local delay="${3:-0.25}"
    local i
    for ((i = 0; i < attempts; i += 1)); do
        if curl --max-time 1 -fsS "http://127.0.0.1:${BRIDGE_PORT}/health" 2>/dev/null | grep -q "\"connected\":${expected}"; then
            return 0
        fi
        sleep "$delay"
    done
    return 1
}

wait_for_runtime_ping() {
    local attempts="${1:-40}"
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

require_cmd node
require_cmd curl
require_cmd timeout

if [[ ! -x "$GODOT_BIN" ]]; then
    echo "Godot binary not found at $GODOT_BIN" >&2
    exit 1
fi

if [[ ! -f "$GOPEAK_ENTRY" ]]; then
    echo "GoPeak entrypoint not found at $GOPEAK_ENTRY" >&2
    exit 1
fi

mkdir -p \
    "$TMP_HOME/.config" \
    "$TMP_HOME/.local/share/godot/app_userdata" \
    "$TMP_HOME/.cache"

echo "Godot version: $("$GODOT_BIN" --version)"
node -e "const p=require('/home/talves/.local/lib/gopeak/node_modules/gopeak/package.json'); console.log('GoPeak version:', p.version)"

echo "Starting GoPeak bridge on 127.0.0.1:${BRIDGE_PORT}"
GODOT_PATH="$GODOT_BIN" \
GODOT_BRIDGE_PORT="$BRIDGE_PORT" \
GODOT_BRIDGE_HOST="127.0.0.1" \
GOPEAK_BRIDGE_HOST="127.0.0.1" \
GOPEAK_TOOL_PROFILE="compact" \
GOPEAK_TOOLS_PAGE_SIZE="${GOPEAK_TOOLS_PAGE_SIZE:-33}" \
LOG_MODE="lite" \
node "$GOPEAK_ENTRY" >"$BRIDGE_LOG" 2>&1 &
BRIDGE_PID=$!

if ! wait_for_http_ok "http://127.0.0.1:${BRIDGE_PORT}/health"; then
    echo "Bridge health check failed" >&2
    cat "$BRIDGE_LOG" >&2 || true
    exit 1
fi
if ! kill -0 "$BRIDGE_PID" 2>/dev/null; then
    echo "Bridge process exited unexpectedly" >&2
    cat "$BRIDGE_LOG" >&2 || true
    exit 1
fi
MCP_INIT_RESPONSE="$(curl -fsS --max-time 5 \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"lob-smoke","version":"1.0"}}}' \
    "http://127.0.0.1:${BRIDGE_PORT}/mcp" || true)"
if [[ "$MCP_INIT_RESPONSE" != *'"serverInfo"'* ]]; then
    echo "Bridge /mcp initialize check failed" >&2
    echo "$MCP_INIT_RESPONSE" >&2
    cat "$BRIDGE_LOG" >&2 || true
    exit 1
fi

echo "Launching headless editor to verify MCP editor bridge"
HOME="$TMP_HOME" \
XDG_DATA_HOME="$TMP_HOME/.local/share" \
XDG_CONFIG_HOME="$TMP_HOME/.config" \
XDG_CACHE_HOME="$TMP_HOME/.cache" \
GODOT_BRIDGE_PORT="$BRIDGE_PORT" \
GODOT_MCP_RUNTIME_ENABLED=0 \
"$GODOT_BIN" --path "$PROJECT_DIR" --headless -e --quit-after 300 --log-file "$EDITOR_LOG" >/dev/null 2>&1 &
EDITOR_PID=$!

if ! wait_for_health_value "true"; then
    echo "Editor bridge did not connect" >&2
    cat "$BRIDGE_LOG" >&2 || true
    cat "$EDITOR_LOG" >&2 || true
    exit 1
fi

echo "Launching headless runtime to verify runtime socket on ${RUNTIME_PORT}"
HOME="$TMP_HOME" \
XDG_DATA_HOME="$TMP_HOME/.local/share" \
XDG_CONFIG_HOME="$TMP_HOME/.config" \
XDG_CACHE_HOME="$TMP_HOME/.cache" \
GODOT_MCP_RUNTIME_ENABLED=1 \
GODOT_MCP_RUNTIME_PORT="$RUNTIME_PORT" \
"$GODOT_BIN" --path "$PROJECT_DIR" --headless --quit-after 300 --log-file "$RUNTIME_LOG" -- --singleplayer --performance-mode "--mcp-runtime-port=${RUNTIME_PORT}" >/dev/null 2>&1 &
RUNTIME_PID=$!

if ! wait_for_runtime_ping; then
    echo "Runtime port ${RUNTIME_PORT} did not answer MCP ping" >&2
    cat "$RUNTIME_LOG" >&2 || true
    exit 1
fi

echo "Smoke test passed"
echo "Bridge log: $BRIDGE_LOG"
echo "Editor log: $EDITOR_LOG"
echo "Runtime log: $RUNTIME_LOG"
