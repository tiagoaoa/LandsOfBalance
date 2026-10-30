#Drogon-class wyvern for the boss arena: a skinned, rigged replacement for the
#rigid-part lizard-king.  The wings ARE the arms (Game of Thrones anatomy):
#the gameplay "fist" is the wing-wrist and its hooked thumb claw.
#blender -b --factory-startup -P tools/build_dragon.py [-- --no-render]
#Writes assets/characters/dragon/{dragon.glb,dragon.blend,*.png}
#and preview renders to $DRAGON_PREVIEW (default: the scratchpad below).
#
#Faces Blender -Y, Z up, metres; _L / .L is -X.  Same frame as the lizard:
#Godot local = (x, z, -y), the arena floor sits at z = 4, the rim at y = -5.
#
#Contract with enemies/colossus/colossus.gd (dragon mode):
#  upperarm.X -> forearm.X is exactly UPPER (6.5), forearm.X -> hand.X FORE
#  (6.0); 'fist.L/R' marker bones run from the wrist along the thumb claw
#  for FIST (1.3); 'core' and 'mouth' marker bones place the chest-fire weak
#  point and the throat (the gaze/breath interrupt).  The game builds its IK
#  pivots from these rests and drives the bones from them.
#
#Body: metaball anatomy (blobby joins where a limb meets the trunk, like
#muscle under hide) remeshed to one watertight skin, auto-weighted by bone
#heat.  Hard parts (horns, spines, claws, teeth) stay crisp, rigidly bound.
#Wing membranes are Coons patches between the finger bones, weighted by
#distance to the wing bones.  Scales come from tileable textures on
#skeleton-cylindrical UVs, so the scale rows follow every limb; ambient
#occlusion and the colour zones (dark back, ember-red undertone, pale belly)
#are baked into vertex colours.
import bpy
import bmesh
import math
import os
import random
import sys
from pathlib import Path
from mathutils import Vector, Matrix, Quaternion
from mathutils.bvhtree import BVHTree
import numpy as np


ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'assets/characters/dragon'
PREVIEW = Path(os.environ.get('DRAGON_PREVIEW',
        '/tmp/claude-1000/-home-talves-mthings-LandsOfBalance/'
        '07261c89-1cc2-4cd7-9029-7c1b17b3a6a2/scratchpad/dragon'))
RENDER = '--no-render' not in sys.argv
STAGE = os.environ.get('DRAGON_STAGE', 'all')   # 'shape' stops before the rig
ONLY = set(os.environ.get('DRAGON_ONLY', '').split(',')) - {''}
BODY_TRIS = int(os.environ.get('DRAGON_TRIS', '90000'))
MB_RES = float(os.environ.get('DRAGON_MBRES', '0.09'))
UPPER, FORE, FIST = 6.5, 6.0, 1.3
MB_K = 0.7          # chained metaball surface radius / element radius

V = Vector


def nrm(*a):
    return V(a).normalized()


#================================================================ anatomy ====
#every joint of the animal, rest pose ("mantling": wings half open, wrists
#out to the sides, head arched over the rim looking down at the platform)
J = {}
J['pelvis'] = V((0, 3.4, 1.9))
J['spine1'] = V((0, 3.1, 4.6))
J['spine2'] = V((0, 2.1, 7.2))
J['chest'] = V((0, 0.5, 9.6))
J['withers'] = V((0, -0.5, 11.7))
J['neck1'] = V((0, -1.2, 12.5))
NECK = [V((0, -1.2, 12.5)), V((0, -1.8, 14.1)), V((0, -2.9, 15.3)),
        V((0, -4.3, 15.7)), V((0, -5.6, 15.35))]
J['head'] = V((0, -6.4, 14.7))
HEAD_DIR = nrm(0, -0.86, -0.5)      # skull axis, base -> snout
HS = 1.25                           # head scale: everything in hp() and the head radii
HEAD_UP = HEAD_DIR.cross(V((1, 0, 0))).normalized()
if HEAD_UP.z < 0:
    HEAD_UP = -HEAD_UP
SNOUT = 4.3
J['jaw'] = J['head'] + (HEAD_DIR * 0.75 - HEAD_UP * 0.55) * HS
J['mouth'] = J['head'] + (HEAD_DIR * 3.0 - HEAD_UP * 0.5) * HS
J['core'] = V((0, -2.3, 9.3))
TAIL = [V((0, 4.4, 0.6)), V((0, 5.6, -1.4)), V((0, 6.4, -3.8)),
        V((0, 6.6, -6.5)), V((0, 6.2, -9.2)), V((0, 5.2, -11.7)),
        V((0, 3.8, -13.8)), V((0, 2.3, -15.4)), V((0, 0.8, -16.4)),
        V((0, -0.6, -17.0))]


def side_joints(s):
    """Joints of one side, authored for -X; s = +1 keeps them there (L),
    s = -1 mirrors them to +X (R)."""
    m = lambda v: V((v.x * s, v.y, v.z))
    j = {}
    j['shoulder'] = m(V((-1.1, -0.2, 11.6)))
    j['upperarm'] = m(V((-2.6, -0.3, 12.0)))
    u = nrm(-0.80, 0.30, 0.52)
    j['forearm'] = j['upperarm'] + m(u) * UPPER
    v = nrm(-0.45, -0.25, -0.86)
    j['hand'] = j['forearm'] + m(v) * FORE
    w = j['hand']
    j['thumb_dir'] = m(nrm(-0.15, -0.88, -0.45))
    j['fist'] = w + j['thumb_dir'] * FIST
    #wing fingers: (direction, first phalanx, second phalanx)
    j['fingers'] = []
    for d, a, b in ((nrm(-0.50, 0.12, 0.86), 5.6, 4.6),
                    (nrm(-0.92, 0.30, 0.20), 5.2, 4.2),
                    (nrm(-0.55, 0.62, -0.56), 4.2, 3.4)):
        d = m(d)
        k = w + d * a
        #the second phalanx swings back a little: a fan, not a star
        d2 = (d + m(V((0.0, 0.25, -0.15)))).normalized()
        j['fingers'].append((w, k, k + d2 * b))
    #braced on the rock below the rim (y -5, z 4): knee forward, toes
    #hooked on the cliff face
    j['hip'] = m(V((-2.0, 3.2, 1.9)))
    j['knee'] = m(V((-2.7, -1.6, 0.4)))
    j['ankle'] = m(V((-2.6, -1.4, -2.6)))
    j['toes'] = m(V((-2.6, -3.9, -1.9)))
    j['flank'] = m(V((-2.3, 2.6, 5.6)))
    return j


#_L / .L is -X, as in the colossus and lizard (the boss's arm 0)
SIDES = {'L': side_joints(1), 'R': side_joints(-1)}


#============================================================== textures ====

def tile_noise(n, seed, beta):
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
    dx = (np.roll(h, -1, 1) - np.roll(h, 1, 1)) * .5 * strength
    dy = (np.roll(h, -1, 0) - np.roll(h, 1, 0)) * .5 * strength
    nz = np.ones_like(h)
    ln = np.sqrt(dx * dx + dy * dy + 1)
    return np.stack([-dx / ln * .5 + .5, -dy / ln * .5 + .5, nz / ln * .5
            + .5], -1)


def scale_cells(n, cells, seed, overlap = 1.4, aspect = 1.0):
    #overlapping scales: Voronoi on a staggered, jittered grid with a metric
    #stretched toward the tail (+v), so each scale lies over the next
    rng = np.random.default_rng(seed)
    R = int(cells * aspect)
    C = cells
    jit = rng.uniform(-.18, .18, (R, C, 2))
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
            dyw = np.where(dy < 0, dy * .7, dy * overlap)
            d = np.sqrt(dx * dx + dyw * dyw)
            m = d < b1
            b2 = np.where(m, b1, np.minimum(b2, d))
            b1 = np.where(m, d, b1)
            bid = np.where(m, jr * C + jc, bid)
            bdy = np.where(m, dy, bdy)
    edge = np.clip((b2 - b1) / .3, 0, 1)
    lift = .45 + .55 * np.clip(.35 - bdy, 0, 1)
    h = np.sqrt(edge) * lift
    return h, tint[bid], edge


