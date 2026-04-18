#!/bin/bash
# Re-export a .blend file back to its original Godot asset location so the
# engine picks up the changes on next editor focus.
#
# The target path is normally stored on the scene's `lob_source_asset`
# custom property — set automatically when you opened the file via
# ./tools/edit_asset.sh. If that's missing (you opened Blender manually),
# pass an explicit target as the second argument.
#
# Usage:
#   ./tools/sync_from_blender.sh <your.blend>
#   ./tools/sync_from_blender.sh <your.blend> <target-path>
#
# Examples:
#   ./tools/sync_from_blender.sh /tmp/paladin_edit.blend
#   ./tools/sync_from_blender.sh /tmp/paladin_edit.blend player/character/armed/Paladin.fbx

set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -z "${BLENDER:-}" ]]; then
    if [[ -x "/home/talves/.local/blender-4.5/blender" ]]; then
        BLENDER="/home/talves/.local/blender-4.5/blender"
    else
        BLENDER="blender"
    fi
fi

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <your.blend> [target-path]" >&2
    exit 1
fi

BLEND="$1"
TARGET="${2:-}"

if [[ ! -f "$BLEND" ]]; then
    echo ".blend file not found: $BLEND" >&2
    exit 1
fi

BLEND_ABS="$(readlink -f "$BLEND")"

if [[ -n "$TARGET" ]]; then
    # If target is relative, resolve against project root.
    if [[ ! "$TARGET" = /* ]]; then
        TARGET="$PWD/$TARGET"
    fi
    TARGET_ABS="$(readlink -f -m "$TARGET")"
    export LOB_TARGET="$TARGET_ABS"
    echo "Exporting $BLEND_ABS → $TARGET_ABS"
else
    echo "Exporting $BLEND_ABS → (target from scene.lob_source_asset)"
fi

LOG=$(mktemp)
"$BLENDER" --background "$BLEND_ABS" \
    --python "$PWD/tools/blender_export.py" \
    > "$LOG" 2>&1 || true
sed -e "s/^/  /" "$LOG"

EXIT_CODE=0
if ! grep -q "\[lob\] Exported to" "$LOG"; then
    EXIT_CODE=1
fi

rm -f "$LOG"

if [[ $EXIT_CODE -ne 0 ]]; then
    echo ""
    echo "Export failed — see log above." >&2
    exit $EXIT_CODE
fi

echo ""
echo "Done. Focus the Godot editor to trigger a re-import."
echo "If Godot is not open, the new file will be imported on next launch."
