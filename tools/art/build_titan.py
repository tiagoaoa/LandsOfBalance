"""Rig a generated lizard titan onto the boss's 21-bone combat skeleton.

  blender -b --python tools/art/build_titan.py
  TITAN_GEN=trellis blender -b --python tools/art/build_titan.py

Starts from tools/art/source/reptilian_rex.blend (its ReptilianRig is the
skeleton every game script drives), replaces the old body with the generated
mesh, moves each bone onto the new anatomy and skins with automatic weights.
Saves the generation's blend (GENS below); helmet, muzzle and export come after
(titan_helmet.py, titan_export.py, same TITAN_GEN).

TITAN_GEN picks the generation: "hunyuan" (Hunyuan3D-2mv,
tools/art/source/lizard_titan/vast_la/textured_20261024.glb, the default) or
"trellis" (TRELLIS.2, tools/art/source/lizard_titan/trellis_clean.glb from
tools/art/prepare_trellis.py).

Landmarks were read off gridded orthographic front/side renders of each
generated mesh, in its own units (snout to -Y, Z up). The mesh is scaled so
its feet land on the old floor and its anchor on the given point, which keeps
the game's arena framing and head offsets in the same range.
"""
import os
from pathlib import Path

import bpy
from mathutils import Vector

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'tools/art/source/reptilian_rex.blend'
OLD_FLOOR = -21.5

GENS = {
    'hunyuan': {
        'label': 'Hunyuan3D-2mv lizard titan (tools/art/source/lizard_titan/vast_la)',
        'mesh': 'tools/art/source/lizard_titan/vast_la/textured_20261024.glb',
        'blend': 'tools/art/source/lizard_titan.blend',
        'feet': -0.78,
        # The first head-pivot guess, put on the old skull's head bone.
        'anchor': ((0.0, -0.72, 0.57), (0.0, -8.1, 13.68)),
        'deltoid_z': 0.25,
        # Bone (head, tail); L is -X.
        'spine': {
            'pelvis': ((0, -0.50, -0.15), (0, -0.58, 0.10)),
            'spine': ((0, -0.58, 0.10), (0, -0.63, 0.30)),
            'chest': ((0, -0.63, 0.30), (0, -0.66, 0.47)),
            # Skull base, snout tip and jaw read off gridded head close-ups after the
            # first fit (the first guess put the head pivot in the neck).
            'neck': ((0, -0.66, 0.47), (0, -0.812, 0.640)),
            'head': ((0, -0.812, 0.640), (0, -0.990, 0.613)),
            'jaw': ((0, -0.831, 0.599), (0, -0.966, 0.572)),
            'tail1': ((0, -0.42, -0.18), (0, -0.05, -0.45)),
            'tail2': ((0, -0.05, -0.45), (0, 0.45, -0.62)),
            'tail3': ((0, 0.45, -0.62), (0, 1.0, -0.76)),
        },
        'limbs': {   # +X side; mirrored to -X for .L
            'upperarm': ((0.33, -0.62, 0.38), (0.45, -0.60, 0.17)),
            'forearm': ((0.45, -0.60, 0.17), (0.50, -0.63, -0.05)),
            'hand': ((0.50, -0.63, -0.05), (0.47, -0.68, -0.30)),
            'thigh': ((0.17, -0.58, -0.12), (0.26, -0.52, -0.42)),
            'shin': ((0.26, -0.52, -0.42), (0.30, -0.52, -0.68)),
            'foot': ((0.30, -0.52, -0.68), (0.33, -0.82, -0.76)),
        },
    },
    'trellis': {
        'label': 'TRELLIS.2 lizard titan (tools/art/source/lizard_titan/vast_trellis, seed 7)',
        'mesh': 'tools/art/source/lizard_titan/trellis_clean.glb',
        'blend': 'tools/art/source/lizard_titan_trellis.blend',
        'feet': -0.305,
        # Head bone onto the Hunyuan titan's head bone, so the arena framing
        # and the hunch in titan_export.py carry over.
        'anchor': ((0.0, -0.418, 0.236), (0.0, -10.50, 15.50)),
        'deltoid_z': 0.10,
        'spine': {
            'pelvis': ((0, -0.315, -0.06), (0, -0.33, 0.04)),
            'spine': ((0, -0.33, 0.04), (0, -0.345, 0.12)),
            'chest': ((0, -0.345, 0.12), (0, -0.37, 0.18)),
            'neck': ((0, -0.37, 0.18), (0, -0.418, 0.236)),
            'head': ((0, -0.418, 0.236), (0, -0.497, 0.232)),
            'jaw': ((0, -0.432, 0.226), (0, -0.49, 0.214)),
            'tail1': ((0, -0.28, -0.07), (0, -0.12, -0.17)),
            'tail2': ((0, -0.12, -0.17), (0, 0.12, -0.245)),
            'tail3': ((0, 0.12, -0.245), (0, 0.5, -0.30)),
        },
        'limbs': {
            # The joint deep in the deltoid: on the mane's top line (0.145,
            # 0.15) the hunched shoulders rode 0.7 m higher and 1.3 m wider
            # than the Hunyuan titan's, and the grab could not reach a player.
            'upperarm': ((0.135, -0.345, 0.14), (0.195, -0.345, 0.065)),
            'forearm': ((0.195, -0.345, 0.065), (0.21, -0.365, -0.025)),
            'hand': ((0.21, -0.365, -0.025), (0.195, -0.39, -0.10)),
            'thigh': ((0.065, -0.335, -0.05), (0.10, -0.37, -0.145)),
            'shin': ((0.10, -0.37, -0.145), (0.11, -0.32, -0.25)),
            'foot': ((0.11, -0.32, -0.25), (0.13, -0.42, -0.30)),
        },
    },
}
GEN = GENS[os.environ.get('TITAN_GEN', 'hunyuan')]
MESH = ROOT / GEN['mesh']
OUT = ROOT / GEN['blend']
GEN_FEET = GEN['feet']
GEN_HEAD, OLD_HEAD = (Vector(p) for p in GEN['anchor'])
K = (OLD_HEAD.z - OLD_FLOOR) / (GEN_HEAD.z - GEN_FEET)
SPINE = GEN['spine']
LIMBS = GEN['limbs']