def make_textures():
    n = 1024
    big = tile_noise(n, 1, 1.8)
    mid = tile_noise(n, 2, 1.2)
    fine = tile_noise(n, 3, .5)
    #hide: charcoal scales with a dried-blood glint on the crowns and soot in
    #the crevices (vertex colour carries the large-scale zones)
    h, tint, edge = scale_cells(n, 12, 21)
    h2, _, _ = scale_cells(n, 34, 22)
    crown = np.array([.115, .1, .095])
    crev = np.array([.012, .009, .008])
    t = (h * (.6 + .4 * h2))[..., None]
    rgb = crev + (crown - crev) * t * (.7 + .6 * tint[..., None])
    red = (smooth(.55, 1.0, tint) * smooth(.4, .9, h))[..., None]
    rgb = rgb * (1 - red * .5) + np.array([.16, .045, .03]) * red * .5
    rgb *= (.75 + .45 * smooth(.3, .8, big))[..., None]
    rgb += (fine - .5)[..., None] * .012
    hide_alb = save_image('dragon_hide_albedo', np.clip(rgb, 0, 1))
    hide_nrm = save_image('dragon_hide_normal',
            normal_map(h * .9 + h2 * .3 + fine * .12, 26), data = True)
    #crowns polished by wind and smoke, crevices dull
    rough = .78 - .38 * smooth(.2, .9, h) + (fine - .5) * .1
    hide_rgh = save_image('dragon_hide_rough',
            np.repeat(np.clip(rough, 0, 1)[..., None], 3, -1), data = True)
    #belly: broad transverse scutes, umber in the grooves
    R, C = 4, 1
    ys, xs = np.mgrid[0:n, 0:n].astype(np.float64)
    gy = (ys + .5) / n * R + .25 * (big - .5)
    gx = (xs + .5) / n * C + .5 * (np.floor(gy) % 2) + .3 * (mid - .5)
    fx = gx % 1
    fy = gy % 1
    rows = np.floor(gy).astype(int) % R
    cols = np.floor(gx).astype(int) % C
    ptint = np.random.default_rng(5).uniform(0, 1, (R, C))[rows, cols]
    pil = (np.clip(.55 + np.minimum(fx, 1 - fx) / .1, 0, 1)
            * np.clip(np.minimum(fy, 1 - fy) / .12, 0, 1))
    pil = np.sqrt(pil) * (.55 + .45 * (1 - fy))
    tan = np.array([.2, .12, .07]) * (.75 + .4 * ptint[..., None])
    groove = np.array([.03, .018, .012])
    rgb = groove + (tan - groove) * pil[..., None]
    rgb *= (.7 + .45 * mid)[..., None]
    rgb += (fine - .5)[..., None] * .02
    belly_alb = save_image('dragon_belly_albedo', np.clip(rgb, 0, 1))
    belly_nrm = save_image('dragon_belly_normal',
            normal_map(pil * .9 + fine * .25 + h2 * .1, 20), data = True)
    #horn: keratin, streaked lengthwise (v runs base -> tip)
    streak = tile_noise(n, 9, 1.0)
    streak = np.repeat(streak[:1, :], n, 0) * .6 + tile_noise(n, 10, 1.4) * .4
    rgb = np.array([.05, .045, .04]) + np.array([.12, .1, .08]) * streak[..., None]
    horn_alb = save_image('dragon_horn_albedo', np.clip(rgb, 0, 1))
    horn_nrm = save_image('dragon_horn_normal', normal_map(streak + fine * .2, 6),
            data = True)
    #membrane: leathery, with veins fanning along u
    vein = np.zeros((n, n))
    rng = np.random.default_rng(31)
    xs_ = (np.arange(n) + .5) / n
    ys_ = ((np.arange(n) + .5) / n)[:, None]
    for k in range(7):
        x0 = (k + .5) / 7 + rng.uniform(-.03, .03)
        warp = (tile_noise(n, 40 + k, 1.9) - .5) * .16
        d = np.abs(((xs_[None, :] - x0 - warp + .5) % 1) - .5)
        vein = np.maximum(vein, 1 - smooth(0, .007, d))
        #branches peel off and fade
        for b in range(3):
            y0 = rng.uniform(0, 1)
            slope = rng.uniform(.25, .6) * (1 if rng.uniform() < .5 else -1)
            xb = x0 + warp + slope * (ys_ - y0)
            db = np.abs(((xs_[None, :] - xb + .5) % 1) - .5)
            fade = np.clip(1 - np.abs(ys_ - y0 - .12) / .14, 0, 1)
            vein = np.maximum(vein, (1 - smooth(0, .004, db)) * fade)
    wr = tile_noise(n, 50, .9)
    rgb = np.array([.05, .022, .018]) * (.7 + .5 * mid)[..., None]
    rgb = rgb * (1 - vein[..., None] * .7) + np.array([.012, .004, .003]) * vein[..., None] * .7
    rgb *= (.85 + .3 * wr)[..., None]
    mem_alb = save_image('dragon_membrane_albedo', np.clip(rgb, 0, 1))
    mem_nrm = save_image('dragon_membrane_normal',
            normal_map(vein * .8 + wr * .5 + fine * .2, 8), data = True)
    #chest fire: molten light in the seams between scutes
    hc, _, ec = scale_cells(n, 5, 77)
    glow = (1 - smooth(.0, .35, ec)) * (.6 + .4 * fine)
    rgb = np.stack([glow, glow * .42, glow * .1], -1)
    save_image('dragon_core_emit', np.clip(rgb * 1.2, 0, 1))
    alb = np.array([.03, .02, .018]) * (1 - glow[..., None]) + np.array([.9, .45, .1]) * glow[..., None]
    save_image('dragon_core_albedo', np.clip(alb, 0, 1))
    return {'hide': (hide_alb, hide_nrm, hide_rgh), 'belly': (belly_alb, belly_nrm, None),
            'horn': (horn_alb, horn_nrm, None), 'membrane': (mem_alb, mem_nrm, None)}


MATS = {}


def materials():
    tex = make_textures()

    def new(name):
        m = bpy.data.materials.new(name)
        m.use_nodes = True
        MATS[name] = m
        return m, next(n for n in m.node_tree.nodes if n.type == 'BSDF_PRINCIPLED')

    def textured(name, key, rough, nstrength, vcol = True, spec = .5):
        m, bsdf = new(name)
        nt = m.node_tree
        alb, nrm_img, rgh = tex[key]
        t = nt.nodes.new('ShaderNodeTexImage')
        t.image = alb
        col = t.outputs['Color']
        if vcol:
            #albedo x baked vertex colour (zones + AO), as Godot will do it
            vc = nt.nodes.new('ShaderNodeVertexColor')
            vc.layer_name = 'Col'
            mul = nt.nodes.new('ShaderNodeMix')
            mul.data_type = 'RGBA'
            mul.blend_type = 'MULTIPLY'
            mul.inputs['Factor'].default_value = 1.0
            nt.links.new(t.outputs['Color'], mul.inputs[6])
            nt.links.new(vc.outputs['Color'], mul.inputs[7])
            col = mul.outputs[2]
        nt.links.new(col, bsdf.inputs['Base Color'])
        tn = nt.nodes.new('ShaderNodeTexImage')
        tn.image = nrm_img
        nm = nt.nodes.new('ShaderNodeNormalMap')
        nm.inputs['Strength'].default_value = nstrength
        nt.links.new(tn.outputs['Color'], nm.inputs['Color'])
        nt.links.new(nm.outputs['Normal'], bsdf.inputs['Normal'])
        if rgh is not None:
            tr = nt.nodes.new('ShaderNodeTexImage')
            tr.image = rgh
            nt.links.new(tr.outputs['Color'], bsdf.inputs['Roughness'])
        else:
            bsdf.inputs['Roughness'].default_value = rough
        bsdf.inputs['Specular IOR Level'].default_value = spec
        return m, bsdf

    textured('Dragon_Hide', 'hide', .6, 1.0)
    textured('Dragon_Belly', 'belly', .55, 1.0)
    textured('Dragon_Horn', 'horn', .35, .6, vcol = True)
    m, bsdf = textured('Dragon_Membrane', 'membrane', .7, .7, vcol = False)
    bsdf.inputs['Subsurface Weight'].default_value = .25
    bsdf.inputs['Subsurface Radius'].default_value = (1.0, .2, .1)
    m.use_backface_culling = False
    for name, base, emit, strength, rough in (
            ('Colossus_Eye', (1.0, .55, .08), (1.0, .55, .08), 2.0, .1),
            ('Dragon_Core', (1.0, .35, .05), (1.0, .35, .05), 8.0, .4),
            ('Colossus_Ember', (1.0, .3, .04), (1.0, .3, .04), 4.0, .4)):
        m, bsdf = new(name)
        bsdf.inputs['Base Color'].default_value = (*base, 1)
        bsdf.inputs['Emission Color'].default_value = (*emit, 1)
        bsdf.inputs['Emission Strength'].default_value = strength
        bsdf.inputs['Roughness'].default_value = rough
    for name, base, rough in (('Dragon_Teeth', (.36, .3, .22), .35),
                              ('Dragon_Mouth', (.12, .025, .02), .35),
                              ('Dragon_Pupil', (.01, .005, .003), .1)):
        m, bsdf = new(name)
        bsdf.inputs['Base Color'].default_value = (*base, 1)
        bsdf.inputs['Roughness'].default_value = rough


#=============================================================== metaballs ===

