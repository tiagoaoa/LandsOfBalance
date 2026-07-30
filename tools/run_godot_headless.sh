#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-/home/talves/mthings/LandsOfBalance}"
GODOT="${GODOT:-/home/talves/bin/godot}"
TIMEOUT_SEC="${TIMEOUT_SEC:-60}"
QUIT_AFTER="${QUIT_AFTER:-0}"
LOG="${LOG:-/tmp/lob-godot-headless.log}"
SCENE=""
IMPORT_ONLY=0
USE_TMP_HOME=1
ENABLE_MCP_RUNTIME=0
RUNTIME_PORT="${GODOT_MCP_RUNTIME_PORT:-7777}"
PROJECT_ARGS=()

usage() {
    cat <<'USAGE'
Usage: tools/run_godot_headless.sh [options] [-- game args...]

Options:
  --scene PATH              Run a specific scene, e.g. res://game.tscn
  --timeout SEC             Wall-clock timeout (default: 60)
  --quit-after FRAMES       Ask Godot to quit after N frames
  --log PATH                Godot log file (default: /tmp/lob-godot-headless.log)
  --import                  Run Godot's headless import pass
  --mcp-runtime             Keep the MCP runtime socket enabled
  --mcp-runtime-port PORT   Runtime port passed to the addon (default: 7777)
  --no-tmp-home             Reuse the caller's HOME/XDG dirs

By default this disables MCP runtime with --no-mcp-runtime so headless tests do
not fight over port 7777. Pass --mcp-runtime when testing GoPeak runtime tools.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --scene)
            SCENE="${2:?missing value for --scene}"
            shift 2
            ;;
        --timeout)
            TIMEOUT_SEC="${2:?missing value for --timeout}"
            shift 2
            ;;
        --quit-after)
            QUIT_AFTER="${2:?missing value for --quit-after}"
            shift 2
            ;;
        --log)
            LOG="${2:?missing value for --log}"
            shift 2
            ;;
        --import)
            IMPORT_ONLY=1
            shift
            ;;
        --mcp-runtime)
            ENABLE_MCP_RUNTIME=1
            shift
            ;;
        --mcp-runtime-port)
            RUNTIME_PORT="${2:?missing value for --mcp-runtime-port}"
            ENABLE_MCP_RUNTIME=1
            shift 2
            ;;
        --no-tmp-home)
            USE_TMP_HOME=0
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        --)
            shift
            PROJECT_ARGS+=("$@")
            break
            ;;
        *)
            PROJECT_ARGS+=("$1")
            shift
            ;;
    esac
done

if [[ ! -x "$GODOT" ]]; then
    echo "Godot binary not found or not executable: $GODOT" >&2
    exit 1
fi

TMP_HOME=""
cleanup() {
    if [[ -n "$TMP_HOME" ]]; then
        rm -rf "$TMP_HOME"
    fi
}
trap cleanup EXIT

ENV_ARGS=()
if [[ "$USE_TMP_HOME" -eq 1 ]]; then
    TMP_HOME="$(mktemp -d /tmp/lob-godot-headless-home.XXXXXX)"
    mkdir -p "$TMP_HOME/.config" "$TMP_HOME/.local/share" "$TMP_HOME/.cache"
    ENV_ARGS+=(
        "HOME=$TMP_HOME"
        "XDG_CONFIG_HOME=$TMP_HOME/.config"
        "XDG_DATA_HOME=$TMP_HOME/.local/share"
        "XDG_CACHE_HOME=$TMP_HOME/.cache"
    )
fi

GODOT_ARGS=(--path "$PROJECT_DIR" --headless --log-file "$LOG")
if [[ "$QUIT_AFTER" != "0" ]]; then
    GODOT_ARGS+=(--quit-after "$QUIT_AFTER")
fi
if [[ "$IMPORT_ONLY" -eq 1 ]]; then
    GODOT_ARGS+=(--import)
fi
if [[ -n "$SCENE" ]]; then
    GODOT_ARGS+=(--scene "$SCENE")
fi

if [[ "$ENABLE_MCP_RUNTIME" -eq 1 ]]; then
    PROJECT_ARGS+=("--mcp-runtime-port=$RUNTIME_PORT")
else
    PROJECT_ARGS+=(--no-mcp-runtime)
fi

STDIO_LOG="${LOG%.*}.stdio.log"
mkdir -p "$(dirname "$LOG")"
: > "$LOG"
: > "$STDIO_LOG"

echo "Running Godot headless (timeout ${TIMEOUT_SEC}s)"
echo "Godot log: $LOG"
echo "Stdout/stderr: $STDIO_LOG"

set +e
if [[ "${#ENV_ARGS[@]}" -gt 0 ]]; then
    timeout --kill-after=5 "$TIMEOUT_SEC" env "${ENV_ARGS[@]}" \
        "$GODOT" "${GODOT_ARGS[@]}" -- "${PROJECT_ARGS[@]}" >"$STDIO_LOG" 2>&1
else
    timeout --kill-after=5 "$TIMEOUT_SEC" \
        "$GODOT" "${GODOT_ARGS[@]}" -- "${PROJECT_ARGS[@]}" >"$STDIO_LOG" 2>&1
fi
STATUS=$?
set -e

if [[ "$STATUS" -eq 124 ]]; then
    echo "Godot timed out after ${TIMEOUT_SEC}s" >&2
elif [[ "$STATUS" -ne 0 ]]; then
    echo "Godot exited with status $STATUS" >&2
fi

exit "$STATUS"
