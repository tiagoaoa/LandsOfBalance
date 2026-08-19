"""Bake the game's character rigs + Mixamo animation FBXs into one GLB per
character, with every clip named exactly like the Godot AnimationPlayer key.

The Godot build keeps the rigged mesh (assets/characters/*.glb, no clips) and
loads each animation from its own FBX at runtime, retargeting by bone name.
The browser can't afford ~30 FBX parses per character, so we do the same
retarget once, offline, and ship a single GLB with named AnimationClips.

Retarget method: the FBX rigs name bones `mixamorig:Hips` while the GLB rig
(round-tripped through glTF) names them `mixamorig_Hips`, and the two
importers disagree about bone roll. Matching local rotations would therefore
be wrong, so we constrain the target bones to the source bones in WORLD space
and bake — roll- and rest-pose-independent.

Run:
    blender --background --python scripts/bake_characters.py
"""

import math
import os
import sys

import bpy
from mathutils import Vector

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "public", "assets", "characters"))

ARMED = "player/character/armed"
UNARMED = "player/character/unarmed"
ARCHER = "player/character/archer"

# clip name -> source FBX. Mirrors ARMED_ANIM_PATHS / ARCHER_ANIM_PATHS in
# player/player.gd, including the clips borrowed across packs.
PALADIN_CLIPS = {
    "Idle": f"{ARMED}/Idle.fbx",
    "Walk": f"{ARMED}/Walk.fbx",
    "Run": f"{ARMED}/Run.fbx",
    "Jump": f"{ARMED}/Jump.fbx",
    "Attack1": f"{ARMED}/Attack1.fbx",
    "Attack2": f"{ARMED}/Attack2.fbx",
    "SwordSlash": f"{ARMED}/SwordSlash.fbx",
    "Block": f"{ARMED}/Block.fbx",
    "Sheath": f"{ARMED}/Sheath.fbx",
    "SpellCast": f"{ARMED}/SpellCast.fbx",
    "Estus": f"{ARMED}/PowerUp.fbx",
    "StrafeLeft": f"{UNARMED}/StrafeLeft.fbx",
    "StrafeRight": f"{UNARMED}/StrafeRight.fbx",
    "TurnLeft": f"{UNARMED}/TurnLeft.fbx",
    "TurnRight": f"{UNARMED}/TurnRight.fbx",
    "DodgeF": f"{ARCHER}/standing dodge forward.fbx",
    "DodgeB": f"{ARCHER}/standing dodge backward.fbx",
    "DodgeL": f"{ARCHER}/standing dodge left.fbx",
    "DodgeR": f"{ARCHER}/standing dodge right.fbx",
    "ReactHit": f"{ARCHER}/standing react small from front.fbx",
    "Death": f"{ARCHER}/standing death backward 01.fbx",
    "WalkBack": f"{ARCHER}/standing walk back.fbx",
    "RunBack": f"{ARCHER}/standing run back.fbx",
}

ARCHER_CLIPS = {
    "Idle": f"{ARCHER}/Idle.fbx",
    "Walk": f"{ARCHER}/Walk.fbx",
    "Run": f"{ARCHER}/Run.fbx",
    "Sprint": f"{ARCHER}/Sprint.fbx",
    "Jump": f"{ARCHER}/Jump.fbx",
    "Attack": f"{ARCHER}/Attack.fbx",
    "Block": f"{ARCHER}/Block.fbx",
    "SpellCast": f"{ARCHER}/Archer_Spell.fbx",
    "Estus": f"{ARMED}/PowerUp.fbx",
    "ReactHit": f"{ARCHER}/standing react small from front.fbx",
    "Death": f"{ARCHER}/standing death backward 01.fbx",
    "Sheath": f"{ARCHER}/standing disarm bow.fbx",
    "DodgeF": f"{ARCHER}/standing dodge forward.fbx",
    "DodgeB": f"{ARCHER}/standing dodge backward.fbx",
    "DodgeL": f"{ARCHER}/standing dodge left.fbx",
    "DodgeR": f"{ARCHER}/standing dodge right.fbx",
    "StrafeLeft": f"{ARCHER}/standing walk left.fbx",
    "StrafeRight": f"{ARCHER}/standing walk right.fbx",
    "RunStrafeLeft": f"{ARCHER}/standing run left.fbx",
    "RunStrafeRight": f"{ARCHER}/standing run right.fbx",
    "WalkBack": f"{ARCHER}/standing walk back.fbx",
    "RunBack": f"{ARCHER}/standing run back.fbx",
    "AimWalk": f"{ARCHER}/standing aim walk forward.fbx",
    "AimWalkBack": f"{ARCHER}/standing aim walk back.fbx",
    "AimStrafeLeft": f"{ARCHER}/standing aim walk left.fbx",
    "AimStrafeRight": f"{ARCHER}/standing aim walk right.fbx",
    "TurnLeft": f"{ARCHER}/standing turn 90 left.fbx",
    "TurnRight": f"{ARCHER}/standing turn 90 right.fbx",
}