def catmull(pts, steps_per_m):
    """Dense samples along a Catmull-Rom spline through pts (with params)."""
    out = []
    P = [pts[0] * 2 - pts[1]] + list(pts) + [pts[-1] * 2 - pts[-2]]
    for i in range(1, len(P) - 2):
        p0, p1, p2, p3 = P[i - 1], P[i], P[i + 1], P[i + 2]
        n = max(2, int((p2 - p1).length * steps_per_m))
        for k in range(n):
            t = k / n
            t2, t3 = t * t, t * t * t
            q = 0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2
                    + (-p0 + 3 * p1 - 3 * p2 + p3) * t3)
            out.append((q, (i - 1 + t) / (len(pts) - 1)))
    out.append((pts[-1], 1.0))
    return out


class Meta:
    def __init__(self, name):
        self.mb = bpy.data.metaballs.new(name)
        self.mb.resolution = MB_RES
        self.mb.render_resolution = MB_RES
        self.mb.threshold = 0.6
        self.ob = bpy.data.objects.new(name, self.mb)
        bpy.context.scene.collection.objects.link(self.ob)

    def ball(self, co, r, size = (1, 1, 1), rot = None, neg = False):
        """r = wanted surface radius (in a chain); size scales the axes."""
        e = self.mb.elements.new(type = 'ELLIPSOID')
        e.co = co
        e.radius = r / MB_K
        e.size_x, e.size_y, e.size_z = size
        if rot is not None:
            e.rotation = rot
        e.use_negative = neg
        e.stiffness = 2.0
        return e

    def chain(self, pts, radii, up = V((0, 0, 1)), flat = None, density = None):
        """A tube through pts; radii [(width, depth)...] per control point,
        interpolated; flat = optional per-point extra squash."""
        #resample at spacing ~ 0.3 x element radius (the calibrated chain)
        dense = catmull(pts, 12.0)
        last = None
        for idx, (q, t) in enumerate(dense):
            w, d = lerp_radii(radii, t)
            r = min(w, d)
            if last is not None and (q - last).length < 0.3 * r / MB_K:
                continue
            last = q
            if idx + 1 < len(dense):
                tan = (dense[idx + 1][0] - q).normalized()
            else:
                tan = (q - dense[idx - 1][0]).normalized()
            x = up.cross(tan)
            if x.length < 1e-4:
                x = V((1, 0, 0))
            x.normalize()
            z = tan.cross(x).normalized()
            #ellipsoid frame: local x = side (width), y = along, z = depth
            m = Matrix((x, tan, z)).transposed()
            rr = max(w, d)
            self.ball(q, rr, (w / rr, min(w, d) / rr, d / rr), m.to_quaternion())

    def mesh(self):
        dg = bpy.context.evaluated_depsgraph_get()
        me = bpy.data.meshes.new_from_object(self.ob.evaluated_get(dg))
        bpy.data.objects.remove(self.ob)
        return me


def lerp_radii(radii, t):
    f = t * (len(radii) - 1)
    i = min(int(f), len(radii) - 2)
    k = f - i
    k = k * k * (3 - 2 * k)
    a, b = radii[i], radii[i + 1]
    return a[0] + (b[0] - a[0]) * k, a[1] + (b[1] - a[1]) * k


def build_body_meta():
    M = Meta('BodyMeta')
    up = V((0, 0, 1))
    fwd = V((0, -1, 0))
    #trunk: pelvis -> withers, deep keeled chest, slung belly
    trunk = [J['pelvis'] + V((0, 1.2, -0.6)), J['pelvis'], J['spine1'], J['spine2'],
            J['chest'], J['withers'], J['neck1']]
    M.chain(trunk, [(1.4, 1.4), (1.9, 1.9), (2.2, 2.4), (2.45, 2.8), (2.55, 3.0),
            (2.2, 2.4), (1.75, 1.95)], up = fwd)
    #keel and pectoral mass: the flight muscles of something this heavy
    M.ball(J['chest'] + V((0, -1.1, -0.7)), 2.1, (1.0, .85, 1.2))
    for s in (-1, 1):
        M.ball(V((s * 1.55, -0.9, 10.6)), 1.55, (1.0, 1.0, 1.25))
        M.ball(V((s * 1.9, 0.9, 7.6)), 1.6, (1.0, 1.1, 1.3))   # ribs
        M.ball(V((s * 1.45, 2.4, 4.7)), 1.7, (1.0, 1.2, 1.0))  # flank
    #neck: thick at the base, ropey under the jaw
    M.chain([J['withers'] + V((0, 0.3, -0.4))] + NECK + [J['head']],
            [(1.95, 2.15), (1.8, 2.0), (1.5, 1.7), (1.25, 1.45), (1.1, 1.25),
             (1.0, 1.1), (.95, 1.0)], up = fwd)
    #tail
    M.chain([J['pelvis'] + V((0, 0.8, 0.2))] + TAIL,
            [(1.6, 1.7), (1.45, 1.55), (1.2, 1.3), (1.0, 1.05), (.8, .82),
             (.62, .64), (.48, .48), (.36, .36), (.26, .26), (.17, .17), (.1, .1)],
            up = fwd)
    build_head_meta(M)
    for s, j in SIDES.items():
        sx = -1 if s == 'L' else 1
        #shoulder joint and wing-arm: humerus heavy with muscle, forearm lean
        M.chain([j['shoulder'], j['upperarm'], j['forearm']],
                [(1.35, 1.5), (1.4, 1.5), (.95, 1.0)], up = up)
        M.ball(j['upperarm'] + (j['forearm'] - j['upperarm']) * .28, 1.45, (1, 1.35, 1))
        M.chain([j['forearm'], j['hand']], [(.95, .95), (.66, .6)], up = up)
        M.ball(j['forearm'] + (j['hand'] - j['forearm']) * .22, .82, (1, 1.4, 1))
        M.ball(j['hand'], .62, (1, 1, .9))
        #thumb pad the claw grows from
        M.chain([j['hand'], j['hand'] + j['thumb_dir'] * .95], [(.5, .45), (.32, .3)],
                up = up)
        for base, knuckle, tip in j['fingers']:
            M.chain([base, knuckle], [(.5, .45), (.3, .28)], up = up)
            M.ball(knuckle, .34)
            M.chain([knuckle, tip], [(.28, .26), (.1, .1)], up = up)
        #hind leg: crouched, gripping the cliff
        M.chain([j['hip'], j['knee']], [(1.45, 1.6), (.95, 1.0)], up = fwd)
        M.ball(j['hip'] + (j['knee'] - j['hip']) * .3, 1.5, (1, 1.3, 1.1))
        M.chain([j['knee'], j['ankle']], [(.85, .9), (.55, .55)], up = fwd)
        M.chain([j['ankle'], j['toes']], [(.55, .5), (.4, .3)], up = up)
        for k in (-1, 0, 1):
            tip = j['toes'] + V((k * .5, -.8, .3))
            M.chain([j['toes'], tip], [(.26, .22), (.15, .13)], up = up)
    return M


#head frame helpers: a = along the skull axis (0 base .. SNOUT tip),
#s = sideways (+x), u = up the head
def hp(a, s, u):
    return J['head'] + (HEAD_DIR * a + V((1, 0, 0)) * s + HEAD_UP * u) * HS


def head_rot(extra_pitch = 0.0):
    x = V((1, 0, 0))
    y = HEAD_DIR
    z = HEAD_UP
    m = Matrix((x, y, z)).transposed()
    if extra_pitch:
        m = Matrix.Rotation(extra_pitch, 3, 'X') @ m
    return m.to_quaternion()


def build_head_meta(M):
    q = head_rot()
    #cranium, wide behind the eyes
    M.ball(hp(.5, 0, .1), 1.05 * HS, (1.15, 1.2, .95), q)
    #cheekbones / jaw muscle (masseters) bulging behind the eyes
    for s in (-1, 1):
        M.ball(hp(.9, s * .78, -.25), .62 * HS, (1.0, 1.5, 1.0), q)
        #brow ridge, heavy and low over the eye
        M.ball(hp(1.55, s * .62, .5), .36 * HS, (1.0, 2.0, .8), q)
        #nostril bump near the tip
        M.ball(hp(3.75, s * .26, .18), .17 * HS, (1.0, 1.3, .9), q)
    #snout: long, narrowing, flat on top
    M.chain([hp(1.0, 0, .05), hp(2.0, 0, -.02), hp(3.1, 0, -.08), hp(SNOUT - .15, 0, -.12)],
            [(.92 * HS, .78 * HS), (.68 * HS, .6 * HS), (.52 * HS, .46 * HS), (.36 * HS, .32 * HS)], up = HEAD_UP)
    #upper lip line, a little fuller than the snout
    M.chain([hp(1.2, 0, -.35), hp(2.4, 0, -.38), hp(3.6, 0, -.3)],
            [(.78 * HS, .4 * HS), (.56 * HS, .34 * HS), (.4 * HS, .26 * HS)], up = HEAD_UP)
    #eye sockets: carve the eye a seat under the brow
    for s in (-1, 1):
        M.ball(hp(1.42, s * .82, .22), .3 * HS, (1.0, 1.4, .9), q, neg = True)


