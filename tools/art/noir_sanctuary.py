#Broken sanctuary masonry. Individual stones are joined into a small reusable kit.
import math
import random
from pathlib import Path

import bpy
import bmesh
from mathutils import Vector

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'assets/environment/sanctuary'
OUT.mkdir(parents = True, exist_ok = True)
rng = random.Random(301)
for old in list(bpy.data.collections):
    if old.name == 'Noir_Sanctuary':
        for ob in list(old.objects):
            bpy.data.objects.remove(ob, do_unlink = True)
        bpy.data.collections.remove(old)
collection = bpy.data.collections.new('Noir_Sanctuary')
bpy.context.scene.collection.children.link(collection)
mat = bpy.data.materials.new('Sanctuary_Stone')
mat.diffuse_color = (.22, .215, .20, 1)
mat.use_nodes = True
bsdf = mat.node_tree.nodes.get('Principled BSDF')
bsdf.inputs['Base Color'].default_value = (.22, .215, .20, 1)
bsdf.inputs['Roughness'].default_value = .77
kit = []


def solid(points, bevel = .035):
    bm = bmesh.new()
    v = [bm.verts.new(p) for p in points]
    for face in [(0, 3, 2, 1), (4, 5, 6, 7), (0, 1, 5, 4),
                 (1, 2, 6, 5), (2, 3, 7, 6), (3, 0, 4, 7)]:
        bm.faces.new([v[i] for i in face])
    bmesh.ops.recalc_face_normals(bm, faces = list(bm.faces))
    bmesh.ops.bevel(bm, geom = list(bm.edges), offset = bevel, segments = 2, affect = 'EDGES')
    bm.verts.ensure_lookup_table()
    start = len(verts)
    verts.extend(v.co.copy() for v in bm.verts)
    faces.extend(tuple(start + v.index for v in f.verts) for f in bm.faces)
    bm.free()


def box(x, y, z, width, depth, height, bevel = .04):
    solid([(x + a * width / 2, y + b * depth / 2, z + c * height / 2)
           for a, b, c in [(-1, -1, -1), (1, -1, -1), (1, 1, -1), (-1, 1, -1),
                          (-1, -1, 1), (1, -1, 1), (1, 1, 1), (-1, 1, 1)]], bevel)


def wedge(r0, r1, a0, a1, bottom, top, bevel = .03):
    corners = [(r0, a0), (r1, a0), (r1, a1), (r0, a1)]
    pts = [(r * math.cos(a), r * math.sin(a), z) for z in [bottom, top] for r, a in corners]
    solid(pts, bevel)


def finish(name):
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata(verts, [], faces)
    mesh.materials.append(mat)
    uv = mesh.uv_layers.new(name = 'UVMap')
    for poly in mesh.polygons:
        normal = poly.normal
        axes = (0, 1) if abs(normal.z) > .6 else ((0, 2) if abs(normal.y) > .6 else (1, 2))
        for li in poly.loop_indices:
            p = mesh.vertices[mesh.loops[li].vertex_index].co
            uv.data[li].uv = (p[axes[0]] / 2, p[axes[1]] / 2)
    ob = bpy.data.objects.new(name, mesh)
    collection.objects.link(ob)
    kit.append(ob)
    print('%s: %d vertices' % (name, len(verts)))


verts, faces = [], []
#Radial flagstones, with deep joints and concentric carved cornices.
for ring, (r0, r1, n) in enumerate([(.02, 1.25, 12), (1.27, 2.85, 20), (2.87, 4.45, 28), (4.47, 5.97, 36)]):
    for k in range(n):
        angle = (k + .5 * (ring % 2)) * math.tau / n
        wedge(r0, r1, angle + .002, angle + math.tau / n - .002, -.32,
              .027 + rng.uniform(-.005, .005), .018)
for course, (r0, r1, z, height) in enumerate([(5.65, 6.0, -.18, .30), (5.58, 5.96, -.60, .50),
                                           (5.50, 5.89, -1.1, .5), (5.45, 6.0, -1.47, .18),
                                           (5.3, 5.7, -1.9, .65)]):
    for k in range(40):
        a = (k + .5 * (course % 2)) * math.tau / 40
        wedge(r0, r1, a + .003, a + math.tau / 40 - .003, z - height / 2, z + height / 2, .027)
finish('Sanctuary_Dais')


verts, faces = [], []
for side in [-1, 1]:
    x = side * 3.4
    for k in range(12):
        width = 1.1 if k > 1 else 1.6 - k * .16
        box(x, 0, .34 + .64 * k, width, 1.4, .60)
        #Thin paired shafts and interrupted capital mouldings.
        box(x - side * .39, -.75, .33 + .64 * k, .19, .2, .60, .025)
    for z, width in [(0.12, 1.9), (.48, 1.6), (6.8, 1.35), (7.15, 1.65)]:
        box(x, 0, z, width, 1.8, .20)
    for k in range(4):
        box(x + side * .72, .25 + k * .04, .75 + 1.45 * k, .68, 2.1 - k * .25, 1.42)
#Pointed arch, separate voussoirs and a second thin archivolt.
for side in [-1, 1]:
    for k in range(12):
        if side == 1 and k in [8, 9]:
            continue
        t0, t1 = k / 12, (k + 1) / 12
        def curve(t, outer):
            return (side * (3.4 * (1 - t ** .64) + outer * .55), 7.2 + 4.9 * t + outer * .2)
        for y, thickness, outer0, outer1 in [(0, 1.5, 0, 1), (-.82, .20, .1, .42)]:
            a, b, c, d = curve(t0 + .003, outer0), curve(t1 - .003, outer0), curve(t1 - .003, outer1), curve(t0 + .003, outer1)
            solid([(x, yy, z) for yy in [y - thickness / 2, y + thickness / 2] for x, z in [a, b, c, d]], .025)
finish('Sanctuary_Arch')


verts, faces = [], []
for k in range(16):
    width = 2.8 - 1.45 * k / 16
    box(0, .18 * math.sin(k * .32), .39 + k * .76, width, width * 1.2, .73, .055)
    if k % 4 == 3:
        box(0, 0, .78 + k * .76, width + .3, width * 1.2 + .3, .18)
finish('Sanctuary_Buttress')


verts, faces = [], []
for r0, r1, z, h in [(.84, 1, -.08, .16), (.86, .96, -.28, .25), (.84, 1.01, -.47, .12)]:
    for k in range(24):
        a = k * math.tau / 24
        wedge(r0, r1, a + .002, a + math.tau / 24 - .002, z - h / 2, z + h / 2, .012)
finish('Sanctuary_Collar')


for ob in bpy.context.scene.objects:
    ob.select_set(ob in kit)
window = bpy.context.window_manager.windows[0]
with bpy.context.temp_override(window = window):
    bpy.context.view_layer.objects.active = kit[0]
    bpy.ops.export_scene.gltf(filepath = str(OUT / 'sanctuary.glb'), export_format = 'GLB',
            use_selection = True, export_yup = True, export_animations = False)
    #A separate source file with only the kit, leaving the dragon source intact.
    bpy.data.libraries.write(str(ROOT / 'tools/art/source/sanctuary.blend'), {collection}, fake_user = True)
print('Sanctuary kit exported')
