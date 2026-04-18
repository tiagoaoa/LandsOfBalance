#!/bin/bash
# Open an FBX/GLB asset in Blender, pre-imported and framed. Save the
# session as a .blend somewhere, then send your edits back to Godot with:
#
#   ./tools/sync_from_blender.sh <your.blend>
#
# Usage:
#   ./tools/edit_asset.sh <path-to-asset>
#
# Examples:
#   ./tools/edit_asset.sh assets/bobba/bobba_character.fbx
#   ./tools/edit_asset.sh player/character/archer/Archer.fbx
#   ./tools/edit_asset.sh assets/dragon.glb

set -euo pipefail
cd "$(dirname "$0")/.."

# Prefer Blender 4.5 LTS if installed (Blender 5.0's FBX importer/exporter
# operators are broken). Falls back to system `blender` otherwise.
if [[ -z "${BLENDER:-}" ]]; then
    if [[ -x "/home/talves/.local/blender-4.5/blender" ]]; then
        BLENDER="/home/talves/.local/blender-4.5/blender"
    else
        BLENDER="blender"
    fi
fi

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <asset-path>" >&2
    echo "Supported extensions: .fbx, .glb, .gltf" >&2
    exit 1
fi

ASSET="$1"
if [[ ! -f "$ASSET" ]]; then
    # try relative to project root
    if [[ -f "$PWD/$ASSET" ]]; then
        ASSET="$PWD/$ASSET"
    else
        echo "Asset not found: $ASSET" >&2
        exit 1
    fi
fi

ASSET_ABS="$(readlink -f "$ASSET")"
EXT="${ASSET_ABS##*.}"
case "${EXT,,}" in
    fbx|glb|gltf) ;;
    *) echo "Unsupported extension .$EXT (need fbx/glb/gltf)" >&2; exit 1 ;;
esac

# Blender 5.0's FBX importer only handles FBX v7100+. Older files (v6100
# is common on legacy Mixamo characters) are rejected. Detour through
# Godot's scene importer, which understands v6100, writing a temp GLB
# that Blender can open. The original FBX path is still stashed on the
# scene so sync_from_blender.sh writes back to a sibling .glb of the
# original.
# Blender's FBX addon refuses FBX v6100 files outright (needs v7100+).
# Route those through Godot for conversion to a temp GLB and open that.
# The original FBX path is still stashed so sync writes to sibling .fbx
# — this will only succeed if Blender later exports back to a modern FBX
# (v7100+), which it does by default.
BLENDER_ASSET="$ASSET_ABS"
if [[ "${EXT,,}" == "fbx" ]]; then
    FBX_VERSION="$(file "$ASSET_ABS" | grep -oE 'version [0-9]+' | awk '{print $2}')"
    if [[ -n "$FBX_VERSION" && "$FBX_VERSION" -lt 7100 ]]; then
        TMP_GLB="$(mktemp --suffix=.glb)"
        RESOURCE_PATH="res://${ASSET_ABS#$PWD/}"
        echo "FBX version $FBX_VERSION is too old for Blender — routing via Godot → $TMP_GLB"
        GODOT="${GODOT:-/home/talves/bin/godot}"
        "$GODOT" --headless --script "$PWD/tools/godot_fbx_to_glb.gd" -- \
            "$RESOURCE_PATH" "$TMP_GLB" > /tmp/lob_fbx_convert.log 2>&1
        if ! grep -q "\[godot_fbx_to_glb\] Wrote" /tmp/lob_fbx_convert.log; then
            echo "Godot-side FBX→GLB conversion failed:"
            tail -20 /tmp/lob_fbx_convert.log
            exit 1
        fi
        BLENDER_ASSET="$TMP_GLB"
    fi
fi

echo "Opening $BLENDER_ASSET in Blender ($BLENDER)…"
if [[ "$BLENDER_ASSET" != "$ASSET_ABS" ]]; then
    echo "  (Godot-converted proxy; original: $ASSET_ABS)"
    echo "  Sync will write back to the original .fbx via Blender's modern exporter."
fi
echo "When done: save your .blend, then run"
echo "  ./tools/sync_from_blender.sh <your.blend>"
echo ""

# LOB_ASSET is what Blender imports; LOB_SOURCE_ORIGIN is the original
# destination the export script should write to (possibly different path
# + extension than the imported proxy).
LOB_ASSET="$BLENDER_ASSET" LOB_SOURCE_ORIGIN="$ASSET_ABS" \
    exec "$BLENDER" --python "$PWD/tools/blender_import.py"