def build_jaw_meta():
    M = Meta('JawMeta')
    q = head_rot()
    #lower jaw, hinge to chin, slightly narrower than the skull
    M.chain([J['jaw'], hp(1.6, 0, -.82), hp(2.8, 0, -.78), hp(SNOUT - .3, 0, -.62)],
            [(.78 * HS, .45 * HS), (.62 * HS, .4 * HS), (.48 * HS, .32 * HS), (.3 * HS, .22 * HS)], up = HEAD_UP)
    for s in (-1, 1):
        M.ball(hp(.95, s * .6, -.6), .46 * HS, (1.0, 1.6, .9), q)
    #throat pouch under the jaw
    M.ball(hp(1.3, 0, -1.0), .55 * HS, (1.2, 1.6, .9), q)
    return M


#=========================================================== hard surfaces ===

def horn(bm, pts, r0, r1 = .02, sides = 10, steps = 14, ridges = 0.0):
    """A tapering curved spike along a Catmull-Rom path; v runs base->tip."""
    samples = [p for p, t in catmull(pts, 30)]
    #resample to `steps`
    L = [0.0]
    for a, b in zip(samples, samples[1:]):
        L.append(L[-1] + (b - a).length)
    total = L[-1]
    ring_prev = None
    rings = []
    ref = V((0, 0, 1))
    for k in range(steps + 1):
        target = total * k / steps
        i = next((i for i, l in enumerate(L) if l >= target), len(L) - 1)
        p = samples[i]
        tan = (samples[min(i + 1, len(samples) - 1)] - samples[max(i - 1, 0)]).normalized()
        x = ref.cross(tan)
        if x.length < 1e-3:
            x = V((1, 0, 0)).cross(tan)
        x.normalize()
        y = tan.cross(x).normalized()
        t = k / steps
        r = r0 + (r1 - r0) * (t ** .85)
        ring = []
        for s in range(sides):
            a = 2 * math.pi * s / sides
            rr = r * (1 + ridges * math.cos(a * 3) * (1 - t))
            ring.append(bm.verts.new(p + (x * math.cos(a) + y * math.sin(a)) * rr))
        rings.append((ring, t))
    for (ra, ta), (rb, tb) in zip(rings, rings[1:]):
        for s in range(sides):
            f = bm.faces.new((ra[s], ra[(s + 1) % sides], rb[(s + 1) % sides], rb[s]))
    bm.faces.new(list(reversed(rings[0][0])))
    tip = bm.verts.new(samples[-1] + (samples[-1] - samples[-2]).normalized() * r1)
    last = rings[-1][0]
    for s in range(sides):
        bm.faces.new((last[s], last[(s + 1) % sides], tip))
    return total


def build_hard():
    """Horns, spines, claws: one object, keratin material; returns
    (mesh_object, islands) where islands lists (vert range, bone name)."""
    bm = bmesh.new()
    groups = []           # (first_vert_index, last_vert_index_excl, bone)
    rng = random.Random(7)

    def add(bone, fn):
        bm.verts.ensure_lookup_table()
        a = len(bm.verts)
        fn()
        bm.verts.ensure_lookup_table()
        groups.append((a, len(bm.verts), bone))

    side = V((1, 0, 0))
    #crown: two great horns sweeping back from the skull, then a row of
    #smaller ones down each side of the head (Drogon's frill of spikes)
    for s in (-1, 1):
        base = hp(.35, s * .55, .62)
        add('head', lambda base = base, s = s: horn(bm, [base,
                base + (-HEAD_DIR * 1.3 + HEAD_UP * .75 + side * s * .45) * HS,
                base + (-HEAD_DIR * 2.8 + HEAD_UP * .7 + side * s * .75) * HS,
                base + (-HEAD_DIR * 3.9 + HEAD_UP * -.1 + side * s * .85) * HS],
                .5, .02, 12, 18, .14))
        #a second, shorter pair behind and outside the first
        base2 = hp(.1, s * .85, .35)
        add('head', lambda base2 = base2, s = s: horn(bm, [base2,
                base2 + (-HEAD_DIR * .9 + HEAD_UP * .3 + side * s * .6) * HS,
                base2 + (-HEAD_DIR * 1.9 + HEAD_UP * .05 + side * s * .8) * HS],
                .3, .02, 10, 12, .1))
        for k, (a, u, ln) in enumerate(((.15, .2, 1.3), (.25, -.15, 1.0), (.45, -.45, .85),
                (.75, -.7, .7), (1.05, -.85, .55))):
            b0 = hp(a, s * (.92 if k else .8), u)
            d = (-HEAD_DIR * 1.0 + side * s * .45 - HEAD_UP * .15 * k).normalized()
            add('head', lambda b0 = b0, d = d, ln = ln, k = k: horn(bm, [b0, b0 + d * ln * .5 * HS
                    + HEAD_UP * .1, b0 + d * ln * 1.25 * HS], (.16 + .03 * (4 - k)), .015, 8, 8))
        #jaw frill
        for k, a in enumerate((.7, 1.1, 1.5, 1.9)):
            b0 = hp(a, s * .6, -.8)
            d = (-HEAD_DIR * .8 + side * s * .6 - HEAD_UP * .4).normalized()
            add('jaw', lambda b0 = b0, d = d, k = k: horn(bm, [b0, b0 + d * (.6 - .1 * k)],
                    .11 - .015 * k, .01, 7, 5))
        #brow spurs over the eyes
        b0 = hp(1.35, s * .7, .72)
        add('head', lambda b0 = b0, s = s: horn(bm, [b0, b0 - HEAD_DIR * .35 + HEAD_UP * .25
                + side * s * .12, b0 - HEAD_DIR * .75 + HEAD_UP * .3 + side * s * .2],
                .12, .01, 7, 7))
    #nasal horn
    b0 = hp(3.4, 0, .28)
    add('head', lambda: horn(bm, [b0, b0 + HEAD_UP * .35 - HEAD_DIR * .1], .1, .01, 7, 5))
    #dorsal spines, skull to tail tip: tall over the shoulders, a saw on the tail
    spine_path = [p for p, t in catmull([J['head'] + HEAD_UP * .6 - HEAD_DIR * .2] +
            list(reversed(NECK)) + [J['withers'], J['chest'] + V((0, 0, 0)),
            J['spine2'], J['spine1'], J['pelvis']] + TAIL[1:], 40)]
    L = [0.0]
    for a, b in zip(spine_path, spine_path[1:]):
        L.append(L[-1] + (b - a).length)
    total = L[-1]
    s_at = 0.6
    while s_at < total - .4:
        i = next(i for i, l in enumerate(L) if l >= s_at)
        p = spine_path[i]
        tan = (spine_path[min(i + 1, len(spine_path) - 1)] - spine_path[max(i - 1, 0)]).normalized()
        f = s_at / total
        #height profile: rises over the withers, falls to the tail
        h = .45 + 1.3 * math.exp(-((f - .2) / .16) ** 2) + .55 * math.exp(-((f - .45) / .2) ** 2)
        h *= rng.uniform(.85, 1.1) * (1 - .6 * max(0, f - .55) / .45)
        bone = nearest_bone_for_spine(p)
        dorsal = dorsal_normal(p, tan)
        root = p + dorsal * (body_radius_at(p, dorsal) - .08)
        tip = root + dorsal * h - tan * h * .55
        add(bone, lambda root = root, tip = tip, h = h, tan = tan, dorsal = dorsal: horn(bm,
                [root, root + dorsal * h * .55 - tan * h * .12, tip], .16 + .2 * h, .01, 8, 7))
        s_at += .5 + .45 * h
    #claws: thumb hook, toe claws
    for s, j in SIDES.items():
        t = j['thumb_dir']
        base = j['hand'] + t * .85
        down = t.cross(V((1, 0, 0))).normalized()
        if down.z > 0:
            down = -down
        add('hand.' + s, lambda base = base, t = t, down = down: horn(bm, [base, base + t * .7,
                base + t * 1.15 + down * .45, base + t * 1.25 + down * .95], .3, .01, 10, 12))
        sx = -1 if s == 'L' else 1
        for k in (-1, 0, 1):
            tipb = j['toes'] + V((k * .5, -.8, .3))
            add('toes.' + s, lambda tipb = tipb: horn(bm, [tipb, tipb + V((0, -.45, .05)),
                    tipb + V((0, -.6, -.45))], .17, .01, 8, 8))
        #a hooked claw on every wing knuckle, as bats and wyverns have
        for (base, knuckle, tip), bn in zip(j['fingers'], ('f1b', 'f2b', 'f3b')):
            d = (tip - knuckle).normalized()
            add(bn + '.' + s, lambda knuckle = knuckle, d = d: horn(bm, [knuckle, knuckle +
                    V((0, -.3, .25)), knuckle + V((0, -.45, .1))], .1, .01, 6, 5))
    me = bpy.data.meshes.new('Dragon_Hard')
    bm.to_mesh(me)
    bm.free()
    ob = bpy.data.objects.new('Dragon_Hard', me)
    bpy.context.scene.collection.objects.link(ob)
    me.materials.append(MATS['Dragon_Horn'])
    for p in me.polygons:
        p.use_smooth = True
    return ob, groups