TARGETS = [
    ("paladin", "assets/characters/paladin_armed_v2.glb", PALADIN_CLIPS),
    ("archer", "assets/characters/archer_v2.glb", ARCHER_CLIPS),
]

# Hips XZ translation is stripped so every clip plays in place — the game
# drives world movement from velocity, exactly as the Godot build does.
STRIP_ROOT_MOTION = True


def log(msg):
    print(f"[bake] {msg}", flush=True)
    sys.stdout.flush()


def wipe():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def norm(name):
    """FBX `mixamorig:Hips` -> GLB `mixamorig_Hips`."""
    return name.replace(":", "_")


def action_fcurves(action):
    """Blender 4.4+ moved F-curves under layers/strips/channelbags (the old
    `action.fcurves` is gone in 5.0). Yield them wherever they live."""
    if hasattr(action, "fcurves"):
        yield from action.fcurves
        return
    for layer in action.layers:
        for strip in layer.strips:
            for bag in strip.channelbags:
                yield from bag.fcurves


def armature_of(objects):
    for o in objects:
        if o.type == "ARMATURE":
            return o
    return None


def rig_height(arm):
    """World-space Y extent of the rig's bones — used to match rig scales."""
    lo, hi = math.inf, -math.inf
    mw = arm.matrix_world
    for b in arm.data.bones:
        for p in (b.head_local, b.tail_local):
            y = (mw @ Vector(p)).y
            lo, hi = min(lo, y), max(hi, y)
    return max(hi - lo, 1e-6)


def import_glb(path):
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=path)
    return [o for o in bpy.data.objects if o not in before]


def import_fbx(path):
    before = set(bpy.data.objects)
    # Blender 5.0's C++ importer. It keeps the FBX's native bone orientation,
    # which is fine — the retarget bakes in world space, so roll never enters
    # the picture. (The legacy `import_scene.fbx` addon fails to register its
    # RNA properties in this build, so it is unusable.)
    bpy.ops.wm.fbx_import(
        filepath=path,
        use_anim=True,
        ignore_leaf_bones=True,
    )
    return [o for o in bpy.data.objects if o not in before]


def source_action(objs):
    for o in objs:
        if o.type == "ARMATURE" and o.animation_data and o.animation_data.action:
            return o.animation_data.action
    return None


def bake_clip(target, src_arm, action, clip_name):
    """Constrain target bones to src bones in world space and bake."""
    # Match the source rig's scale to the target's so world-space location
    # copies (hips bob) land at the right magnitude.
    bpy.context.view_layer.update()
    # Multiply, never overwrite: the importer already puts Mixamo's
    # centimetre rigs at 0.01, and clobbering that would blow the rig up 100x.
    ratio = rig_height(target) / rig_height(src_arm)
    src_arm.scale = tuple(s * ratio for s in src_arm.scale)
    src_arm.location = target.location
    bpy.context.view_layer.update()

    src_names = {norm(b.name): b.name for b in src_arm.pose.bones}
    constrained = []
    for pb in target.pose.bones:
        sname = src_names.get(pb.name)
        if sname is None:
            continue
        c = pb.constraints.new("COPY_ROTATION")
        c.target = src_arm
        c.subtarget = sname
        c.target_space = "WORLD"
        c.owner_space = "WORLD"
        constrained.append(pb)
        if pb.name.endswith("_Hips"):
            cl = pb.constraints.new("COPY_LOCATION")
            cl.target = src_arm
            cl.subtarget = sname
            cl.target_space = "WORLD"
            cl.owner_space = "WORLD"

    if not constrained:
        raise RuntimeError(f"no bones matched for clip {clip_name}")

    start = int(math.floor(action.frame_range[0]))
    end = int(math.ceil(action.frame_range[1]))
    if end <= start:
        end = start + 1

    bpy.ops.object.select_all(action="DESELECT")
    target.select_set(True)
    bpy.context.view_layer.objects.active = target
    bpy.ops.object.mode_set(mode="POSE")
    bpy.ops.pose.select_all(action="SELECT")
    bpy.ops.nla.bake(
        frame_start=start,
        frame_end=end,
        only_selected=True,
        visual_keying=True,
        clear_constraints=True,
        clear_parents=False,
        use_current_action=False,
        bake_types={"POSE"},
    )
    bpy.ops.object.mode_set(mode="OBJECT")

    baked = target.animation_data.action
    baked.name = clip_name
    baked.use_fake_user = True

    # Any constraint the bake didn't clear (it clears only selected bones).
    for pb in target.pose.bones:
        for c in list(pb.constraints):
            pb.constraints.remove(c)

    if STRIP_ROOT_MOTION:
        for fc in action_fcurves(baked):
            if fc.data_path.endswith(".location") and "_Hips" in fc.data_path and fc.array_index in (0, 2):
                for kp in fc.keyframe_points:
                    kp.co[1] = 0.0
                    kp.handle_left[1] = 0.0
                    kp.handle_right[1] = 0.0

    target.animation_data.action = None
    return baked


