#Ssethrak, the Chained Lizard-King: rigid-part saurian giant, waist up,
#no armature.  Same contract as tools/build_colossus.py (same object names).
#blender -b --factory-startup -P tools/build_lizard.py
#Writes assets/characters/lizard/{lizard.glb,lizard.blend,*.png}
#and preview renders to $LIZARD_PREVIEW (default: the scratchpad below).
#Pass -- --no-render to skip the previews.
#
#Every part is its own mesh object with its origin on the joint pivot and
#identity rotation/scale, so the game can swing them procedurally.
#Faces Blender -Y, Z up, metres.  _L is -X, _R is +X.
#Jaw: +X rotation opens it (tip down) in Blender and in Godot alike.
#Tail: hangs along -Z (Godot local -Y), base pivot behind the waist.
#
#Glow is venom: a sickly yellow-green, not ember.  The party's fire is the
#game's light-and-fear language (torches, fire arrows, the AI's fire
#reveal); an orange boss would read as "more fire" in the mist.  Green-gold
#reads as poison, matches the acid spit, and sits opposite the blue
#moonlight so the weak points pop at night.
import bpy
import bmesh
import math
import os
import random
import sys
from pathlib import Path
from mathutils import Vector, Matrix, Euler, noise
from mathutils.kdtree import KDTree
import numpy as np


ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'assets/characters/lizard'
PREVIEW = Path(os.environ.get('LIZARD_PREVIEW',
        '/tmp/claude-1000/-home-talves-mthings-LandsOfBalance/'
        '07261c89-1cc2-4cd7-9029-7c1b17b3a6a2/scratchpad/lizard'))
RENDER = '--no-render' not in sys.argv
TRI_BUDGET = 70000

STONE, BONE, EMBER, EYE, IRON, BELLY, TEETH, OBSID, EYEBALL, MOUTH = range(10)
MAT_NAMES = ['Colossus_Stone', 'Colossus_Bronze', 'Colossus_Ember',
        'Colossus_Eye', 'Colossus_Iron', 'Lizard_Belly', 'Lizard_Teeth',
        'Lizard_Obsidian', 'Lizard_EyeBall', 'Lizard_Mouth']
SMOOTH = {STONE: True, BONE: True, EMBER: False, EYE: False, IRON: True,
        BELLY: True, TEETH: True, OBSID: False, EYEBALL: True, MOUTH: True}
VENOM = (.62, 1.0, .12)
GEM = (.86, 1.0, .5)

#the head, jaw and third eye are modelled at these and then scaled up
#about the neck pivot by HEAD_SCALE; PIVOT holds the scaled positions
HEAD_PIVOT = Vector((0, -.3, 13.2))
HEAD_SCALE = 1.15
EYE0 = Vector((0, -1.55, 14.8))
JAW0 = Vector((0, -.55, 13.5))
#skull, jaw and eye sit this far forward/up of the neck that carries them,
#so the open jaw clears the chest
HEAD_OFF = Vector((0, -.75, .35))


def head_scaled(p):
    return tuple(HEAD_PIVOT + (Vector(p) + HEAD_OFF - HEAD_PIVOT)
            * HEAD_SCALE)


