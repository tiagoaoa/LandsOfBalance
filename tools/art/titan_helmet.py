"""Forge the iron helmet and jaw-locking muzzle onto the rigged lizard titan.

  blender -b --python tools/art/titan_helmet.py

Works on the generation's blend (from build_titan.py, same TITAN_GEN) and
saves it back. The helmet is grown from the titan's own head: crown and snout-top faces
of the hide, smoothed into forged plates, pushed out and thickened, with the
horns, eyes and nostrils left bare. The muzzle's hoops are fitted to the
measured cross-section of the shut snout and jaw, as tools/art/muzzle_helmet.py
does for the old skull. Every part rides the head bone rigidly; the game never
opens the jaw. Re-running replaces both.
"""
import math
import os
from pathlib import Path

import bmesh
import bpy
import numpy as np
from mathutils import Vector

ROOT = Path(__file__).resolve().parents[2]
IRON_SOURCE = ROOT / 'tools/art/source/reptilian_rex.blend'

# Head landmarks in the rigged blend (metres; snout toward -Y), read off
# gridded close-ups of each generated head. TITAN_GEN picks the body, as in
# tools/art/build_titan.py.
HEADS = {
    'hunyuan': {
        'blend': 'tools/art/source/lizard_titan.blend',
        'lip_z': 14.4,                     # helmet stops above the mouth line
        'back_y': -9.8,                    # and in front of the neck
        'eyes': (1.5, -12.6, 16.2),
        'bands_y': [-13.5, -14.6],         # muzzle hoops on the snout, ahead of the eyes
        'brow_z': 16.3,                    # hoops fit the snout below the brow
        'horn': (2.9, 17.4, 1.15),         # |x| beyond, or above z and beyond |x|
    },
    'trellis': {
        'blend': 'tools/art/source/lizard_titan_trellis.blend',
        'lip_z': 14.7,
        'back_y': -10.8,
        'eyes': (1.55, -14.1, 16.35),
        # Its snout is short ahead of the eyes: both hoops crowd the front,
        # fitted up to the snout's ridge.
        'bands_y': [-14.65, -15.45],
        'brow_z': 17.2,
        'horn': (2.4, 18.6, 1.6),
    },
}
HEAD = HEADS[os.environ.get('TITAN_GEN', 'hunyuan')]
BLEND = ROOT / HEAD['blend']
LIP_Z = HEAD['lip_z']
BACK_Y = HEAD['back_y']
EYES = [Vector((s * HEAD['eyes'][0], HEAD['eyes'][1], HEAD['eyes'][2])) for s in (-1, 1)]
BANDS_Y = HEAD['bands_y']
BROW_Z = HEAD['brow_z']
HORN_X, HORN_Z, HORN_ZX = HEAD['horn']
STRAP_W, STRAP_T = 0.75, 0.24


def materials():
    have = {m.name for m in bpy.data.materials}
    want = [n for n in ('Rex_Blackened_Iron', 'Rex_Worn_Iron', 'Rex_Old_Rust', 'Rex_Amber') if n not in have]
    if want:
        with bpy.data.libraries.load(str(IRON_SOURCE), link=False) as (src, dst):
            dst.materials = want
    return [bpy.data.materials[n] for n in ('Rex_Blackened_Iron', 'Rex_Worn_Iron', 'Rex_Old_Rust')]


def clear():
    for ob in [o for o in bpy.data.objects if o.name.startswith(('Titan_Helmet', 'Muzzle_', 'Helmet_'))]:
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


def activate(ob):
    bpy.ops.object.select_all(action='DESELECT')
    ob.select_set(True)
    bpy.context.view_layer.objects.active = ob


