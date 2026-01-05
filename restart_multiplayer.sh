#!/bin/bash
# Restart multiplayer test environment: server, bot, and Godot client

PROJECT_DIR="/home/talves/mthings/LandsOfBalance"
GODOT="/home/talves/bin/godot"

echo "Stopping existing processes..."
pkill -9 game_server 2>/dev/null
pkill -9 bot_client 2>/dev/null
pkill -9 godot 2>/dev/null
sleep 0.5

echo "Starting game server..."
cd "$PROJECT_DIR/server"
./game_server &
sleep 0.5

echo "Starting bot client..."
./bot_client 1 &
sleep 0.5

echo "Starting Godot client..."
cd "$PROJECT_DIR"
$GODOT --path "$PROJECT_DIR" game.tscn &

echo ""
echo "All processes started!"
echo "  - game_server (background)"
echo "  - bot_client 1 (background)"
echo "  - godot client (background)"
echo ""
echo "Use 'pkill game_server bot_client godot' to stop all"
