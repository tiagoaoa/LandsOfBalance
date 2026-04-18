# Startup script for Blender — imports the asset specified by the
# `LOB_ASSET` environment variable, wipes the default scene, and remembers
# the source path in a custom scene property so the companion export
# script can send the edits back to the same file.
#
# Used by tools/edit_asset.sh. Do not invoke directly.

import bpy
import os
import sys


def _clear_default_scene():
    for obj in list(bpy.data.objects):
        bpy.data.objects.remove(obj, do_unlink=True)


def _import(path: str) -> None:
    ext = os.path.splitext(path)[1].lower()
    if ext == ".fbx":
        bpy.ops.import_scene.fbx(filepath=path)
    elif ext in (".glb", ".gltf"):
        bpy.ops.import_scene.gltf(filepath=path)
    else:
        raise RuntimeError("Unsupported asset type: %s" % ext)


def _frame_all():
    # Select everything, then frame the 3D viewport on the selection.
    for obj in bpy.data.objects:
        obj.select_set(True)
    for area in bpy.context.screen.areas:
        if area.type == "VIEW_3D":
            ctx = {"area": area, "region": area.regions[-1]}
            try:
                with bpy.context.temp_override(**ctx):
                    bpy.ops.view3d.view_selected()
            except Exception:
                pass


def main():
    asset = os.environ.get("LOB_ASSET")
    if not asset:
        print("[lob] LOB_ASSET not set; nothing to import.")
        return
    if not os.path.exists(asset):
        print("[lob] Asset not found:", asset)
        return

    _clear_default_scene()
    try:
        _import(asset)
    except Exception as e:
        print("[lob] Import failed:", e, file=sys.stderr)
        return

    # Stash source path on the Scene so the export script can find it.
    # When LOB_SOURCE_ORIGIN is set (edit_asset.sh routed an old-format FBX
    # through Godot), we want to export back to the ORIGINAL path on sync,
    # not the temp GLB we imported from.
    origin = os.environ.get("LOB_SOURCE_ORIGIN", asset)
    bpy.context.scene["lob_source_asset"] = origin
    bpy.context.scene["lob_source_kind"] = os.path.splitext(origin)[1].lower()
    bpy.context.scene["lob_imported_proxy"] = asset

    _frame_all()
    print("[lob] Imported", asset)
    print("[lob] When you're done, save the .blend and run:")
    print("      ./tools/sync_from_blender.sh <your.blend>")


main()
