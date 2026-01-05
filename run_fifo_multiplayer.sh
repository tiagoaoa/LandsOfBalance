#!/bin/bash
# FIFO-based Multiplayer Test Script
# Launches the FIFO mock server and multiple Godot player instances

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_DIR="$SCRIPT_DIR/server"
FIFO_SERVER="$SERVER_DIR/fifo_server"

# Number of players (default: 2)
NUM_PLAYERS=${1:-2}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=========================================${NC}"
echo -e "${BLUE}  FIFO Multiplayer Test Launcher${NC}"
echo -e "${BLUE}=========================================${NC}"
echo ""

# Check if server exists, build if not
if [ ! -f "$FIFO_SERVER" ]; then
    echo -e "${YELLOW}Building FIFO server...${NC}"
    cd "$SERVER_DIR"
    make fifo
    cd "$SCRIPT_DIR"
fi

# Cleanup function
cleanup() {
    echo ""
    echo -e "${YELLOW}Cleaning up...${NC}"

    # Kill server if running
    if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
        echo "Stopping FIFO server (PID: $SERVER_PID)"
        kill "$SERVER_PID" 2>/dev/null || true
    fi

    # Kill Godot instances
    for pid in "${GODOT_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            echo "Stopping Godot (PID: $pid)"
            kill "$pid" 2>/dev/null || true
        fi
    done

    # Remove FIFOs
    echo "Removing FIFOs..."
    rm -f /tmp/lob_player*_to_server /tmp/lob_server_to_player*

    echo -e "${GREEN}Cleanup complete.${NC}"
}

trap cleanup EXIT INT TERM

# Remove any existing FIFOs
rm -f /tmp/lob_player*_to_server /tmp/lob_server_to_player*

echo -e "${GREEN}Starting FIFO server for $NUM_PLAYERS players...${NC}"
"$FIFO_SERVER" "$NUM_PLAYERS" &
SERVER_PID=$!
echo "Server PID: $SERVER_PID"

# Wait for FIFOs to be created
echo "Waiting for FIFOs to be created..."
sleep 1

# Check if FIFOs exist
for i in $(seq 1 $NUM_PLAYERS); do
    if [ ! -p "/tmp/lob_player${i}_to_server" ]; then
        echo -e "${RED}Error: FIFO /tmp/lob_player${i}_to_server not created${NC}"
        exit 1
    fi
    if [ ! -p "/tmp/lob_server_to_player${i}" ]; then
        echo -e "${RED}Error: FIFO /tmp/lob_server_to_player${i} not created${NC}"
        exit 1
    fi
done

echo -e "${GREEN}FIFOs created successfully.${NC}"
echo ""

# Find Godot executable
GODOT=""
if command -v godot &> /dev/null; then
    GODOT="godot"
elif command -v godot4 &> /dev/null; then
    GODOT="godot4"
elif [ -f "/usr/bin/godot" ]; then
    GODOT="/usr/bin/godot"
else
    echo -e "${RED}Error: Godot not found. Please install Godot or add it to PATH.${NC}"
    exit 1
fi

echo -e "${GREEN}Found Godot: $GODOT${NC}"
echo ""

# Launch Godot instances
GODOT_PIDS=()
echo -e "${GREEN}Launching $NUM_PLAYERS Godot player instances...${NC}"
echo ""
echo -e "${YELLOW}NOTE: In each Godot instance, you'll need to:${NC}"
echo "1. Enable FIFO mode in the multiplayer settings"
echo "2. Set the player ID (1, 2, etc.)"
echo "3. Connect to the FIFO server"
echo ""

for i in $(seq 1 $NUM_PLAYERS); do
    echo "Launching Player $i..."

    # Calculate window position (side by side)
    WINDOW_X=$((100 + (i - 1) * 800))
    WINDOW_Y=100

    # Launch Godot with player ID as command line argument
    # Note: The game needs to parse --player-id from command line
    "$GODOT" --path "$SCRIPT_DIR" --player-id=$i --windowed --position $WINDOW_X,$WINDOW_Y &
    GODOT_PIDS+=($!)

    echo "  Player $i PID: ${GODOT_PIDS[$((i-1))]}"
    sleep 0.5
done

echo ""
echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN}  All instances launched!${NC}"
echo -e "${GREEN}=========================================${NC}"
echo ""
echo "Server PID: $SERVER_PID"
echo "Player PIDs: ${GODOT_PIDS[*]}"
echo ""
echo "Press Ctrl+C to stop all instances and cleanup."
echo ""

# Wait for server to exit
wait $SERVER_PID