PIVOT = {
    'Colossus_Torso': (0, 0, 0),
    'Colossus_Core': (0, -2.3, 9.5),
    'Colossus_ShutterL': (-1.1, -2.5, 9.5),
    'Colossus_ShutterR': (1.1, -2.5, 9.5),
    'Colossus_Head': (0, -.3, 13.2),
    'Colossus_Eye': head_scaled(EYE0),
    'Colossus_Jaw': head_scaled(JAW0),
    'Colossus_UpperArm_L': (-5.5, 0, 12),
    'Colossus_Forearm_L': (-5.5, 0, 5.5),
    'Colossus_Hand_L': (-5.5, 0, -.5),
    'Colossus_UpperArm_R': (5.5, 0, 12),
    'Colossus_Forearm_R': (5.5, 0, 5.5),
    'Colossus_Hand_R': (5.5, 0, -.5),
    'Colossus_Tail': (0, 2.0, .5),
}
PARENT = {
    'Colossus_Core': 'Colossus_Torso',
    'Colossus_ShutterL': 'Colossus_Torso',
    'Colossus_ShutterR': 'Colossus_Torso',
    'Colossus_Head': 'Colossus_Torso',
    'Colossus_Eye': 'Colossus_Head',
    'Colossus_Jaw': 'Colossus_Head',
    'Colossus_UpperArm_L': 'Colossus_Torso',
    'Colossus_Forearm_L': 'Colossus_UpperArm_L',
    'Colossus_Hand_L': 'Colossus_Forearm_L',
    'Colossus_UpperArm_R': 'Colossus_Torso',
    'Colossus_Forearm_R': 'Colossus_UpperArm_R',
    'Colossus_Hand_R': 'Colossus_Forearm_R',
    'Colossus_Tail': 'Colossus_Torso',
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


def save_image(name, rgb, data = False):
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
    if data:
        img.colorspace_settings.name = 'Non-Color'
    return img


def normal_map(h, strength):
    #tangent-space (OpenGL, +Y = +v) normals from a periodic height field;
    #pixel rows run bottom-up, so axis 0 is v
    dx = (np.roll(h, -1, 1) - np.roll(h, 1, 1)) * .5 * strength
    dy = (np.roll(h, -1, 0) - np.roll(h, 1, 0)) * .5 * strength
    nz = np.ones_like(h)
    ln = np.sqrt(dx * dx + dy * dy + 1)
    return np.stack([-dx / ln * .5 + .5, -dy / ln * .5 + .5, nz / ln * .5
            + .5], -1)


def scale_cells(n, cells, seed):
    #overlapping reptile scales: Voronoi on a staggered, jittered grid with a
    #metric stretched downward so each scale hangs over the one below it
    rng = np.random.default_rng(seed)
    R = C = cells
    jit = rng.uniform(-.2, .2, (R, C, 2))
    tint = rng.uniform(0, 1, R * C)
    ys, xs = np.mgrid[0:n, 0:n].astype(np.float64)
    gy = (ys + .5) / n * R
    gx = (xs + .5) / n * C
    r0 = np.floor(gy).astype(int)
    b1 = np.full((n, n), 9.0)
    b2 = np.full((n, n), 9.0)
    bid = np.zeros((n, n), int)
    bdy = np.zeros((n, n))
    for dr in (-1, 0, 1):
        r = r0 + dr
        off = .5 * (r % 2)
        cb = np.floor(gx - off).astype(int)
        for dc in (-1, 0, 1):
            c = cb + dc
            jr, jc = r % R, c % C
            dx = gx - (c + off + .5 + jit[jr, jc, 0])
            dy = gy - (r + .5 + jit[jr, jc, 1])
            dyw = np.where(dy < 0, dy * .72, dy * 1.4)
            d = np.sqrt(dx * dx + dyw * dyw)
            m = d < b1
            b2 = np.where(m, b1, np.minimum(b2, d))
            b1 = np.where(m, d, b1)
            bid = np.where(m, jr * C + jc, bid)
            bdy = np.where(m, dy, bdy)
    edge = np.clip((b2 - b1) / .32, 0, 1)
    #scales rise toward their free lower edge
    lift = .5 + .5 * np.clip(.3 - bdy, 0, 1)
    h = np.sqrt(edge) * lift
    return h, tint[bid], edge


def make_textures():
    n = 1024
    big = tile_noise(n, 1, 1.7)
    mid = tile_noise(n, 2, 1.2)
    fine = tile_noise(n, 3, .6)
    #hide: green-black scales, olive crowns, near-black crevices, mottled
    h, tint, edge = scale_cells(n, 10, 11)
    h2, tint2, _ = scale_cells(n, 26, 12)
    crown = np.array([.12, .15, .075])
    crev = np.array([.018, .022, .016])
    t = (h * (.55 + .45 * h2))[..., None]
    rgb = crev + (crown - crev) * t * (.65 + .7 * tint[..., None])
    olive = (tint > .88)[..., None] * smooth(.3, .9, h)[..., None]
    rgb = rgb * (1 - olive * .6) + np.array([.22, .2, .08]) * olive * .6
    mott = smooth(.35, .75, big)[..., None]
    rgb *= .55 + .65 * mott
    rgb += (fine - .5)[..., None] * .015
    hide_alb = save_image('lizard_hide_albedo', np.clip(rgb, 0, 1))
    hide_nrm = save_image('lizard_hide_normal',
            normal_map(h * .8 + h2 * .25 + fine * .15, 22), data = True)
    #belly: ochre transverse scutes in a grid, grime in the grooves
    R, C = 5, 1
    ys, xs = np.mgrid[0:n, 0:n].astype(np.float64)
    gy = (ys + .5) / n * R + .35 * (big - .5)
    gx = (xs + .5) / n * C + .5 * (np.floor(gy) % 2) + .5 * (mid - .5)
    fx = gx % 1
    fy = gy % 1
    rows = np.floor(gy).astype(int) % R
    cols = np.floor(gx).astype(int) % C
    ptint = np.random.default_rng(5).uniform(0, 1, (R, C))[rows, cols]
    pil = (np.clip(np.minimum(fx, 1 - fx) / .1, 0, 1)
            * np.clip(np.minimum(fy, 1 - fy) / .16, 0, 1))
    pil = np.sqrt(pil) * (.6 + .4 * (1 - fy))
    ochre = np.array([.4, .29, .11]) * (.7 + .45 * ptint[..., None])
    groove = np.array([.09, .06, .025])
    rgb = groove + (ochre - groove) * pil[..., None]
    rgb *= (.7 + .45 * mid)[..., None]
    dirt = smooth(.55, .8, big)[..., None]
    rgb = rgb * (1 - dirt * .5) + np.array([.06, .07, .04]) * dirt * .5
    belly_alb = save_image('lizard_belly_albedo', np.clip(rgb, 0, 1))
    belly_nrm = save_image('lizard_belly_normal',
            normal_map(pil + fine * .2, 18), data = True)
    #bone: old ivory, soot in the lows, hairline cracks
    m2 = tile_noise(n, 7, 1.0)
    crack = 1 - smooth(0, .01, np.abs(m2 - .5))
    grime = smooth(.5, .78, .6 * tile_noise(n, 8, 1.3) + .4 * fine)
    ivory = np.array([.6, .54, .42]) * (.78 + .32 * big)[..., None]
    rgb = ivory * (1 - grime[..., None] * .75) + np.array([.12, .1, .07]) \
            * grime[..., None] * .75
    rgb *= (1 - crack * .7)[..., None]
    bone_alb = save_image('lizard_bone_albedo', np.clip(rgb, 0, 1))
    bone_nrm = save_image('lizard_bone_normal',
            normal_map(mid * .6 + fine * .3 - crack * .4, 10), data = True)
    return {STONE: (hide_alb, hide_nrm), BELLY: (belly_alb, belly_nrm),
            BONE: (bone_alb, bone_nrm)}


def materials():
    tex = make_textures()
    mats = []
    for name in MAT_NAMES:
        mat = bpy.data.materials.new(name)
        mat.use_nodes = True
        mats.append(mat)

    def bsdf_of(i):
        return next(n for n in mats[i].node_tree.nodes
                if n.type == 'BSDF_PRINCIPLED')

    def textured(i, rough, metal, nstrength):
        nt = mats[i].node_tree
        bsdf = bsdf_of(i)
        alb, nrm = tex[i]
        t = nt.nodes.new('ShaderNodeTexImage')
        t.image = alb
        nt.links.new(t.outputs['Color'], bsdf.inputs['Base Color'])
        tn = nt.nodes.new('ShaderNodeTexImage')
        tn.image = nrm
        nm = nt.nodes.new('ShaderNodeNormalMap')
        nm.inputs['Strength'].default_value = nstrength
        nt.links.new(tn.outputs['Color'], nm.inputs['Color'])
        nt.links.new(nm.outputs['Normal'], bsdf.inputs['Normal'])
        bsdf.inputs['Roughness'].default_value = rough
        bsdf.inputs['Metallic'].default_value = metal
    textured(STONE, .75, 0, 1.0)
    textured(BELLY, .7, 0, 1.0)
    textured(BONE, .4, .2, .8)

    for idx, color, strength in ((EMBER, VENOM, 3), (EYE, GEM, 5)):
        bsdf = bsdf_of(idx)
        bsdf.inputs['Base Color'].default_value = (*color, 1)
        bsdf.inputs['Emission Color'].default_value = (*color, 1)
        bsdf.inputs['Emission Strength'].default_value = strength
        bsdf.inputs['Roughness'].default_value = .4
    for idx, color, metal, rough in (
            (IRON, (.07, .06, .055), .85, .7),
            (TEETH, (.72, .64, .48), 0, .35),
            (OBSID, (.018, .018, .024), 0, .12),
            (EYEBALL, (.62, .34, .04), 0, .08),
            (MOUTH, (.16, .035, .03), 0, .4)):
        bsdf = bsdf_of(idx)
        bsdf.inputs['Base Color'].default_value = (*color, 1)
        bsdf.inputs['Metallic'].default_value = metal
        bsdf.inputs['Roughness'].default_value = rough
    return mats


#---------------------------------------------------------------- geometry
#(helpers shared with build_colossus.py)

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


def ico(radius, mat, loc = (0, 0, 0), sub = 1, scale = (1, 1, 1),
        rot = (0, 0, 0)):
    bm = bmesh.new()
    bmesh.ops.create_icosphere(bm, subdivisions = sub, radius = radius)
    bm.transform(mat_trs(loc, rot, scale))
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


def shard(base, direction, length, radius, mat, rng, sides = 5, bend = .15,
        bend_dir = None):
    #a bent, noisy spike: spines, spurs, teeth, crystals
    d = Vector(direction).normalized()
    side = (Vector(bend_dir) - d * d.dot(Vector(bend_dir))).normalized() \
            if bend_dir is not None else d.orthogonal().normalized()
    rings = []
    steps = 4
    for i in range(steps):
        t = i / steps
        c = Vector(base) + d * length * t + side * bend * length * t * t
        r = radius * (1 - t) ** .8
        ring = []
        for k in range(sides):
            a = 2 * math.pi * k / sides + rng.uniform(-.2, .2)
            v = (side * math.cos(a) + d.cross(side) * math.sin(a))
            ring.append(c + v * r * rng.uniform(.82, 1.15))
        rings.append(ring)
    tip = Vector(base) + d * length + side * bend * length
    return finish(loft(rings, cap0 = True, tip = tip), mat)


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
    #split the hide into raised osteoderm plates over a venom underlay; hot
    #plates pull back from their seams so the glow shows, cold ones stay
    #tight and only their uneven lift reads
    faces = [f for f in bm.faces if f.material_index == STONE
            and (only is None or only(f))]
    if not faces:
        return bm
    faces = bmesh.ops.triangulate(bm, faces = faces,
            quad_method = 'ALTERNATE')['faces']
    region = set(faces)
    bm.normal_update()
    for v in dict.fromkeys(v for f in faces for v in f.verts):
        if any(f not in region for f in v.link_faces) or not v.link_edges:
            continue
        el = sum(e.calc_length() for e in v.link_edges) / len(v.link_edges)
        j = Vector((rng.uniform(-1, 1), rng.uniform(-1, 1),
                rng.uniform(-1, 1))) * el * .3
        v.co += j - v.normal * j.dot(v.normal)
    bm.normal_update()
    dup = bmesh.ops.duplicate(bm, geom = faces)['geom']
    under = [g for g in dup if isinstance(g, bmesh.types.BMFace)]
    uverts = [g for g in dup if isinstance(g, bmesh.types.BMVert)]
    bm.normal_update()
    for v in uverts:
        v.co -= v.normal * depth
    for f in under:
        f.material_index = EMBER
        f.smooth = False
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
    #`thick` deep; jag(u) adds extra length/raggedness at the v1 edge
    def point(u, v):
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
    for j in range(nv - 1):
        if not closed_u:
            bm.faces.new((T[j][0], T[j + 1][0], B[j + 1][0], B[j][0]))
            bm.faces.new((T[j][-1], B[j][-1], B[j + 1][-1], T[j + 1][-1]))
    for i in range(nuu):
        k = (i + 1) % nu
        bm.faces.new((T[0][i], B[0][i], B[0][k], T[0][k]))
        bm.faces.new((T[-1][i], T[-1][k], B[-1][k], B[-1][i]))
    return finish(bm, mat)


#---------------------------------------------------------------- organic

def spline(ctrl, steps):
    #Catmull-Rom through the control points
    P = [Vector(c) for c in ctrl]
    P = [P[0] * 2 - P[1]] + P + [P[-1] * 2 - P[-2]]
    pts = []
    for i in range(1, len(P) - 2):
        p0, p1, p2, p3 = P[i - 1], P[i], P[i + 1], P[i + 2]
        for s in range(steps):
            t = s / steps
            pts.append(.5 * ((2 * p1) + (-p0 + p2) * t
                    + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t * t
                    + (-p0 + 3 * p1 - 3 * p2 + p3) * t ** 3))
    pts.append(P[-2].copy())
    return pts


def bezier(P, t):
    u = 1 - t
    return (Vector(P[0]) * u ** 3 + Vector(P[1]) * 3 * u * u * t
            + Vector(P[2]) * 3 * u * t * t + Vector(P[3]) * t ** 3)


def frames(pts, ref = (1, 0, 0)):
    #parallel-transported (tangent, normal, binormal) along a polyline
    out = []
    n = None
    for i, p in enumerate(pts):
        a = pts[max(0, i - 1)]
        b = pts[min(len(pts) - 1, i + 1)]
        t = (b - a).normalized()
        if n is None:
            n = Vector(ref) - t * t.dot(Vector(ref))
            if n.length < 1e-4:
                n = t.orthogonal()
        else:
            n = n - t * n.dot(t)
        n.normalize()
        out.append((t, n, t.cross(n)))
    return out


def tube(pts, radius, mat, sides = 8, ref = (1, 0, 0), squash = 1.0,
        tip = None, cap0 = True, cap1 = True):
    #rings around a path; radius(t) with t in [0, 1]; squash narrows the
    #`ref` direction
    fr = frames(pts, ref)
    rings = []
    for i, (p, (t, n, b)) in enumerate(zip(pts, fr)):
        r = radius(i / (len(pts) - 1))
        rings.append([p + n * math.cos(a) * r * squash + b * math.sin(a) * r
                for a in (2 * math.pi * k / sides for k in range(sides))])
    return finish(loft(rings, cap0 = cap0, cap1 = cap1, tip = tip), mat)


def horn(P, r0, mat, rng, steps = 10, sides = 8, r1 = .02):
    #curved tapering horn along a cubic bezier, slightly ridged
    pts = [bezier(P, i / steps) for i in range(steps + 1)]
    tipp = pts.pop()
    bm = tube(pts, lambda t: (r0 - r1) * (1 - t * steps / (steps + 1)) ** .9
            + r1, mat, sides = sides, tip = tipp, cap1 = False)
    for v in bm.verts:
        v.co += Vector((rng.uniform(-1, 1), rng.uniform(-1, 1),
                rng.uniform(-1, 1))) * r0 * .03
    return finish(bm, mat)


def membrane(bases, tips, frac, sag, thick, mat):
    #webbing between consecutive spines, scalloped between them
    bm = bmesh.new()
    rows = []
    for (b0, t0), (b1, t1) in zip(zip(bases, tips), zip(bases[1:], tips[1:])):
        b0, t0, b1, t1 = map(Vector, (b0, t0, b1, t1))
        u0 = b0.lerp(t0, frac)
        u1 = b1.lerp(t1, frac)
        mb = (b0 + b1) / 2
        mu = (u0 + u1) / 2
        mu = mu.lerp(mb, sag)
        quad = [(b0, u0), (mb, mu), (b1, u1)]
        rows.append(quad)
    for quad in rows:
        vs = [(bm.verts.new(a), bm.verts.new(b)) for a, b in quad]
        for (a0, b0), (a1, b1) in zip(vs, vs[1:]):
            bm.faces.new((a0, a1, b1, b0))
    bmesh.ops.remove_doubles(bm, verts = bm.verts[:], dist = 1e-4)
    bm.normal_update()
    bmesh.ops.solidify(bm, geom = bm.faces[:], thickness = thick)
    return finish(bm, mat)


#---------------------------------------------------------------- torso

TZ = [-1.0, 0, 1.5, 3.5, 6, 8, 9.5, 11, 12, 12.6, 13.1, 13.6]
TW = [2.15, 1.95, 1.75, 1.95, 2.95, 3.85, 4.3, 4.4, 4.3, 3.9, 2.8, 1.6]
TF = [1.65, 1.6, 1.6, 1.8, 2.1, 2.35, 2.45, 2.2, 1.6, 1.3, 1.1, 1.0]
TB = [1.6, 1.55, 1.55, 1.8, 2.3, 2.7, 2.9, 3.0, 2.8, 2.3, 1.8, 1.35]
TP = 2.15


def hunch(z):
    t = min(1, max(0, (z - 8.5) / 5.1))
    return -.3 * t * t * (3 - 2 * t)


def torso_point(t, z):
    w = float(np.interp(z, TZ, TW))
    s = math.sin(t)
    d = float(np.interp(z, TZ, TF if s < 0 else TB))
    c = math.cos(t)
    x = w * math.copysign(abs(c) ** (2 / TP), c)
    y = d * math.copysign(abs(s) ** (2 / TP), s)
    if s < 0:
        #pectoral mass either side of the socket
        y -= .3 * math.exp(-((abs(x) - 2.3) / 1.3) ** 2) \
                * math.exp(-((z - 10.2) / 1.3) ** 2)
    else:
        #a channel down the spine between the back muscles
        y -= .18 * math.exp(-(x / .7) ** 2) * min(1, max(0, (z - 2) / 2))
        #lats flaring under the shoulder blades
        x *= 1 + .05 * math.exp(-((z - 9) / 1.8) ** 2)
    return Vector((x, y + hunch(z), z))


def torso_axis(p):
    return Vector((0, .1 + hunch(p.z), p.z))


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
    zs = list(np.arange(-1.0, 13.61, .38))
    n = 44
    rings = [[torso_point(2 * math.pi * i / n + math.pi / 2, z)
            for i in range(n)] for z in zs]
    body = loft(rings)
    finish(body, STONE)

    def calm(p):
        d = math.hypot(p.x, p.z - SOCKET.z)
        return min(1, max(0, (d - 1.4) / 1.2)) if p.y < 0 else 1
    displace(body, .14, .35, seed = 1, mask = calm)
    displace(body, .04, 1.4, seed = 2)
    #ochre belly down the front
    for f in body.faces:
        c = f.calc_center_median()
        if c.y < -.8 and abs(c.x) < .55 * float(np.interp(c.z, TZ, TW)) \
                and c.z < 8.2:
            f.material_index = BELLY
    #osteoderm plates over back and flanks with venom in some seams
    crack_slabs(body, 80, .2, rng, inset = .11, depth = .18, jitter = .07,
            only = lambda f: f.calc_center_median().z > 1.6
                and (f.calc_center_median().y > -.6
                    or abs(f.calc_center_median().x) > 3.4))
    #the socket: open a hole in the chest, line it with an obsidian cup
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
    finish(cup, OBSID)
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

    #socket frame of bone, then the protruding lower lip
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
    part.add(finish(bm, BONE))
    lip = ring_shape(1.14, 1.75, -3.28, -2.4, math.radians(195),
            math.radians(345), 16)
    for ring in lip:
        for v in ring:
            if v.y < -2.6:
                v.z += .12
    part.add(finish(loft(lip), BONE))
    #fangs on the lip, curling up like a lower jaw round the heart
    for a in (205, 228, 252, 288, 312, 335):
        r = math.radians(a)
        base = Vector((math.cos(r) * 1.42, -3.15, SOCKET.z
                + math.sin(r) * 1.42 + .1))
        part.add(shard(base, (math.cos(r) * .25, -.55, .8), .55, .13, TEETH,
                rng, sides = 5, bend = .15, bend_dir = (0, 1, 0)))

    #pectoral scale-plates: three rows of overlapping scutes per side, the
    #glowing underlay shows in the gaps between them
    for side in (-1, 1):
        def f(u, z):
            return torso_point(u, z)
        ta = t_for_x(side * 1.75, 10.2)
        tb = t_for_x(side * 4.25, 10.2)
        u0, u1 = min(ta, tb), max(ta, tb)
        for k, (zt, zb) in enumerate(((11.3, 10.4), (10.75, 9.35),
                (9.55, 8.05))):
            cols = 3 if k < 2 else 2
            for j in range(cols):
                a = u0 + (u1 - u0) * j / cols - .03
                b = u0 + (u1 - u0) * (j + 1) / cols + .03
                part.add(shell(f, a, b, zt, zb, 5, 4, .22 - .06 * k
                        + .03 * (j % 2), .2,
                        STONE, torso_axis,
                        jag = lambda u: -rng.uniform(0, .22)))
    #ab scutes: overlapping ochre bands, each hanging over the next
    z = 7.85
    k = 0
    while z > 1.7:
        zb = z - .66
        wz = float(np.interp(z, TZ, TW))
        half = min(1.85, .47 * wz)
        ta = t_for_x(-half, z - .3)
        tb = t_for_x(half, z - .3)
        def fa(u, zz):
            return torso_point(u, zz)
        part.add(shell(fa, min(ta, tb), max(ta, tb), z, zb, 8, 3,
                .05 + .02 * (k % 2), .12, BELLY, torso_axis))
        z = zb + .08
        k += 1

    #trapezius masses: the head sits low and forward between them
    for side in (-1, 1):
        c = Vector((side * 2.6, .5 + hunch(12.1), 12.1))
        bm = ico(1.0, STONE, loc = c, sub = 2, scale = (1.8, 1.6, .95))
        bm.transform(Matrix.Translation(c)
                @ Matrix.Rotation(side * math.radians(-22), 4, 'Y')
                @ Matrix.Translation(-c))
        displace(bm, .15, .7, seed = 40 + side)
        part.add(bm)

    #bone mantle over the shoulders and nape: a ragged collar of plates
    #riding low, so the neck and head stand clear of it
    MC = Vector((0, .35, 11.7))
    def fm(az, pol):
        return MC + Vector((math.cos(az) * math.sin(pol) * 4.35,
                math.sin(az) * math.sin(pol) * 2.8,
                math.cos(pol) * 1.75))
    part.add(shell(fm, math.radians(-25), math.radians(205), math.radians(40),
            math.radians(82), 24, 4, .0, .2, BONE, lambda p: MC,
            jag = lambda u: rng.uniform(-.1, .45)))
    #rib-tusks rising off the mantle behind the shoulders
    for x, h, lean in ((-3.0, 2.2, -.7), (-1.7, 2.9, -.35), (1.7, 2.8, .35),
            (3.0, 2.1, .7)):
        b = fm(math.atan2(1.0, x / 4.3), math.radians(55)) + Vector((0, 0, .1))
        P = [b, b + Vector((lean * .4, .6, h * .4)),
                b + Vector((lean * 1.3, 1.8, h * .8)),
                b + Vector((lean * 1.6, 2.9, h))]
        part.add(horn(P, .34, BONE, rng, steps = 8, sides = 7))

    #dorsal spines down the back, longest between the shoulder blades
    zz = 11.4
    while zz > 1.6:
        p = torso_point(math.pi / 2, zz)
        t = (zz - 1.6) / 9.8
        length = .5 + 1.5 * math.sin(min(1, t * 1.15) * math.pi * .55)
        part.add(shard(p - Vector((0, .15, 0)), (0, 1, .7 + .2 * t), length,
                .22 + .15 * t, BONE, rng, sides = 5, bend = .2,
                bend_dir = (0, 1, -1)))
        for side in (-1, 1):
            q = torso_point(t_for_x(side * .95, zz, front = False), zz)
            part.add(shard(q - Vector((0, .1, 0)), (side * .4, 1, .6),
                    length * .45, .15, BONE, rng, sides = 4, bend = .1))
        zz -= .85

    #belt: iron strap with bone plaques
    def fw(u, z):
        return torso_point(u, z)
    part.add(shell(fw, math.pi / 2, math.pi / 2 + 2 * math.pi, .35, 1.4,
            40, 3, .06, .26, IRON, torso_axis, closed_u = True))
    for i in range(16):
        a = 2 * math.pi * i / 16 + math.pi / 2 + .1
        p = torso_point(a, .88)
        nrm = (p - torso_axis(p)).normalized()
        part.add(box((.4, .14, .55), BONE, loc = p + nrm * .38,
                rot = (0, 0, a + math.pi / 2), bevel = .05))
    by = torso_point(1.5 * math.pi, .9).y - .35
    #a beast-skull buckle
    part.add(ico(.55, BONE, loc = (0, by - .2, 1.0), sub = 2,
            scale = (1.1, .7, .9)))
    part.add(box((.55, .7, .4), BONE, loc = (0, by - .65, .72), bevel = .1))
    for sx in (-.24, .24):
        part.add(sphere(.13, OBSID, loc = (sx, by - .58, 1.12), u = 8, v = 5))
    #ritual plaque of obsidian hanging from the buckle, a venom sigil on it
    part.add(box((1.5, .16, 2.1), OBSID, loc = (0, by - .2, -.5),
            rot = (math.radians(-8), 0, 0), bevel = .06))
    part.add(torus(.42, .05, EMBER, loc = (0, by - .38, -.35),
            rot = (math.pi / 2 - math.radians(8), 0, 0), seg = 16, sides = 4,
            scale = (.6, 1, 1)))
    part.add(box((.07, .06, .5), EMBER, loc = (0, by - .4, -.35),
            rot = (math.radians(-8), 0, 0)))
    for sx in (-1, 1):
        part.add(box((.06, .06, .5), EMBER, loc = (sx * .45, by - .44, -1.15),
                rot = (math.radians(-8), sx * .5, 0)))
    #ragged skirt: bone tassets and hide strips, flaring out
    count = 12
    for i in range(count):
        a0 = math.pi / 2 + 2 * math.pi * i / count + .03
        a1 = a0 + 2 * math.pi / count + .1
        drop = rng.uniform(-1.4, -.8)
        mat = BONE if i % 3 == 0 else STONE
        def ft(u, z):
            p = torso_point(u, max(z, -1.0))
            flare = (.4 - z) * .25
            nrm = (p - torso_axis(p)).normalized()
            return Vector((p.x, p.y, z)) + nrm * max(0, flare)
        part.add(shell(ft, a0, a1, .45, drop, 5, 4, .26, .12, mat,
                torso_axis, jag = lambda u: -rng.uniform(0, .4)))
    return part


def build_core(rng):
    part = Part()
    bm = ico(.85, EMBER, loc = SOCKET, sub = 2)
    displace(bm, .08, 2.2, seed = 7)
    part.add(bm)
    return part


def build_shutter(side, rng):
    #closed geometry first: half a dome of scale-plate over the socket, then
    #swung open on its hinge
    part = Part()
    C = Vector((0, -2.5, SOCKET.z))
    def f(a, th):
        return C + Vector((math.sin(th) * math.cos(a), -math.cos(th),
                math.sin(th) * math.sin(a))) * 1.1
    a0, a1 = (math.pi / 2, 3 * math.pi / 2) if side < 0 else \
            (-math.pi / 2, math.pi / 2)
    part.add(shell(f, a0, a1, .02, math.pi / 2, 10, 6, 0, .14, STONE,
            lambda p: C))
    #overlapping scute ridges across the plate
    for k in (.25, .5, .75):
        a = a0 + (a1 - a0) * k
        pts = [f(a, th) for th in np.linspace(.05, math.pi / 2, 6)]
        for p, q in zip(pts, pts[1:]):
            part.add(seg_box(p + (p - C).normalized() * .12,
                    q + (q - C).normalized() * .12, .14, .1, BONE,
                    bevel = 0))
    part.add(cyl(.17, .17, 2.3, BONE, loc = (side * 1.12, -2.5,
            SOCKET.z), seg = 10))
    hinge = Vector(PIVOT['Colossus_ShutterL' if side < 0
            else 'Colossus_ShutterR'])
    ang = -SHUTTER_OPEN if side < 0 else SHUTTER_OPEN
    m = (Matrix.Translation(hinge) @ Matrix.Rotation(ang, 4, 'Z')
            @ Matrix.Translation(-hinge))
    part.bm.transform(m)
    return part


#---------------------------------------------------------------- head
#skull lofted along Y, from the occiput (+Y) to the snout tip (-Y)

HY = [1.0, .7, .2, -.4, -.9, -1.4, -1.9, -2.4, -2.9, -3.35, -3.65, -3.8]
HTOP = [14.25, 14.7, 14.85, 14.78, 14.62, 14.5, 14.2, 13.85, 13.55, 13.32,
        13.18, 13.05]
HBOT = [13.35, 13.45, 13.5, 13.53, 13.42, 13.3, 13.16, 13.02, 12.9, 12.8,
        12.76, 12.8]
HW = [1.05, 1.42, 1.55, 1.52, 1.45, 1.36, 1.18, 1.0, .85, .7, .52, .28]


def skull(y):
    yy = -y
    xs = [-v for v in HY]
    return (float(np.interp(yy, xs, HTOP)), float(np.interp(yy, xs, HBOT)),
            float(np.interp(yy, xs, HW)))


def skull_point(a, y):
    top, bot, w = skull(y)
    zm = bot + .42 * (top - bot)
    c, s = math.cos(a), math.sin(a)
    x = w * math.copysign(abs(c) ** (2 / 2.6), c)
    if s >= 0:
        z = zm + (top - zm) * abs(s) ** (2 / 2.3)
    else:
        z = zm - (zm - bot) * abs(s) ** (2 / 7)
    #sunken temples between brow and cheek
    if s > 0:
        x *= 1 - .08 * math.exp(-((y + .4) / .5) ** 2) * s
    return Vector((x, y, z))


JY = [.25, -.2, -.55, -1.2, -1.9, -2.6, -3.2, -3.6, -3.78]
JBOT = [12.95, 12.78, 12.72, 12.66, 12.55, 12.42, 12.3, 12.28, 12.42]


def jaw_point(a, y):
    top = skull(min(y, -.55))[1] - .015
    if y > -.55:
        top = skull(-.55)[1] - .015 + (y + .55) * .1
    bot = float(np.interp(-y, [-v for v in JY], JBOT))
    w = skull(y)[2] * .9
    zm = top - .3 * (top - bot)
    c, s = math.cos(a), math.sin(a)
    x = w * math.copysign(abs(c) ** (2 / 2.4), c)
    if s >= 0:
        z = zm + (top - zm) * abs(s) ** (2 / 8)
    else:
        z = zm - (zm - bot) * abs(s) ** (2 / 2.2)
    return Vector((x, y, z))


def build_head(rng):
    part = Part()
    #thick neck, rooted deep in the torso
    rings = []
    for z in np.arange(11.3, 14.61, .3):
        t = (z - 11.3) / 3.3
        cy = -.3 - .55 * t
        rx = 1.75 - .35 * t
        ry = 1.55 - .2 * t
        rings.append([Vector((math.cos(a) * rx, cy + math.sin(a) * ry, z))
                for a in (2 * math.pi * i / 18 for i in range(18))])
    bm = finish(loft(rings), STONE)
    displace(bm, .08, .9, seed = 3)
    for f in bm.faces:
        if f.normal.y < -.55:
            f.material_index = BELLY
    part.add(bm)
    neck, part = part, Part()

    nu = 26
    ys = list(np.linspace(HY[0], HY[-1], 22))
    rings = [[skull_point(2 * math.pi * i / nu, y) for i in range(nu)]
            for y in ys]
    bm = finish(loft(rings), STONE)
    displace(bm, .035, 2.2, seed = 4)
    for f in bm.faces:
        c = f.calc_center_median()
        if f.normal.z < -.75 and c.y < -.5:
            f.material_index = MOUTH
    part.add(bm)

    #armoured snout: overlapping obsidian plates along the bridge
    for k, (y0, y1) in enumerate(((-1.95, -2.6), (-2.45, -3.1),
            (-2.95, -3.55))):
        part.add(shell(skull_point, math.pi / 2 - .75, math.pi / 2 + .75,
                y0, y1, 6, 3, .04 + .05 * (2 - k), .12, STONE,
                lambda p: Vector((0, p.y, skull(p.y)[1] + .3)),
                jag = lambda u: -rng.uniform(0, .08)))
    #nasal horn and nostrils
    part.add(shard((0, -3.35, 13.42), (0, -.55, 1), .55, .2, BONE, rng,
            sides = 5, bend = .2, bend_dir = (0, 1, 0)))
    for sx in (-.3, .3):
        part.add(sphere(.12, OBSID, loc = (sx, -3.62, 13.12), u = 8, v = 5,
                scale = (1, 1.3, .7)))
        part.add(sphere(.2, STONE, loc = (sx * 1.15, -3.55, 13.12), u = 8,
                v = 5, scale = (1, 1.2, .8)))

    #heavy brow ridges overhanging the reptile eyes
    for side in (-1, 1):
        c = Vector((side * 1.0, -1.25, 14.62))
        bm = ico(1, STONE, loc = c, sub = 2, scale = (.55, 1.05, .34),
                rot = (math.radians(14), 0, side * math.radians(-14)))
        displace(bm, .05, 2.5, seed = 50 + side)
        part.add(bm)
        part.add(shard(c + Vector((side * .25, .7, .05)), (side * .35, 1, .3),
                .9, .16, BONE, rng, sides = 4, bend = .15,
                bend_dir = (0, 0, 1)))
        part.add(shard(c + Vector((side * .4, .2, -.05)), (side * .8, .7, .1),
                .55, .12, BONE, rng, sides = 4, bend = .1))
        #the eye: amber, vertical slit, sunk under the brow
        e = Vector((side * 1.24, -1.42, 14.16))
        part.add(sphere(.27, EYEBALL, loc = e, u = 14, v = 9,
                scale = (.8, 1, .95)))
        part.add(box((.06, .07, .4), OBSID, loc = e + Vector((side * .21,
                -.06, 0)), rot = (0, 0, side * math.radians(-25))))
        #lids
        part.add(torus(.29, .07, STONE, loc = e + Vector((side * .02, 0, 0)),
                rot = (0, math.pi / 2, side * math.radians(-25)),
                scale = (1, 1, 1), seg = 12, sides = 5))

    #third-eye setting: a bone ring proud of the forehead, claws gripping it
    eye = EYE0.copy()
    nrm = Vector((0, -.6, .8)).normalized()
    q = Vector((0, 0, 1)).rotation_difference(nrm)
    tr = torus(.5, .12, BONE, seg = 18, sides = 6)
    tr.transform(Matrix.Translation(eye + nrm * .02) @ q.to_matrix().to_4x4())
    part.add(finish(tr, BONE))
    bm = ico(.55, BONE, loc = eye + Vector((0, .3, -.28)), sub = 2,
            scale = (1.1, 1.1, .6))
    part.add(bm)
    for ang in (-60, 0, 60):
        r = Matrix.Rotation(math.radians(ang), 3, nrm)
        d = r @ Vector((0, .5, .55)).normalized()
        part.add(shard(eye + d * .52, d + nrm * .2, .55, .1, BONE, rng,
                sides = 4, bend = .25, bend_dir = -d))

    #crest: tall spines from the crown down the nape, webbed between
    spine_b = [(0, -.75, 14.75), (0, -.2, 14.88), (0, .35, 14.82),
            (0, .85, 14.45), (0, 1.25, 13.95), (0, 1.5, 13.4), (0, 1.6, 12.8),
            (0, 1.55, 12.2), (0, 1.45, 11.6)]
    spine_h = [.7, 1.3, 1.9, 2.3, 2.1, 1.8, 1.5, 1.1, .8]
    tips = []
    for i, (b, h) in enumerate(zip(spine_b, spine_h)):
        b = Vector(b)
        d = Vector((0, .35 + .14 * i, 1)).normalized()
        tip = b + d * h
        tips.append(tip)
        part.add(shard(b - Vector((0, 0, .1)), d, h, .2 + .02 * h, BONE, rng,
                sides = 5, bend = .12, bend_dir = (0, 1, 0)))
    part.add(membrane(spine_b, tips, .8, .45, .07, STONE))
    #swept crown horns, the long pair a king's
    for side in (-1, 1):
        part.add(horn([(side * .95, .3, 14.55), (side * 2.1, .9, 15.0),
                (side * 3.1, 2.1, 15.8), (side * 3.4, 3.5, 17.3)], .5, BONE,
                rng, steps = 12, sides = 9))
        part.add(horn([(side * 1.25, .5, 14.05), (side * 2.0, 1.3, 13.9),
                (side * 2.4, 2.4, 13.9), (side * 2.6, 3.3, 14.3)], .32, BONE,
                rng, steps = 9, sides = 7))
        part.add(horn([(side * 1.45, .05, 13.7), (side * 1.9, .6, 13.3),
                (side * 2.15, 1.5, 12.9), (side * 2.2, 2.2, 12.9)], .24, BONE,
                rng, steps = 8, sides = 6))
        #cheek scutes
        for k in range(3):
            y = -.1 - k * .45
            p = skull_point(0 if side > 0 else math.pi, y)
            part.add(ico(.26 - k * .04, STONE, loc = p + Vector((side * .05,
                    0, -.05)), sub = 1, scale = (.6, 1.2, 1)))

    #upper teeth along the lip line, overlapping the jaw like a crocodile
    for side in (-1, 1):
        for i, y in enumerate(np.linspace(-.85, -3.45, 11)):
            top, bot, w = skull(y)
            fang = i == 8
            L = .62 if fang else rng.uniform(.25, .42)
            base = Vector((side * (w * .93), y, bot + .1))
            part.add(shard(base, (side * .12, -.05, -1), L,
                    .11 if fang else .08, TEETH, rng, sides = 5, bend = .12,
                    bend_dir = (0, 1, 0)))
    for sx in (-.2, .2):
        part.add(shard((sx, -3.68, 12.88), (0, -.25, -1), .4, .08, TEETH, rng,
                sides = 5, bend = .1, bend_dir = (0, 1, 0)))
    #venom sac glowing at the back of the throat; hidden while the jaw is
    #shut, it shows when it roars or spits
    part.add(ico(.42, EMBER, loc = (0, -.95, 13.25), sub = 2,
            scale = (1.2, 1, .7)))
    #throat skin filling under the hinge so an open jaw shows a stretched
    #throat, not a hole
    rings = []
    for y in np.linspace(.6, -1.6, 7):
        t = (y - .6) / -2.2
        w = 1.1 - .25 * t
        zt = 13.4
        zb = 12.2 + .55 * t
        rings.append([Vector((math.cos(a) * w, y, (zt + zb) / 2
                + math.sin(a) * (zt - zb) / 2)) for a in
                (2 * math.pi * i / 12 for i in range(12))])
    part.add(finish(loft(rings), BELLY))
    part.bm.transform(Matrix.Translation(HEAD_OFF))
    neck.add(part.bm)
    return neck


def build_jaw(rng):
    part = Part()
    nu = 22
    ys = list(np.linspace(JY[0], JY[-1], 18))
    rings = [[jaw_point(2 * math.pi * i / nu, y) for i in range(nu)]
            for y in ys]
    bm = finish(loft(rings), STONE)
    displace(bm, .03, 2.2, seed = 6)
    for f in bm.faces:
        c = f.calc_center_median()
        if f.normal.z > .75 and c.y < -.4:
            f.material_index = MOUTH
        elif f.normal.z < -.6 and c.y < -.2:
            f.material_index = BELLY
    part.add(bm)
    #hinge knuckles, buried in the cheeks at rest
    hinge = JAW0.copy()
    for side in (-1, 1):
        part.add(sphere(.4, STONE, loc = hinge + Vector((side * .95, 0,
                -.05)), u = 10, v = 7))
    #tongue
    pts = [Vector((0, y, skull(min(y, -.55))[1] - .05)) for y in
            np.linspace(-.4, -2.9, 7)]
    part.add(tube(pts, lambda t: .45 - .25 * t, MOUTH, sides = 8,
            ref = (1, 0, 0), squash = 1.0))
    #lower teeth inside the upper ones
    for side in (-1, 1):
        for i, y in enumerate(np.linspace(-.9, -3.45, 10)):
            top = jaw_point(math.pi / 2, y).z
            w = skull(y)[2] * .9
            fang = i == 7
            L = .55 if fang else rng.uniform(.22, .36)
            part.add(shard((side * (w - .14), y, top - .08),
                    (-side * .05, -.05, 1), L, .1 if fang else .075, TEETH,
                    rng, sides = 5, bend = .1, bend_dir = (0, 1, 0)))
    #chin barbels of bone and spurs at the jaw angle
    for k, y in enumerate((-2.2, -2.75, -3.25)):
        p = jaw_point(-math.pi / 2, y)
        part.add(shard(p + Vector((0, 0, .05)), (0, .45, -1), .55 - k * .1,
                .13, BONE, rng, sides = 4, bend = .2, bend_dir = (0, 1, 0)))
    for side in (-1, 1):
        p = jaw_point(0 if side > 0 else math.pi, -.1)
        part.add(shard(p + Vector((0, 0, -.2)), (side * .45, 1, -.55), 1.0,
                .2, BONE, rng, sides = 5, bend = .15, bend_dir = (0, 0, -1)))
    return part


def build_eye(rng):
    part = Part()
    eye = EYE0.copy()
    nrm = Vector((0, -.6, .8)).normalized()
    bm = ico(.45, EYE, loc = eye, sub = 2)
    #almond, faceted gem with a slit pupil facing out of the forehead
    for v in bm.verts:
        d = v.co - eye
        along = d.dot(nrm)
        v.co = eye + d + nrm * along * -.15
    part.add(bm)
    q = Vector((0, 0, 1)).rotation_difference(nrm)
    slit = box((.07, .55, .06), OBSID)
    slit.transform(Matrix.Translation(eye + nrm * .385)
            @ q.to_matrix().to_4x4() @ Matrix.Rotation(math.pi / 2, 4, 'Z'))
    part.add(finish(slit, OBSID))
    return part


#---------------------------------------------------------------- arms (L)

AX = -5.5


def arm_loft(z0, z1, radius, n = 20, step = .4, center = (AX, 0),
        muscle = None):
    zs = list(np.arange(z0, z1 - 1e-6, -step)) + [z1]
    rings = []
    for z in zs:
        r = radius(z)
        ring = []
        for a in (2 * math.pi * i / n for i in range(n)):
            m = muscle(z, a) if muscle else 1
            ring.append(Vector((center[0] + math.cos(a) * r * m,
                    center[1] + math.sin(a) * r * .92 * m, z)))
        rings.append(ring)
    return finish(loft(rings), STONE)


def arm_axis(p):
    return Vector((AX, 0, p.z))


def build_upper_arm(rng):
    part = Part()
    bm = sphere(1.4, STONE, loc = (AX, 0, 12), u = 18, v = 10)
    displace(bm, .08, .8, seed = 11)
    part.add(bm)

    def radius(z):
        r = .84 + .015 * (z - 5)
        r += .45 * math.exp(-((z - 11.2) / 1.3) ** 2)
        r += .24 * math.exp(-((z - 8.4) / 1.0) ** 2)
        return r
    def muscle(z, a):
        s, c = math.sin(a), math.cos(a)
        return (1 + .2 * math.exp(-((z - 8.6) / 1.2) ** 2) * max(0, -s)
                + .16 * math.exp(-((z - 9.6) / 1.5) ** 2) * max(0, s)
                + .1 * math.exp(-((z - 10.8) / 1.0) ** 2) * max(0, -c))
    bm = arm_loft(12.6, 4.9, radius, n = 18, step = .38, muscle = muscle)
    displace(bm, .1, .5, seed = 12)
    for f in bm.faces:
        c = f.calc_center_median()
        if c.x - AX > .55 and c.y < 0:
            f.material_index = BELLY
    crack_slabs(bm, 22, .2, rng, inset = .07, depth = .12,
            only = lambda f: f.calc_center_median().x < AX + .3)
    part.add(bm)

    #bone pauldron: a great curved plate, a cascade under it, horns on top
    PC = Vector((AX - .35, 0, 12.25))
    tilt = Matrix.Rotation(math.radians(24), 4, 'Y')
    def fd(az, pol):
        p = Vector((math.cos(az) * math.sin(pol) * 2.0,
                math.sin(az) * math.sin(pol) * 1.9,
                math.cos(pol) * 1.1))
        p.y *= 1 - .18 * math.cos(pol)
        return PC + tilt @ p
    part.add(shell(fd, 0, 2 * math.pi, .05, math.radians(96), 14, 6, 0,
            .22, BONE, lambda p: PC, closed_u = True,
            jag = lambda u: rng.uniform(-.25, .2)))
    def fd2(az, pol):
        return PC + tilt @ Vector((math.cos(az) * math.sin(pol) * 2.25 - .2,
                math.sin(az) * math.sin(pol) * 1.95,
                math.cos(pol) * 1.0 - .55))
    part.add(shell(fd2, math.radians(110), math.radians(250),
            math.radians(55), math.radians(100), 8, 4, 0, .18, BONE,
            lambda p: PC + Vector((0, 0, -.5)),
            jag = lambda u: rng.uniform(-.3, .1)))
    #three swept horns off the pauldron, raking back
    for dy, h, r in ((-.55, 2.4, .36), (.35, 3.0, .4), (1.1, 2.0, .3)):
        b = PC + tilt @ Vector((-.6, dy, 1.0))
        P = [b, b + Vector((-.3, .25, h * .4)), b + Vector((-.9, .9, h * .8)),
                b + Vector((-1.3, 1.8, h))]
        part.add(horn(P, r, BONE, rng, steps = 8, sides = 7))
    return part


def build_forearm(rng):
    part = Part()
    bm = sphere(.92, STONE, loc = (AX, 0, 5.5), u = 16, v = 10)
    displace(bm, .08, .9, seed = 21)
    part.add(bm)

    def radius(z):
        r = .56 + .02 * (z + .9)
        r += .4 * math.exp(-((z - 4.5) / 1.3) ** 2)
        return r
    def muscle(z, a):
        return 1 + .16 * math.exp(-((z - 4.2) / 1.0) ** 2) * max(0,
                -math.cos(a)) * max(0, -math.sin(a) + .5)
    bm = arm_loft(6.0, -.95, radius, n = 16, step = .38, muscle = muscle)
    displace(bm, .08, .55, seed = 22)
    for f in bm.faces:
        c = f.calc_center_median()
        if c.x - AX > .45 and c.y < .1:
            f.material_index = BELLY
    crack_slabs(bm, 18, .3, rng, inset = .06, depth = .1,
            only = lambda f: f.calc_center_median().z > .7
                and f.calc_center_median().x < AX + .2)
    part.add(bm)

    #elbow spur, raking back
    part.add(shard((AX, .55, 5.4), (0, 1, .35), 1.6, .4, BONE, rng,
            sides = 6, bend = .2, bend_dir = (0, 0, 1)))
    #bony spurs down the outer edge of the forearm, like a fin
    for i, z in enumerate((4.6, 3.7, 2.85, 2.05, 1.3)):
        r = radius(z)
        part.add(shard((AX - r + .1, .25, z), (-.75, .35, .7),
                1.15 - i * .14, .24 - i * .02, BONE, rng, sides = 5,
                bend = .15, bend_dir = (0, 0, 1)))

    #manacle: iron cuff at the wrist, a broken chain off the outside
    def fm(az, z):
        return Vector((AX + math.cos(az) * .9, math.sin(az) * .86, z))
    part.add(shell(fm, 0, 2 * math.pi, -.3, .45, 18, 2, 0, .26, IRON,
            arm_axis, closed_u = True))
    for z in (-.25, .4):
        part.add(torus(1.18, .07, IRON, loc = (AX, 0, z), seg = 18,
                sides = 4, scale = (1, .96, 1)))
    part.add(box((.35, .5, .6), IRON, loc = (AX + 1.18, 0, .08), bevel = .05))
    part.add(shard((AX + 1.25, 0, .5), (.3, 0, 1), .45, .12, IRON, rng,
            sides = 4, bend = 0))
    part.add(box((.5, .7, .9), IRON, loc = (AX - 1.25, 0, .08), bevel = .07))
    part.add(torus(.26, .09, IRON, loc = (AX - 1.55, 0, -.25),
            rot = (math.pi / 2, 0, 0), seg = 10, sides = 6))
    z = -.8
    for i in range(4):
        rot = (math.pi / 2, 0, 0) if i % 2 else (math.pi / 2, 0, math.pi / 2)
        arc = 2 * math.pi if i < 3 else math.radians(250)
        bm = torus(.27, .09, IRON, rot = rot, seg = 10, sides = 6, arc = arc)
        bm.transform(Matrix.Translation((AX - 1.55 - i * .04, 0, z))
                @ Matrix.Diagonal((1, 1, 1.5, 1)))
        part.add(finish(bm, IRON))
        z -= .62
    return part


def build_hand(rng):
    part = Part()
    W = Vector((AX, 0, -.5))
    def at(x, y, z):
        return W + Vector((x, y, z))
    bm = sphere(.82, STONE, loc = W, u = 12, v = 8)
    part.add(bm)
    #the hand's back (+Y): scaled, cracked open over venom
    bm = box((2.0, 1.35, 1.6), STONE, loc = at(0, .05, -1.15), bevel = .3,
            seg = 1)
    bmesh.ops.subdivide_edges(bm, edges = bm.edges[:], cuts = 2,
            use_grid_fill = True)
    finish(bm, STONE)
    for v in bm.verts:
        if v.co.y > W.y:
            v.co.y += .15 * (1 - ((v.co.x - AX) / 1.1) ** 2)
        #narrow toward the wrist
        k = min(1, max(0, (v.co.z - (W.z - .9)) / .6))
        v.co.x = AX + (v.co.x - AX) * (1 - .25 * k)
    displace(bm, .05, 1.5, seed = 32)
    for f in bm.faces:
        if f.normal.y < -.5:
            f.material_index = BELLY
    crack_slabs(bm, 9, .85, rng, inset = .07, depth = .14, jitter = .06,
            only = lambda f: f.normal.y > .35)
    part.add(bm)
    #three clawed fingers curled into a half-fist, palm forward (-Y)
    for i, x in enumerate((-.66, 0, .66)):
        s = (.95, 1.0, .9)[i]
        sx = x * 1.05
        ctrl = [at(x, .1, -1.55), at(x, -.02, -1.95), at(sx, -.38, -2.3),
                at(sx, -.9, -2.38)]
        pts = spline(ctrl, 3)
        part.add(tube(pts, lambda t: (.36 - .08 * t) * s, STONE, sides = 9))
        #knuckle pads
        for k in (1, 2):
            part.add(sphere(.37 * s - k * .02, STONE, loc = ctrl[k], u = 8,
                    v = 6))
        #hooked claw raking down in front of the fist
        p0 = ctrl[-1]
        P = [p0 - Vector((0, -.1, 0)), p0 + Vector((sx * .05, -.55, -.1)),
                p0 + Vector((sx * .08, -.9, -.5)),
                p0 + Vector((sx * .1, -.85, -1.05))]
        part.add(horn(P, .27 * s, TEETH, rng, steps = 8, sides = 7))
        #bony spur over the knuckle (back of the hand)
        part.add(shard(at(x, .55, -1.75), (0, 1, -.25), .5, .14, BONE, rng,
                sides = 4, bend = .1))
    #thumb wrapping across the front of the fingers
    ctrl = [at(-.95, -.15, -.75), at(-1.15, -.65, -1.3), at(-.8, -1.2, -1.7),
            at(-.25, -1.45, -1.78)]
    pts = spline(ctrl, 3)
    part.add(tube(pts, lambda t: .38 - .08 * t, STONE, sides = 9))
    p0 = ctrl[-1]
    d = (ctrl[-1] - ctrl[-2]).normalized()
    part.add(horn([p0, p0 + d * .4, p0 + d * .7 + Vector((0, .15, -.1)),
            p0 + d * .8 + Vector((0, .5, -.3))], .23, TEETH, rng, steps = 7,
            sides = 7))
    #venom crystals breaking out of the back of the hand
    for x, z, d, l in ((-.45, -.85, (-.3, 1, .4), .9), (.35, -1.35,
            (.2, 1, -.2), .7), (.6, -.6, (.4, 1, .3), .55),
            (-.1, -1.6, (0, 1, -.4), .5)):
        part.add(shard(at(x, .8, z), d, l, .17, EMBER, rng, sides = 5,
                bend = .08))
    #iron wrist cuff remnant
    def fw(az, z):
        return Vector((AX + math.cos(az) * .9, math.sin(az) * .86, z))
    part.add(shell(fw, 0, 2 * math.pi, .1, -.45, 16, 2, 0, .12, IRON,
            lambda p: Vector((AX, 0, p.z)), closed_u = True))
    return part


#---------------------------------------------------------------- tail

def build_tail(rng):
    part = Part()
    pv = Vector(PIVOT['Colossus_Tail'])
    ctrl = [(0, 1.5, 1.2), (0, 3.0, -1.2), (0, 4.0, -4.6), (0, 3.4, -8.1),
            (0, 4.1, -11.2), (0, 5.4, -13.0)]
    pts = spline(ctrl, 5)
    radius = lambda t: 1.45 * (1 - t) ** .85 + .22
    bm = tube(pts, radius, STONE, sides = 16, ref = (1, 0, 0), squash = .82)
    displace(bm, .05, 1.2, seed = 60)
    #ventral (front, -Y) belly scutes; dorsal plates over a venom underlay
    for f in bm.faces:
        if f.normal.y < -.45:
            f.material_index = BELLY
    crack_slabs(bm, 40, .25, rng, inset = .08, depth = .12,
            only = lambda f: f.normal.y > .2)
    part.add(bm)
    part.add(sphere(1.55, STONE, loc = pv + Vector((0, -.2, .2)), u = 16,
            v = 10, scale = (1, 1, 1.1)))
    #double row of dorsal spikes
    fr = frames(pts)
    for i in range(1, len(pts) - 2, 2):
        p = pts[i]
        t, n, b = fr[i]
        dors = -b if b.y < 0 else b
        r = radius(i / (len(pts) - 1))
        for side in (-1, 1):
            base = p + dors * r * .85 + n * side * r * .35
            part.add(shard(base, dors + t * .5 + n * side * .25,
                    .35 + .5 * r, .12 + .12 * r, BONE, rng, sides = 4,
                    bend = .15, bend_dir = t))
    #spiked bone club at the tip, a long blade spike at the very end
    E = pts[-1]
    tE = fr[-1][0]
    q = Vector((0, 0, 1)).rotation_difference(tE)
    club = ico(1, BONE, sub = 2, scale = (.8, .8, 1.25))
    displace(club, .08, 2.5, seed = 61)
    club.transform(Matrix.Translation(E + tE * .7) @ q.to_matrix().to_4x4())
    part.add(finish(club, BONE))
    for k in range(9):
        a = 2 * math.pi * k / 9
        ring = (k % 3) - 1
        d = q @ Vector((math.cos(a), math.sin(a), ring * .6)).normalized()
        part.add(shard(E + tE * (.7 + ring * .5) + d * .6, d, 1.0 + .3 * rng.random(),
                .2, OBSID, rng, sides = 4, bend = .1, bend_dir = tE))
    part.add(shard(E + tE * 1.6, tE, 1.8, .3, OBSID, rng, sides = 4,
            bend = .15, bend_dir = (0, 1, 0)))
    #venom seam ring where the club grows out of the tail
    tr = torus(.42, .06, EMBER, seg = 12, sides = 4)
    tr.transform(Matrix.Translation(E) @ q.to_matrix().to_4x4())
    part.add(finish(tr, EMBER))
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
    me.set_sharp_from_angle(angle = math.radians(40))
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
        'Colossus_Jaw': build_jaw(rng),
        'Colossus_Tail': build_tail(rng),
    }
    up, fore, hand = build_upper_arm(rng), build_forearm(rng), build_hand(rng)
    parts['Colossus_UpperArm_R'] = mirror(up)
    parts['Colossus_Forearm_R'] = mirror(fore)
    parts['Colossus_Hand_R'] = mirror(hand)
    for name in ('Colossus_Jaw', 'Colossus_Eye'):
        parts[name].bm.transform(Matrix.Translation(HEAD_OFF))
    for name in ('Colossus_Head', 'Colossus_Jaw', 'Colossus_Eye'):
        parts[name].bm.transform(Matrix.Translation(HEAD_PIVOT)
                @ Matrix.Scale(HEAD_SCALE, 4)
                @ Matrix.Translation(-HEAD_PIVOT))
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
    scene.view_settings.exposure = .6
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
    ramp.color_ramp.elements[0].color = (.004, .006, .008, 1)
    ramp.color_ramp.elements[1].color = (.04, .06, .085, 1)
    nt.links.new(coord.outputs['Generated'], mapn.inputs['Vector'])
    nt.links.new(mapn.outputs['Vector'], grad.inputs['Vector'])
    nt.links.new(grad.outputs['Fac'], ramp.inputs['Fac'])
    nt.links.new(ramp.outputs['Color'], bg.inputs['Color'])
    bg.inputs['Strength'].default_value = 1.0
    #the abyss: a bank of mist the body rises out of
    me = bpy.data.meshes.new('Abyss')
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size = 1)
    bm.transform(mat_trs((0, 0, -21.4), (0, 0, 0), (140, 140, 40)))
    bm.to_mesh(me)
    bm.free()
    mist = bpy.data.objects.new('Abyss', me)
    scene.collection.objects.link(mist)
    mm = bpy.data.materials.new('AbyssMist')
    mm.use_nodes = True
    mnt = mm.node_tree
    for nd in [nd for nd in mnt.nodes if nd.type == 'BSDF_PRINCIPLED']:
        mnt.nodes.remove(nd)
    vol = mnt.nodes.new('ShaderNodeVolumePrincipled')
    vol.inputs['Color'].default_value = (.1, .13, .18, 1)
    tc = mnt.nodes.new('ShaderNodeTexCoord')
    sep = mnt.nodes.new('ShaderNodeSeparateXYZ')
    mr = mnt.nodes.new('ShaderNodeMapRange')
    mr.inputs['From Min'].default_value = 1.0
    mr.inputs['From Max'].default_value = .93
    mr.inputs['To Min'].default_value = 0
    mr.inputs['To Max'].default_value = .12
    mnt.links.new(tc.outputs['Generated'], sep.inputs['Vector'])
    mnt.links.new(sep.outputs['Z'], mr.inputs['Value'])
    mnt.links.new(mr.outputs['Result'], vol.inputs['Density'])
    mout = next(nd for nd in mnt.nodes if nd.type == 'OUTPUT_MATERIAL')
    mnt.links.new(vol.outputs['Volume'], mout.inputs['Volume'])
    me.materials.append(mm)

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
    light('Rim', 'SUN', (40, 35, 15), 7.0, (.55, .68, 1.0))
    light('Key', 'SUN', (-20, -40, 35), 2.2, (.5, .6, .85))
    light('CoreGlow', 'POINT', (0, -4.5, 9.0), 700, VENOM, size = 1)
    for x in (-5.5, 5.5):
        light('FistGlow', 'POINT', (x, 1.8, -2.0), 150, VENOM)
    light('EyeGlow', 'POINT', (0, -2.8, 15.4), 120, GEM)

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


