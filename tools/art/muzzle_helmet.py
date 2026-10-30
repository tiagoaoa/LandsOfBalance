#Iron muzzle: bands locking the T-rex jaw shut, riveted to the helmet.
#Run in the open tools/art/source/reptilian_rex.blend (Blender MCP:
#tools/art/blender_mcp.py execute_blender_code tools/art/muzzle_helmet.py),
#then export with tools/art/muzzle_export.py. Re-running replaces the muzzle.
#
#Everything is authored around the CLOSED jaw (jaw bone posed -30 degrees,
#as the game holds it) and bound rigidly to the head bone: the game never
#opens the jaw again, so the bands always sit on the shut mouth.
import math

import bmesh
import bpy
import numpy as np
from mathutils import Euler, Vector

HEAD_Y = -8.1
BANDS = [4.6, 7.6]            #metres forward of the head bone
STRAP_W, STRAP_T = 1.05, .3

rig = bpy.data.objects['ReptilianRig']
iron = bpy.data.materials['Rex_Blackened_Iron']
edge = bpy.data.materials['Rex_Worn_Iron']
rust = bpy.data.materials['Rex_Old_Rust']


def at(x, f, z):
    return Vector((x, HEAD_Y - f, z))


def close_jaw():
    pb = rig.pose.bones['jaw']
    pb.rotation_mode = 'XYZ'
    pb.rotation_euler = Euler((math.radians(-30), 0, 0))
    bpy.context.view_layer.update()


def clear():
    for ob in [o for o in bpy.data.objects if o.name.startswith('Muzzle_')]:
        bpy.data.objects.remove(ob, do_unlink=True)


def link(name, bm, mat):
    data = bpy.data.meshes.new(name)
    bm.to_mesh(data)
    bm.free()
    ob = bpy.data.objects.new(name, data)
    bpy.context.scene.collection.objects.link(ob)
    data.materials.append(mat)
    for p in data.polygons:
        p.use_smooth = True
    return ob


def finish(ob, bevel=.05):
    bpy.ops.object.select_all(action='DESELECT')
    ob.select_set(True)
    bpy.context.view_layer.objects.active = ob
    if bevel:
        mod = ob.modifiers.new('Worn edges', 'BEVEL')
        mod.width, mod.segments, mod.limit_method = bevel, 2, 'ANGLE'
        bpy.ops.object.modifier_apply(modifier=mod.name)
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_all(action='SELECT')
    bpy.ops.uv.smart_project(angle_limit=math.radians(66), island_margin=.02)
    bpy.ops.object.mode_set(mode='OBJECT')
    ob.vertex_groups.new(name='head').add(list(range(len(ob.data.vertices))), 1, 'REPLACE')
    mod = ob.modifiers.new('Combat skeleton', 'ARMATURE')
    mod.object = rig
    ob.parent = rig
    return ob


def outline(f, n=72, slab=.45):
    #The shut muzzle's real cross-section at f: per angle around its centre,
    #the outermost hide, helmet or tooth, so the hoop hugs it.
    dg = bpy.context.evaluated_depsgraph_get()
    pts = []
    for name in ['Reptilian_Hide', 'Rex_Blackened_Iron', 'Rex_Worn_Iron', 'Rex_Old_Ivory', 'Rex_Old_Rust']:
        ob = bpy.data.objects[name].evaluated_get(dg)
        me = ob.to_mesh()
        mw = ob.matrix_world
        for v in me.vertices:
            w = mw @ v.co
            if abs(HEAD_Y - w.y - f) < slab and w.z > 9.8:
                pts.append((w.x, w.z))
        ob.to_mesh_clear()
    zs = [z for _, z in pts]
    zc = (min(zs) + max(zs)) / 2
    radius = [0.0] * n
    for x, z in pts:
        k = int(round(math.atan2(z - zc, x) / math.tau * n)) % n
        radius[k] = max(radius[k], math.hypot(x, z - zc))
    #Fill and smooth: a hoop is forged round the high points, not into gaps.
    for k in range(n):
        if radius[k] == 0.0:
            radius[k] = max(radius[(k - 1) % n], radius[(k + 1) % n])
    for _ in range(3):
        radius = [max(radius[k], (radius[(k - 1) % n] + 2 * radius[k] + radius[(k + 1) % n]) / 4)
                  for k in range(n)]
    return zc, radius


def ring(f, n=72):
    zc, radius = outline(f, n)
    rng = np.random.default_rng(int(f * 100))
    pts = []
    for k in range(n):
        t = math.tau * k / n
        out = Vector((math.cos(t), 0, math.sin(t)))
        r = radius[k] + .06 + .025 * math.sin(t * 7 + f) + rng.uniform(-.01, .01)
        p = Vector((0, 0, zc)) + out * r
        pts.append((p, out))
    return pts


def band(f):
    bm = bmesh.new()
    pts = ring(f)
    rows = []
    for p, out in pts:
        quad = []
        for dy, dr in [(-STRAP_W / 2, 0), (STRAP_W / 2, 0), (STRAP_W / 2, STRAP_T), (-STRAP_W / 2, STRAP_T)]:
            quad.append(bm.verts.new(at(p.x, f, p.z) + Vector((0, dy, 0)) + out * dr))
        rows.append(quad)
    for k in range(len(rows)):
        a, b = rows[k], rows[(k + 1) % len(rows)]
        for j in range(4):
            bm.faces.new((a[j], a[(j + 1) % 4], b[(j + 1) % 4], b[j]))
    bmesh.ops.recalc_face_normals(bm, faces=list(bm.faces))
    ob = finish(link('Muzzle_Band', bm, iron))
    #Rivets where a smith would have closed the hoop: top, sides, chin.
    for k in range(0, len(pts), 9):
        p, out = pts[k]
        rivet(at(p.x, f, p.z) + out * (STRAP_T + .02), out, .16)
    return ob


