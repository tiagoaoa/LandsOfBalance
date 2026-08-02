"""Rig a generated body mesh onto an existing Mixamo character's skeleton.

The animations are the asset here: 71 clips are retargeted by BONE NAME onto
mixamorig_*, so the new character must ride the SAME skeleton. Rather than
compute fresh weights (heat-map weighting on an AI-generated mesh deforms
badly at the shoulders and hips), transfer the ORIGINAL mesh's vertex groups
onto the new one by proximity. The shipped mesh is already correctly
weighted, so the new body inherits deformation that is known to work.

That transfer is proximity-based, which is why the generated mesh must be
in a T-pose matching the armature's rest pose.

Weapons (sword, shield, bow, arrow) are kept from the original — only the
BODY is replaced.

  blender -b -P rig_character.py -- <orig.fbx> <new_body.glb> <out.glb> <keep1,keep2>
"""
import bpy, sys, os
from mathutils import Vector

argv = sys.argv[sys.argv.index("--") + 1:]
ORIG, NEWBODY, OUT = argv[0], argv[1], argv[2]
KEEP = [k for k in (argv[3].split(",") if len(argv) > 3 and argv[3] else []) if k]

bpy.ops.wm.read_factory_settings(use_empty=True)


def meshes():
    return [o for o in bpy.data.objects if o.type == 'MESH']


def bbox(o):
    pts = [o.matrix_world @ Vector(c) for c in o.bound_box]
    lo = Vector([min(p[i] for p in pts) for i in range(3)])
    hi = Vector([max(p[i] for p in pts) for i in range(3)])
    return lo, hi


# --- original character: armature, body meshes, kept weapon meshes ---------
bpy.ops.wm.fbx_import(filepath=ORIG)
arm = next(o for o in bpy.data.objects if o.type == 'ARMATURE')
orig_meshes = meshes()


def influences(o):
    """How many bones actually deform this mesh. Mesh NAMES in these FBXs do
    not match their data — on the armed Paladin the 7k-vert body is called
    "_Sword" — so classify by skinning instead: a body is driven by dozens of
    bones, a prop by one or two."""
    used = set()
    for v in o.data.vertices:
        for g in v.groups:
            if g.weight > 0.001:
                used.add(g.group)
    return used


def bone_names(o, groups):
    return sorted(o.vertex_groups[i].name for i in groups
                  if i < len(o.vertex_groups))


# A prop worth keeping hangs off a WEAPON joint. Anything else driven by one
# or two bones is a leftover scrap (eyes, a stray cap) that would float in
# space once the body under it is replaced.
WEAPON_BONES = ("Sword_joint", "Shield_joint", "arch")
infl = {o.name: influences(o) for o in orig_meshes}
for o in orig_meshes:
    bn = bone_names(o, infl[o.name])
    l, h = bbox(o)
    print("  mesh %-34s verts=%-6d bones=%-3d z=%.2f..%.2f  %s" % (
        o.name, len(o.data.vertices), len(bn), l.z, h.z,
        ",".join(b.replace("mixamorig:", "") for b in bn[:4])))

PROP_MAX_BONES = 4
keep_meshes = [o for o in orig_meshes
               if KEEP and len(infl[o.name]) <= PROP_MAX_BONES
               and any(w in b for b in bone_names(o, infl[o.name])
                       for w in WEAPON_BONES)]
body_meshes = [o for o in orig_meshes if o not in keep_meshes]
if not body_meshes:
    raise SystemExit("no body mesh to replace")

# Donor for the weight transfer: the mesh that COVERS the whole figure, not
# merely the one with the most bone influences — on the Archer the hair has
# 38 influences but spans only the head, and using it scaled the new body to
# a fifth of its size.
def zspan(o):
    l, h = bbox(o)
    return h.z - l.z


donor = max((o for o in body_meshes if len(infl[o.name]) >= 10),
            key=zspan, default=max(body_meshes, key=zspan))
print("DONOR", donor.name, "bones=%d zspan=%.2f" % (len(infl[donor.name]),
                                                    zspan(donor)))
# Union over EVERY body mesh — slicing this list dropped the first entry,
# which on the Archer was the full body, leaving only head-height bounds.
lo_o, hi_o = bbox(donor)
for o in body_meshes:
    l, h = bbox(o)
    lo_o = Vector([min(lo_o[i], l[i]) for i in range(3)])
    hi_o = Vector([max(hi_o[i], h[i]) for i in range(3)])
print("ORIG body bounds", [round(v, 3) for v in lo_o], [round(v, 3) for v in hi_o])

before = set(bpy.data.objects)
bpy.ops.import_scene.gltf(filepath=NEWBODY)
new_objs = [o for o in set(bpy.data.objects) - before if o.type == 'MESH']
if not new_objs:
    raise SystemExit("new body glb had no mesh")
