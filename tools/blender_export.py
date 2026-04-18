# Headless Blender export script — re-exports the currently opened .blend
# back to the `LOB_TARGET` path (or the scene's `lob_source_asset`
# property if the target isn't explicitly set). Used by
# tools/sync_from_blender.sh. Not meant to run interactively.

import bpy
import os
import sys


def _target() -> str:
    env_target = os.environ.get("LOB_TARGET", "").strip()
    if env_target:
        return env_target
    scene_target = bpy.context.scene.get("lob_source_asset", "")
    return str(scene_target)


def _export_fbx(path: str) -> None:
    # Runs under Blender 4.5 LTS — full FBX exporter is available.
    bpy.ops.export_scene.fbx(
        filepath=path,
        use_selection=False,
        apply_unit_scale=True,
        apply_scale_options="FBX_SCALE_ALL",
        object_types={"ARMATURE", "MESH", "EMPTY"},
        use_mesh_modifiers=True,
        mesh_smooth_type="FACE",
        add_leaf_bones=False,
        bake_anim=True,
        bake_anim_use_all_bones=True,
        bake_anim_use_nla_strips=False,
        bake_anim_use_all_actions=False,
        bake_anim_force_startend_keying=True,
        path_mode="COPY",
        embed_textures=False,
    )


def _export_gltf(path: str) -> None:
    # .glb = binary, .gltf = separate textures; Blender's exporter chooses
    # based on `export_format`.
    ext = os.path.splitext(path)[1].lower()
    export_format = "GLB" if ext == ".glb" else "GLTF_SEPARATE"
    bpy.ops.export_scene.gltf(
        filepath=path,
        export_format=export_format,
        export_apply=True,
        export_yup=True,
        export_animations=True,
        export_skins=True,
    )


def main():
    target = _target()
    if not target:
        print("[lob] No export target (neither LOB_TARGET nor scene.lob_source_asset set)", file=sys.stderr)
        sys.exit(2)

    target = os.path.abspath(target)
    target_dir = os.path.dirname(target)
    if not os.path.isdir(target_dir):
        print("[lob] Target directory does not exist:", target_dir, file=sys.stderr)
        sys.exit(2)

    ext = os.path.splitext(target)[1].lower()
    try:
        if ext == ".fbx":
            _export_fbx(target)
        elif ext in (".glb", ".gltf"):
            _export_gltf(target)
        else:
            print("[lob] Unsupported target extension:", ext, file=sys.stderr)
            sys.exit(2)
    except Exception as e:
        print("[lob] Export failed:", e, file=sys.stderr)
        sys.exit(1)

    print("[lob] Exported to", target)


main()
