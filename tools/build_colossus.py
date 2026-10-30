#Vaelgor, the Chained Colossus: rigid-part boss, waist up, no armature.
#blender -b --factory-startup -P tools/build_colossus.py
#Writes assets/characters/colossus/{colossus.glb,colossus.blend,*.png}
#and preview renders to $COLOSSUS_PREVIEW (default: the scratchpad below).
#Pass -- --no-render to skip the previews.
#
#Every part is its own mesh object with its origin on the joint pivot and
#identity rotation/scale, so the game can swing them procedurally.
#Faces Blender -Y, Z up, metres.  _L is -X, _R is +X.
import bpy
import bmesh
import math
import os
import random
import sys
from pathlib import Path
from mathutils import Vector, Matrix, noise
from mathutils.kdtree import KDTree
import numpy as np


ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'assets/characters/colossus'
PREVIEW = Path(os.environ.get('COLOSSUS_PREVIEW',
        '/tmp/claude-1000/-home-talves-mthings-LandsOfBalance/'
        '07261c89-1cc2-4cd7-9029-7c1b17b3a6a2/scratchpad/colossus'))
RENDER = '--no-render' not in sys.argv

STONE, BRONZE, EMBER, EYE, IRON = range(5)
MAT_NAMES = ['Colossus_Stone', 'Colossus_Bronze', 'Colossus_Ember',
        'Colossus_Eye', 'Colossus_Iron']
SMOOTH = {STONE: False, BRONZE: True, EMBER: False, EYE: True, IRON: True}

PIVOT = {
    'Colossus_Torso': (0, 0, 0),
    'Colossus_Core': (0, -2.3, 9.5),
    'Colossus_ShutterL': (-1.1, -2.5, 9.5),
    'Colossus_ShutterR': (1.1, -2.5, 9.5),
    'Colossus_Head': (0, -.3, 13.2),
    'Colossus_Eye': (0, -1.55, 14.8),
    'Colossus_UpperArm_L': (-5.5, 0, 12),
    'Colossus_Forearm_L': (-5.5, 0, 5.5),
    'Colossus_Hand_L': (-5.5, 0, -.5),
    'Colossus_UpperArm_R': (5.5, 0, 12),
    'Colossus_Forearm_R': (5.5, 0, 5.5),
    'Colossus_Hand_R': (5.5, 0, -.5),
}
PARENT = {
    'Colossus_Core': 'Colossus_Torso',
    'Colossus_ShutterL': 'Colossus_Torso',
    'Colossus_ShutterR': 'Colossus_Torso',
    'Colossus_Head': 'Colossus_Torso',
    'Colossus_Eye': 'Colossus_Head',
    'Colossus_UpperArm_L': 'Colossus_Torso',
    'Colossus_Forearm_L': 'Colossus_UpperArm_L',
    'Colossus_Hand_L': 'Colossus_Forearm_L',
    'Colossus_UpperArm_R': 'Colossus_Torso',
    'Colossus_Forearm_R': 'Colossus_UpperArm_R',
    'Colossus_Hand_R': 'Colossus_Forearm_R',
}

#closing the shutters = rotate local +Z by this (Godot: local +Y, same sign)
SHUTTER_OPEN = math.radians(90)


#---------------------------------------------------------------- textures

def tile_noise(n, seed, beta):
    #FFT-filtered white noise is periodic, so it tiles for free
    rng = np.random.default_rng(seed)
    f = np.fft.fft2(rng.normal(size = (n, n)))
    k = np.fft.fftfreq(n)
    k = np.sqrt(k[:, None] ** 2 + k[None, :] ** 2)
    k[0, 0] = 1
    f /= k ** beta
    f[0, 0] = 0
    img = np.real(np.fft.ifft2(f))
    img -= img.min()
    return img / img.max()


def smooth(a, b, x):
    t = np.clip((x - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)


def save_image(name, rgb):
    n = rgb.shape[0]
    img = bpy.data.images.new(name, n, n, alpha = False)
    rgba = np.ones((n, n, 4), dtype = np.float32)
    rgba[..., :3] = rgb
    img.pixels.foreach_set(rgba.ravel())
    path = OUT / (name + '.png')
    img.filepath_raw = str(path)
    img.file_format = 'PNG'
    img.save()
    img.filepath = str(path)
    return img


def make_textures():
    n = 1024
    big = tile_noise(n, 1, 1.6)
    mid = tile_noise(n, 2, 1.2)
    fine = tile_noise(n, 3, .6)
    #basalt: near-black blue grey, pale lichen-ash blotches, pitted
    v = .08 + .07 * big + .035 * mid + .025 * (fine - .5)
    ash = smooth(.62, .8, tile_noise(n, 4, 1.4)) * .06
    stone = np.stack([v + ash, v * .98 + ash, v * .95 + ash * .9], -1)
    stone_img = save_image('colossus_stone_albedo', np.clip(stone, 0, 1))
    #bronze: dark brown metal under verdigris crust, crust pools in noise lows
    crust = smooth(.42, .7, .45 * tile_noise(n, 5, 1.2) + .3 * mid
            + .25 * fine)
    metal = np.array([.26, .17, .08])
    verd = np.array([.13, .29, .23]) * (.8 + .4 * mid[..., None])
    rgb = metal * (1 - crust[..., None]) + verd * crust[..., None]
    rgb *= (.75 + .35 * big)[..., None]
    bronze_img = save_image('colossus_bronze_albedo', np.clip(rgb, 0, 1))
    #glTF metallicRoughness: G rough, B metal; crust is rough and dielectric
    mr = np.zeros((n, n, 3))
    mr[..., 1] = .3 + .45 * crust + .1 * fine
    mr[..., 2] = .95 - .6 * crust
    mr_img = save_image('colossus_bronze_mr', np.clip(mr, 0, 1))
    for img in (mr_img,):
        img.colorspace_settings.name = 'Non-Color'
    return stone_img, bronze_img, mr_img


def materials():
    stone_img, bronze_img, mr_img = make_textures()
    mats = []
    for name in MAT_NAMES:
        mat = bpy.data.materials.new(name)
        mat.use_nodes = True
        mats.append(mat)
    nt = mats[STONE].node_tree
    bsdf = next(n for n in nt.nodes if n.type == 'BSDF_PRINCIPLED')
    tex = nt.nodes.new('ShaderNodeTexImage')
    tex.image = stone_img
    nt.links.new(tex.outputs['Color'], bsdf.inputs['Base Color'])
    bsdf.inputs['Roughness'].default_value = .9
    bsdf.inputs['Metallic'].default_value = 0

    nt = mats[BRONZE].node_tree
    bsdf = next(n for n in nt.nodes if n.type == 'BSDF_PRINCIPLED')
    tex = nt.nodes.new('ShaderNodeTexImage')
    tex.image = bronze_img
    nt.links.new(tex.outputs['Color'], bsdf.inputs['Base Color'])
    mr = nt.nodes.new('ShaderNodeTexImage')
    mr.image = mr_img
    sep = nt.nodes.new('ShaderNodeSeparateColor')
    nt.links.new(mr.outputs['Color'], sep.inputs['Color'])
    nt.links.new(sep.outputs['Green'], bsdf.inputs['Roughness'])
    nt.links.new(sep.outputs['Blue'], bsdf.inputs['Metallic'])

    for idx, color, strength in ((EMBER, (1, .42, .1), 6),
            (EYE, (1, .93, .72), 8)):
        bsdf = next(n for n in mats[idx].node_tree.nodes
                if n.type == 'BSDF_PRINCIPLED')
        bsdf.inputs['Base Color'].default_value = (*color, 1)
        bsdf.inputs['Emission Color'].default_value = (*color, 1)
        bsdf.inputs['Emission Strength'].default_value = strength
        bsdf.inputs['Roughness'].default_value = .5

    bsdf = next(n for n in mats[IRON].node_tree.nodes
            if n.type == 'BSDF_PRINCIPLED')
    bsdf.inputs['Base Color'].default_value = (.07, .055, .045, 1)
    bsdf.inputs['Metallic'].default_value = .85
    bsdf.inputs['Roughness'].default_value = .7
    return mats


#---------------------------------------------------------------- geometry

def finish(bm, mat, smooth = None):
    bmesh.ops.recalc_face_normals(bm, faces = bm.faces[:])
    for f in bm.faces:
        f.material_index = mat
        f.smooth = SMOOTH[mat] if smooth is None else smooth
    return bm


class Part:
    def __init__(self):
        self.bm = bmesh.new()

    def add(self, bm):
        me = bpy.data.meshes.new('tmp')
        bm.to_mesh(me)
        self.bm.from_mesh(me)
        bpy.data.meshes.remove(me)
        bm.free()


def mat_trs(loc = (0, 0, 0), rot = (0, 0, 0), scale = (1, 1, 1)):
    from mathutils import Euler
    return (Matrix.Translation(loc) @ Euler(rot).to_matrix().to_4x4()
            @ Matrix.Diagonal((*scale, 1)))


def box(size, mat, loc = (0, 0, 0), rot = (0, 0, 0), bevel = 0, seg = 1,
        cuts = 0):
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size = 1)
    bm.transform(Matrix.Diagonal((*size, 1)))
    if bevel:
        bmesh.ops.bevel(bm, geom = bm.edges[:] + bm.verts[:],
                offset = bevel, segments = seg, affect = 'EDGES',
                profile = .5, clamp_overlap = True)
    if cuts:
        bmesh.ops.subdivide_edges(bm, edges = bm.edges[:], cuts = cuts,
                use_grid_fill = True)
    bm.transform(mat_trs(loc, rot))
    return finish(bm, mat)


