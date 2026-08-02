"""Play a real game animation clip on a rigged character and render frames.

The in-engine screenshots of the combat scenarios are shot at night from
inside the enemy's legs, so they cannot answer "does the bind survive a sword
swing". This drives the ACTUAL fbx clip the game loads, on a clean background.

  blender -b -P render_anim.py -- <char.glb> <clip.fbx> <outdir> [frames]
"""
import bpy, sys, os, math
from mathutils import Vector

argv = sys.argv[sys.argv.index("--") + 1:]
GLB, CLIP, OUT = argv[0], argv[1], argv[2]
NFRAMES = int(argv[3]) if len(argv) > 3 else 6
os.makedirs(OUT, exist_ok=True)

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=GLB)
arm = next(o for o in bpy.data.objects if o.type == 'ARMATURE')
for o in list(bpy.data.objects):
    if o.type == 'MESH' and o.parent is not arm:
        bpy.data.objects.remove(o, do_unlink=True)   # glTF importer artifact

before = set(bpy.data.actions)
bpy.ops.wm.fbx_import(filepath=CLIP)
acts = [a for a in bpy.data.actions if a not in before]
if not acts:
    raise SystemExit("clip has no action")
act = max(acts, key=lambda a: a.frame_range[1] - a.frame_range[0])

# The clip's bones are mixamorig:X, the character's are mixamorig_X.
def fcurves(a):
    out = []
    for layer in a.layers:
        for strip in layer.strips:
            if strip.type != 'KEYFRAME':
                continue
            for slot in a.slots:
                bag = strip.channelbag(slot)
                if bag:
                    out.extend(bag.fcurves)
    return out

n = 0
drop = []
for fc in fcurves(act):
    if "mixamorig:" in fc.data_path:
        fc.data_path = fc.data_path.replace("mixamorig:", "mixamorig_")
        n += 1
    # The game strips Hips POSITION (root motion) on import; these clips key
    # it in centimetres, so keeping it throws the character out of frame.
    if fc.data_path.endswith(".location") and "Hips" in fc.data_path:
        drop.append(fc)
for layer in act.layers:
    for strip in layer.strips:
        if strip.type != 'KEYFRAME':
            continue
        for slot in act.slots:
            bag = strip.channelbag(slot)
            if not bag:
                continue
            for fc in list(bag.fcurves):
                if fc in drop:
                    bag.fcurves.remove(fc)
print("dropped %d root-motion curves" % len(drop))
print("retargeted %d fcurves from %s" % (n, os.path.basename(CLIP)))

for o in [o for o in bpy.data.objects if o.type == 'ARMATURE' and o is not arm]:
    bpy.data.objects.remove(o, do_unlink=True)

if not arm.animation_data:
    arm.animation_data_create()
arm.animation_data.action = act
if act.slots:
    arm.animation_data.action_slot = act.slots[0]

pts = []
for o in bpy.data.objects:
    if o.type == 'MESH':
        pts += [o.matrix_world @ Vector(c) for c in o.bound_box]
lo = Vector([min(p[i] for p in pts) for i in range(3)])
hi = Vector([max(p[i] for p in pts) for i in range(3)])
mid = (lo + hi) / 2
height = max(hi.z - lo.z, 1.7)

sc = bpy.context.scene
sc.render.engine = 'BLENDER_EEVEE'
sc.render.resolution_x = 560
sc.render.resolution_y = 700
w = bpy.data.worlds.new("W"); sc.world = w; w.use_nodes = True
w.node_tree.nodes["Background"].inputs[0].default_value = (0.09, 0.10, 0.12, 1)

for name, loc, e in [("k", (3, -4, 3), 900), ("f", (-4, -3, 1.5), 350), ("r", (0, 5, 3), 500)]:
    lt = bpy.data.lights.new(name, 'AREA'); lt.energy = e; lt.size = 4
    ob = bpy.data.objects.new(name, lt); sc.collection.objects.link(ob)
    ob.location = Vector(loc) + Vector((0, 0, 1.0))
    ob.rotation_euler = (Vector((0, 0, 1.0)) - ob.location).to_track_quat('-Z', 'Y').to_euler()

cd = bpy.data.cameras.new("C"); cd.lens = 45
cam = bpy.data.objects.new("C", cd); sc.collection.objects.link(cam)
sc.camera = cam
a = math.radians(35)
dist = height * 2.0
tgt = Vector((0, 0, height * 0.55))
cam.location = tgt + Vector((math.sin(a) * dist, -math.cos(a) * dist, height * 0.12))
cam.rotation_euler = (tgt - cam.location).to_track_quat('-Z', 'Y').to_euler()

f0, f1 = int(act.frame_range[0]), int(act.frame_range[1])
for i in range(NFRAMES):
    f = f0 + round((f1 - f0) * i / max(NFRAMES - 1, 1))
    sc.frame_set(f)
    sc.render.filepath = os.path.join(OUT, "f%02d.png" % i)
    bpy.ops.render.render(write_still=True)
print("rendered %d frames over %d..%d" % (NFRAMES, f0, f1))