def rivet(p, normal, r):
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=12, v_segments=8, radius=r)
    for v in bm.verts:
        v.co.z *= .55
    rot = Vector((0, 0, 1)).rotation_difference(normal)
    bmesh.ops.rotate(bm, verts=bm.verts, matrix=rot.to_matrix())
    bmesh.ops.translate(bm, verts=bm.verts, vec=p)
    return finish(link('Muzzle_Rivet', bm, edge), bevel=0)


def box(name, centre, size, mat, bevel=.04):
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    for v in bm.verts:
        v.co = Vector((v.co.x * size.x, v.co.y * size.y, v.co.z * size.z)) + centre
    return finish(link(name, bm, mat), bevel)


def chin_lock():
    bottoms = [min(p.z for p, _ in ring(f)) for f in BANDS]
    z = min(bottoms) - STRAP_T
    a, b = at(0, BANDS[0], bottoms[0] - STRAP_T), at(0, BANDS[1], bottoms[1] - STRAP_T)
    box('Muzzle_Chin_Bar', (a + b) / 2 + Vector((0, 0, -.06)), Vector((.8, (a - b).length + STRAP_W, .26)), iron)
    #The lock: a heavy forged block hanging from the bar, shackle through it.
    mid = at(0, (BANDS[0] + BANDS[1]) / 2, z - .8)
    box('Muzzle_Lock', mid, Vector((1.0, 1.2, 1.1)), edge, .08)
    box('Muzzle_Lock_Plate', mid + Vector((0, -.62, 0)), Vector((.6, .08, .75)), rust, .03)
    bm = bmesh.new()
    bmesh.ops.create_circle(bm, cap_ends=False, segments=24, radius=.5)
    ob = link('Muzzle_Shackle', bm, edge)
    ob.location = mid + Vector((0, 0, .7))
    ob.rotation_euler = (0, math.pi / 2, 0)
    bpy.ops.object.select_all(action='DESELECT')
    ob.select_set(True)
    bpy.context.view_layer.objects.active = ob
    bpy.ops.object.convert(target='CURVE')
    ob.data.bevel_depth, ob.data.bevel_resolution = .11, 3
    bpy.ops.object.convert(target='MESH')
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    #The curve round trip drops the mesh's material slots.
    ob.data.materials.clear()
    ob.data.materials.append(edge)
    finish(ob, bevel=0)


def hide_width(f, z, slab=.35):
    dg = bpy.context.evaluated_depsgraph_get()
    best = 0.0
    for name in ['Reptilian_Hide', 'Rex_Blackened_Iron', 'Rex_Worn_Iron']:
        ob = bpy.data.objects[name].evaluated_get(dg)
        me = ob.to_mesh()
        mw = ob.matrix_world
        for v in me.vertices:
            w = mw @ v.co
            if abs(HEAD_Y - w.y - f) < slab and abs(w.z - z) < .45:
                best = max(best, abs(w.x))
        ob.to_mesh_clear()
    return best


def cheek_straps():
    #From the rear hoop back along the cheek to the helmet's temple guard,
    #following the hide so the strap lies on it instead of cutting through.
    z = 12.45
    fs = [BANDS[0], 3.8, 3.0, 2.2, 1.4, .7]
    widths = [hide_width(f, z) for f in fs]
    for s in [-1, 1]:
        pts = [at(s * (w + .06), f, z + .1 * k) for k, (f, w) in enumerate(zip(fs, widths))]
        bm = bmesh.new()
        rows = []
        for k, p in enumerate(pts):
            ahead = pts[min(k + 1, len(pts) - 1)] - pts[max(k - 1, 0)]
            out = Vector((s, 0, 0))
            up = ahead.cross(out).normalized()
            if up.z < 0:
                up = -up
            rows.append([bm.verts.new(p + up * dz + out * dr)
                         for dz, dr in [(-.4, 0), (.4, 0), (.4, .2), (-.4, .2)]])
        for a, b in zip(rows, rows[1:]):
            for j in range(4):
                bm.faces.new((a[j], a[(j + 1) % 4], b[(j + 1) % 4], b[j]))
        for cap in [rows[0], rows[-1][::-1]]:
            bm.faces.new(cap)
        bmesh.ops.recalc_face_normals(bm, faces=list(bm.faces))
        finish(link('Muzzle_Cheek_Strap', bm, iron), .03)
        for p in pts[1::2] + [pts[-1]]:
            rivet(p + Vector((s * .22, 0, 0)), Vector((s, 0, 0)), .15)


def join_by_material():
    for mat in [iron, edge, rust]:
        parts = [ob for ob in bpy.data.objects if ob.name.startswith('Muzzle_')
                 and ob.type == 'MESH' and ob.data.materials[0] == mat]
        if not parts:
            continue
        bpy.ops.object.select_all(action='DESELECT')
        for ob in parts:
            ob.select_set(True)
        bpy.context.view_layer.objects.active = parts[0]
        bpy.ops.object.join()
        bpy.context.object.name = 'Muzzle_' + mat.name.removeprefix('Rex_')


if bpy.context.object and bpy.context.object.mode != 'OBJECT':
    bpy.ops.object.mode_set(mode='OBJECT')
close_jaw()
clear()
for f in BANDS:
    band(f)
chin_lock()
cheek_straps()
join_by_material()
rig['muzzle'] = 'Forged bands lock the jaw shut; rigid on the head bone'
print('MUZZLE', [ob.name for ob in bpy.data.objects if ob.name.startswith('Muzzle_')])