def to_old(p):
    p = Vector(p)
    return Vector((p.x * K, (p.y - GEN_HEAD.y) * K + OLD_HEAD.y, (p.z - GEN_FEET) * K + OLD_FLOOR))


def bones():
    out = {name: ht for name, ht in SPINE.items()}
    for name, (h, t) in LIMBS.items():
        out[name + '.R'] = (h, t)
        out[name + '.L'] = ((-h[0], h[1], h[2]), (-t[0], t[1], t[2]))
    return out


def replace_body(rig):
    for ob in [o for o in bpy.data.objects if o.type in ('MESH', 'CURVE', 'FONT')]:
        bpy.data.objects.remove(ob, do_unlink=True)
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=str(MESH))
    new = [o for o in bpy.data.objects if o not in before]
    meshes = [o for o in new if o.type == 'MESH']
    assert len(meshes) == 1, [o.name for o in new]
    body = meshes[0]
    for o in new:
        if o is not body:
            bpy.data.objects.remove(o, do_unlink=True)
    body.parent = None
    bpy.context.view_layer.update()
    mw = body.matrix_world.copy()
    body.matrix_world = mw
    body.data.transform(mw)
    body.matrix_world.identity()
    for v in body.data.vertices:
        v.co = to_old(v.co)
    body.data.update()
    # The game finds the skin by these names (SkinProbe, ReptilianRig).
    body.name = 'Reptilian_Hide'
    body.data.name = 'Reptilian_Hide'
    body.data.materials[0].name = 'Titan_Hide'
    return body


