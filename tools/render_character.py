"""Render a rigged character glb in isolation, in poses that stress the bind.

In-engine screenshots put the character in grass under scene lighting, which
hides deformation errors. This renders on a flat background with even light
so a collapsed arm or a stray shell is unmistakable.

  blender -b -P render_char.py -- <char.glb> <outdir>
"""
import bpy, sys, os, math
from mathutils import Vector, Euler

argv = sys.argv[sys.argv.index("--") + 1:]
GLB, OUT = argv[0], argv[1]
os.makedirs(OUT, exist_ok=True)

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=GLB)
arm = next(o for o in bpy.data.objects if o.type == 'ARMATURE')
# Blender's glTF importer invents a placeholder "Icosphere" that is NOT in
# the file (verified against the raw glb JSON). Drop anything not riding the
# armature so the render shows only what actually ships.
for o in list(bpy.data.objects):
    if o.type == 'MESH' and o.parent is not arm:
        print("ignoring importer artifact:", o.name)
        bpy.data.objects.remove(o, do_unlink=True)
print("MESHES:", [(o.name, len(o.data.vertices)) for o in bpy.data.objects
                  if o.type == 'MESH'])

pts = []
for o in bpy.data.objects:
    if o.type == 'MESH':
        pts += [o.matrix_world @ Vector(c) for c in o.bound_box]
lo = Vector([min(p[i] for p in pts) for i in range(3)])
hi = Vector([max(p[i] for p in pts) for i in range(3)])
mid = (lo + hi) / 2
height = hi.z - lo.z
print("BOUNDS", [round(v, 3) for v in lo], [round(v, 3) for v in hi])

sc = bpy.context.scene
sc.render.engine = 'BLENDER_EEVEE'
sc.render.resolution_x = 700
sc.render.resolution_y = 900
sc.render.film_transparent = False
world = bpy.data.worlds.new("W"); sc.world = world
world.use_nodes = True
world.node_tree.nodes["Background"].inputs[0].default_value = (0.09, 0.10, 0.12, 1)
world.node_tree.nodes["Background"].inputs[1].default_value = 1.0

for name, loc, energy in [("key", (3, -4, 3), 900), ("fill", (-4, -3, 1.5), 350),
                          ("rim", (0, 5, 3), 500)]:
    lt = bpy.data.lights.new(name, 'AREA'); lt.energy = energy; lt.size = 4
    ob = bpy.data.objects.new(name, lt); sc.collection.objects.link(ob)
    ob.location = Vector(loc) + Vector((0, 0, mid.z))
    d = (mid - ob.location).normalized()
    ob.rotation_euler = d.to_track_quat('-Z', 'Y').to_euler()

cam_d = bpy.data.cameras.new("C"); cam_d.lens = 60
cam = bpy.data.objects.new("C", cam_d); sc.collection.objects.link(cam)
sc.camera = cam


def look(angle_deg, dist=None):
    # Frame the WIDTH too — a T-pose arm span is wider than the figure is
    # tall, and the previous framing cropped the hands clean off, which read
    # as missing arms in the render.
    span = max(hi.x - lo.x, hi.y - lo.y)
    dist = dist or max(height * 1.55, span * 1.75)
    a = math.radians(angle_deg)
    cam.location = mid + Vector((math.sin(a) * dist, -math.cos(a) * dist, height * 0.12))
    cam.rotation_euler = (mid - cam.location).to_track_quat('-Z', 'Y').to_euler()


def pose(spec):
    """spec: {short bone name: (rx, ry, rz) degrees}"""
    for pb in arm.pose.bones:
        pb.rotation_mode = 'XYZ'
        pb.rotation_euler = (0, 0, 0)
    for n, rot in spec.items():
        for pb in arm.pose.bones:
            if pb.name.replace("mixamorig:", "").replace("mixamorig_", "") == n:
                pb.rotation_euler = Euler([math.radians(v) for v in rot], 'XYZ')
    bpy.context.view_layer.update()


POSES = {
    "rest": {},
    # A stride with the arms swung and the torso twisted: the shoulders,
    # elbows and hips all leave rest at once, which is where a bad bind tears.
    "stride": {"LeftUpLeg": (-35, 0, 0), "RightUpLeg": (30, 0, 0),
               "LeftLeg": (25, 0, 0), "RightLeg": (10, 0, 0),
               "LeftArm": (0, 0, -35), "RightArm": (0, 0, 35),
               "LeftForeArm": (0, -50, 0), "RightForeArm": (0, 50, 0),
               "Spine1": (0, 0, 8), "Head": (0, 0, -12)},
    # Arms fully overhead: worst case for shoulder weighting.
    "overhead": {"LeftArm": (0, 0, -100), "RightArm": (0, 0, 100),
                 "LeftForeArm": (0, -20, 0), "RightForeArm": (0, 20, 0)},
}

for pname, spec in POSES.items():
    pose(spec)
    for ang in (0, 90):
        look(ang)
        sc.render.filepath = os.path.join(OUT, "%s_%03d.png" % (pname, ang))
        bpy.ops.render.render(write_still=True)
        print("rendered", sc.render.filepath)