def build(name, glb_rel, clips):
    wipe()
    glb_path = os.path.join(REPO, glb_rel)
    log(f"=== {name}: {glb_rel}")
    char_objs = import_glb(glb_path)
    target = armature_of(char_objs)
    if target is None:
        raise RuntimeError(f"{glb_rel} has no armature")
    log(f"    target rig '{target.name}' with {len(target.pose.bones)} bones")

    baked_names = []
    for clip_name, rel in clips.items():
        path = os.path.join(REPO, rel)
        if not os.path.exists(path):
            log(f"    !! MISSING {rel} — skipping {clip_name}")
            continue
        keep = set(bpy.data.objects)
        imported = import_fbx(path)
        src_arm = armature_of(imported)
        action = source_action(imported)
        if src_arm is None or action is None:
            log(f"    !! no animated rig in {rel} — skipping {clip_name}")
            for o in imported:
                bpy.data.objects.remove(o, do_unlink=True)
            continue
        try:
            bake_clip(target, src_arm, action, clip_name)
            baked_names.append(clip_name)
            log(f"    baked {clip_name} ({rel})")
        finally:
            for o in list(bpy.data.objects):
                if o not in keep and o is not target:
                    bpy.data.objects.remove(o, do_unlink=True)

    # Stack every baked action as its own NLA strip so the glTF exporter
    # emits one AnimationClip per clip name.
    if target.animation_data is None:
        target.animation_data_create()
    for clip_name in baked_names:
        act = bpy.data.actions[clip_name]
        track = target.animation_data.nla_tracks.new()
        track.name = clip_name
        strip = track.strips.new(clip_name, int(act.frame_range[0]), act)
        strip.name = clip_name
        track.mute = True

    out_path = os.path.join(OUT, f"{name}.glb")
    os.makedirs(OUT, exist_ok=True)
    bpy.ops.export_scene.gltf(
        filepath=out_path,
        export_format="GLB",
        export_animations=True,
        export_animation_mode="NLA_TRACKS",
        export_skins=True,
        export_morph=False,
        export_apply=False,
        export_yup=True,
        export_image_format="JPEG",
    )
    size = os.path.getsize(out_path) / 1024 / 1024
    log(f"    -> {out_path} ({size:.1f} MB, {len(baked_names)} clips)")
    log(f"    clips: {', '.join(baked_names)}")


def build_static(rel_in, name):
    """Mesh-only convert (skeleton rig is animated procedurally in code)."""
    wipe()
    path = os.path.join(REPO, rel_in)
    if not os.path.exists(path):
        log(f"!! MISSING {rel_in}")
        return
    log(f"=== {name}: {rel_in}")
    if path.lower().endswith(".fbx"):
        import_fbx(path)
    else:
        import_glb(path)
    # The skeleton FBX ships C4D editor baggage the game strips at load.
    for junk in ("CINEMA_4D_Editor", "Null"):
        o = bpy.data.objects.get(junk)
        if o:
            bpy.data.objects.remove(o, do_unlink=True)
    os.makedirs(OUT, exist_ok=True)
    out_path = os.path.join(OUT, f"{name}.glb")
    bpy.ops.export_scene.gltf(
        filepath=out_path,
        export_format="GLB",
        export_animations=False,
        export_skins=True,
        export_yup=True,
        export_image_format="JPEG",
    )
    log(f"    -> {out_path} ({os.path.getsize(out_path)/1024/1024:.1f} MB)")


if __name__ == "__main__":
    # `-- --smoke` bakes two clips of one character so the export path can be
    # validated in seconds instead of minutes.
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    if "--smoke" in argv:
        name, glb, clips = TARGETS[0]
        build(name, glb, {k: clips[k] for k in ("Idle", "SwordSlash")})
    else:
        for name, glb, clips in TARGETS:
            build(name, glb, clips)
        build_static("assets/skeleton/skeleton_axe.fbx", "skeleton_axe")
    log("done")