def fit_skeleton(rig):
    bpy.context.view_layer.objects.active = rig
    bpy.ops.object.mode_set(mode='EDIT')
    eb = rig.data.edit_bones
    for b in eb:
        b.use_connect = False
    for name, (h, t) in bones().items():
        eb[name].head = to_old(h)
        eb[name].tail = to_old(t)
    bpy.ops.object.mode_set(mode='OBJECT')
    for pb in rig.pose.bones:
        pb.location = (0, 0, 0)
        pb.rotation_quaternion = (1, 0, 0, 0)
        pb.rotation_euler = (0, 0, 0)
        pb.scale = (1, 1, 1)


def weld_body(body):
    import bmesh
    bm = bmesh.new()
    bm.from_mesh(body.data)
    #UVs live on face corners. Welding positions preserves them and lets
    #skin weights cross texture seams without cutting or capping the hide.
    bmesh.ops.remove_doubles(bm, verts=list(bm.verts), dist=0.0001)
    bm.to_mesh(body.data)
    bm.free()
    body.data.update()


def joint_band(w, edges, rings=12):
    import numpy as np
    top = w.argmax(axis=1)
    joint = np.zeros(len(w), dtype=bool)
    joint[edges[top[edges[:, 0]] != top[edges[:, 1]]].ravel()] = True
    #Keep palms, skull and armour rigid outside the joint bands.
    for _ in range(rings):
        spread = joint.copy()
        np.logical_or.at(spread, edges[:, 0], joint[edges[:, 1]])
        np.logical_or.at(spread, edges[:, 1], joint[edges[:, 0]])
        joint = spread
    return joint


def diffuse_weights(w, points, edges, passes, factor, locked):
    import numpy as np
    length = np.linalg.norm(points[edges[:, 0]] - points[edges[:, 1]], axis=1)
    strength = 1.0 / np.maximum(length, 0.01)
    deg = np.bincount(edges.ravel(), weights=np.repeat(strength, 2), minlength=len(w))
    deg[deg == 0] = 1.0
    original = w.copy()
    for _ in range(passes):
        acc = np.zeros_like(w)
        np.add.at(acc, edges[:, 0], w[edges[:, 1]] * strength[:, None])
        np.add.at(acc, edges[:, 1], w[edges[:, 0]] * strength[:, None])
        w = (1 - factor) * w + factor * acc / deg[:, None]
        w[locked] = original[locked]
    return w


def limit_weights(w, limit):
    import numpy as np
    #Dropping the fifth weight tears the skin where influences trade places.
    #Fade all weights by it before keeping the top four.
    cutoff = np.partition(w, -limit - 1, axis=1)[:, -limit - 1]
    w = np.maximum(w - cutoff[:, None], 0)
    return w / np.maximum(w.sum(axis=1, keepdims=True), 1e-12)


def read_weights(ob):
    import numpy as np
    w = np.zeros((len(ob.data.vertices), len(ob.vertex_groups)))
    for v in ob.data.vertices:
        for g in v.groups:
            w[v.index, g.group] = g.weight
    return w


def write_weights(ob, w):
    import numpy as np
    for gi, g in enumerate(ob.vertex_groups):
        col = w[:, gi]
        idx = np.nonzero(col > 1e-5)[0]
        g.remove(list(range(len(w))))
        for i in idx:
            g.add([int(i)], float(col[i]), 'REPLACE')


def smooth_weights(ob, passes=8, factor=0.5, limit=0):
    import numpy as np
    w = read_weights(ob)
    edges = np.array([e.vertices[:] for e in ob.data.edges])
    points = np.array([v.co[:] for v in ob.data.vertices])
    locked = np.zeros(len(w), dtype=bool)
    if limit:
        w /= np.maximum(w.sum(axis=1, keepdims=True), 1e-12)
        locked = ~joint_band(w, edges)
    w = diffuse_weights(w, points, edges, passes, factor, locked)
    if limit:
        w = limit_weights(w, limit)
    write_weights(ob, w)


