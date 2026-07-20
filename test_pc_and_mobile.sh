#!/bin/bash
# Test multiplayer with one desktop window and mobile device via USB
# Desktop uses 127.0.0.1, Mobile uses network IP

PROJECT_DIR="/home/talves/mthings/LandsOfBalance"
GODOT="/home/talves/bin/godot"
PACKAGE_NAME="com.tpgame.douglassthekeeper"
APK_PATH="/tmp/douglassthekeeper.apk"

# Window settings
WINDOW_WIDTH=960
WINDOW_HEIGHT=540

echo "=== PC + Mobile Multiplayer Test ==="

# Get local network IP
LOCAL_IP=$(ip route get 1 2>/dev/null | awk '{print $7; exit}')
if [ -z "$LOCAL_IP" ]; then
    LOCAL_IP=$(hostname -I | awk '{print $1}')
fi

if [ -z "$LOCAL_IP" ]; then
    echo "ERROR: Could not determine local IP address"
    exit 1
fi

echo "Local IP: $LOCAL_IP"

# Check if ADB device is connected
if ! adb devices | grep -q "device$"; then
    echo "ERROR: No Android device connected via USB"
    echo "Please connect your phone and enable USB debugging"
    exit 1
fi

DEVICE_NAME=$(adb devices -l | grep "device " | head -1 | sed 's/.*model:\([^ ]*\).*/\1/')
echo "Mobile device: $DEVICE_NAME"

# Check current server address in protocol.gd
CURRENT_SERVER=$(grep "DEFAULT_SERVER" "$PROJECT_DIR/multiplayer/protocol.gd" | sed 's/.*"\(.*\)".*/\1/')
echo "Current server in protocol.gd: $CURRENT_SERVER"

# Build mobile APK with network IP if needed
if [ "$CURRENT_SERVER" != "$LOCAL_IP" ]; then
    echo "Setting server to $LOCAL_IP for mobile APK..."
    sed -i "s/DEFAULT_SERVER: String = \".*\"/DEFAULT_SERVER: String = \"$LOCAL_IP\"/" "$PROJECT_DIR/multiplayer/protocol.gd"

    echo "Rebuilding APK with network IP..."
    cd "$PROJECT_DIR"
    $GODOT --export-debug "Android" "$APK_PATH" 2>&1 | tail -5

    if [ ! -f "$APK_PATH" ]; then
        echo "ERROR: APK export failed"
        exit 1
    fi

    echo "Installing APK on mobile device..."
    adb install -r "$APK_PATH"
    if [ $? -ne 0 ]; then
        echo "ERROR: APK installation failed"
        exit 1
    fi
    echo "APK installed successfully"
fi

# Set protocol.gd to localhost for desktop
echo "Setting server to 127.0.0.1 for desktop..."
sed -i "s/DEFAULT_SERVER: String = \".*\"/DEFAULT_SERVER: String = \"127.0.0.1\"/" "$PROJECT_DIR/multiplayer/protocol.gd"

# Kill any existing processes
echo ""
echo "Checking for existing processes..."

kill_if_running() {
    local process_name="$1"
    local pids=$(pgrep -f "$process_name" 2>/dev/null)
    if [ -n "$pids" ]; then
        echo "  Killing existing $process_name (PIDs: $pids)"
        pkill -9 -f "$process_name" 2>/dev/null
        return 0
    fi
    return 1
}

killed_something=false

if kill_if_running "game_server"; then killed_something=true; fi
if kill_if_running "godot"; then killed_something=true; fi

# Stop mobile app if running
adb shell am force-stop "$PACKAGE_NAME" 2>/dev/null

if [ "$killed_something" = true ]; then
    echo "  Waiting for processes to terminate..."
    sleep 0.5
else
    echo "  No existing processes found"
fi

# Start game server
echo ""
echo "Starting game server..."
cd "$PROJECT_DIR/server"
./game_server > /tmp/mp_server.log 2>&1 &
SERVER_PID=$!
sleep 0.5

# Check server started
if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo "Server failed to start!"
    cat /tmp/mp_server.log
    exit 1
fi

echo "Server running (PID $SERVER_PID)"
echo "  Desktop connects to: 127.0.0.1:7777"
echo "  Mobile connects to:  $LOCAL_IP:7777"

# Launch desktop client
echo ""
echo "Launching desktop client..."
cd "$PROJECT_DIR"
$GODOT --path "$PROJECT_DIR" \
    --resolution ${WINDOW_WIDTH}x${WINDOW_HEIGHT} \
    --position 0,100 \
    game.tscn &
DESKTOP_PID=$!
sleep 2

# Launch mobile client
echo "Launching mobile client..."
adb shell am start -n "$PACKAGE_NAME/com.godot.game.GodotApp"

echo ""
echo "==========================================="
echo "  PC + Mobile Test Running"
echo "==========================================="
echo "  Desktop: Window on left (PID $DESKTOP_PID) -> 127.0.0.1:7777"
echo "  Mobile:  $DEVICE_NAME -> $LOCAL_IP:7777"
echo "  Server:  PID $SERVER_PID"
echo ""
echo "Server log: tail -f /tmp/mp_server.log"
echo "Mobile log: adb logcat | grep godot"
echo ""
echo "Press Ctrl+C to stop all"
echo "==========================================="

# Cleanup on exit
cleanup() {
    echo ""
    echo "Stopping..."
    kill $DESKTOP_PID 2>/dev/null
    kill $SERVER_PID 2>/dev/null
    adb shell am force-stop "$PACKAGE_NAME" 2>/dev/null
    echo "Done"
}

trap cleanup EXIT

# Wait for user to stop
wait $DESKTOP_PID 2>/dev/null