def finish(ob, rig, bevel=0.0):
    activate(ob)
    if bevel:
        mod = ob.modifiers.new('Worn edges', 'BEVEL')
        mod.width, mod.segments, mod.limit_method = bevel, 2, 'ANGLE'
        bpy.ops.object.modifier_apply(modifier=mod.name)
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_all(action='SELECT')
    bpy.ops.uv.smart_project(angle_limit=math.radians(66), island_margin=0.02)
    bpy.ops.object.mode_set(mode='OBJECT')
    ob.vertex_groups.new(name='head').add(list(range(len(ob.data.vertices))), 1.0, 'REPLACE')
    mod = ob.modifiers.new('Combat skeleton', 'ARMATURE')
    mod.object = rig
    ob.parent = rig
    return ob


def head_faces(hide):
    """Hide faces the helmet covers: head-weighted, above the lip, ahead of
    the neck, clear of horns, eyes and nostrils."""
    #Head and jaw together: the snout's skin is shared between the two bones,
    #and a head-only test left the face full of holes.
    gis = {hide.vertex_groups[n].index for n in ('head', 'jaw')}
    ok = []
    for v in hide.data.vertices:
        w = sum(g.weight for g in v.groups if g.group in gis)
        p = v.co
        horn = abs(p.x) > HORN_X or (p.z > HORN_Z and abs(p.x) > HORN_ZX)
        #Only the eyes stay bare. Cutting the (guessed) nostrils too opened a
        #wide oval through the face plate; the nostril smoke leaves at its rim.
        hole = any((p - e).length < 0.55 for e in EYES)
        ok.append(w > 0.5 and p.z > LIP_Z and p.y < BACK_Y and not horn and not hole)
    return [f.index for f in hide.data.polygons if all(ok[i] for i in f.vertices)]


def rivet(p, normal, r, mat, rig):
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=12, v_segments=8, radius=r)
    for v in bm.verts:
        v.co.z *= 0.55
    rot = Vector((0, 0, 1)).rotation_difference(normal)
    bmesh.ops.rotate(bm, verts=bm.verts, matrix=rot.to_matrix())
    bmesh.ops.translate(bm, verts=bm.verts, vec=p)
    return finish(link('Helmet_Rivet', bm, mat), rig)


def helmet(hide, rig, iron, edge):
    faces = set(head_faces(hide))
    bm = bmesh.new()
    bm.from_mesh(hide.data)
    bm.faces.ensure_lookup_table()
    drop = [f for f in bm.faces if f.index not in faces]
    bmesh.ops.delete(bm, geom=drop, context='FACES')
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=0.02)
    # Keep the largest connected patch: stray islands are not plate.
    islands, seen = [], set()
    for f in bm.faces:
        if f in seen:
            continue
        stack, isle = [f], []
        while stack:
            g = stack.pop()
            if g in seen:
                continue
            seen.add(g)
            isle.append(g)
            for e in g.edges:
                stack.extend(x for x in e.link_faces if x not in seen)
        islands.append(isle)
    keep = set(max(islands, key=len))
    bmesh.ops.delete(bm, geom=[f for f in bm.faces if f not in keep], context='FACES')
    # Forged, not grown: iron smooths over the scales.
    inner = [v for v in bm.verts if not v.is_boundary]
    for _ in range(12):
        bmesh.ops.smooth_vert(bm, verts=inner, factor=0.5, use_axis_x=True, use_axis_y=True, use_axis_z=True)
    #A plate's rim is a cut line, not the edge of whichever faces passed the
    #test: relax it along itself (the snap below puts it back on the hide).
    rim = [v for v in bm.verts if v.is_boundary]
    for _ in range(10):
        moved = {}
        for v in rim:
            ends = [e.other_vert(v) for e in v.link_edges if e.is_boundary]
            if len(ends) == 2:
                moved[v] = v.co * 0.5 + (ends[0].co + ends[1].co) * 0.25
        for v, co in moved.items():
            v.co = co
    bm.normal_update()
    #Laplacian smoothing shrinks a convex patch inward: on the snout the plate
    #sank inside the hide and the skin showed through. Keep the smoothed
    #normals for the forged look, but sit every vertex back on the hide first.
    from mathutils.bvhtree import BVHTree
    tree = BVHTree.FromPolygons([v.co for v in hide.data.vertices],
                                [tuple(p.vertices) for p in hide.data.polygons])
    for v in bm.verts:
        hit = tree.find_nearest(v.co)
        if hit[0] is not None:
            v.co = hit[0]
        v.co += v.normal * 0.14
    shell = link('Titan_Helmet', bm, iron)
    activate(shell)
    mod = shell.modifiers.new('Forged thickness', 'SOLIDIFY')
    mod.thickness, mod.offset = 0.22, 1.0
    bpy.ops.object.modifier_apply(modifier=mod.name)
    finish(shell, rig, bevel=0.06)
    # Rivets round the rim: every ~0.9 m of boundary.
    bm = bmesh.new()
    bm.from_mesh(shell.data)
    rim = [e for e in bm.edges if e.is_boundary]
    run = 0.0
    for e in rim:
        run += e.calc_length()
        if run > 0.9:
            run = 0.0
            p = (e.verts[0].co + e.verts[1].co) / 2
            n = (e.verts[0].normal + e.verts[1].normal).normalized()
            rivet(p + n * 0.05, n, 0.13, edge, rig)
    bm.free()
    return shell