def render(cam, name, loc, target, lens, abyss = True):
    if ONLY and name not in ONLY:
        return
    mist = bpy.context.scene.objects.get('Abyss')
    if mist:
        mist.hide_render = not abyss
    cam.location = loc
    cam.data.lens = lens
    look_at(cam, target)
    bpy.context.scene.render.filepath = str(PREVIEW / (name + '.png'))
    bpy.ops.render.render(write_still = True)
    print('rendered', name)


ONLY = set(os.environ.get('LIZARD_ONLY', '').split(',')) - {''}


def pose(objs, rots):
    for o in objs.values():
        o.rotation_euler = (0, 0, 0)
    for name, rot in rots.items():
        objs[name].rotation_euler = rot
    bpy.context.view_layer.update()


def previews(objs):
    PREVIEW.mkdir(parents = True, exist_ok = True)
    cam = setup_scene()
    render(cam, 'front', (0, -62, 7.5), (0, 0, 7.6), 70)
    render(cam, 'three_quarter', (30, -40, 1), (0, 0, 8.5), 60)
    pose(objs, {'Colossus_Jaw': (math.radians(14), 0, 0)})
    render(cam, 'head', (10, -15, 16.3), (0, -1.8, 14.2), 50)
    pose(objs, {})
    render(cam, 'back_of_hand', (-7.2, 8.0, -3.0), (-5.5, .5, -1.6), 45,
            abyss = False)
    render(cam, 'tail', (26, 30, -4), (0, 3.6, -5.5), 38, abyss = False)
    render(cam, 'back', (-18, 40, 12), (0, 0, 8), 60)
    #right claw overhead, left arm reaching forward, roaring, tail lashing
    pose(objs, {
        'Colossus_UpperArm_R': (math.radians(-170), 0, math.radians(-10)),
        'Colossus_Forearm_R': (math.radians(-35), 0, 0),
        'Colossus_Hand_R': (math.radians(-20), 0, 0),
        'Colossus_UpperArm_L': (math.radians(-80), 0, math.radians(-15)),
        'Colossus_Forearm_L': (math.radians(-25), 0, 0),
        'Colossus_Hand_L': (math.radians(-60), 0, 0),
        'Colossus_Head': (math.radians(-12), 0, math.radians(20)),
        'Colossus_Jaw': (math.radians(30), 0, 0),
        'Colossus_Tail': (0, math.radians(-60), 0),
    })
    render(cam, 'posed', (32, -44, 6), (0, -2, 9), 45)
    render(cam, 'posed_side', (48, -6, 9), (0, -2, 9), 42, abyss = False)
    #the game's widest jaw (35 deg) with everything else at rest: the jaw
    #must swing clear of the chest
    pose(objs, {'Colossus_Jaw': (math.radians(35), 0, 0)})
    render(cam, 'roar_side', (26, -9, 13), (0, -2.2, 12.3), 50,
            abyss = False)
    pose(objs, {})
    for o in list(bpy.context.scene.objects):
        if o.name not in objs:
            bpy.data.objects.remove(o)


#---------------------------------------------------------------- export

def export(objs):
    OUT.mkdir(parents = True, exist_ok = True)
    for o in objs.values():
        assert tuple(o.rotation_euler) == (0, 0, 0)
        assert tuple(o.scale) == (1, 1, 1)
    for o in bpy.context.scene.objects:
        o.select_set(o.name in objs)
    bpy.ops.export_scene.gltf(filepath = str(OUT / 'lizard.glb'),
            export_format = 'GLB', use_selection = True, export_yup = True,
            export_apply = True, export_texcoords = True,
            export_normals = True, export_materials = 'EXPORT')
    bpy.context.preferences.filepaths.save_version = 0
    bpy.ops.wm.save_as_mainfile(filepath = str(OUT / 'lizard.blend'))


def verify():
    bpy.ops.wm.read_factory_settings(use_empty = True)
    bpy.ops.import_scene.gltf(filepath = str(OUT / 'lizard.glb'))
    total = 0
    print('\n=== lizard.glb re-import ===')
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
    assert not missing and total <= TRI_BUDGET


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