def sphere(radius, mat, loc = (0, 0, 0), u = 16, v = 10, scale = (1, 1, 1),
        rot = (0, 0, 0)):
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments = u, v_segments = v,
            radius = radius)
    bm.transform(mat_trs(loc, rot, scale))
    return finish(bm, mat)


def ico(radius, mat, loc = (0, 0, 0), sub = 1, scale = (1, 1, 1)):
    bm = bmesh.new()
    bmesh.ops.create_icosphere(bm, subdivisions = sub, radius = radius)
    bm.transform(mat_trs(loc, (0, 0, 0), scale))
    return finish(bm, mat)


def cyl(r1, r2, depth, mat, loc = (0, 0, 0), rot = (0, 0, 0), seg = 12):
    bm = bmesh.new()
    bmesh.ops.create_cone(bm, cap_ends = True, cap_tris = False,
            segments = seg, radius1 = r1, radius2 = r2, depth = depth)
    bm.transform(mat_trs(loc, rot))
    return finish(bm, mat)


def frame_between(p0, p1):
    p0, p1 = Vector(p0), Vector(p1)
    d = p1 - p0
    q = Vector((0, 0, 1)).rotation_difference(d.normalized())
    return (Matrix.Translation((p0 + p1) / 2) @ q.to_matrix().to_4x4()), d.length


def seg_box(p0, p1, w, h, mat, bevel = .08):
    m, length = frame_between(p0, p1)
    bm = box((w, h, length), mat, bevel = bevel, seg = 2)
    bm.transform(m)
    return finish(bm, mat)


def shard(base, direction, length, radius, mat, rng, sides = 5, bend = .15):
    #jagged crystal/rock spike: a bent, noisy pyramid
    d = Vector(direction).normalized()
    side = d.orthogonal().normalized()
    rings = []
    steps = 4
    for i in range(steps):
        t = i / steps
        c = Vector(base) + d * length * t + side * bend * length * t * t
        r = radius * (1 - t) ** .8
        ring = []
        for k in range(sides):
            a = 2 * math.pi * k / sides + rng.uniform(-.25, .25)
            v = (side * math.cos(a) + d.cross(side) * math.sin(a))
            ring.append(c + v * r * rng.uniform(.75, 1.2))
        rings.append(ring)
    tip = Vector(base) + d * length + side * bend * length
    return finish(loft(rings, cap0 = True, tip = tip), mat)


def loft(rings, cap0 = True, cap1 = True, tip = None, closed = True):
    bm = bmesh.new()
    vr = [[bm.verts.new(p) for p in ring] for ring in rings]
    n = len(rings[0])
    span = n if closed else n - 1
    for a, b in zip(vr, vr[1:]):
        for i in range(span):
            j = (i + 1) % n
            bm.faces.new((a[i], a[j], b[j], b[i]))
    if cap0 and closed:
        bm.faces.new(vr[0][::-1])
    if tip is not None:
        t = bm.verts.new(tip)
        for i in range(n):
            bm.faces.new((vr[-1][i], vr[-1][(i + 1) % n], t))
    elif cap1 and closed:
        bm.faces.new(vr[-1])
    return bm


def torus(major, minor, mat, loc = (0, 0, 0), rot = (0, 0, 0),
        scale = (1, 1, 1), seg = 12, sides = 6, arc = 2 * math.pi):
    full = arc >= 2 * math.pi - 1e-6
    count = seg if full else seg + 1
    rings = []
    for i in range(count):
        a = arc * i / seg
        c = Vector((math.cos(a) * major, math.sin(a) * major, 0))
        out = Vector((math.cos(a), math.sin(a), 0))
        rings.append([c + out * math.cos(b) * minor
                + Vector((0, 0, math.sin(b) * minor))
                for b in (2 * math.pi * k / sides for k in range(sides))])
    if full:
        rings.append(rings[0])
        bm = loft(rings, cap0 = False, cap1 = False)
        bmesh.ops.remove_doubles(bm, verts = bm.verts[:], dist = 1e-5)
    else:
        bm = loft(rings)
    bm.transform(mat_trs(loc, rot, scale))
    return finish(bm, mat)


def displace(bm, amp, freq, seed = 0, mask = None):
    bm.normal_update()
    off = Vector((seed * 17.3, seed * 5.1, seed * 9.7))
    for v in bm.verts:
        w = mask(v.co) if mask else 1
        if w <= 0:
            continue
        n = noise.fractal(v.co * freq + off, .6, 2.1, 3)
        v.co += v.normal * n * amp * w