def proxy_of(body):
    """Close the generated surface's remaining gaps for bone-heat weighting."""
    proxy = body.copy()
    proxy.data = body.data.copy()
    proxy.name = 'Titan_WeightProxy'
    bpy.context.scene.collection.objects.link(proxy)
    proxy.modifiers.clear()
    for g in list(proxy.vertex_groups):
        proxy.vertex_groups.remove(g)
    bpy.ops.object.select_all(action='DESELECT')
    proxy.select_set(True)
    bpy.context.view_layer.objects.active = proxy
    mod = proxy.modifiers.new('Voxel', 'REMESH')
    mod.mode = 'VOXEL'
    mod.voxel_size = 0.3
    bpy.ops.object.modifier_apply(modifier=mod.name)
    mod = proxy.modifiers.new('Lighter', 'DECIMATE')
    mod.ratio = max(0.02, min(1.0, 60000 / max(1, len(proxy.data.polygons))))
    bpy.ops.object.modifier_apply(modifier=mod.name)
    #Small voxel islands (studs, claw tips) and the odd non-manifold edge they
    #leave made bone heat fail for every bone on the TRELLIS body. The weights
    #only need the body itself; the transfer reaches the strays by distance.
    import bmesh
    bm = bmesh.new()
    bm.from_mesh(proxy.data)
    islands, seen = [], set()
    for v in bm.verts:
        if v in seen:
            continue
        stack, isle = [v], []
        seen.add(v)
        while stack:
            x = stack.pop()
            isle.append(x)
            for e in x.link_edges:
                o = e.other_vert(x)
                if o not in seen:
                    seen.add(o)
                    stack.append(o)
        islands.append(isle)
    islands.sort(key=len, reverse=True)
    bmesh.ops.delete(bm, geom=[v for isle in islands[1:] for v in isle], context='VERTS')
    bm.to_mesh(proxy.data)
    bm.free()
    proxy.data.update()
    print('TITAN proxy faces', len(proxy.data.polygons))
    return proxy


ARM = ('upperarm', 'forearm', 'hand')
HIP = ('pelvis', 'thigh', 'tail1', 'spine')


def separate_arms(body, rig):
    """In the A-pose the hands hang beside the hips: bone heat let the arm
    bones claim loincloth and hip vertices (they stretched into spikes when an
    arm moved) and the hips claim the hands. Draw the line at the arm's inner
    edge below the shoulders, then hand orphans to the nearest bone."""
    from mathutils.geometry import intersect_point_line

    def seg_dist(p, names):
        best = 1e18
        for n in names:
            b = rig.data.bones[n]
            q, f = intersect_point_line(p, b.head_local, b.tail_local)
            q = b.head_local if f < 0 else (b.tail_local if f > 1 else q)
            best = min(best, (p - q).length)
        return best

    #Nearer the arm's bones or the hip's decides it. Splitting by |x| alone
    #left the thigh's armour plates (as wide as the hanging hands) on hand.L.
    below = to_old((0, 0, GEN['deltoid_z'])).z           # under the shoulder's deltoid
    groups = {g.index: g.name for g in body.vertex_groups}
    arm_ids = [i for i, n in groups.items() if n.split('.')[0] in ARM]
    hip_ids = [i for i, n in groups.items() if n.split('.')[0] in HIP]
    for v in body.data.vertices:
        if v.co.z > below:
            continue
        side = '.L' if v.co.x < 0 else '.R'
        arm = seg_dist(v.co, ['forearm' + side, 'hand' + side])
        hip = seg_dist(v.co, ['pelvis', 'thigh' + side, 'tail1'])
        drop = arm_ids if hip < arm else hip_ids
        for gi in drop:
            try:
                body.vertex_groups[groups[gi]].remove([v.index])
            except RuntimeError:
                pass
    segs = [(b.name, b.head_local, b.tail_local) for b in rig.data.bones]
    orphans = 0
    for v in body.data.vertices:
        if any(g.weight > 1e-4 for g in v.groups):
            continue
        best, bd = None, 1e18
        for name, h, t in segs:
            p, f = intersect_point_line(v.co, h, t)
            p = h if f < 0 else (t if f > 1 else p)
            d = (v.co - p).length_squared
            if d < bd:
                best, bd = name, d
        body.vertex_groups[best].add([v.index], 1.0, 'REPLACE')
        orphans += 1
    print('TITAN weights: %d orphans given their nearest bone' % orphans)


