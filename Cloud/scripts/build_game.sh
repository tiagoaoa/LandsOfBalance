#!/usr/bin/env bash
# Export the game as a self-contained Linux binary (build/lob_server.x86_64)
# for the container image. Needs the matching export templates installed.
set -euo pipefail
cd "$(dirname "$0")/../.."
GODOT="${GODOT:-/home/talves/bin/godot}"
OUT="${1:-build/lob_server.x86_64}"
mkdir -p "$(dirname "$OUT")"
timeout 600 "$GODOT" --headless --path . --export-release Linux "$OUT"
ls -la "$OUT"