SPINE_BONES = []


def nearest_bone_for_spine(p):
    best, bn = 1e9, 'chest'
    for name, a, b in SPINE_BONES:
        d = seg_dist(p, a, b)
        if d < best:
            best, bn = d, name
    return bn


def seg_dist(p, a, b):
    ab = b - a
    t = max(0.0, min(1.0, (p - a).dot(ab) / max(ab.length_squared, 1e-9)))
    return (a + ab * t - p).length


BODY_BVH = None


def body_radius_at(p, dorsal):
    """Distance from an axis point out to the hide along `dorsal`."""
    hit = BODY_BVH.ray_cast(p + dorsal * 8.0, -dorsal, 8.0)
    return 8.0 - hit[3] if hit[0] is not None else 1.0


def dorsal_normal(p, tan):
    #the dragon's back faces +y (behind) and up; at the neck it faces up/back
    n = V((0, .55, 1)).normalized()
    n = n - tan * n.dot(tan)
    return n.normalized()


#==================================================================== main ===

def add_mesh(name, me, mat):
    ob = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(ob)
    me.materials.clear()
    me.materials.append(MATS[mat])
    return ob


def remesh(ob, voxel):
    mod = ob.modifiers.new('rm', 'REMESH')
    mod.mode = 'VOXEL'
    mod.voxel_size = voxel
    mod.adaptivity = 0
    apply_all(ob)


def apply_all(ob):
    bpy.context.view_layer.objects.active = ob
    for o in bpy.context.scene.objects:
        o.select_set(o == ob)
    for m in list(ob.modifiers):
        bpy.ops.object.modifier_apply(modifier = m.name)


def decimate(ob, tris):
    cur = sum(len(p.vertices) - 2 for p in ob.data.polygons)
    if cur <= tris:
        return
    mod = ob.modifiers.new('dec', 'DECIMATE')
    mod.ratio = tris / cur
    apply_all(ob)


def smooth_mesh(ob, factor = .5, reps = 4):
    mod = ob.modifiers.new('sm', 'CORRECTIVE_SMOOTH')
    mod.factor = factor
    mod.iterations = reps
    mod.use_only_smooth = True
    mod.smooth_type = 'LENGTH_WEIGHTED'
    apply_all(ob)


def build_shape():
    materials()
    body = add_mesh('Dragon_Body', build_body_meta().mesh(), 'Dragon_Hide')
    remesh(body, MB_RES * .9)
    decimate(body, BODY_TRIS)
    jaw = add_mesh('Dragon_Jaw', build_jaw_meta().mesh(), 'Dragon_Hide')
    remesh(jaw, MB_RES * .6)
    decimate(jaw, 6000)
    for o in (body, jaw):
        for p in o.data.polygons:
            p.use_smooth = True
    global BODY_BVH
    bm = bmesh.new()
    bm.from_mesh(body.data)
    BODY_BVH = BVHTree.FromBMesh(bm)
    bm.free()
    hard, groups = build_hard()
    return {'body': body, 'jaw': jaw, 'hard': hard, 'hard_groups': groups}


#================================================================ previews ===

def look_at(obj, target):
    d = Vector(target) - obj.location
    obj.rotation_euler = d.to_track_quat('-Z', 'Y').to_euler()


def setup_scene():
    scene = bpy.context.scene
    scene.render.engine = 'BLENDER_EEVEE'
    scene.render.resolution_x = 1200
    scene.render.resolution_y = 1000
    scene.eevee.taa_render_samples = 48
    try:
        scene.eevee.use_raytracing = True
    except Exception:
        pass
    scene.view_settings.view_transform = 'AgX'
    scene.view_settings.exposure = .4
    world = bpy.data.worlds.new('Night')
    scene.world = world
    world.use_nodes = True
    bg = next(n for n in world.node_tree.nodes if n.type == 'BACKGROUND')
    bg.inputs['Color'].default_value = (.02, .028, .04, 1)
    bg.inputs['Strength'].default_value = 1.0

    def light(name, kind, loc, energy, color, size = 1, target = (0, 0, 10)):
        data = bpy.data.lights.new(name, kind)
        data.energy = energy
        data.color = color
        if kind == 'AREA':
            data.size = size
        ob = bpy.data.objects.new(name, data)
        scene.collection.objects.link(ob)
        ob.location = loc
        look_at(ob, target)
    light('Moon', 'SUN', (-30, -20, 40), 3.0, (.7, .8, 1.0))
    light('Rim', 'AREA', (10, 35, 25), 60000, (.75, .85, 1.0), 20)
    light('Fire', 'AREA', (6, -25, 4), 9000, (1.0, .45, .15), 10)
    light('Fill', 'AREA', (-25, -30, 12), 6000, (.5, .6, .8), 15)
    cam = bpy.data.objects.new('Cam', bpy.data.cameras.new('Cam'))
    scene.collection.objects.link(cam)
    scene.camera = cam
    cam.data.clip_end = 500
    #a slab of platform for scale
    bpy.ops.mesh.primitive_cylinder_add(radius = 14.7 / 1.48, depth = 1.0,
            location = (0, -5 - 14.7 / 1.48, 3.5), vertices = 48)
    plat = bpy.context.active_object
    plat.name = 'Platform'
    pm = bpy.data.materials.new('PlatformMat')
    pm.use_nodes = True
    next(n for n in pm.node_tree.nodes if n.type == 'BSDF_PRINCIPLED').inputs[
            'Base Color'].default_value = (.08, .08, .085, 1)
    plat.data.materials.append(pm)
    return cam


def render(cam, name, loc, target, lens):
    if ONLY and name not in ONLY:
        return
    cam.location = loc
    cam.data.lens = lens
    look_at(cam, target)
    bpy.context.scene.render.filepath = str(PREVIEW / (name + '.png'))
    bpy.ops.render.render(write_still = True)
    print('rendered', name)


def previews():
    PREVIEW.mkdir(parents = True, exist_ok = True)
    cam = setup_scene()
    #the player's view: from the platform, looking up at it
    render(cam, 'player_view', (4, -22, 6.5), (0, -2, 11.5), 24)
    render(cam, 'three_quarter', (34, -40, 14), (0, 0, 8), 40)
    render(cam, 'side', (55, -2, 9), (0, 2, 7), 35)
    render(cam, 'head', (7, -14, 17), hp(2.0, 0, 0), 45)
    render(cam, 'back', (-20, 40, 22), (0, 2, 8), 40)


#=================================================================== rig =====

def bone_table():
    """(name, head, tail, parent, deform) for every bone, rest pose."""
    B = []
    B.append(('pelvis', J['pelvis'], J['spine1'], None, True))
    B.append(('spine1', J['spine1'], J['spine2'], 'pelvis', True))
    B.append(('spine2', J['spine2'], J['chest'], 'spine1', True))
    B.append(('chest', J['chest'], J['withers'], 'spine2', True))
    prev = 'chest'
    pts = NECK + [J['head']]
    for k in range(len(NECK)):
        B.append(('neck%d' % (k + 1), pts[k], pts[k + 1], prev, True))
        prev = 'neck%d' % (k + 1)
    B.append(('head', J['head'], hp(SNOUT, 0, 0), prev, True))
    B.append(('jaw', J['jaw'], hp(SNOUT - .3, 0, -.7), 'head', True))
    B.append(('mouth', J['mouth'], J['mouth'] + HEAD_DIR * .6, 'head', False))
    #markers: Godot only sees joint positions, so every point the game needs
    #is the HEAD of some bone
    B.append(('snout', hp(SNOUT, 0, 0), hp(SNOUT + .3, 0, 0), 'head', False))
    B.append(('core', J['core'], J['core'] + V((0, -.6, 0)), 'chest', False))
    prev = 'pelvis'
    for k in range(len(TAIL) - 1):
        B.append(('tail%d' % (k + 1), TAIL[k], TAIL[k + 1], prev, True))
        prev = 'tail%d' % (k + 1)
    B.append(('tailtip', TAIL[-1], TAIL[-1] + (TAIL[-1] - TAIL[-2]).normalized() * .3, prev, False))
    for s, j in SIDES.items():
        B.append(('shoulder.' + s, j['shoulder'], j['upperarm'], 'chest', True))
        B.append(('upperarm.' + s, j['upperarm'], j['forearm'], 'shoulder.' + s, True))
        B.append(('forearm.' + s, j['forearm'], j['hand'], 'upperarm.' + s, True))
        B.append(('hand.' + s, j['hand'], j['hand'] + j['thumb_dir'] * .9, 'forearm.' + s, True))
        B.append(('fist.' + s, j['fist'], j['fist'] + j['thumb_dir'] * .3, 'hand.' + s, False))
        for k, (base, knuckle, tip) in enumerate(j['fingers']):
            a = 'f%da.%s' % (k + 1, s)
            B.append((a, base, knuckle, 'hand.' + s, True))
            B.append(('f%db.%s' % (k + 1, s), knuckle, tip, a, True))
            B.append(('f%dt.%s' % (k + 1, s), tip, tip + (tip - knuckle).normalized() * .3,
                    'f%db.%s' % (k + 1, s), False))
        B.append(('thigh.' + s, j['hip'], j['knee'], 'pelvis', True))
        B.append(('shin.' + s, j['knee'], j['ankle'], 'thigh.' + s, True))
        B.append(('foot.' + s, j['ankle'], j['toes'], 'shin.' + s, True))
        B.append(('toes.' + s, j['toes'], j['toes'] + V((0, -.8, .3)), 'foot.' + s, True))
    return B