new = max(new_objs, key=lambda o: len(o.data.vertices))
for o in new_objs:
    if o is not new:
        bpy.data.objects.remove(o, do_unlink=True)

# --- align the new body into the original's bounds -------------------------
lo_n, hi_n = bbox(new)
scale = (hi_o.z - lo_o.z) / max(hi_n.z - lo_n.z, 1e-6)   # match height
new.scale = (scale, scale, scale)
bpy.context.view_layer.update()
lo_n, hi_n = bbox(new)
new.location += Vector((
    (lo_o.x + hi_o.x) / 2 - (lo_n.x + hi_n.x) / 2,
    (lo_o.y + hi_o.y) / 2 - (lo_n.y + hi_n.y) / 2,
    lo_o.z - lo_n.z))                                     # stand on the same floor
bpy.context.view_layer.update()
print("NEW aligned scale=%.4f" % scale, [round(v, 3) for v in bbox(new)[0]],
      [round(v, 3) for v in bbox(new)[1]])

with bpy.context.temp_override(active_object=new, selected_editable_objects=[new]):
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)

# --- bind the new body to the skeleton -------------------------------------
# Proximity-transferring the shipped mesh's weights looks obvious but fails
# wherever the two silhouettes disagree: the generated knight's closed helm
# juts further forward than the Mixamo head and its arms sit thicker, so
# nearest-face lookup handed helm vertices to a chest bone (a second helm
# appeared mid-torso) and arm vertices to the shield, which erased the arms.
#
# Bind geometrically instead. Every vertex is weighted by its distance to the
# BONE SEGMENTS themselves, over the standard humanoid deform set. That needs
# no correspondence between the two meshes, cannot leave a vertex unweighted,
# and is unbothered by the ~80 disconnected shells these generated meshes
# ship as (which is also why Blender's bone-heat weighting is not an option).
DEFORM = ["Hips", "Spine", "Spine1", "Spine2", "Neck", "Head",
          "LeftShoulder", "LeftArm", "LeftForeArm", "LeftHand",
          "RightShoulder", "RightArm", "RightForeArm", "RightHand",
          "LeftUpLeg", "LeftLeg", "LeftFoot", "LeftToeBase",
          "RightUpLeg", "RightLeg", "RightFoot", "RightToeBase"]
K = 4          # bones blended per vertex
POWER = 4.0    # inverse-distance falloff; higher binds tighter to one bone


def bind_to_bones(mesh_obj, armature):
    import numpy as np
    short = {b.name.replace("mixamorig:", "").replace("mixamorig_", ""): b
             for b in armature.data.bones}
    bones = [(n, short[n]) for n in DEFORM if n in short]
    if not bones:
        raise SystemExit("no deform bones matched")
    M = armature.matrix_world
    heads = np.array([[*(M @ b.head_local)] for _, b in bones], dtype=np.float64)
    tails = np.array([[*(M @ b.tail_local)] for _, b in bones], dtype=np.float64)

    n = len(mesh_obj.data.vertices)
    co = np.empty(n * 3)
    mesh_obj.data.vertices.foreach_get("co", co)
    co = co.reshape(n, 3)
    MW = np.array(mesh_obj.matrix_world.to_4x4())
    co = co @ MW[:3, :3].T + MW[:3, 3]

    seg = tails - heads
    L2 = (seg ** 2).sum(1)
    L2[L2 < 1e-12] = 1e-12
    # Perpendicular distance to each bone's segment, clamped to its ends.
    d = co[:, None, :] - heads[None, :, :]
    t = np.clip((d * seg[None]).sum(2) / L2[None], 0.0, 1.0)
    closest = heads[None] + t[:, :, None] * seg[None]
    dist = np.linalg.norm(co[:, None, :] - closest, axis=2)

    w = 1.0 / np.maximum(dist, 1e-4) ** POWER
    keep = np.argsort(-w, axis=1)[:, :K]
    mask = np.zeros_like(w, dtype=bool)
    np.put_along_axis(mask, keep, True, axis=1)
    w = np.where(mask, w, 0.0)
    w /= w.sum(1, keepdims=True)

    for vg in list(mesh_obj.vertex_groups):
        mesh_obj.vertex_groups.remove(vg)
    for i, (sname, b) in enumerate(bones):
        grp = mesh_obj.vertex_groups.new(name=b.name)
        idx = np.nonzero(w[:, i] > 0.001)[0]
        for v in idx:
            grp.add([int(v)], float(w[v, i]), 'REPLACE')
    return len(bones), float(dist.min(1).mean())