def outline(y, helm, hide, n=72, slab=0.4):
    dg = bpy.context.evaluated_depsgraph_get()
    pts = []
    #Only the head's own skin: the TRELLIS mane spikes reach forward under
    #the jaw, and the hull took them in and hung the hoops down to the chest.
    gis = {hide.vertex_groups[n].index for n in ('head', 'jaw')}
    skull = [sum(g.weight for g in v.groups if g.group in gis) > 0.5 for v in hide.data.vertices]
    for ob in (hide, helm):
        ev = ob.evaluated_get(dg)
        me = ev.to_mesh()
        for v in me.vertices:
            if ob is hide and not skull[v.index]:
                continue
            w = ob.matrix_world @ v.co
            if abs(w.y - y) < slab and 12.0 < w.z < BROW_Z and abs(w.x) < 3.0:
                pts.append((w.x, w.z))
        ev.to_mesh_clear()
    zs = [z for _, z in pts]
    zc = (min(zs) + max(zs)) / 2
    #A forged hoop spans the high points, it does not follow the scales into
    #every gap: per angle, the distance out to the section's convex hull.
    #The farthest point per angle made a saw-toothed ring on the TRELLIS
    #head, whose hide is all small spikes.
    from mathutils.geometry import convex_hull_2d
    hull = [Vector((pts[i][0], pts[i][1] - zc)) for i in convex_hull_2d(pts)]
    radius = []
    for k in range(n):
        t = math.tau * k / n
        d = Vector((math.cos(t), math.sin(t)))
        best = 0.0
        for a, b in zip(hull, hull[1:] + hull[:1]):
            e = b - a
            den = d.x * e.y - d.y * e.x
            if abs(den) < 1e-9:
                continue
            r = (a.x * e.y - a.y * e.x) / den
            u = (a.x * d.y - a.y * d.x) / den
            if r > 0 and -1e-6 <= u <= 1 + 1e-6:
                best = max(best, r)
        radius.append(best)
    return zc, radius


def band(y, helm, hide, rig, iron, edge):
    zc, radius = outline(y, helm, hide)
    n = len(radius)
    rng = np.random.default_rng(int(abs(y) * 100))
    bm = bmesh.new()
    rows, ring = [], []
    for k in range(n):
        t = math.tau * k / n
        out = Vector((math.cos(t), 0, math.sin(t)))
        r = radius[k] + 0.06 + 0.025 * math.sin(t * 7 + y) + rng.uniform(-0.01, 0.01)
        p = Vector((0, y, zc)) + out * r
        ring.append((p, out))
        rows.append([bm.verts.new(p + Vector((0, dy, 0)) + out * dr)
                     for dy, dr in [(-STRAP_W / 2, 0), (STRAP_W / 2, 0), (STRAP_W / 2, STRAP_T), (-STRAP_W / 2, STRAP_T)]])
    for k in range(n):
        a, b = rows[k], rows[(k + 1) % n]
        for j in range(4):
            bm.faces.new((a[j], a[(j + 1) % 4], b[(j + 1) % 4], b[j]))
    bmesh.ops.recalc_face_normals(bm, faces=list(bm.faces))
    finish(link('Muzzle_Band', bm, iron), rig, bevel=0.04)
    for k in range(0, n, 9):
        p, out = ring[k]
        rivet(p + out * (STRAP_T + 0.02), out, 0.14, edge, rig)
    return min(p.z for p, _ in ring)