BONES = bone_table()
BONE_SEG = {b[0]: (b[1], b[2]) for b in BONES}
SPINE_BONES[:] = [(b[0], b[1], b[2]) for b in BONES if b[0].startswith(('neck', 'tail',
        'spine', 'chest', 'pelvis', 'head'))]


def build_rig():
    arm = bpy.data.armatures.new('Dragon_Rig')
    ob = bpy.data.objects.new('Dragon_Rig', arm)
    bpy.context.scene.collection.objects.link(ob)
    bpy.context.view_layer.objects.active = ob
    for o in bpy.context.scene.objects:
        o.select_set(o == ob)
    bpy.ops.object.mode_set(mode = 'EDIT')
    eb = {}
    for name, h, t, parent, deform in BONES:
        b = arm.edit_bones.new(name)
        b.head = h
        b.tail = t
        b.use_deform = deform
        #roll: +Z of every bone toward the sky/back, so Godot rests are sane
        b.align_roll(V((0, .3, 1)))
        if parent:
            b.parent = eb[parent]
            b.use_connect = False
        eb[name] = b
    bpy.ops.object.mode_set(mode = 'OBJECT')
    return ob


def bind_auto(mesh_ob, rig):
    for o in bpy.context.scene.objects:
        o.select_set(o in (mesh_ob, rig))
    bpy.context.view_layer.objects.active = rig
    bpy.ops.object.parent_set(type = 'ARMATURE_AUTO')
    #a bone heat failure leaves verts unweighted: give them their nearest bone
    groups = {g.index: g.name for g in mesh_ob.vertex_groups}
    lost = [v for v in mesh_ob.data.vertices if not any(g.weight > 1e-4 for g in v.groups)]
    for v in lost:
        bind_vertex(mesh_ob, v.index, nearest_bones(mesh_ob.matrix_world @ v.co, 1))
    print('bone heat: %d / %d vertices unweighted -> nearest bone' % (len(lost),
            len(mesh_ob.data.vertices)))


def bind_vertex(ob, vi, pairs):
    for name, w in pairs:
        g = ob.vertex_groups.get(name) or ob.vertex_groups.new(name = name)
        g.add([vi], w, 'REPLACE')


def nearest_bones(p, n, only = None, falloff = 4.0, soft = .35):
    ds = []
    for name, (a, b) in BONE_SEG.items():
        if only is not None and name not in only:
            continue
        if not next(b[4] for b in BONES if b[0] == name):
            continue
        ds.append((seg_dist(p, a, b), name))
    ds.sort()
    ds = ds[:n]
    ws = [(name, 1.0 / (d + soft) ** falloff) for d, name in ds]
    tot = sum(w for _, w in ws)
    return [(name, w / tot) for name, w in ws]


def bind_custom(ob, rig, fn):
    ob.parent = rig
    mod = ob.modifiers.new('Armature', 'ARMATURE')
    mod.object = rig
    for v in ob.data.vertices:
        bind_vertex(ob, v.index, fn(v))


#============================================================== membrane =====

def coons(c0, c1, d0, d1, nu, nv):
    """c0(u), c1(u): bottom/top edges; d0(v), d1(v): left/right edges.
    Returns grid[i][j] = point at (u_i, v_j)."""
    P00, P10, P01, P11 = c0(0), c0(1), c1(0), c1(1)
    g = []
    for i in range(nu + 1):
        u = i / nu
        row = []
        for j in range(nv + 1):
            v = j / nv
            p = (c0(u) * (1 - v) + c1(u) * v + d0(v) * (1 - u) + d1(v) * u
                    - (P00 * (1 - u) * (1 - v) + P10 * u * (1 - v) + P01 * (1 - u) * v
                    + P11 * u * v))
            row.append(p)
        g.append(row)
    return g


def polyline(pts):
    L = [0.0]
    for a, b in zip(pts, pts[1:]):
        L.append(L[-1] + (b - a).length)

    def f(t):
        x = t * L[-1]
        for k in range(len(pts) - 1):
            if x <= L[k + 1] or k == len(pts) - 2:
                seg = max(L[k + 1] - L[k], 1e-9)
                return pts[k].lerp(pts[k + 1], (x - L[k]) / seg)
    return f


def scallop(a, b, toward, depth):
    #a trailing edge sagging between two finger tips
    return lambda t: a.lerp(b, t) + (toward - a.lerp(b, t)).normalized() * depth * math.sin(
            math.pi * t)


def build_membrane():
    bm = bmesh.new()
    uv = bm.loops.layers.uv.new('UVMap')
    wing_of = []        # side per vertex

    def patch(grid, side, u0, u1, vscale):
        nu = len(grid) - 1
        nv = len(grid[0]) - 1
        vs = [[bm.verts.new(p) for p in row] for row in grid]
        for row in vs:
            for _ in row:
                wing_of.append(side)
        for i in range(nu):
            for j in range(nv):
                q = (vs[i][j], vs[i + 1][j], vs[i + 1][j + 1], vs[i][j + 1])
                if len({id(x) for x in q}) < 4 or len({x.co.to_tuple(4) for x in q}) < 3:
                    continue
                try:
                    f = bm.faces.new(q)
                except ValueError:
                    continue
                for loop, (a, b) in zip(f.loops, ((i, j), (i + 1, j), (i + 1, j + 1), (i, j + 1))):
                    loop[uv].uv = (u0 + (u1 - u0) * a / nu, b / nv * vscale)

    for s, j in SIDES.items():
        sx = -1 if s == 'L' else 1
        W = j['hand']
        (b1, k1, t1), (b2, k2, t2), (b3, k3, t3) = j['fingers']
        S = j['upperarm'] + V((0, .4, -.3))
        E = j['forearm']
        D = V((sx * 2.0, 3.4, 2.6))       # attaches along the flank to the thigh
        mid = V((sx * 2.4, 2.4, 7.5))
        body_c = V((sx * 1.0, 2.0, 6.0))
        #inner panel (plagiopatagium): arm + finger 3 against the flank
        c0 = lambda u: polyline([S, E, W, k3, t3])(u)
        c1 = lambda u: polyline([S, mid, D])(u * .999)
        nu, nv = 26, 12
        grid = []
        for i in range(nu + 1):
            u = i / nu
            a = c0(u)
            #the matching point on the body side; the last stretch closes
            #along the trailing edge from t3 down to the thigh
            b = c1(u)
            row = []
            for jv in range(nv + 1):
                v = jv / nv
                p = a.lerp(b, v)
                #billow: membrane bellies outward/down between its bones
                #skin, not a board: a deep billow between arm and flank, and
                #folds running from the arm bones to the trailing edge
                belly = math.sin(math.pi * v) * math.sin(math.pi * u) * 1.6
                folds = math.sin(u * math.pi * 14) * math.sin(math.pi * v) ** .7 * .22
                p += V((sx * .25, .35, -1.0)).normalized() * (belly + folds)
                row.append(p)
            grid.append(row)
        patch(grid, s, 0, 6, 3)
        #finger panels: fan from the wrist, trailing edge scalloped toward it
        for (ka, ta), (kb, tb), u0 in (((k3, t3), (k2, t2), 6), ((k2, t2), (k1, t1), 9)):
            ea = polyline([W, ka, ta])
            eb = polyline([W, kb, tb])
            tr = scallop(ta, tb, W, ((ta - tb).length) * .22)
            nu, nv = 10, 18
            grid = []
            for i in range(nu + 1):
                u = i / nu
                row = []
                for jv in range(nv + 1):
                    v = jv / nv
                    #blend the two finger edges, ending on the scalloped edge
                    p = ea(v).lerp(eb(v), u)
                    edge = tr(u)
                    lin = ta.lerp(tb, u)
                    p = p + (edge - lin) * (v ** 3)
                    p += V((0, .2, -.6)) * math.sin(math.pi * u) * math.sin(math.pi * v) * .9
                    #radial folds between the finger bones
                    p += V((0, .2, -.6)).normalized() * math.sin(u * math.pi * 5) \
                            * math.sin(math.pi * v) ** .6 * .18
                    row.append(p)
                grid.append(row)
            patch(grid, s, u0, u0 + 3, 4)
    bmesh.ops.remove_doubles(bm, verts = bm.verts[:], dist = 1e-4)
    me = bpy.data.meshes.new('Dragon_Wings')
    bm.to_mesh(me)
    bm.free()
    for p in me.polygons:
        p.use_smooth = True
    ob = bpy.data.objects.new('Dragon_Wings', me)
    bpy.context.scene.collection.objects.link(ob)
    me.materials.append(MATS['Dragon_Membrane'])
    return ob


