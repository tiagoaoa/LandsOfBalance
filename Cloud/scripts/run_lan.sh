#!/usr/bin/env bash
# Serve the game to browsers on the local network. The gateway listens on
# every interface; per player one game window opens on THIS desktop
# (existing-display mode) and is streamed to their browser. Leave those
# windows alone — clicking one lets it grab the real mouse.
set -euo pipefail
cd "$(dirname "$0")/.."
export LOB_GODOT="${LOB_GODOT:-/home/talves/bin/godot}"
export LOB_GAME_DIR="${LOB_GAME_DIR:-$(cd .. && pwd)}"
IP=$(ip -4 addr show | awk '/inet .*(wl|en|eth)/ {sub(/\/.*/,"",$2); print $2; exit}')
go build -o bin/lobcloud ./cmd/lobcloud
# The C multiplayer server: sessions whose players pick MULTIPLAYER in the
# menu all join it and share one match.
make -C "$LOB_GAME_DIR/server" >/dev/null
echo
echo "Players open:  http://${IP}:8080"
echo
exec bin/lobcloud -listen :8080 -display-mode existing -max-sessions 2 -game-server "$@"