def chest_off_the_arms(body, rig):
    """Chest and belly skin well inside the shoulder joints is the torso's:
    upper-arm weight there dragged the pecs into a ragged tear whenever an
    arm lifted for a blow."""
    inner = 0.62 * abs(rig.data.bones['upperarm.R'].head_local.x)
    for side in ('.L', '.R'):
        g = body.vertex_groups['upperarm' + side]
        drop = [v.index for v in body.data.vertices if abs(v.co.x) < inner
                and any(x.group == g.index for x in v.groups)]
        if drop:
            g.remove(drop)
    print('TITAN weights: upper arms kept outside |x| %.1f' % inner)


def shoulder_plates_ride(body, rig, reach=4.5):
    """The spiked plates over each shoulder were weighted to the chest: an arm
    raised for a blow left them behind and the skin between tore. Give the
    skin round the shoulder joint a share of the upper arm, fading with
    distance from the joint, so the plates ride up with it."""
    for side in ('.L', '.R'):
        joint = rig.data.bones['upperarm' + side].head_local
        g = body.vertex_groups['upperarm' + side]
        for v in body.data.vertices:
            if (v.co.x > 0) != (joint.x > 0) or abs(v.co.x) < 0.75 * abs(joint.x):
                continue
            d = (v.co - joint).length
            if d >= reach:
                continue
            share = 0.85 * (1.0 - d / reach)
            have = next((x.weight for x in v.groups if x.group == g.index), 0.0)
            if share > have:
                g.add([v.index], share, 'REPLACE')
    print('TITAN weights: shoulder plates share the upper arms')


def neighbours_only(body, rig):
    """A vertex may only blend its dominant bone with that bone's parent and
    children. Bone heat smeared weight across bones far apart in the skeleton
    (spine with thigh, neck with upper arm, head with upper arm): in the
    arena, where the IK swings an arm or the head slams down, those vertices
    were pulled between bones metres apart into rods, webs and torn holes."""
    near = {b.name: {b.name} | ({b.parent.name} if b.parent else set()) | {c.name for c in b.children}
            for b in rig.data.bones}
    names = {g.index: g.name for g in body.vertex_groups}
    trimmed = 0
    for v in body.data.vertices:
        if not v.groups:
            continue
        top = max(v.groups, key=lambda g: g.weight)
        keep = near[names[top.group]]
        drop = [names[g.group] for g in v.groups if names[g.group] not in keep and g.weight > 0.0]
        for n in drop:
            body.vertex_groups[n].remove([v.index])
        trimmed += bool(drop)
    print('TITAN weights: %d vertices trimmed to neighbouring bones' % trimmed)


def cut_fused_hands(body):
    """In the A-pose the generated hands rest against the hips, and the mesh
    fused them: faces bridge claw and thigh armour. Whatever their weights,
    those faces stretch into rods the moment an arm lifts. Cut every face
    that joins a forearm/hand vertex to a hip, leg or tail vertex, then cap
    the openings on both sides."""
    import bmesh
    names = {g.index: g.name for g in body.vertex_groups}

    def chain(v):
        if not v.groups:
            return 'body'
        top = names[max(v.groups, key=lambda g: g.weight).group].split('.')[0]
        if top in ('forearm', 'hand'):
            return 'arm'
        if top in ('pelvis', 'thigh', 'shin', 'foot', 'tail1', 'tail2', 'tail3', 'spine'):
            return 'hip'
        return 'other'

    kind = [chain(v) for v in body.data.vertices]
    bm = bmesh.new()
    bm.from_mesh(body.data)
    bm.faces.ensure_lookup_table()
    bridges = [f for f in bm.faces if {kind[v.index] for v in f.verts} >= {'arm', 'hip'}]
    #Only close the arm/hip cut. Capping UV seams added overlapping faces
    #all over the old Hunyuan body, including inside its claws.
    cut_verts = {v for f in bridges for v in f.verts}
    bmesh.ops.delete(bm, geom=bridges, context='FACES')
    edges = [e for e in bm.edges if e.is_boundary and e.is_valid
             and all(v in cut_verts for v in e.verts)]
    filled = bmesh.ops.holes_fill(bm, edges=edges, sides=0)['faces']
    bmesh.ops.triangulate(bm, faces=filled)
    bm.to_mesh(body.data)
    bm.free()
    body.data.update()
    print('TITAN fused hands: %d bridging faces cut, %d caps' % (len(bridges), len(filled)))