#=================================================================== UVs =====

CHAINS = {
    #name: (bones root->tip, scale tiles around the circumference)
    'axis': (['tail9', 'tail8', 'tail7', 'tail6', 'tail5', 'tail4', 'tail3', 'tail2', 'tail1',
              'pelvis', 'spine1', 'spine2', 'chest', 'neck1', 'neck2', 'neck3', 'neck4',
              'neck5', 'head'], 4),
}
for _s in ('L', 'R'):
    CHAINS['arm' + _s] = (['shoulder.' + _s, 'upperarm.' + _s, 'forearm.' + _s, 'hand.' + _s], 3)
    CHAINS['leg' + _s] = (['thigh.' + _s, 'shin.' + _s, 'foot.' + _s, 'toes.' + _s], 4)
    for _k in (1, 2, 3):
        CHAINS['f%d%s' % (_k, _s)] = (['f%da.%s' % (_k, _s), 'f%db.%s' % (_k, _s)], 2)


def chain_frames():
    """Per bone: (chain, start arclength, tiles around)."""
    out = {}
    for cname, (bones, tiles) in CHAINS.items():
        acc = 0.0
        for bn in bones:
            a, b = BONE_SEG[bn]
            #the axis runs tail-tip -> head, against the tail bones' direction
            rev = cname == 'axis' and bn.startswith('tail')
            out[bn] = (cname, acc, tiles, rev)
            acc += (b - a).length
    return out


def body_uvs(ob):
    """Cylindrical UVs around the nearest skeleton segment: u around (seam on
    the dorsal line, under the spines), v along the chain with a rate that
    follows the local girth, so scales stay square on thick and thin parts."""
    frames = chain_frames()
    me = ob.data
    if not me.uv_layers:
        me.uv_layers.new(name = 'UVMap')
    uvl = me.uv_layers[0].data
    #local radius per bone (mean vertex distance), for the v rate
    near = {}
    radius = {}
    for v in me.vertices:
        p = ob.matrix_world @ v.co
        best, bn = 1e9, None
        for name, (cname, acc, tiles, rev) in frames.items():
            a, b = BONE_SEG[name]
            d = seg_dist(p, a, b)
            if d < best:
                best, bn = d, name
        near[v.index] = (bn, best)
        radius.setdefault(bn, []).append(best)
    radius = {k: max(.1, sum(r) / len(r)) for k, r in radius.items()}
    per_vert = {}
    belly = {}
    for v in me.vertices:
        p = ob.matrix_world @ v.co
        bn, d = near[v.index]
        cname, acc, tiles, rev = frames[bn]
        a, b = BONE_SEG[bn]
        ax = (b - a)
        L = ax.length
        ax = ax / L
        t = max(0.0, min(1.0, (p - a).dot(ax) / L))
        if rev:
            t = 1 - t
            ax = -ax
        along = acc + t * L
        dorsal = V((0, .55, 1.0)) if cname == 'axis' else V((0, 0, 1.0))
        if cname.startswith(('f', 'arm')):
            dorsal = V((0, .3, 1.0))
        dorsal = (dorsal - ax * dorsal.dot(ax)).normalized()
        side = ax.cross(dorsal)
        r = p - (a + (b - a) * (1 - t if rev else t))
        ang = math.atan2(r.dot(side), r.dot(dorsal))      # 0 on the dorsal line
        u = (ang / (2 * math.pi) + .5) * tiles
        circ = 2 * math.pi * radius[bn]
        vv = along / max(circ / tiles, .25)
        per_vert[v.index] = (u, vv)
        belly[v.index] = cname == 'axis' and abs(ang) > math.radians(125) \
                and bn not in ('head',)
    #faces: fix the wrap across the seam (u jumps by `tiles`)
    for poly in me.polygons:
        us = [per_vert[me.loops[li].vertex_index][0] for li in poly.loop_indices]
        lo, hi = min(us), max(us)
        tiles = frames[near[me.loops[poly.loop_indices[0]].vertex_index][0]][2]
        for li in poly.loop_indices:
            u, vv = per_vert[me.loops[li].vertex_index]
            if hi - lo > tiles * .5 and u < tiles * .5:
                u += tiles
            uvl[li].uv = (u, vv)
        if sum(belly[me.loops[li].vertex_index] for li in poly.loop_indices) >= 2:
            poly.material_index = 1
    return near


def hard_uvs(ob):
    #keratin streaks run base -> tip: v along the spike, u around it
    me = ob.data
    if not me.uv_layers:
        me.uv_layers.new(name = 'UVMap')
    uvl = me.uv_layers[0].data
    for poly in me.polygons:
        for k, li in enumerate(poly.loop_indices):
            co = me.vertices[me.loops[li].vertex_index].co
            uvl[li].uv = ((co.x + co.y) * .7, co.z * .5)


#========================================================= vertex colour =====

def zone_colours(ob, near):
    """Large-scale colour zones in a colour attribute (AO multiplies in later):
    the back and the wing-arms darker, a smoulder of red down the flanks and
    under the jaw, the belly a shade warmer."""
    me = ob.data
    attr = me.color_attributes.get('Col') or me.color_attributes.new('Col', 'BYTE_COLOR', 'CORNER')
    for poly in me.polygons:
        for li in poly.loop_indices:
            vi = me.loops[li].vertex_index
            co = ob.matrix_world @ me.vertices[vi].co
            n = (ob.matrix_world.to_3x3() @ me.vertices[vi].normal).normalized()
            up = max(0.0, n.dot(V((0, .5, 1)).normalized()))
            down = max(0.0, -n.z)
            bn = near[vi][0] if near else ''
            c = V((1.0, 1.0, 1.0)) * (1.0 - .35 * up)
            #ember undertone low on the flanks and under the neck
            red = .55 * down * (1.0 if bn and bn.startswith(('neck', 'chest', 'spine', 'head')) else .4)
            c = V((c.x + red * .9, c.y + red * .15, c.z + red * .05))
            attr.data[li].color = (min(c.x, 2.0) * .8, c.y * .8, c.z * .8, 1)


def bake_ao(objs, samples = 32):
    scene = bpy.context.scene
    old = scene.render.engine
    scene.render.engine = 'CYCLES'
    scene.cycles.samples = samples
    scene.cycles.device = 'CPU'
    for ob in objs:
        me = ob.data
        ao = me.color_attributes.get('AO') or me.color_attributes.new('AO', 'BYTE_COLOR', 'CORNER')
        me.color_attributes.active_color = ao
        for o in bpy.context.scene.objects:
            o.select_set(o == ob)
        bpy.context.view_layer.objects.active = ob
        bpy.ops.object.bake(type = 'AO', target = 'VERTEX_COLORS')
        col = me.color_attributes.get('Col')
        if col is not None:
            for k in range(len(col.data)):
                a = ao.data[k].color
                c = col.data[k].color
                f = .25 + .75 * a[0]
                col.data[k].color = (c[0] * f, c[1] * f, c[2] * f, c[3])
            me.color_attributes.remove(ao)
            me.color_attributes.active_color = me.color_attributes.get('Col')
    scene.render.engine = old


def glow_masks(ob, near):
    """Where fire shows through the hide (the skin shader lights the scale
    seams there): the chest (the core), the throat (the breath's tell) and
    the wrist knuckles (a pinned fist's weak point), packed into UV2 --
    glTF drops vertex-colour alpha."""
    me = ob.data
    while len(me.uv_layers) < 2:
        me.uv_layers.new(name = 'Masks')
    mk = me.uv_layers[1].data
    col = me.color_attributes.get('Col')
    for poly in me.polygons:
        for li in poly.loop_indices:
            vi = me.loops[li].vertex_index
            p = ob.matrix_world @ me.vertices[vi].co
            n = (ob.matrix_world.to_3x3() @ me.vertices[vi].normal).normalized()
            #chest: a broad patch on the breast, facing the platform
            d = (p - (J['core'] + V((0, .4, 0)))).length
            chest = math.exp(-(d / 1.9) ** 2) * max(0.0, -n.y) ** .5
            #throat: the underside of the neck up into the jaw
            throat = 0.0
            if near is None:
                #the jaw: only a faint underglow, the throat behind it carries the tell
                throat = max(0.0, -n.dot(HEAD_UP)) ** 4 * .22
            else:
                bn = near[vi][0]
                if bn.startswith('neck'):
                    t = (p - NECK[0]).length / ((J['head'] - NECK[0]).length + 1e-6)
                    down = max(0.0, n.dot(V((0, -.75, -1)).normalized()))
                    throat = down ** 3 * min(1.0, t * 1.4)
            #packed: (chest, throat) >= 0; a left wrist is (-w, 0), a right
            #wrist (0, -w) -- the regions never overlap.  glTF flips v, so
            #store 1 - y to have Godot read y.
            x, y = min(1.0, chest * 1.3), min(1.0, throat)
            for s_, j in SIDES.items():
                c = j['hand'] + j['thumb_dir'] * .35
                w = min(1.0, 1.4 * math.exp(-((p - c).length / .95) ** 2))
                if w > .03 and w > max(x, y):
                    x, y = (-w, 0.0) if s_ == 'L' else (0.0, -w)
            mk[li].uv = (x, 1.0 - y)