def box(name, centre, size, mat, rig, bevel=0.04):
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    for v in bm.verts:
        v.co = Vector((v.co.x * size.x, v.co.y * size.y, v.co.z * size.z)) + centre
    return finish(link(name, bm, mat), rig, bevel)


def chin_lock(bottoms, rig, iron, edge, rust):
    a = Vector((0, BANDS_Y[0], bottoms[0] - STRAP_T))
    b = Vector((0, BANDS_Y[1], bottoms[1] - STRAP_T))
    box('Muzzle_Chin_Bar', (a + b) / 2 + Vector((0, 0, -0.05)),
        Vector((0.7, (a - b).length + STRAP_W, 0.22)), iron, rig)
    mid = (a + b) / 2 + Vector((0, 0, -0.75))
    box('Muzzle_Lock', mid, Vector((0.9, 1.05, 0.95)), edge, rig, 0.07)
    box('Muzzle_Lock_Plate', mid + Vector((0, -0.55, 0)), Vector((0.55, 0.07, 0.65)), rust, rig, 0.03)
    return mid + Vector((0, 0, -0.475))


def join(prefix, mat, name):
    parts = [o for o in bpy.data.objects if o.name.startswith(prefix) and o.type == 'MESH'
             and o.data.materials and o.data.materials[0] == mat]
    if not parts:
        return
    bpy.ops.object.select_all(action='DESELECT')
    for o in parts:
        o.select_set(True)
    bpy.context.view_layer.objects.active = parts[0]
    bpy.ops.object.join()
    bpy.context.object.name = name


def main():
    bpy.ops.wm.open_mainfile(filepath=str(BLEND))
    rig = bpy.data.objects['ReptilianRig']
    hide = bpy.data.objects['Reptilian_Hide']
    iron, edge, rust = materials()
    clear()
    helm = helmet(hide, rig, iron, edge)
    bottoms = [band(y, helm, hide, rig, iron, edge) for y in BANDS_Y]
    lock = chin_lock(bottoms, rig, iron, edge, rust)
    # Embers behind the helmet's eye openings: the game makes Rex_Amber glow.
    for i, e in enumerate(EYES):
        bm = bmesh.new()
        bmesh.ops.create_uvsphere(bm, u_segments=16, v_segments=10, radius=0.42)
        bmesh.ops.translate(bm, verts=bm.verts, vec=e + Vector((0, 0.15, 0)))
        finish(link('Titan_Eye', bm, bpy.data.materials['Rex_Amber']), rig)
    for prefix in ('Helmet_', 'Muzzle_'):
        join(prefix, iron, prefix + 'Blackened_Iron')
        join(prefix, edge, prefix + 'Worn_Iron')
        join(prefix, rust, prefix + 'Old_Rust')
    rig['helmet'] = 'Forged from the titan head; muzzle hoops lock the jaw shut'
    rig['muzzle_lock_bottom'] = list(lock)
    bpy.context.preferences.filepaths.save_version = 0
    bpy.ops.wm.save_as_mainfile(filepath=str(BLEND))
    print('HELMET built; lock bottom %s; objects %s' % (tuple(round(c, 2) for c in lock),
          sorted(o.name for o in bpy.data.objects if o.name.startswith(('Titan_Helmet', 'Helmet_', 'Muzzle_')))))


main()