def skin(rig, body):
    proxy = proxy_of(body)
    bpy.ops.object.select_all(action='DESELECT')
    proxy.select_set(True)
    rig.select_set(True)
    bpy.context.view_layer.objects.active = rig
    bpy.ops.object.parent_set(type='ARMATURE_AUTO')
    empty = sum(1 for v in proxy.data.vertices if not v.groups)
    print('TITAN proxy skin: %d verts, %d with no weight' % (len(proxy.data.vertices), empty))
    #Smooth automatic weights before transferring them to the textured skin.
    smooth_weights(proxy, passes=8)
    # Carry the proxy's weights onto the real mesh, nearest surface point.
    for g in proxy.vertex_groups:
        if g.name not in body.vertex_groups:
            body.vertex_groups.new(name=g.name)
    bpy.ops.object.select_all(action='DESELECT')
    body.select_set(True)
    bpy.context.view_layer.objects.active = body
    mod = body.modifiers.new('Weights', 'DATA_TRANSFER')
    mod.object = proxy
    mod.use_vert_data = True
    mod.data_types_verts = {'VGROUP_WEIGHTS'}
    mod.vert_mapping = 'POLYINTERP_NEAREST'
    mod.layers_vgroup_select_src = 'ALL'
    mod.layers_vgroup_select_dst = 'NAME'
    bpy.ops.object.modifier_apply(modifier=mod.name)
    separate_arms(body, rig)
    chest_off_the_arms(body, rig)
    shoulder_plates_ride(body, rig)
    neighbours_only(body, rig)
    cut_fused_hands(body)
    #The neck and upper arms meet through the chest. The anatomical cuts
    #above leave abrupt boundaries until their weights are smoothed.
    #Blend across the connected surface after separating hands from hips.
    smooth_weights(body, passes=320, factor=0.7, limit=4)
    bpy.ops.object.vertex_group_normalize_all(group_select_mode='ALL', lock_active=False)
    body.parent = rig
    arm = body.modifiers.new('Combat skeleton', 'ARMATURE')
    arm.object = rig
    bpy.data.objects.remove(proxy, do_unlink=True)
    unweighted = sum(1 for v in body.data.vertices if not v.groups)
    print('TITAN skin: %d verts, %d with no weight' % (len(body.data.vertices), unweighted))
    return unweighted


def main():
    bpy.ops.wm.open_mainfile(filepath=str(SOURCE))
    rig = bpy.data.objects['ReptilianRig']
    body = replace_body(rig)
    weld_body(body)
    fit_skeleton(rig)
    skin(rig, body)
    rig['body'] = GEN['label']
    bpy.context.preferences.filepaths.save_version = 0
    bpy.ops.wm.save_as_mainfile(filepath=str(OUT))
    lo = Vector((1e9,) * 3)
    hi = Vector((-1e9,) * 3)
    for v in body.data.vertices:
        lo = Vector(map(min, lo, v.co))
        hi = Vector(map(max, hi, v.co))
    print('TITAN saved %s, K=%.2f, bounds %s..%s' % (OUT, K, tuple(round(c, 1) for c in lo), tuple(round(c, 1) for c in hi)))


main()