#================================================================= export ====

def export(objs, rig):
    OUT.mkdir(parents = True, exist_ok = True)
    for o in bpy.context.scene.objects:
        o.select_set(o in objs or o == rig)
    bpy.ops.export_scene.gltf(filepath = str(OUT / 'dragon.glb'),
            export_format = 'GLB', use_selection = True, export_yup = True,
            export_apply = False, export_texcoords = True,
            export_normals = True, export_materials = 'EXPORT',
            export_skins = True, export_animations = False,
            export_vertex_color = 'ACTIVE', export_all_vertex_colors = False)
    bpy.context.preferences.filepaths.save_version = 0
    bpy.ops.wm.save_as_mainfile(filepath = str(OUT / 'dragon.blend'))


def build_all():
    parts = build_shape()
    body, jaw, hard, groups = parts['body'], parts['jaw'], parts['hard'], parts['hard_groups']
    body.data.materials.append(MATS['Dragon_Belly'])
    near = body_uvs(body)
    jaw_near = {v.index: ('jaw', 0) for v in jaw.data.vertices}
    jaw.data.materials.append(MATS['Dragon_Belly'])
    body_uvs_simple(jaw)
    hard_uvs(hard)
    wings = build_membrane()
    eyes, core, embers, teeth, mouth, pupils = build_details()
    rig = build_rig()
    bind_auto(body, rig)
    bind_custom(jaw, rig, lambda v: [('jaw', 1.0)])
    bone_of = {}
    for a, b, bn in groups:
        for k in range(a, b):
            bone_of[k] = bn
    bind_custom(hard, rig, lambda v: [(bone_of.get(v.index, 'head'), 1.0)])
    wing_bones = {s: ['upperarm.' + s, 'forearm.' + s, 'hand.' + s, 'f1a.' + s, 'f1b.' + s,
            'f2a.' + s, 'f2b.' + s, 'f3a.' + s, 'f3b.' + s, 'spine1', 'spine2', 'chest',
            'pelvis', 'thigh.' + s] for s in ('L', 'R')}
    bind_custom(wings, rig, lambda v: nearest_bones(v.co, 3,
            wing_bones['L' if v.co.x < 0 else 'R'], 4.0, .6))
    for ob, bn in ((eyes, 'head'), (pupils, 'head'), (mouth, 'head')):
        bind_custom(ob, rig, lambda v, bn = bn: [(bn, 1.0)])
    for ob in [core] + embers:
        if ob is not None:
            bpy.data.objects.remove(ob)
    bind_custom(teeth, rig, lambda v: [('jaw' if v.index in TEETH_LOWER else 'head', 1.0)])
    for ob in (body, jaw, hard):
        zone_colours(ob, near if ob == body else None)
    bake_ao([body, jaw, hard])
    glow_masks(body, near)
    glow_masks(jaw, None)
    return rig, [body, jaw, hard, wings, eyes, pupils, teeth, mouth]


def body_uvs_simple(ob):
    me = ob.data
    if not me.uv_layers:
        me.uv_layers.new(name = 'UVMap')
    uvl = me.uv_layers[0].data
    for poly in me.polygons:
        for li in poly.loop_indices:
            co = me.vertices[me.loops[li].vertex_index].co
            uvl[li].uv = (co.x * .45, (co.y * .9 + co.z * .43) * .45)


TEETH_LOWER = set()


def teeth_lower(co):
    #lower teeth were built below the lip line
    rel = co - J['head']
    return rel.dot(HEAD_UP) < -.55 * HS


def build_details():
    #eyes: amber, slit pupils, set under the brow
    bm = bmesh.new()
    for s in (-1, 1):
        c = hp(1.42, s * .78, .22)
        m = Matrix.Translation(c) @ Matrix.Diagonal((.15 * HS, .22 * HS, .13 * HS, 1))
        bmesh.ops.create_uvsphere(bm, u_segments = 16, v_segments = 10, radius = 1.0, matrix = m)
    eyes = mesh_from(bm, 'Dragon_Eyes', 'Colossus_Eye')
    bm = bmesh.new()
    for s in (-1, 1):
        #a vertical slit just proud of the eye's outer face
        #a black slit standing proud of the eye's outer face, tall and thin,
        #so it reads at fighting distance (a small one sank into the glow)
        c = hp(1.42, s * .78, .22) + V((s * .15 * HS, 0, 0))
        m = Matrix.Translation(c) @ Matrix.Diagonal((.035 * HS, .05 * HS, .135 * HS, 1))
        bmesh.ops.create_uvsphere(bm, u_segments = 10, v_segments = 8, radius = 1.0, matrix = m)
    pupils = mesh_from(bm, 'Dragon_Pupils', 'Dragon_Pupil')
    #chest fire: a glowing seam between the chest scutes (the core)
    bm = bmesh.new()
    c = J['core'] + V((0, .62, 0))
    m = Matrix.Translation(c) @ Matrix.Diagonal((1.25, .62, 1.7, 1))
    bmesh.ops.create_uvsphere(bm, u_segments = 24, v_segments = 16, radius = 1.0, matrix = m)
    core = mesh_from(bm, 'Dragon_Core', 'Dragon_Core')
    uvl = core.data.uv_layers[0].data
    for poly in core.data.polygons:
        for li in poly.loop_indices:
            co = core.data.vertices[core.data.loops[li].vertex_index].co
            uvl[li].uv = (co.x * .45 + .5, co.z * .3)
    #wrist embers: a molten seam over each wrist knuckle (the pinned weak point)
    embers = []
    for s, j in SIDES.items():
        bm = bmesh.new()
        c = j['hand'] + j['thumb_dir'] * .45 + V((0, 0, .35))
        m = Matrix.Translation(c) @ Matrix.Diagonal((.38, .38, .26, 1))
        bmesh.ops.create_icosphere(bm, subdivisions = 2, radius = 1.0, matrix = m)
        embers.append(mesh_from(bm, 'Dragon_Ember_' + s, 'Colossus_Ember'))
    #teeth: rows of uneven fangs on both jaws
    bm = bmesh.new()
    rng = random.Random(3)
    for s in (-1, 1):
        for k in range(11):
            a = 1.2 + k * .26 + rng.uniform(-.05, .05)
            w = (.62 - .028 * k) * s
            ln = (.28 if k in (2, 3) else .16) * rng.uniform(.7, 1.15)
            top = hp(a, w, -.36)
            bm.verts.ensure_lookup_table()
            n0 = len(bm.verts)
            horn(bm, [top, top - HEAD_UP * ln * HS * .6 + HEAD_DIR * .03, top - HEAD_UP * ln * HS],
                    .04 * HS, .004, 6, 5)
            bm.verts.ensure_lookup_table()
            n1 = len(bm.verts)
            bot = hp(a + .1, w * .92, -.66)
            horn(bm, [bot, bot + HEAD_UP * ln * HS * .55, bot + HEAD_UP * ln * HS * .9 - HEAD_DIR * .03],
                    .036 * HS, .004, 6, 5)
            bm.verts.ensure_lookup_table()
            #whole teeth to one jaw each: a tooth split by a height test
            #stretched into a white string when the mouth opened
            TEETH_LOWER.update(range(n1, len(bm.verts)))
    teeth = mesh_from(bm, 'Dragon_Teeth', 'Dragon_Teeth')
    #the mouth: a dark gullet behind the lips, seen when the jaw drops
    bm = bmesh.new()
    m = Matrix.Translation(hp(1.9, 0, -.5)) @ Matrix(head_rot().to_matrix()).to_4x4() @ \
            Matrix.Diagonal((.5 * HS, 1.4 * HS, .22 * HS, 1))
    bmesh.ops.create_uvsphere(bm, u_segments = 16, v_segments = 10, radius = 1.0, matrix = m)
    mouth = mesh_from(bm, 'Dragon_Mouth', 'Dragon_Mouth')
    return eyes, None, embers, teeth, mouth, pupils


def mesh_from(bm, name, mat):
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    for p in me.polygons:
        p.use_smooth = True
    ob = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(ob)
    me.materials.append(MATS[mat])
    if not me.uv_layers:
        me.uv_layers.new(name = 'UVMap')
    return ob


def main():
    bpy.ops.wm.read_factory_settings(use_empty = True)
    OUT.mkdir(parents = True, exist_ok = True)
    if STAGE == 'shape':
        build_shape()
        if RENDER:
            previews()
        return
    rig, objs = build_all()
    export(objs, rig)
    if RENDER:
        previews()


main()