def crack_slabs(bm, cells, ember, rng, inset = .08, depth = .1,
        jitter = .06, only = None):
    #split the surface into Voronoi slabs of stone floating over a molten
    #underlay; hot slabs pull back from their seams so the ember shows,
    #cold ones stay tight and only their uneven lift reads
    faces = [f for f in bm.faces if f.material_index == STONE
            and (only is None or only(f))]
    if not faces:
        return bm
    faces = bmesh.ops.triangulate(bm, faces = faces,
            quad_method = 'ALTERNATE')['faces']
    region = set(faces)
    bm.normal_update()
    #shake interior verts sideways so seams wander off the grid
    for v in dict.fromkeys(v for f in faces for v in f.verts):
        if any(f not in region for f in v.link_faces) or not v.link_edges:
            continue
        el = sum(e.calc_length() for e in v.link_edges) / len(v.link_edges)
        j = Vector((rng.uniform(-1, 1), rng.uniform(-1, 1),
                rng.uniform(-1, 1))) * el * .3
        v.co += j - v.normal * j.dot(v.normal)
    bm.normal_update()
    #molten underlay
    dup = bmesh.ops.duplicate(bm, geom = faces)['geom']
    under = [g for g in dup if isinstance(g, bmesh.types.BMFace)]
    uverts = [g for g in dup if isinstance(g, bmesh.types.BMVert)]
    bm.normal_update()
    for v in uverts:
        v.co -= v.normal * depth
    for f in under:
        f.material_index = EMBER
        f.smooth = False
    #cells
    if len(faces) < cells * 3:
        cells = max(1, len(faces) // 3)
    centers = [f.calc_center_median() for f in faces]
    seeds = rng.sample(centers, cells)
    tree = KDTree(len(seeds))
    for i, sd in enumerate(seeds):
        tree.insert(sd, i)
    tree.balance()
    cell_of = {}
    groups = {}
    for f, c in zip(faces, centers):
        k = tree.find(c)[1]
        cell_of[f] = k
        groups.setdefault(k, []).append(f)
    seams = [e for f in faces for e in f.edges if len(e.link_faces) == 2
            and all(g in region for g in e.link_faces)
            and cell_of[e.link_faces[0]] != cell_of[e.link_faces[1]]]
    bmesh.ops.split_edges(bm, edges = list(set(seams)))
    #hot cells cluster into veins: rank cells by a low-frequency noise
    off = Vector((rng.uniform(0, 99), rng.uniform(0, 99), rng.uniform(0, 99)))
    heat = {k: noise.noise(seeds[k] * .22 + off) + rng.uniform(-.15, .15)
            for k in groups}
    ranked = sorted(groups, key = lambda k: -heat[k])
    hot_cells = set(ranked[:int(round(len(ranked) * ember))])
    for cell, fs in groups.items():
        verts = {v for f in fs for v in f.verts}
        mid = sum((v.co for v in verts), Vector()) / len(verts)
        normal = sum((f.normal for f in fs), Vector()).normalized()
        gap = inset * rng.uniform(.8, 1.3) if cell in hot_cells else 0
        edges = [e for f in fs for e in f.edges if e.is_boundary]
        rim = {v for e in edges for v in e.verts}
        for v in rim:
            d = mid - v.co
            d -= normal * d.dot(normal)
            if d.length > 1e-6:
                v.co += d.normalized() * min(gap, d.length * .45)
        lift = rng.uniform(-jitter, jitter)
        tilt = Vector((rng.uniform(-1, 1), rng.uniform(-1, 1),
                rng.uniform(-1, 1))) * jitter * .5
        for v in verts:
            v.co += normal * (lift + tilt.dot(v.co - mid))
        #slab walls down into the melt
        if edges:
            ext = bmesh.ops.extrude_edge_only(bm, edges = list(set(edges)))
            for g in ext['geom']:
                if isinstance(g, bmesh.types.BMVert):
                    g.co -= normal * depth * 1.4
                elif isinstance(g, bmesh.types.BMFace):
                    g.material_index = STONE
                    g.smooth = False
    return bm


def shell(f, u0, u1, v0, v1, nu, nv, offset, thick, mat, outward,
        jag = None, closed_u = False):
    #a plate lying on parametric surface f(u, v), pushed `offset` out,
    #`thick` deep; jag(u, v) adds extra length/raggedness at the v1 edge
    def point(u, v, extra = 0):
        p = f(u, v)
        e = 1e-3
        du = f(u + e, v) - f(u - e, v)
        dv = f(u, v + e) - f(u, v - e)
        n = du.cross(dv).normalized()
        if n.dot(p - outward(p)) < 0:
            n = -n
        return p, n
    us = [u0 + (u1 - u0) * i / (nu - (0 if closed_u else 1))
            for i in range(nu)]
    vs = [v0 + (v1 - v0) * j / (nv - 1) for j in range(nv)]
    top, bot = [], []
    for j, v in enumerate(vs):
        rt, rb = [], []
        for u in us:
            vv = v
            if jag and j == nv - 1:
                vv = v + jag(u)
            p, n = point(u, vv)
            rt.append(p + n * (offset + thick))
            rb.append(p + n * offset)
        top.append(rt)
        bot.append(rb)
    bm = bmesh.new()
    T = [[bm.verts.new(p) for p in r] for r in top]
    B = [[bm.verts.new(p) for p in r] for r in bot]
    nuu = nu if closed_u else nu - 1
    for j in range(nv - 1):
        for i in range(nuu):
            k = (i + 1) % nu
            bm.faces.new((T[j][i], T[j][k], T[j + 1][k], T[j + 1][i]))
            bm.faces.new((B[j][i], B[j + 1][i], B[j + 1][k], B[j][k]))
    #rim
    for j in range(nv - 1):
        if not closed_u:
            bm.faces.new((T[j][0], T[j + 1][0], B[j + 1][0], B[j][0]))
            bm.faces.new((T[j][-1], B[j][-1], B[j + 1][-1], T[j + 1][-1]))
    for i in range(nuu):
        k = (i + 1) % nu
        bm.faces.new((T[0][i], B[0][i], B[0][k], T[0][k]))
        bm.faces.new((T[-1][i], T[-1][k], B[-1][k], B[-1][i]))
    return finish(bm, mat)


def boolean_diff(bm, cutter, mat_for_cut, cut_test):
    me1 = bpy.data.meshes.new('bool_a')
    bm.to_mesh(me1)
    me2 = bpy.data.meshes.new('bool_b')
    cutter.to_mesh(me2)
    a = bpy.data.objects.new('bool_a', me1)
    b = bpy.data.objects.new('bool_b', me2)
    bpy.context.collection.objects.link(a)
    bpy.context.collection.objects.link(b)
    mod = a.modifiers.new('cut', 'BOOLEAN')
    mod.operation = 'DIFFERENCE'
    mod.object = b
    mod.solver = 'EXACT'
    dg = bpy.context.evaluated_depsgraph_get()
    me = bpy.data.meshes.new_from_object(a.evaluated_get(dg))
    out = bmesh.new()
    out.from_mesh(me)
    for f in out.faces:
        if cut_test(f.calc_center_median()):
            f.material_index = mat_for_cut
            f.smooth = SMOOTH[mat_for_cut]
    for o in (a, b):
        bpy.data.objects.remove(o)
    for m in (me1, me2, me):
        bpy.data.meshes.remove(m)
    bm.free()
    cutter.free()
    return out


#---------------------------------------------------------------- torso

TZ = [-.5, 0, 1.5, 3.5, 6, 8, 9.5, 11, 12, 12.6, 13.1, 13.7]
TW = [2.6, 2.65, 2.65, 3.0, 3.8, 4.35, 4.55, 4.65, 4.45, 3.7, 2.5, 1.6]
TF = [1.85, 1.9, 2.0, 2.15, 2.3, 2.45, 2.5, 2.4, 2.05, 1.7, 1.4, 1.2]
TB = [1.8, 1.85, 1.95, 2.15, 2.5, 2.9, 3.2, 3.35, 3.1, 2.5, 1.8, 1.2]
TP = 2.3


def torso_point(t, z):
    w = float(np.interp(z, TZ, TW))
    s = math.sin(t)
    d = float(np.interp(z, TZ, TF if s < 0 else TB))
    c = math.cos(t)
    x = w * math.copysign(abs(c) ** (2 / TP), c)
    y = d * math.copysign(abs(s) ** (2 / TP), s)
    #pectoral mass either side of the socket
    if s < 0:
        y -= .25 * math.exp(-((abs(x) - 2.4) / 1.3) ** 2) \
                * math.exp(-((z - 10) / 1.4) ** 2)
    return Vector((x, y, z))


def torso_axis(p):
    return Vector((0, .1, p.z))


def t_for_x(x, z, front = True):
    #angle on the front (sin<0) or back half whose x is `x`
    lo, hi = (math.pi, 2 * math.pi) if front else (0, math.pi)
    if not front:
        lo, hi = hi, lo
    for _ in range(40):
        m = (lo + hi) / 2
        if torso_point(m, z).x < x:
            lo = m
        else:
            hi = m
    return (lo + hi) / 2


SOCKET = Vector((0, -2.3, 9.5))


def build_torso(rng):
    part = Part()
    zs = list(np.arange(-.5, 13.71, .36))
    n = 46
    rings = [[torso_point(2 * math.pi * i / n + math.pi / 2, z)
            for i in range(n)] for z in zs]
    body = loft(rings)
    finish(body, STONE)

    def calm(p):
        d = math.hypot(p.x, p.z - SOCKET.z)
        return min(1, max(0, (d - 1.4) / 1.2)) if p.y < 0 else 1
    displace(body, .3, .32, seed = 1, mask = calm)
    displace(body, .08, 1.3, seed = 2)
    crack_slabs(body, 70, .38, rng, inset = .13, depth = .2,
            only = lambda f: not (abs(f.calc_center_median().x) < 1.9
                and abs(f.calc_center_median().z - SOCKET.z) < 1.9
                and f.calc_center_median().y < 0))
    #the socket: open a hole in the chest, line it with a bronze cup
    #(radius 1.05, floor .6 behind the frame face); the frame ring hides
    #the ragged edge of the hole
    dead = [f for f in body.faces if f.calc_center_median().y < 0
            and math.hypot(f.calc_center_median().x,
                f.calc_center_median().z - SOCKET.z) < 1.3]
    bmesh.ops.delete(body, geom = dead, context = 'FACES')
    rings = []
    for y in (-3.0, -1.95):
        rings.append([Vector((math.cos(a) * 1.05, y, SOCKET.z
                + math.sin(a) * 1.05)) for a in (2 * math.pi * i / 24
                for i in range(24))])
    cup = loft(rings, cap0 = False, cap1 = True)
    finish(cup, BRONZE)
    #walls face inward
    for f in cup.faces:
        c = f.calc_center_median()
        radial = Vector((c.x, 0, c.z - SOCKET.z))
        if radial.length < .1:
            if f.normal.y > 0:
                f.normal_flip()
        elif f.normal.dot(radial) > 0:
            f.normal_flip()
    part.add(cup)
    part.add(body)

    #socket frame: bronze ring flush with the chest, then the lower lip
    def ring_shape(r_in, r_out, y_front, y_back, a0, a1, seg):
        rings = []
        prof = [(r_in, y_back), (r_in, y_front), (r_out, y_front + .12),
                (r_out, y_back)]
        for i in range(seg + 1):
            a = a0 + (a1 - a0) * i / seg
            rings.append([Vector((math.cos(a) * r, y, SOCKET.z
                    + math.sin(a) * r)) for r, y in prof])
        return rings
    rg = ring_shape(1.05, 1.6, -2.72, -2.2, 0, 2 * math.pi, 32)
    rg[-1] = rg[0]
    bm = loft(rg, cap0 = False, cap1 = False)
    bmesh.ops.remove_doubles(bm, verts = bm.verts[:], dist = 1e-4)
    part.add(finish(bm, BRONZE))
    #lower lip: protrudes ~.55 proud, shielding the core from below
    lip = ring_shape(1.14, 1.75, -3.28, -2.4, math.radians(195),
            math.radians(345), 16)
    for ring in lip:
        for v in ring:
            #lip leans up and out like a jaw
            if v.y < -2.6:
                v.z += .12
    part.add(finish(loft(lip), BRONZE))
    #spikes on the lip
    for a in (220, 250, 290, 320):
        r = math.radians(a)
        base = Vector((math.cos(r) * 1.5, -3.1, SOCKET.z + math.sin(r) * 1.5))
        part.add(shard(base, (math.cos(r) * .4, -1, math.sin(r) * .6),
                .7, .16, BRONZE, rng, sides = 4, bend = 0))

    #pectoral plates
    for side in (-1, 1):
        def f(u, z, side = side):
            return torso_point(u, z)
        zlo, zhi = 7.9, 11.9
        ta = t_for_x(side * 1.7, 10)
        tb = t_for_x(side * 4.3, 10)
        u0, u1 = min(ta, tb), max(ta, tb)
        def jag(u):
            return -rng.uniform(0, .45) if rng.random() < .5 else 0
        bm = shell(f, u0, u1, zhi, zlo, 9, 7, .12, .22, BRONZE, torso_axis,
                jag = jag)
        part.add(bm)
        #rivets along the inner edge
        for k in range(5):
            z = zlo + .5 + k * .7
            p = torso_point(t_for_x(side * 1.95, z), z)
            part.add(sphere(.11, BRONZE, loc = p + Vector((0, -.38, 0)),
                    u = 8, v = 4))
        #lower lames under the pecs
        for k, (za, zb) in enumerate(((7.0, 7.95), (6.1, 7.1))):
            ta = t_for_x(side * (1.5 + k * .3), za)
            tb = t_for_x(side * (4.0 - k * .3), za)
            bm = shell(f, min(ta, tb), max(ta, tb), zb, za, 7, 3, .14,
                    .16, BRONZE, torso_axis)
            part.add(bm)

    #back plate: one big cracked slab of bronze over the shoulder blades
    def fb(u, z):
        return torso_point(u, z)
    ta = t_for_x(-3.4, 10.5, front = False)
    tb = t_for_x(3.4, 10.5, front = False)
    part.add(shell(fb, min(ta, tb), max(ta, tb), 12.2, 8.4, 11, 6, .14,
            .22, BRONZE, torso_axis,
            jag = lambda u: -rng.uniform(0, .7) if rng.random() < .6 else 0))

    #gorget: flared bronze collar at the neck base
    rings = []
    for z, r, d in ((12.6, 2.2, 2.0), (13.0, 1.95, 1.8),
            (13.4, 1.8, 1.65), (13.75, 1.78, 1.62)):
        rings.append([Vector((math.cos(a) * r, math.sin(a) * d + .05, z))
                for a in (2 * math.pi * i / 28 for i in range(28))])
    outer = rings
    inner = [[Vector((p.x * .9, p.y * .9, p.z)) for p in r] for r in rings]
    bm = loft(outer + inner[::-1], cap0 = False, cap1 = False)
    #close the tube ends
    bm.verts.ensure_lookup_table()
    nn = 28
    rows = len(outer) + len(inner)
    V = [bm.verts[i * nn:(i + 1) * nn] for i in range(rows)]
    for i in range(nn):
        j = (i + 1) % nn
        bm.faces.new((V[-1][i], V[-1][j], V[0][j], V[0][i]))
    part.add(finish(bm, BRONZE))

    #belt and ragged skirt
    def fw(u, z):
        return torso_point(u, z)
    part.add(shell(fw, math.pi / 2, math.pi / 2 + 2 * math.pi, .4, 1.7,
            40, 3, .1, .3, BRONZE, torso_axis, closed_u = True))
    by = torso_point(1.5 * math.pi, 1.05).y - .45
    part.add(cyl(.75, .6, .35, BRONZE, loc = (0, by, 1.05),
            rot = (math.pi / 2, 0, 0), seg = 16))
    part.add(sphere(.34, BRONZE, loc = (0, by - .15, 1.05), u = 10, v = 6,
            scale = (1, .6, 1)))
    for i in range(18):
        a = 2 * math.pi * i / 18 + math.pi / 2
        if abs(math.sin(a) + 1) < .05:
            continue
        p = torso_point(a, 1.05)
        n = (p - torso_axis(p)).normalized()
        part.add(box((.22, .22, .22), BRONZE, loc = p + n * .42,
                rot = (0, 0, a), bevel = .05))
    #tassets, flaring out; some snapped short
    count = 10
    for i in range(count):
        a0 = math.pi / 2 + 2 * math.pi * i / count + .04
        a1 = a0 + 2 * math.pi / count + .12
        drop = rng.uniform(-1.2, -.5) if i % 3 else rng.uniform(-.4, 0)
        def ft(u, z, drop = drop):
            p = torso_point(u, max(z, -.5))
            flare = (.6 - z) * .28
            n = (p - torso_axis(p)).normalized()
            return Vector((p.x, p.y, z)) + n * max(0, flare)
        part.add(shell(ft, a0, a1, .6, drop, 5, 4, .22, .16, BRONZE,
                torso_axis,
                jag = lambda u: -rng.uniform(0, .35)))
    #stone rubble hanging between the tassets, hides the waist cap
    for i in range(14):
        a = 2 * math.pi * i / 14 + rng.uniform(-.1, .1)
        p = torso_point(a, -.3)
        n = (p - torso_axis(p)).normalized()
        part.add(shard(p + n * .1 + Vector((0, 0, .3)),
                (n.x * .3, n.y * .3, -1), rng.uniform(.8, 1.5),
                rng.uniform(.35, .55), STONE, rng))

    #hunched trapezius masses: the head sits low between them
    for side in (-1, 1):
        bm = ico(1.0, STONE, loc = (side * 2.5, .7, 12.7), sub = 2,
                scale = (2.1, 1.9, 1.35))
        bm.transform(Matrix.Translation((side * 2.5, .7, 12.7))
                @ Matrix.Rotation(side * math.radians(-22), 4, 'Y')
                @ Matrix.Translation((-side * 2.5, -.7, -12.7)))
        displace(bm, .25, .7, seed = 40 + side)
        crack_slabs(bm, 9, .3, rng, inset = .12, depth = .18)
        part.add(bm)

    #rock spines breaking out of the upper back
    for base, d, length, r in (
            ((-2.5, 2.3, 12.0), (-.4, .7, 1), 3.2, .55),
            ((2.5, 2.3, 12.0), (.4, .7, 1), 3.4, .6),
            ((-1.1, 2.9, 11.0), (-.1, 1, .9), 2.4, .45),
            ((1.2, 2.9, 10.9), (.15, 1, .8), 2.0, .45),
            ((0, 3.0, 9.6), (0, 1, .7), 1.8, .4),
            ((-3.6, 1.9, 12.0), (-.6, .6, 1), 1.6, .4),
            ((3.7, 1.9, 11.9), (.6, .6, 1), 1.4, .38)):
        part.add(shard(base, d, length, r, STONE, rng, sides = 6))

    #a broken chain draped over the left breast, anchored at the belt
    p0 = Vector((-3.6, -2.2, 11.9))
    p1 = Vector((1.2, -2.6, 3.6))
    links = 11
    for i in range(links):
        t = i / (links - 1)
        p = p0.lerp(p1, t)
        sag = math.sin(t * math.pi) * .35
        p.y -= .35 + sag
        #follow chest surface roughly
        surf = torso_point(t_for_x(p.x, p.z), p.z)
        p.y = min(p.y, surf.y - .35)
        d = (p1 - p0).normalized()
        rot_axis = Vector((0, 0, 1)).rotation_difference(d)
        m = Matrix.Translation(p) @ rot_axis.to_matrix().to_4x4()
        if i % 2:
            m = m @ Matrix.Rotation(math.pi / 2, 4, 'Z')
        bm = torus(.32, .1, IRON, rot = (math.pi / 2, 0, 0),
                scale = (1, 1, 1), seg = 10, sides = 6)
        bm.transform(Matrix.Diagonal((1, 1, 1.5, 1)))
        bm.transform(m)
        part.add(finish(bm, IRON))
    return part


def build_core(rng):
    part = Part()
    bm = ico(.85, EMBER, loc = SOCKET, sub = 2)
    displace(bm, .08, 2.2, seed = 7)
    part.add(bm)
    return part


def build_shutter(side, rng):
    #closed geometry first: half a dome over the socket, then swung open
    part = Part()
    C = Vector((0, -2.5, SOCKET.z))
    def f(a, th):
        return C + Vector((math.sin(th) * math.cos(a), -math.cos(th),
                math.sin(th) * math.sin(a))) * 1.1
    a0, a1 = (math.pi / 2, 3 * math.pi / 2) if side < 0 else \
            (-math.pi / 2, math.pi / 2)
    bm = shell(f, a0, a1, .02, math.pi / 2, 10, 6, 0, .12, BRONZE,
            lambda p: C)
    part.add(bm)
    #ribs
    for k in (.3, .5, .7):
        a = a0 + (a1 - a0) * k
        pts = [f(a, th) for th in np.linspace(.05, math.pi / 2, 6)]
        for p, q in zip(pts, pts[1:]):
            part.add(seg_box(p + (p - C).normalized() * .1,
                    q + (q - C).normalized() * .1, .12, .1, BRONZE,
                    bevel = 0))
    #hinge barrel
    part.add(cyl(.17, .17, 2.3, BRONZE, loc = (side * 1.12, -2.5,
            SOCKET.z), seg = 10))
    #swing open about the hinge
    hinge = Vector(PIVOT['Colossus_ShutterL' if side < 0
            else 'Colossus_ShutterR'])
    ang = -SHUTTER_OPEN if side < 0 else SHUTTER_OPEN
    m = (Matrix.Translation(hinge) @ Matrix.Rotation(ang, 4, 'Z')
            @ Matrix.Translation(-hinge))
    part.bm.transform(m)
    return part


#---------------------------------------------------------------- head

HC = Vector((0, -.2, 15.0))
HR = Vector((1.5, 1.6, 1.65))


def helm_point(az, pol):
    #superellipsoid-ish helm; az around Z (0 = +X), pol from +Z
    sp, cp = math.sin(pol), math.cos(pol)
    ca, sa = math.cos(az), math.sin(az)
    e = 2 / 2.6
    x = HR.x * math.copysign(abs(ca) ** e, ca) * abs(sp) ** e
    y = HR.y * math.copysign(abs(sa) ** e, sa) * abs(sp) ** e
    z = HR.z * math.copysign(abs(cp) ** .9, cp)
    p = Vector((x, y, z))
    #wedge the face forward, pinch the jaw
    if y < 0:
        p.y -= .3 * max(0, 1 - abs(x) / HR.x) ** 2 * (1 - abs(cp) * .4)
    if z < 0:
        k = 1 - .25 * (-z / HR.z) ** 2
        p.x *= k
    return HC + p


def build_head(rng):
    part = Part()
    #neck
    rings = []
    for z in np.arange(12.2, 14.31, .35):
        rings.append([Vector((math.cos(a) * 1.4, math.sin(a) * 1.3 - .1, z))
                for a in (2 * math.pi * i / 14 for i in range(14))])
    bm = finish(loft(rings), STONE)
    displace(bm, .15, .9, seed = 3)
    part.add(bm)

    nu, nv = 34, 20
    rings = [[helm_point(2 * math.pi * i / nu, math.pi * j / nv)
            for i in range(nu)] for j in range(1, nv)]
    bm = finish(loft(rings), BRONZE)
    displace(bm, .03, 2.5, seed = 4)
    eye = Vector(PIVOT['Colossus_Eye'])
    pocket = sphere(.66, STONE, loc = eye + Vector((0, .05, 0)), u = 16, v = 10,
            scale = (1.25, 1, .95))
    bm = boolean_diff(bm, pocket, STONE,
            lambda c: (c - eye).length < .9 and c.y > eye.y - .4)
    part.add(bm)

    #heavy V brow overhanging the eye
    for side in (-1, 1):
        part.add(box((1.55, .75, .42), BRONZE,
                loc = (side * .72, -1.82, 15.42),
                rot = (math.radians(-12), side * math.radians(16), 0),
                bevel = .1, seg = 2))
    part.add(shard((0, -2.05, 15.35), (0, -.3, -1), .45, .22, BRONZE, rng,
            sides = 4, bend = 0))
    #crest fin from brow over the crown to the nape
    rings = []
    for b in np.linspace(-math.radians(55), math.radians(160), 16):
        az = -math.pi / 2 if b < 0 else math.pi / 2
        base = helm_point(az, abs(b) + .001)
        n = (base - HC).normalized()
        h = .2 + .75 * math.sin(min(1, max(0, (b + .95) / 3.1)) * math.pi)
        w = .16
        top = base + n * h
        rings.append([base + Vector((-w, 0, 0)) - n * .1,
                top + Vector((-w * .3, 0, 0)), top + Vector((w * .3, 0, 0)),
                base + Vector((w, 0, 0)) - n * .1])
    rings.sort(key = lambda r: r[0].y)
    part.add(finish(loft(rings), BRONZE))

    #cheek guards flaring down
    for side in (-1, 1):
        az0 = -math.pi / 2 + side * .35
        az1 = -math.pi / 2 + side * 1.35
        def fh(az, pol):
            return helm_point(az, pol)
        part.add(shell(fh, min(az0, az1), max(az0, az1), math.radians(108),
                math.radians(165), 6, 5, .06, .14, BRONZE,
                lambda p: HC + Vector((0, 0, p.z - HC.z)),
                jag = lambda u: rng.uniform(0, .1)))
    #mandible tusks curving down off the cheek guards
    for side in (-1, 1):
        base = helm_point(-math.pi / 2 + side * .9, math.radians(150))
        part.add(shard(base, (side * .25, -.6, -1), 1.1, .2, BRONZE, rng,
                sides = 4, bend = .25))
    #mouth grille: vertical teeth under the eye
    for i in range(7):
        x = (i - 3) * .27
        y = helm_point(-math.pi / 2, math.radians(130)).y
        part.add(box((.13, .2, .9 - abs(i - 3) * .08), BRONZE,
                loc = (x, y - .12 + abs(x) * .12, 13.95), bevel = .04))
    #crown circlet with snapped spikes
    pol_c = math.radians(38)
    def fc(az, pol):
        return helm_point(az, pol)
    part.add(shell(fc, 0, 2 * math.pi, pol_c - .12, pol_c + .12, 34, 2,
            .02, .16, BRONZE, lambda p: HC + Vector((0, 0, p.z - HC.z)),
            closed_u = True))
    heights = [1.5, .35, 1.0, .25, .8, .3, .9, .4, 1.1]
    for i, h in enumerate(heights):
        az = -math.pi / 2 + (i - 4) * .5
        base = helm_point(az, pol_c)
        out = (base - HC).normalized()
        d = (out * .35 + Vector((0, 0, 1))).normalized()
        part.add(shard(base - out * .05, d, h, .2 if i == 0 else .15,
                BRONZE, rng, sides = 4, bend = .05))
    #horns: left whole, right snapped off
    for side, cut in ((-1, 1.0), (1, .42)):
        P = [Vector((side * 1.2, .0, 15.55)), Vector((side * 3.0, -.1, 15.5)),
                Vector((side * 4.3, -.8, 16.7)), Vector((side * 4.0, -2.0,
                18.7))]
        def bez(t):
            u = 1 - t
            return (P[0] * u ** 3 + P[1] * 3 * u * u * t
                    + P[2] * 3 * u * t * t + P[3] * t ** 3)
        rings = []
        steps = 16
        for i in range(steps + 1):
            t = cut * i / steps
            c = bez(t)
            tan = (bez(min(1, t + .01)) - bez(max(0, t - .01))).normalized()
            s1 = tan.orthogonal().normalized()
            s2 = tan.cross(s1)
            r = .64 * (1 - t) ** .9 + .03
            r *= 1 + .08 * math.sin(i * 2.1)
            rings.append([c + (s1 * math.cos(a) + s2 * math.sin(a)) * r
                    for a in (2 * math.pi * k / 9 for k in range(9))])
        if cut < 1:
            tip = bez(cut) + Vector((0, 0, .05))
            #jagged break
            for k, v in enumerate(rings[-1]):
                v += (bez(cut) - bez(cut - .02)).normalized() * \
                        rng.uniform(-.15, .2)
            bm = loft(rings, cap0 = True, cap1 = True)
        else:
            bm = loft(rings, cap0 = True, cap1 = False, tip = P[3])
        bm = finish(bm, STONE)
        displace(bm, .04, 3, seed = 5 + side)
        part.add(bm)
        #bronze ring at the horn root
        c = bez(.1)
        tan = (bez(.12) - bez(.08)).normalized()
        q = Vector((0, 0, 1)).rotation_difference(tan)
        tb = torus(.62, .13, BRONZE, seg = 12, sides = 6)
        tb.transform(Matrix.Translation(c) @ q.to_matrix().to_4x4())
        part.add(finish(tb, BRONZE))
        if cut < 1:
            #ember glowing in the broken stump
            part.add(ico(.2, EMBER, loc = bez(cut), sub = 1))
    return part


def build_eye(rng):
    part = Part()
    eye = Vector(PIVOT['Colossus_Eye'])
    part.add(sphere(.45, EYE, loc = eye, u = 18, v = 12))
    #slit pupil
    part.add(box((.09, .06, .62), STONE, loc = eye + Vector((0, -.42, 0)),
            bevel = .02))
    return part


#---------------------------------------------------------------- arms (L)

AX = -5.5


def arm_loft(z0, z1, radius, n = 20, step = .4, center = (AX, 0)):
    zs = list(np.arange(z0, z1 - 1e-6, -step)) + [z1]
    rings = []
    for z in zs:
        r = radius(z)
        rings.append([Vector((center[0] + math.cos(a) * r,
                center[1] + math.sin(a) * r * .95, z))
                for a in (2 * math.pi * i / n for i in range(n))])
    return finish(loft(rings), STONE)


def arm_axis(p):
    return Vector((AX, 0, p.z))


def build_upper_arm(rng):
    part = Part()
    bm = sphere(1.6, STONE, loc = (AX, 0, 12), u = 18, v = 10)
    displace(bm, .12, .8, seed = 11)
    part.add(bm)

    def radius(z):
        #deltoid, then a narrower arm swelling again at biceps/triceps
        r = 1.15 + .02 * (z - 5)
        r += .45 * math.exp(-((z - 11.4) / 1.3) ** 2)
        r += .22 * math.exp(-((z - 8.4) / 1.1) ** 2)
        return r
    bm = arm_loft(12.6, 4.9, radius, n = 20, step = .35)
    displace(bm, .18, .45, seed = 12)
    crack_slabs(bm, 26, .3, rng, inset = .06, depth = .12)
    part.add(bm)

    #pauldron: a low faceted dome tilted outward and down, a fin on top
    PC = Vector((AX - .4, 0, 12.2))
    tilt = Matrix.Rotation(math.radians(24), 4, 'Y')
    def fd(az, pol):
        p = Vector((math.cos(az) * math.sin(pol) * 2.05,
                math.sin(az) * math.sin(pol) * 1.95,
                math.cos(pol) * 1.15))
        #front and back come to a ridge-line, not a mushroom
        p.y *= 1 - .18 * math.cos(pol)
        return PC + tilt @ p
    part.add(shell(fd, 0, 2 * math.pi, .05, math.radians(96), 14, 6, 0,
            .22, BRONZE, lambda p: PC, closed_u = True,
            jag = lambda u: rng.uniform(-.2, .15)))
    #second plate cascading over the outer edge
    def fd2(az, pol):
        return PC + tilt @ Vector((math.cos(az) * math.sin(pol) * 2.3 - .2,
                math.sin(az) * math.sin(pol) * 2.0,
                math.cos(pol) * 1.0 - .55))
    part.add(shell(fd2, math.radians(110), math.radians(250),
            math.radians(55), math.radians(100), 8, 4, 0, .18, BRONZE,
            lambda p: PC + Vector((0, 0, -.5)),
            jag = lambda u: rng.uniform(-.25, .1)))
    #fin over the top
    rings = []
    for t in np.linspace(-1, 1, 9):
        pol = abs(t) * math.radians(70) + .001
        p = fd(0 if t > 0 else math.pi, pol)
        n = (p - PC).normalized()
        h = .9 * (1 - abs(t) ** 1.3) + .05
        rings.append([p + Vector((0, -.17, 0)), p + n * h + Vector((0, -.04,
                0)), p + n * h + Vector((0, .04, 0)), p + Vector((0, .17,
                0))])
    part.add(finish(loft(rings), BRONZE))
    for dx, dy, h in ((-1.2, .55, 1.8), (-.5, .75, 1.2), (-1.5, -.45, 1.0)):
        base = PC + tilt @ Vector((dx, dy, 1.0 - abs(dx) * .3))
        part.add(shard(base, (-.6, .3, 1), h, .26, BRONZE, rng, sides = 4,
                bend = .12))
    #a rock outcrop splitting the pauldron at the back
    part.add(shard(PC + Vector((-.3, 1.3, .2)), (-.3, 1, .8), 1.8, .5, STONE,
            rng, sides = 6))
    for k in range(2):
        ztop = 10.85 - k * .8
        r = 1.95 - k * .15
        def fl(az, z, r = r, ztop = ztop, k = k):
            rr = r + (ztop - z) * .25
            dz = .25 * math.cos(az) * (1 if k else -1)
            return Vector((PC.x + .25 + math.cos(az) * rr,
                    math.sin(az) * rr * .95, z + dz))
        part.add(shell(fl, math.radians(100), math.radians(260), ztop,
                ztop - 1.0, 10, 2, 0, .13, BRONZE,
                lambda p: Vector((AX, 0, p.z)),
                jag = lambda u: -rng.uniform(0, .35)))
    return part


def build_forearm(rng):
    part = Part()
    bm = sphere(1.25, STONE, loc = (AX, 0, 5.5), u = 16, v = 10)
    displace(bm, .1, .9, seed = 21)
    part.add(bm)

    def radius(z):
        r = .88 + .025 * (z + .9)
        r += .38 * math.exp(-((z - 4.4) / 1.2) ** 2)
        return r
    bm = arm_loft(6.0, -.95, radius, n = 18, step = .35)
    displace(bm, .14, .5, seed = 22)
    crack_slabs(bm, 20, .35, rng, inset = .06, depth = .1,
            only = lambda f: f.calc_center_median().z > 2.7)
    part.add(bm)

    #couter: bronze cup on the back of the elbow with a spike
    CC = Vector((AX, .5, 5.5))
    def fc(az, pol):
        return CC + Vector((math.cos(az) * math.sin(pol) * 1.05,
                math.cos(pol) * 1.0,
                math.sin(az) * math.sin(pol) * 1.1))
    part.add(shell(fc, 0, 2 * math.pi, .05, math.radians(80), 16, 5, 0, .16,
            BRONZE, lambda p: CC, closed_u = True))
    part.add(shard(CC + Vector((0, .9, .1)), (0, 1, .25), 1.3, .3, BRONZE,
            rng, sides = 4, bend = 0))

    #bracer over the lower forearm, ragged top edge
    def fb(az, z):
        r = radius(z) + .1
        return Vector((AX + math.cos(az) * r, math.sin(az) * r * .95, z))
    part.add(shell(fb, 0, 2 * math.pi, .35, 2.9, 20, 4, 0, .14, BRONZE,
            arm_axis, closed_u = True,
            jag = lambda u: rng.uniform(-.45, .1)))
    for z in (.62, 2.0):
        r = radius(z) + .25
        part.add(torus(r, .1, BRONZE, loc = (AX, 0, z), seg = 18, sides = 5,
                scale = (1, .95, 1)))
    #studs down the outside of the bracer
    for z in (1.0, 1.35, 1.7):
        part.add(box((.2, .2, .2), BRONZE, loc = (AX - radius(z) - .26, 0, z),
                rot = (0, math.pi / 4, 0), bevel = .04))

    #manacle: iron cuff at the wrist, broken chain hanging off the outside
    def fm(az, z):
        return Vector((AX + math.cos(az) * 1.08, math.sin(az) * 1.04, z))
    part.add(shell(fm, 0, 2 * math.pi, -.3, .45, 20, 2, 0, .28, IRON,
            arm_axis, closed_u = True))
    for z in (-.25, .4):
        part.add(torus(1.38, .07, IRON, loc = (AX, 0, z), seg = 20, sides = 4,
                scale = (1, .97, 1)))
    #snapped hinge on the inside, lock lug + loop outside
    part.add(box((.35, .5, .6), IRON, loc = (AX + 1.38, 0, .08), bevel = .05))
    part.add(shard((AX + 1.45, 0, .5), (.3, 0, 1), .45, .12, IRON, rng,
            sides = 4, bend = 0))
    part.add(box((.5, .7, .9), IRON, loc = (AX - 1.45, 0, .08), bevel = .07))
    part.add(torus(.26, .09, IRON, loc = (AX - 1.75, 0, -.25),
            rot = (math.pi / 2, 0, 0), seg = 10, sides = 6))
    z = -.8
    for i in range(4):
        rot = (math.pi / 2, 0, 0) if i % 2 else (math.pi / 2, 0, math.pi / 2)
        arc = 2 * math.pi if i < 3 else math.radians(250)
        bm = torus(.27, .09, IRON, rot = rot, seg = 10, sides = 6, arc = arc)
        bm.transform(Matrix.Translation((AX - 1.75 - i * .04, 0, z))
                @ Matrix.Diagonal((1, 1, 1.5, 1)))
        part.add(finish(bm, IRON))
        z -= .62
    return part


def build_hand(rng):
    part = Part()
    W = Vector((AX, 0, -.5))
    def at(x, y, z):
        return W + Vector((x, y, z))
    #wrist ball
    bm = sphere(.95, STONE, loc = W, u = 14, v = 8)
    displace(bm, .06, 1.2, seed = 31)
    part.add(bm)
    #back of the hand: cracked open, ember underneath
    bm = box((2.0, 1.55, 1.8), STONE, loc = at(0, 0, -1.1), bevel = .25,
            seg = 1)
    bmesh.ops.subdivide_edges(bm, edges = bm.edges[:], cuts = 2,
            use_grid_fill = True)
    finish(bm, STONE)
    for v in bm.verts:
        if v.co.y > W.y:
            v.co.y += .15 * (1 - ((v.co.x - AX) / 1.1) ** 2)
    displace(bm, .06, 1.5, seed = 32)
    crack_slabs(bm, 9, .85, rng, inset = .06, depth = .14, jitter = .06,
            only = lambda f: f.normal.y > .4)
    part.add(bm)
    #fingers: index on the outside (-X) for a palm-forward left hand
    for i, x in enumerate((-.74, -.25, .25, .73)):
        s = (.96, 1.0, .97, .86)[i]
        dz = (.05, 0, .03, .14)[i]
        part.add(box((.47 * s, 1.05 * s, .88 * s), STONE,
                loc = at(x, .22, -2.2 + dz), bevel = .16, seg = 2))
        part.add(box((.45 * s, .62 * s, .78 * s), STONE,
                loc = at(x, -.5, -2.28 + dz), bevel = .13, seg = 1))
        part.add(box((.43 * s, .42 * s, .52 * s), STONE,
                loc = at(x, -.66, -1.7 + dz), bevel = .1, seg = 1))
        #knuckle crystal
        part.add(shard(at(x, .6, -2.5 + dz), (rng.uniform(-.25, .25), .9,
                -.35), rng.uniform(.55, .85), .16, EMBER, rng, sides = 5,
                bend = .05))
    #thumb wrapping across the fingers
    part.add(seg_box(at(-1.0, -.25, -.7), at(-.95, -.7, -1.45), .5, .45,
            STONE, bevel = .12))
    part.add(seg_box(at(-.98, -.85, -1.5), at(-.05, -1.0, -1.85), .42, .4,
            STONE, bevel = .1))
    #crystals breaking out of the back of the hand
    for x, z, d, l in ((-.45, -.8, (-.3, 1, .4), .9), (.35, -1.3,
            (.2, 1, -.2), .7), (.6, -.55, (.4, 1, .3), .5)):
        part.add(shard(at(x, .85, z), d, l, .2, EMBER, rng, sides = 5,
                bend = .08))
    #bronze cuff at the wrist
    def fw(az, z):
        return Vector((AX + math.cos(az) * 1.0, math.sin(az) * .96, z))
    part.add(shell(fw, 0, 2 * math.pi, .1, -.5, 18, 2, 0, .12, BRONZE,
            lambda p: Vector((AX, 0, p.z)), closed_u = True))
    return part


#---------------------------------------------------------------- assembly

def mirror(part):
    bm = part.bm.copy()
    bm.transform(Matrix.Diagonal((-1, 1, 1, 1)))
    bmesh.ops.reverse_faces(bm, faces = bm.faces[:])
    p = Part()
    p.bm = bm
    return p


def box_uv(bm, tile):
    uv = bm.loops.layers.uv.verify()
    for f in bm.faces:
        n = f.normal
        ax = max(range(3), key = lambda i: abs(n[i]))
        a, b = [(1, 2), (0, 2), (0, 1)][ax]
        flip = -1 if n[ax] < 0 else 1
        for loop in f.loops:
            co = loop.vert.co
            loop[uv].uv = (co[a] / tile * flip, co[b] / tile)


def make_object(name, part, mats):
    bm = part.bm
    bmesh.ops.remove_doubles(bm, verts = bm.verts[:], dist = 1e-5)
    bmesh.ops.triangulate(bm, faces = bm.faces[:])
    bm.normal_update()
    box_uv(bm, 3.0)
    pivot = Vector(PIVOT[name])
    bm.transform(Matrix.Translation(-pivot))
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    used = sorted({p.material_index for p in me.polygons})
    remap = {m: i for i, m in enumerate(used)}
    for p in me.polygons:
        p.material_index = remap[p.material_index]
    for m in used:
        me.materials.append(mats[m])
    me.set_sharp_from_angle(angle = math.radians(38))
    obj = bpy.data.objects.new(name, me)
    bpy.context.collection.objects.link(obj)
    obj.location = pivot
    return obj


def build(mats):
    rng = random.Random(7)
    parts = {
        'Colossus_Torso': build_torso(rng),
        'Colossus_Core': build_core(rng),
        'Colossus_ShutterL': build_shutter(-1, rng),
        'Colossus_ShutterR': build_shutter(1, rng),
        'Colossus_Head': build_head(rng),
        'Colossus_Eye': build_eye(rng),
    }
    up, fore, hand = build_upper_arm(rng), build_forearm(rng), build_hand(rng)
    parts['Colossus_UpperArm_R'] = mirror(up)
    parts['Colossus_Forearm_R'] = mirror(fore)
    parts['Colossus_Hand_R'] = mirror(hand)
    parts['Colossus_UpperArm_L'] = up
    parts['Colossus_Forearm_L'] = fore
    parts['Colossus_Hand_L'] = hand
    objs = {name: make_object(name, parts[name], mats) for name in PIVOT}
    for name, parent in PARENT.items():
        o = objs[name]
        o.parent = objs[parent]
        o.matrix_parent_inverse = Matrix.Identity(4)
        o.location = Vector(PIVOT[name]) - Vector(PIVOT[parent])
    return objs


#---------------------------------------------------------------- previews

def look_at(obj, target):
    d = Vector(target) - obj.location
    obj.rotation_euler = d.to_track_quat('-Z', 'Y').to_euler()


def setup_scene():
    scene = bpy.context.scene
    scene.render.engine = 'BLENDER_EEVEE'
    scene.render.resolution_x = 1200
    scene.render.resolution_y = 1200
    scene.render.film_transparent = False
    scene.eevee.taa_render_samples = 64
    try:
        scene.eevee.use_raytracing = True
    except Exception:
        pass
    scene.view_settings.view_transform = 'AgX'
    scene.view_settings.exposure = .4
    try:
        scene.view_settings.look = 'AgX - Punchy'
    except Exception:
        pass
    world = bpy.data.worlds.new('Night')
    scene.world = world
    world.use_nodes = True
    nt = world.node_tree
    bg = next(n for n in nt.nodes if n.type == 'BACKGROUND')
    grad = nt.nodes.new('ShaderNodeTexGradient')
    coord = nt.nodes.new('ShaderNodeTexCoord')
    mapn = nt.nodes.new('ShaderNodeMapping')
    mapn.inputs['Rotation'].default_value = (0, math.radians(-90), 0)
    ramp = nt.nodes.new('ShaderNodeValToRGB')
    ramp.color_ramp.elements[0].color = (.004, .005, .009, 1)
    ramp.color_ramp.elements[1].color = (.045, .06, .095, 1)
    nt.links.new(coord.outputs['Generated'], mapn.inputs['Vector'])
    nt.links.new(mapn.outputs['Vector'], grad.inputs['Vector'])
    nt.links.new(grad.outputs['Fac'], ramp.inputs['Fac'])
    nt.links.new(ramp.outputs['Color'], bg.inputs['Color'])
    bg.inputs['Strength'].default_value = 1.0

    def light(name, kind, loc, energy, color, size = 1, target = (0, 0, 8)):
        data = bpy.data.lights.new(name, kind)
        data.energy = energy
        data.color = color
        if kind == 'SUN':
            data.angle = math.radians(2)
        elif kind == 'AREA':
            data.size = size
        else:
            data.shadow_soft_size = size
        o = bpy.data.objects.new(name, data)
        scene.collection.objects.link(o)
        o.location = loc
        look_at(o, target)
        return o
    light('Moon', 'SUN', (-30, 45, 40), 6.0, (.62, .72, 1.0))
    light('Rim', 'SUN', (40, 35, 15), 4.0, (.55, .65, 1.0))
    light('Key', 'SUN', (-20, -40, 35), 1.8, (.5, .6, .85))
    light('CoreGlow', 'POINT', (0, -4.5, 9.0), 3000, (1, .45, .12), size = 1)
    for x in (-5.5, 5.5):
        light('FistGlow', 'POINT', (x, 1.6, -2.0), 900, (1, .45, .12))
    light('EyeGlow', 'POINT', (0, -2.6, 14.7), 500, (1, .9, .7))

    #bloom through the compositor
    try:
        tree = bpy.data.node_groups.new('Bloom', 'CompositorNodeTree')
        scene.compositing_node_group = tree
        tree.interface.new_socket('Image', in_out = 'OUTPUT',
                socket_type = 'NodeSocketColor')
        rl = tree.nodes.new('CompositorNodeRLayers')
        glare = tree.nodes.new('CompositorNodeGlare')
        out = tree.nodes.new('NodeGroupOutput')
        glare.inputs['Type'].default_value = 'Bloom'
        glare.inputs['Threshold'].default_value = 1.0
        glare.inputs['Strength'].default_value = .6
        glare.inputs['Size'].default_value = .6
        tree.links.new(rl.outputs['Image'], glare.inputs['Image'])
        tree.links.new(glare.outputs['Image'], out.inputs[0])
    except Exception as e:
        print('bloom setup failed:', e)

    cam_data = bpy.data.cameras.new('Cam')
    cam = bpy.data.objects.new('Cam', cam_data)
    scene.collection.objects.link(cam)
    scene.camera = cam
    return cam


def render(cam, name, loc, target, lens):
    cam.location = loc
    cam.data.lens = lens
    look_at(cam, target)
    bpy.context.scene.render.filepath = str(PREVIEW / (name + '.png'))
    bpy.ops.render.render(write_still = True)
    print('rendered', name)


def previews(objs):
    PREVIEW.mkdir(parents = True, exist_ok = True)
    cam = setup_scene()
    render(cam, 'front', (0, -62, 7.5), (0, 0, 7.4), 75)
    render(cam, 'three_quarter', (30, -42, 2), (0, 0, 7.8), 65)
    render(cam, 'back_of_hand', (-6.8, 7.5, -3.2), (-5.5, 0.6, -1.7), 45)
    render(cam, 'back', (-18, 40, 12), (0, 0, 8), 60)
    #pose: right fist overhead, left arm reaching forward
    pose = {
        'Colossus_UpperArm_R': (math.radians(-170), 0, math.radians(-10)),
        'Colossus_Forearm_R': (math.radians(-35), 0, 0),
        'Colossus_Hand_R': (math.radians(-20), 0, 0),
        'Colossus_UpperArm_L': (math.radians(-80), 0, math.radians(-15)),
        'Colossus_Forearm_L': (math.radians(-25), 0, 0),
        'Colossus_Hand_L': (math.radians(-60), 0, 0),
        'Colossus_Head': (math.radians(10), 0, math.radians(20)),
        'Colossus_ShutterL': (0, 0, SHUTTER_OPEN),
        'Colossus_ShutterR': (0, 0, -SHUTTER_OPEN),
    }
    for name, rot in pose.items():
        objs[name].rotation_euler = rot
    bpy.context.view_layer.update()
    render(cam, 'posed', (30, -42, 6), (0, -2, 11), 50)
    render(cam, 'posed_side', (48, -6, 9), (0, -2, 10), 50)
    for o in objs.values():
        o.rotation_euler = (0, 0, 0)
    bpy.context.view_layer.update()
    for o in list(bpy.context.scene.objects):
        if o.name not in objs:
            bpy.data.objects.remove(o)


#---------------------------------------------------------------- export

def export(objs):
    OUT.mkdir(parents = True, exist_ok = True)
    for o in bpy.context.scene.objects:
        o.select_set(o.name in objs)
    bpy.ops.export_scene.gltf(filepath = str(OUT / 'colossus.glb'),
            export_format = 'GLB', use_selection = True, export_yup = True,
            export_apply = True, export_texcoords = True,
            export_normals = True, export_materials = 'EXPORT')
    bpy.context.preferences.filepaths.save_version = 0
    bpy.ops.wm.save_as_mainfile(filepath = str(OUT / 'colossus.blend'))


def verify():
    bpy.ops.wm.read_factory_settings(use_empty = True)
    bpy.ops.import_scene.gltf(filepath = str(OUT / 'colossus.glb'))
    total = 0
    print('\n=== colossus.glb re-import ===')
    for o in sorted(bpy.context.scene.objects, key = lambda o: o.name):
        tris = 0
        mats = []
        if o.type == 'MESH':
            tris = sum(len(p.vertices) - 2 for p in o.data.polygons)
            mats = [m.name for m in o.data.materials]
        total += tris
        w = o.matrix_world.translation
        r = o.matrix_world.to_euler()
        print('%-22s parent=%-22s origin=(%6.2f, %6.2f, %6.2f) rot=(%.2f,%.2f,'
                '%.2f) tris=%6d %s' % (o.name, o.parent.name if o.parent
                else '-', w.x, w.y, w.z, r.x, r.y, r.z, tris, mats))
        if o.name in PIVOT:
            err = (w - Vector(PIVOT[o.name])).length
            assert err < 1e-3, (o.name, err)
            assert o.parent is None and o.name == 'Colossus_Torso' or \
                    o.parent.name == PARENT.get(o.name), o.name
    missing = set(PIVOT) - {o.name for o in bpy.context.scene.objects}
    print('total triangles', total, 'missing', sorted(missing))
    assert not missing and total <= 60000


def main():
    bpy.ops.wm.read_factory_settings(use_empty = True)
    OUT.mkdir(parents = True, exist_ok = True)
    mats = materials()
    objs = build(mats)
    if RENDER:
        previews(objs)
    export(objs)
    verify()


main()
