#!/bin/bash
# Export, install and launch the Android build.
#
# Usage:
#   ./tools/deploy_mobile.sh              export, install, launch
#   ./tools/deploy_mobile.sh --no-launch  stop after installing
#   ./tools/deploy_mobile.sh --install    skip the export, install what's built
#
# Notes earned the hard way on this machine:
#   * adb's daemon regularly reports "no devices" on its FIRST call after
#     starting. The device is there; the call is too early. Every adb step
#     retries rather than failing.
#   * Godot's importer and exporter have both been OOM-killed here (exit 137)
#     when the browser is holding memory, so free RAM is checked up front and
#     a kill is reported as such instead of as a mystery failure.
#   * node_modules under lands-of-balance-*/ used to be packed into the game.
#     They carry .gdignore now; the size check below is what would catch a
#     regression of that (it was 495 MB, now ~355 MB).

set -uo pipefail
cd "$(dirname "$0")/.."

GODOT="${GODOT:-/home/talves/bin/godot}"
ADB="${ADB:-$HOME/Android/Sdk/platform-tools/adb}"
PRESET="${PRESET:-Android}"
PKG="com.tpgame.douglassthekeeper"
ACTIVITY="com.godot.game.GodotApp"
APK="$PWD/build/douglass_the_keeper.apk"

DO_EXPORT=1
DO_LAUNCH=1
for arg in "$@"; do
    case "$arg" in
        --install)   DO_EXPORT=0 ;;
        --no-launch) DO_LAUNCH=0 ;;
        *) echo "unknown option: $arg"; exit 2 ;;
    esac
done

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

# adb, but tolerant of the daemon not being up yet.
adb_retry() {
    local tries=0
    until "$ADB" "$@"; do
        tries=$((tries + 1))
        if [ "$tries" -ge 4 ]; then
            echo "adb $* failed after $tries attempts" >&2
            return 1
        fi
        sleep 2
    done
}

wait_for_device() {
    say "Waiting for device"
    "$ADB" start-server >/dev/null 2>&1
    for _ in $(seq 1 15); do
        if "$ADB" get-state 2>/dev/null | grep -q device; then
            "$ADB" devices | sed -n '2p'
            return 0
        fi
        sleep 2
    done
    echo "No device. Plug the phone in, unlock it, and allow USB debugging." >&2
    return 1
}

if [ "$DO_EXPORT" = 1 ]; then
    AVAIL=$(free -m | awk '/^Mem:/ {print $7}')
    say "Exporting $PRESET  (${AVAIL} MB RAM available)"
    if [ "$AVAIL" -lt 700 ]; then
        echo "WARNING: under 700 MB free — the exporter has been OOM-killed here."
        echo "         Close some browser tabs if this dies with exit 137."
    fi
    mkdir -p build
    "$GODOT" --headless --export-debug "$PRESET" "$APK"
    rc=$?
    if [ "$rc" -eq 137 ]; then
        echo "Export was OOM-KILLED (137). Free some memory and retry." >&2
        exit 137
    elif [ "$rc" -ne 0 ]; then
        echo "Export failed (exit $rc)." >&2
        exit "$rc"
    fi
fi

[ -f "$APK" ] || { echo "No APK at $APK — run without --install first." >&2; exit 1; }
say "APK: $(du -h "$APK" | cut -f1)  ($(date -r "$APK" '+%H:%M:%S'))"

wait_for_device || exit 1

say "Installing"
adb_retry install -r "$APK" | tail -3 || exit 1

if [ "$DO_LAUNCH" = 1 ]; then
    say "Launching"
    adb_retry shell am force-stop "$PKG" >/dev/null
    adb_retry shell am start -n "$PKG/$ACTIVITY" | tail -1
    sleep 8
    PID=$(adb_retry shell pidof "$PKG" 2>/dev/null | tr -d '\r')
    if [ -n "$PID" ]; then
        echo "Running (pid $PID)"
    else
        echo "Not running — the phone may be locked. Unlock it and open the game."
    fi
fi

say "Done"
echo "Logs:  $ADB logcat -d -s godot:*"
