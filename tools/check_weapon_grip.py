"""Is the weapon actually IN the fist? Renders a lit close-up of each hand and
measures the gap between the mesh's fist and the weapon geometry.

  blender -b -P hand_check.py -- <char.glb> <outdir>
"""
import bpy, sys, os, math
import numpy as np
from mathutils import Vector

argv = sys.argv[sys.argv.index("--") + 1:]
GLB, OUT = argv[0], argv[1]
os.makedirs(OUT, exist_ok=True)

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=GLB)
arm = next(o for o in bpy.data.objects if o.type == 'ARMATURE')
for o in list(bpy.data.objects):
    if o.type == 'MESH' and o.parent is not arm:
        bpy.data.objects.remove(o, do_unlink=True)
mesh_objs = [o for o in bpy.data.objects if o.type == 'MESH']
body = max(mesh_objs, key=lambda o: len(o.data.vertices))
props = [o for o in mesh_objs if o is not body]


def world_co(o):
    n = len(o.data.vertices)
    a = np.empty(n * 3); o.data.vertices.foreach_get("co", a)
    a = a.reshape(n, 3)
    M = np.array(o.matrix_world.to_4x4())
    return a @ M[:3, :3].T + M[:3, 3]


names = [g.name.replace("mixamorig_", "").replace("mixamorig:", "")
         for g in body.vertex_groups]
bco = world_co(body)
fists = {}
for side in ("LeftHand", "RightHand"):
    if side not in names:
        continue
    gi = names.index(side)
    idx = [v.index for v in body.data.vertices
           if v.groups and names[max(v.groups, key=lambda g: g.weight).group] == side]
    if idx:
        fists[side] = bco[idx]

print("%-30s %-9s %8s %8s" % ("prop", "nearest", "gap(m)", "verts"))
targets = {}
for p in props:
    pco = world_co(p)
    best = (None, 1e9)
    for side, f in fists.items():
        d = np.linalg.norm(pco[:, None, :] - f[None, :, :], axis=2).min()
        if d < best[1]:
            best = (side, d)
    targets[p.name] = best
    print("%-30s %-9s %8.3f %8d" % (p.name, best[0], best[1], len(pco)))
    print("      prop centre %s  fist centre %s" % (
        np.round(pco.mean(0), 3), np.round(fists[best[0]].mean(0), 3)))

# ---- lit close-up of each hand -------------------------------------------
sc = bpy.context.scene
sc.render.engine = 'BLENDER_EEVEE'
sc.render.resolution_x = 640
sc.render.resolution_y = 640
w = bpy.data.worlds.new("W"); sc.world = w; w.use_nodes = True
bg = w.node_tree.nodes["Background"]
bg.inputs[0].default_value = (0.42, 0.45, 0.50, 1)   # bright neutral surround
bg.inputs[1].default_value = 1.6                      # lifts shadow detail

for nm, loc, e in [("key", (2.5, -3, 2.5), 1800), ("fill", (-3, -2, 1.2), 900),
                   ("rim", (0, 3.5, 2.5), 1200), ("top", (0, 0, 4), 900)]:
    lt = bpy.data.lights.new(nm, 'AREA'); lt.energy = e; lt.size = 3
    ob = bpy.data.objects.new(nm, lt); sc.collection.objects.link(ob)
    ob.location = Vector(loc) + Vector((0, 0, 1.0))
    ob.rotation_euler = (Vector((0, 0, 1.3)) - ob.location).to_track_quat('-Z', 'Y').to_euler()

cd = bpy.data.cameras.new("C"); cd.lens = 85
cam = bpy.data.objects.new("C", cd); sc.collection.objects.link(cam)
sc.camera = cam
for side, f in fists.items():
    c = Vector(f.mean(0).tolist())
    for ang in (20, 110):
        a = math.radians(ang)
        cam.location = c + Vector((math.sin(a) * 0.85, -math.cos(a) * 0.85, 0.16))
        cam.rotation_euler = (c - cam.location).to_track_quat('-Z', 'Y').to_euler()
        sc.render.filepath = os.path.join(OUT, "%s_%03d.png" % (side, ang))
        bpy.ops.render.render(write_still=True)
        print("rendered", sc.render.filepath)
