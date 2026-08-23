#!/usr/bin/env bash
# Run the gateway against the checked-out game on this machine's desktop.
# The game opens as a normal window on $DISPLAY and only that window is
# streamed; nothing virtual is needed. Open http://localhost:8080.
set -euo pipefail
cd "$(dirname "$0")/.."
export LOB_GODOT="${LOB_GODOT:-/home/talves/bin/godot}"
export LOB_GAME_DIR="${LOB_GAME_DIR:-$(cd .. && pwd)}"
export LOB_DISPLAY_MODE="${LOB_DISPLAY_MODE:-existing}"
go build -o bin/lobcloud ./cmd/lobcloud
exec bin/lobcloud "$@"
