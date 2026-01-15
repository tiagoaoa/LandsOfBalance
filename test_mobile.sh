#!/bin/bash
# Deploy and test mobile version via USB-C
# Requires: Godot, adb (Android Debug Bridge)

PROJECT_DIR="/home/talves/mthings/LandsOfBalance"
GODOT="/home/talves/bin/godot"
APK_PATH="$PROJECT_DIR/build/douglass_the_keeper.apk"
PACKAGE_NAME="com.tpgame.douglassthekeeper"

echo "=== Mobile Deployment (Android via USB-C) ==="

# Check for adb
if ! command -v adb &> /dev/null; then
    echo "ERROR: adb not found. Install Android SDK platform-tools."
    echo "  sudo apt install adb"
    echo "  or download from: https://developer.android.com/studio/releases/platform-tools"
    exit 1
fi

# Check for connected device
echo "Checking for connected Android device..."
DEVICE=$(adb devices | grep -v "List" | grep "device$" | head -1 | cut -f1)

if [ -z "$DEVICE" ]; then
    echo "ERROR: No Android device connected."
    echo ""
    echo "Make sure:"
    echo "  1. USB debugging is enabled on your device"
    echo "     (Settings > Developer options > USB debugging)"
    echo "  2. Device is connected via USB-C"
    echo "  3. You've authorized this computer on the device"
    echo ""
    echo "Run 'adb devices' to check connection status."
    exit 1
fi

echo "Found device: $DEVICE"

# Create build directory
mkdir -p "$PROJECT_DIR/build"

# Export APK
echo ""
echo "Exporting Android APK..."
cd "$PROJECT_DIR"

# Kill any running Godot editor that might lock files
pkill -f "godot.*--editor" 2>/dev/null || true
sleep 0.5

$GODOT --headless --export-debug "Android" "$APK_PATH" 2>&1
EXPORT_RESULT=$?

if [ $EXPORT_RESULT -ne 0 ]; then
    echo "ERROR: Export failed with code $EXPORT_RESULT"
    echo ""
    echo "Common issues:"
    echo "  - Android export templates not installed"
    echo "  - Missing debug keystore"
    echo "  - Project errors"
    echo ""
    echo "Try opening the project in Godot editor and exporting manually first."
    exit 1
fi

if [ ! -f "$APK_PATH" ]; then
    echo "ERROR: APK file not created at $APK_PATH"
    exit 1
fi

APK_SIZE=$(du -h "$APK_PATH" | cut -f1)
echo "APK created: $APK_PATH ($APK_SIZE)"

# Uninstall old version (ignore errors if not installed)
echo ""
echo "Removing old installation (if exists)..."
adb -s "$DEVICE" uninstall "$PACKAGE_NAME" 2>/dev/null || true

# Install new APK
echo "Installing APK to device..."
adb -s "$DEVICE" install -r "$APK_PATH"
INSTALL_RESULT=$?

if [ $INSTALL_RESULT -ne 0 ]; then
    echo "ERROR: Installation failed with code $INSTALL_RESULT"
    echo ""
    echo "Common issues:"
    echo "  - Not enough storage on device"
    echo "  - APK signature mismatch (try uninstalling first)"
    echo "  - USB debugging not fully authorized"
    exit 1
fi

echo ""
echo "=== Installation Complete ==="

# Launch the app
echo "Launching app on device..."
adb -s "$DEVICE" shell am start -n "$PACKAGE_NAME/com.godot.game.GodotApp"

echo ""
echo "=== Douglass The Keeper is now running on your device ==="
echo ""
echo "Useful commands:"
echo "  adb logcat -s godot:V     # View Godot logs"
echo "  adb logcat | grep -i godot  # Filter all Godot messages"
echo "  adb shell am force-stop $PACKAGE_NAME  # Force stop app"
echo ""