def fit_arms(mesh_obj, armature):
    """Match the mesh's arm LENGTH to the skeleton's.

    Aligning by overall height is not enough: these generated bodies come out
    long-armed relative to the Mixamo rig (the knight measured 0.745 m from
    shoulder to fingertip against the skeleton's 0.560 m). The hands then
    overshoot the hand bones by a third of an arm, so the sword and shield —
    which hang off Sword_joint and Shield_joint at the BONE's hand — sit well
    inside the mesh's fist and read as floating next to a stump.

    Rest pose is a T-pose, so the arm axis is world X and this is a 1-D
    rescale about each shoulder. Thickness is untouched.
    """
    import numpy as np
    short = {b.name.replace("mixamorig:", "").replace("mixamorig_", ""): b
             for b in armature.data.bones}
    M = armature.matrix_world
    n = len(mesh_obj.data.vertices)
    co = np.empty(n * 3)
    mesh_obj.data.vertices.foreach_get("co", co)
    co = co.reshape(n, 3)
    MW = np.array(mesh_obj.matrix_world.to_4x4())
    world = co @ MW[:3, :3].T + MW[:3, 3]

    report = []
    for side, sgn in (("Left", 1.0), ("Right", -1.0)):
        upper, hand = short.get(side + "Arm"), short.get(side + "Hand")
        if not upper or not hand:
            continue
        sx = (M @ upper.head_local).x
        tx = (M @ hand.tail_local).x
        sel = (world[:, 0] * sgn) > (sx * sgn)
        if not sel.any():
            continue
        tip = world[sel, 0].max() if sgn > 0 else world[sel, 0].min()
        cur, want = abs(tip - sx), abs(tx - sx)
        if cur < 1e-4:
            continue
        s = want / cur
        world[sel, 0] = sx + (world[sel, 0] - sx) * s
        report.append("%s %.3f->%.3f (x%.2f)" % (side, cur, want, s))

    local = (world - MW[:3, 3]) @ np.linalg.inv(MW[:3, :3]).T
    mesh_obj.data.vertices.foreach_set("co", local.reshape(-1))
    mesh_obj.data.update()
    print("arm fit:", "; ".join(report) if report else "no change")


fit_arms(new, arm)
nbones, mean_d = bind_to_bones(new, arm)
print("bound new body to %d bones (mean distance to nearest bone %.3f m)"
      % (nbones, mean_d))
print("vertex groups on new body:", len(new.vertex_groups))

# --- ride the original armature -------------------------------------------
new.parent = arm
new.matrix_parent_inverse = arm.matrix_world.inverted()
amod = new.modifiers.new("Armature", 'ARMATURE')
amod.object = arm
new.name = "CharacterBody"

for o in body_meshes:
    bpy.data.objects.remove(o, do_unlink=True)

# Godot matches animation tracks by bone name; ':' is not legal in a node
# name and gets sanitised, so make the rename explicit here.
for b in arm.data.bones:
    b.name = b.name.replace("mixamorig:", "mixamorig_")

# The FBX importer leaves the armature OBJECT carrying the file's axis
# conversion and its 0.01 unit scale. Exporting that on top of the glTF
# Y-up conversion double-rotates, and the character ships lying on its
# back. Bake the object transform into the data so the armature exports
# as identity.
print("ARM xform before: rot=%s scale=%s" % (
    [round(v, 3) for v in arm.rotation_euler], [round(v, 4) for v in arm.scale]))
sel = [arm] + [o for o in meshes()]
for o in sel:
    o.select_set(True)
with bpy.context.temp_override(active_object=arm, object=arm,
                               selected_editable_objects=sel):
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
print("ARM xform after:  rot=%s scale=%s" % (
    [round(v, 3) for v in arm.rotation_euler], [round(v, 4) for v in arm.scale]))

print("KEPT:", [o.name for o in meshes() if o is not new])

# Export is scene-wide, so anything that drifted into the scene ships inside
# the character. A stray unit-radius Icosphere did exactly that and rendered
# as a second helm-sized blob through the torso. Allowlist instead: the
# armature, the new body, and the props we deliberately kept.
allowed = {arm, new, *keep_meshes}
for o in list(bpy.data.objects):
    if o not in allowed:
        print("  dropping stray object:", o.name, o.type)
        bpy.data.objects.remove(o, do_unlink=True)

# The kept props drag in the original character's full-size texture set —
# the Archer's 212-vertex bow was carrying 4.9 MB of 2k maps. Cap them.
MAX_PX = 512
for img in bpy.data.images:
    if img.has_data and max(img.size) > MAX_PX:
        print("  downscaling %s %dx%d -> %d" % (img.name, *img.size, MAX_PX))
        img.scale(MAX_PX, MAX_PX)
bpy.ops.export_scene.gltf(filepath=OUT, export_format='GLB',
                          export_apply=False, export_yup=True,
                          export_animations=False, export_skins=True,
                          export_image_format='JPEG')
print("WROTE", OUT, round(os.path.getsize(OUT) / 1e6, 2), "MB")
