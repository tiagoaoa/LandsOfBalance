#Original lizard-man sculpt, guided by kusumo's Lizardman DnD preview.
#Run through Blender MCP. Metres, -Y forward, Z up; combat pivots stay rigid.
import ast
import math
from pathlib import Path

import bpy
import bmesh
import numpy as np
from mathutils import Vector, Matrix
from mathutils.bvhtree import BVHTree


ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'assets/characters/lizard'
V = Vector

#Use the existing mesh primitives without executing the old model build.
src = ROOT / 'tools/build_lizard.py'
tree = ast.parse(src.read_text())
tree.body.pop()  #the final main() call
g = {'__file__': str(src), '__name__': 'lizard_mesh'}
exec(compile(tree, str(src), 'exec'), g)
Part, loft, finish = [g[n] for n in ['Part', 'loft', 'finish']]
sphere, tube, spline = [g[n] for n in ['sphere', 'tube', 'spline']]
SKIN, BONE, CORE, EYE, IRON, BELLY, TOOTH, BLACK, IRIS, MOUTH = range(10)
NOSTRIL = 10
bpy.ops.wm.open_mainfile(filepath = str(OUT / 'lizard.blend'))
for ob in list(bpy.data.objects):
    bpy.data.objects.remove(ob, do_unlink = True)
mats = [bpy.data.materials[n] for n in g['MAT_NAMES']]
parts = {}
g['SMOOTH'][NOSTRIL] = True
g['SMOOTH'][CORE] = True
g['SMOOTH'][EYE] = True
g['SMOOTH'][BLACK] = True


def image(name, data, linear = False):
    h, w = data.shape[:2]
    img = bpy.data.images.new(name, w, h, alpha = False)
    if linear:
        img.colorspace_settings.name = 'Non-Color'
    rgba = np.ones((h, w, 4), dtype = np.float32)
    rgba[:, :, :3] = data
    img.pixels.foreach_set(rgba.ravel())
    img.filepath_raw = str(OUT / (name + '.png'))
    img.file_format = 'PNG'
    img.save()
    return img


def scale_height(n, cells, jitter):
    rng = np.random.default_rng(318)
    centers = rng.uniform(-jitter, jitter, (cells, cells, 2))
    y, x = np.mgrid[0:n, 0:n].astype(np.float32) * cells / n
    x += .10 * np.sin(y * math.tau * .8) + .025 * np.sin(y * math.tau * 1.5 + x * 3)
    y += .09 * np.sin(x * math.tau * .65) + .025 * np.sin(x * math.tau * 1.4 - y)
    ix, iy = np.floor(x).astype(int), np.floor(y).astype(int)
    nearest = np.full((n, n), 99, dtype = np.float32)
    second = nearest.copy()
    pigment = nearest.copy()
    for dy in [-1, 0, 1]:
        for dx in [-1, 0, 1]:
            cx, cy = ix + dx, iy + dy
            offset = centers[cy % cells, cx % cells]
            d = (x - cx - .5 - offset[:, :, 0]) ** 2
            d += (y - cy - .5 - offset[:, :, 1]) ** 2
            hit = d < nearest
            second = np.minimum(second, np.where(hit, nearest, d))
            nearest = np.minimum(nearest, d)
            value = .80 + .21 * np.sin(cx * 17.3 + cy * 31.1)
            pigment = np.where(hit, value, pigment)
    edge = np.maximum(0, np.sqrt(second) - np.sqrt(nearest))
    dome = (1 - np.exp(-edge * 30)) * (.30 + .70 * np.exp(-nearest * 3.5))
    grain = g['tile_noise'](n, 29, 1.7)
    folds = np.sin(y * math.tau * 8 + x * 3) * np.sin(x * math.tau * 5 - y)
    return dome + grain * .06 + folds * .003, pigment, grain


def texture_set(name, color, cells, jitter):
    height, pigment, grain = scale_height(2048, cells, jitter)
    light = (.43 + .27 * height + .47 * grain) * pigment
    rgb = light[:, :, None] * np.array(color)
    albedo = image(name + '_albedo', rgb)
    normal = image(name + '_normal', g['normal_map'](height, 32), True)
    rough = .62 + .19 * (1 - height) + grain * .07
    roughness = image(name + '_roughness', np.repeat(rough[:, :, None], 3, 2), True)
    return albedo, normal, roughness


def texture_material(mat, textures):
    nodes, links = mat.node_tree.nodes, mat.node_tree.links
    nodes.clear()
    output = nodes.new('ShaderNodeOutputMaterial')
    bsdf = nodes.new('ShaderNodeBsdfPrincipled')
    links.new(bsdf.outputs['BSDF'], output.inputs['Surface'])
    for img, socket in zip(textures, ['Base Color', 'Normal', 'Roughness']):
        tex = nodes.new('ShaderNodeTexImage')
        tex.image = img
        if socket == 'Normal':
            normal = nodes.new('ShaderNodeNormalMap')
            normal.inputs['Strength'].default_value = .72
            links.new(tex.outputs['Color'], normal.inputs['Color'])
            links.new(normal.outputs['Normal'], bsdf.inputs[socket])
        else:
            links.new(tex.outputs['Color'], bsdf.inputs[socket])


def plain(mat, color, rough = .6):
    bsdf = mat.node_tree.nodes.get('Principled BSDF')
    for link in list(mat.node_tree.links):
        if link.to_node == bsdf:
            mat.node_tree.links.remove(link)
    bsdf.inputs['Base Color'].default_value = (*color, 1)
    bsdf.inputs['Roughness'].default_value = rough
    bsdf.inputs['Metallic'].default_value = 0
    bsdf.inputs['Emission Strength'].default_value = 0


def materials():
    texture_material(mats[SKIN], texture_set('ssethrak_hide', (.13, .155, .083), 19, .37))
    texture_material(mats[BELLY], texture_set('ssethrak_belly', (.20, .185, .112), 10, .23))
    plain(mats[TOOTH], (.16, .145, .095), .58)
    plain(mats[BLACK], (.011, .013, .009), .32)
    plain(mats[IRIS], (.105, .075, .022), .28)
    plain(mats[MOUTH], (.043, .014, .011), .52)
    plain(mats[CORE], (.22, .15, .045), .43)
    plain(mats[EYE], (.095, .070, .019), .28)
    for i in [CORE, EYE]:
        bsdf = mats[i].node_tree.nodes.get('Principled BSDF')
        bsdf.inputs['Emission Color'].default_value = (.18, .12, .028, 1)
        bsdf.inputs['Emission Strength'].default_value = .3
    nostril = mats[BLACK].copy()
    nostril.name = 'Lizard_Nostril'
    plain(nostril, (.002, .002, .001), .98)
    nostril.node_tree.nodes['Principled BSDF'].inputs['Specular IOR Level'].default_value = 0
    mats.append(nostril)


def profile(rows, count):
    #Cubic interpolation avoids a stack of visible rings in the silhouette.
    return spline([V(row) for row in rows], count)


def shape_z(rows, at, mat = SKIN, bulge = None, sides = 48):
    rings = []
    for z, rx, ry in profile(rows, 4):
        ring = []
        for j in range(sides):
            a = math.tau * j / sides
            p = V((at[0] + rx * math.cos(a), at[1] + ry * math.sin(a), z))
            if bulge:
                p = bulge(p, a)
            ring.append(p)
        rings.append(ring)
    return finish(loft(rings), mat)


def muscle(p, a):
    x, z = abs(p.x), p.z
    front = max(0, -math.sin(a)) ** 3
    pec = .65 * math.exp(-((x - 2.4) / 1.4) ** 4 - ((z - 10.25) / 1.22) ** 4)
    ribs = .11 * math.cos(z * 4.5 + x * 1.2) * math.exp(-((z - 7.6) / 2.2) ** 2)
    abdomen = .16 * math.exp(-((x - .9) / .9) ** 2) * math.cos(z * 3)
    p.y -= front * (pec + ribs + abdomen)
    p.y += front * .12 * math.exp(-(x / .28) ** 2)
    p.x *= 1 + .035 * math.sin(z * 2.4) * math.exp(-((z - 6.5) / 2) ** 2)
    return p


def torso():
    part = Part()
    rows = [(-.9, 2.0, 1.5), (0, 2.7, 1.8), (2, 3.05, 1.7),
            (4.5, 2.8, 1.7), (6.5, 3.45, 2.0), (8.5, 4.25, 2.25),
            (10.6, 4.8, 2.3), (11.8, 4.7, 2.2), (12.8, 3.25, 1.9),
            (13.8, 1.7, 1.5), (14.3, 1.4, 1.3)]
    bm = shape_z(rows, (0, .05), bulge = muscle, sides = 64)
    dead = []
    for face in bm.faces:
        c = face.calc_center_median()
        width = 1.9 + .74 * math.exp(-((c.z - 9.5) / 2.0) ** 2)
        if c.y < -1 and abs(c.x) < width and 1.0 < c.z < 11.7 - .12 * c.x ** 2:
            face.material_index = BELLY
        if c.y < -1 and math.hypot(c.x, c.z - 9.5) < .95:
            dead.append(face)
    bmesh.ops.delete(bm, geom = dead, context = 'FACES')
    part.add(bm)
    #The stagger target is a scarred sternum beneath two overlapping scutes.
    part.add(sphere(1, MOUTH, loc = (0, -2.18, 9.5), scale = (1.0, .25, 1.05), u = 32, v = 20))
    part.add(sphere(1, BELLY, loc = (0, -2.55, 8.4), scale = (1.25, .21, .18), u = 32, v = 16))
    return part


def skull_profile(y, jaw = False):
    ys = [-.8, .0, .75, 1.4, 2.05, 2.7, 3.25, 3.6, 3.85, 3.96]
    width = [1.25, 1.70, 1.88, 1.90, 1.74, 1.57, 1.48, 1.42, 1.33, 1.19]
    top = [15.15, 15.95, 16.25, 16.20, 15.97, 15.60, 15.28, 15.14, 15.04, 14.94]
    bot = [13.85, 14.07, 14.21, 14.29, 14.35, 14.35, 14.35, 14.36, 14.39, 14.43]
    if jaw:
        top = [z - .07 for z in bot]
        bot = [13.45, 13.40, 13.46, 13.51, 13.57, 13.62, 13.71, 13.76, 13.85, 14.06]
        width = [w * .92 for w in width]
    k = min(len(ys) - 2, max(0, int(np.searchsorted(ys, -y)) - 1))
    t = (-y - ys[k]) / (ys[k + 1] - ys[k])
    out = []
    for row in [width, top, bot]:
        p0, p1, p2, p3 = [row[min(len(row) - 1, max(0, k + j))] for j in [-1, 0, 1, 2]]
        out.append(.5 * (2 * p1 + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t*t + (-p0 + 3 * p1 - 3 * p2 + p3) * t*t*t))
    return out


def skull(jaw = False):
    rings = []
    for y in np.linspace(.79, -3.96, 72):
        w, top, bot = skull_profile(y, jaw)
        ring = []
        for a in np.linspace(0, math.tau, 112, endpoint = False):
            x, q = w * math.cos(a), math.sin(a)
            if jaw:
                z = top - .16 * q if q > 0 else top - (top - bot) * abs(q) ** .72
            else:
                roof = np.interp(abs(x) / w, [0, .4, .72, .9, 1], [1, .99, .90, .66, .09])
                z = bot - .015 * abs(q) if q < 0 else bot + (top - bot) * roof
                if q > 0:
                    ridge = math.exp(-((abs(x) - 1.56) / .24) ** 2 - ((y + 1.60) / .65) ** 2)
                    z += .18 * ridge
                    z += .018 * math.sin(x * 7 + y * 2) * math.sin(y * 6)
            ring.append(V((x, y, z)))
        rings.append(ring)
    bm = finish(loft(rings), SKIN)
    for f in bm.faces:
        c = f.calc_center_median()
        if jaw and f.normal.z > .6:
            f.material_index = MOUTH
        elif jaw and c.z < 13.5:
            f.material_index = BELLY
        elif not jaw and f.normal.z < -.7:
            f.material_index = MOUTH
    return bm


def nostril(part, s):
    #A small slit conforming to the muzzle, with a smooth oval boundary.
    bm = bmesh.new()
    ring = []
    for a in np.linspace(0, math.tau, 32, endpoint = False):
        x = s * (1.30 + .045 * math.cos(a))
        y = -3.48 + .105 * math.sin(a)
        w, top, bot = skull_profile(y)
        h = np.interp(abs(x) / w, [0, .4, .72, .9, 1], [1, .99, .90, .66, .09])
        z = bot + (top - bot) * h + .018 * math.sin(x * 7 + y * 2) * math.sin(y * 6)
        ring.append(bm.verts.new((x, y, z + .010)))
    center = bm.verts.new(sum((v.co for v in ring), V()) / len(ring))
    for i in range(len(ring)):
        face = bm.faces.new((center, ring[i], ring[(i + 1) % len(ring)]))
        face.material_index = NOSTRIL
        face.smooth = True
    bm.normal_update()
    for face in bm.faces:
        if face.normal.z < 0:
            face.normal_flip()
    part.add(bm)


def stroke(part, points, radius, mat, sides = 12):
    pts = spline(points, 4)
    part.add(tube(pts, lambda t: radius * (.8 + .2 * math.sin(math.pi * t)), mat, sides = sides))


def tooth(part, p, length, down):
    p = V(p)
    pts = spline([p, p + V((0, .04, down * length * .55)),
                  p + V((0, .13, down * length))], 4)
    part.add(tube(pts, lambda t: .075 * (1 - t) ** .8 + .005, TOOTH, sides = 10))


def teeth(part, jaw):
    for s in [-1, 1]:
        for i, y in enumerate(np.linspace(-.8, -3.68, 14)):
            w, top, bot = skull_profile(y, jaw)
            z = top - .10 if jaw else bot + .15
            length = .23 + .14 * math.sin(i * 1.17 + .5) ** 2
            tooth(part, (s * w * .80, y, z), length, 1 if jaw else -1)
    w, top, bot = skull_profile(-3.73, jaw)
    for i, x in enumerate(np.linspace(-.95, .95, 9)):
        tooth(part, (x, -3.73, top - .1 if jaw else bot + .15),
              .22 + .045 * math.sin(i * 1.7) ** 2, 1 if jaw else -1)


EYE_POS = V((-1.76, -1.63, 15.40))


def eye(part, s, mat):
    center = V((s * abs(EYE_POS.x), EYE_POS.y, EYE_POS.z))
    normal = V((s * .88, -.46, .12)).normalized()
    rot = V((0, -1, 0)).rotation_difference(normal).to_euler()
    center -= normal * .035
    part.add(sphere(1, mat, loc = center, scale = (.19, .10, .115), rot = rot, u = 32, v = 20))
    part.add(sphere(1, BLACK, loc = center + normal * .09, scale = (.025, .018, .095), rot = rot, u = 24, v = 16))


def eyelids(part, s):
    center = V((s * abs(EYE_POS.x), EYE_POS.y, EYE_POS.z))
    normal = V((s * .88, -.46, .12)).normalized()
    across = V((.46, s * .88, 0))
    rings = []
    for rx, rz, depth in [(.185, .088, .06), (.25, .15, .018), (.44, .34, 0)]:
        ring = []
        for a in np.linspace(0, math.tau, 48, endpoint = False):
            p = center + across * math.cos(a) * rx + V((0, 0, math.sin(a) * rz))
            if rx == .44:
                w, top, bot = skull_profile(p.y)
                h = (p.z - bot) / (top - bot)
                p.x = s * w * np.interp(h, [.09, .66, .90, .99, 1], [1, .9, .72, .4, 0])
                p += normal * .008
            else:
                p += normal * depth
            ring.append(p)
        rings.append(ring)
    bm = finish(loft(rings, cap0 = False, cap1 = False), SKIN)
    #An open eyelid has no enclosed volume from which to infer its front.
    for face in bm.faces:
        if face.normal.dot(normal) < 0:
            face.normal_flip()
    part.add(bm)


def head():
    part = Part()
    part.add(skull())
    def nape(p, a):
        p.y += .60 * (15.6 - p.z) / 3.1
        return p
    part.add(shape_z([(12.5, 1.74, 1.85), (13.4, 1.78, 1.7),
                      (14.2, 1.65, 1.42), (15.1, 1.40, 1.18),
                      (15.55, 1.05, .9)], (0, 0), bulge = nape))
    #A narrow mouth seam, nostrils and recessed eyelids replace the old crown.
    for s in [-1, 1]:
        points = []
        for y in np.linspace(-.8, -3.86, 20):
            w, top, bot = skull_profile(y)
            points.append(V((s * w * .985, y, bot - .015)))
        stroke(part, points, .018, MOUTH)
        nostril(part, s)
        eyelids(part, s)
    eye(part, 1, IRIS)
    teeth(part, False)
    for y in np.linspace(-1.1, -3.2, 8):
        points = [V((x, y + .08 * x * x, 14.25 - .035 * x * x))
                  for x in np.linspace(-1.0, 1.0, 12)]
        stroke(part, points, .035, MOUTH)
    return part


def jaw():
    part = Part()
    part.add(skull(True))
    part.add(sphere(1, MOUTH, loc = (0, -2.35, 14.17), scale = (.53, 1.10, .14), u = 36, v = 20))
    lip = [V((x, -3.89 + .13 * x*x, 14.31)) for x in np.linspace(-1.17, 1.17, 24)]
    stroke(part, lip, .065, SKIN, 14)
    for s in [-1, 1]:
        points = []
        for y in np.linspace(-.9, -3.55, 18):
            w, top, bot = skull_profile(y, True)
            points.append(V((s * w * .76, y, top - .11)))
        stroke(part, points, .060, MOUTH, 14)
    teeth(part, True)
    return part


def arm(s, fore = False):
    part = Part()
    rows = [(12.5, 1.10, 1.23), (11.75, 1.72, 1.8), (10.5, 1.73, 1.6),
            (8.7, 1.37, 1.55), (7.1, 1.23, 1.4), (5.5, 1.10, 1.09), (5.12, .82, .82)]
    if fore:
        rows = [(5.75, .97, .98), (5.05, 1.17, 1.18), (3.9, 1.49, 1.39),
                (2.5, 1.31, 1.22), (1.0, .98, 1), (-.45, .78, .81), (-.8, .68, .72)]
    def flex(p, a):
        p.y -= .15 * max(0, -math.sin(a)) * math.sin(p.z * .9)
        return p
    part.add(shape_z(rows, (s * 5.5, 0), bulge = flex))
    return part


def claw(part, points, radius = .18):
    part.add(tube(spline(points, 5), lambda t: radius * (1 - t) ** .7 + .008, BLACK, sides = 14))


def hand(s):
    part = Part()
    x = s * 5.5
    rows = [(-.25, .67, .70), (-.85, .95, .69), (-1.55, 1.08, .64),
            (-2.1, .99, .58), (-2.35, .72, .47)]
    part.add(shape_z(rows, (x, 0), sides = 36))
    for i, dx in enumerate([-.77, -.27, .26, .74]):
        z = -2.7 + abs(dx) * .15
        points = [V((x + dx, .0, -1.7)), V((x + dx * 1.12, -.04, -2.35)),
                  V((x + dx * 1.14, -.46, z)), V((x + dx, -.9, z + .12))]
        stroke(part, points, .26, SKIN, 16)
        end = points[-1]
        claw(part, [end, end + V((0, -.30, .10)), end + V((0, -.49, .40))], .17)
    points = [V((x - s * .8, -.10, -1.05)), V((x - s * 1.3, -.4, -1.5)),
              V((x - s * .93, -.9, -1.9)), V((x - s * .45, -1.12, -1.95))]
    stroke(part, points, .33, SKIN, 18)
    end = points[-1]
    claw(part, [end, end + V((s * .30, -.05, .1)), end + V((s * .4, .05, .40))], .20)
    return part


def leg(s, shin = False):
    part = Part()
    x = s * 2.12
    rows = [(.45, 1.65, 1.55), (-1.0, 1.8, 1.65), (-2.5, 1.64, 1.53),
            (-4, 1.18, 1.26), (-4.95, 1.0, 1.07)]
    if shin:
        rows = [(-4.7, 1.0, 1.04), (-5.8, 1.15, 1.12), (-7, 1.10, .93),
                (-8.4, .67, .61), (-9.35, .62, .63)]
    def bend(p, a):
        p.y += .5 * math.sin((p.z + 2) * .6)
        return p
    part.add(shape_z(rows, (x, 0), bulge = bend))
    if shin:
        part.add(sphere(1, SKIN, loc = (x, -.35, -9.40), scale = (1.03, 1.2, .49), u = 32, v = 16))
        for dx in [-.65, 0, .65]:
            end = V((x + dx * 1.22, -2.05 + abs(dx) * .35, -9.62))
            stroke(part, [V((x + dx, -.65, -9.35)),
                          V((x + dx, -1.50, -9.6)), end], .30, SKIN, 16)
            claw(part, [end, end + V((0, -.42, 0)), end + V((0, -.64, -.18))], .20)
    return part


def tail():
    part = Part()
    points = [V(p) for p in [(0, 1.4, .6), (0, 3.1, -.8), (0, 4.4, -3.4),
                             (0, 5.7, -6.4), (.8, 7.3, -8.5), (2.4, 9.8, -9.1),
                             (3.4, 12.0, -8.65)]]
    part.add(tube(spline(points, 7), lambda t: 1.52 * (1 - t) ** 1.2 + .035, SKIN, sides = 36))
    return part


def core():
    part = Part()
    part.add(sphere(1, CORE, loc = (0, -2.30, 9.5), scale = (.72, .25, .90), u = 32, v = 20))
    return part


def shutter(s):
    part = Part()
    part.add(sphere(1, BELLY, loc = (s * .52, -2.49, 9.5), scale = (.60, .22, 1.12), u = 28, v = 20))
    pivot = V((s * 1.1, -2.5, 9.5))
    #Export the open rest pose; runtime closes the plates around the scar.
    mat = Matrix.Translation(pivot) @ Matrix.Rotation(s * math.pi / 2, 4, 'Z') @ Matrix.Translation(-pivot)
    part.bm.transform(mat)
    return part


def make_parts():
    parts['Colossus_Torso'] = torso()
    parts['Colossus_Head'] = head()
    parts['Colossus_Jaw'] = jaw()
    parts['Colossus_Tail'] = tail()
    parts['Colossus_Core'] = core()
    parts['Colossus_Eye'] = Part()
    eye(parts['Colossus_Eye'], -1, EYE)
    g['PIVOT']['Colossus_Eye'] = tuple(EYE_POS)
    for s, side in [(-1, 'L'), (1, 'R')]:
        parts['Colossus_Shutter' + side] = shutter(s)
        parts['Colossus_UpperArm_' + side] = arm(s)
        parts['Colossus_Forearm_' + side] = arm(s, True)
        parts['Colossus_Hand_' + side] = hand(s)
        thigh, shin = 'Lizard_Thigh_' + side, 'Lizard_Shin_' + side
        parts[thigh], parts[shin] = leg(s), leg(s, True)
        g['PIVOT'][thigh] = (s * 2.12, 0, .3)
        g['PIVOT'][shin] = (s * 2.12, 0, -4.8)
        g['PARENT'][shin] = thigh


def objects():
    objs = {}
    for name, part in parts.items():
        objs[name] = g['make_object'](name, part, mats)
    for name, parent in g['PARENT'].items():
        ob = objs[name]
        ob.parent = objs[parent]
        ob.location = V(g['PIVOT'][name]) - V(g['PIVOT'][parent])
    bpy.context.view_layer.update()
    return objs


def crevices(objs):
    verts, faces = [], []
    for ob in objs.values():
        start = len(verts)
        verts.extend(ob.matrix_world @ v.co for v in ob.data.vertices)
        faces.extend(tuple(start + i for i in f.vertices) for f in ob.data.polygons)
    tree = BVHTree.FromPolygons(verts, faces)
    rays = []
    for i in range(10):
        z, a = (i + .5) / 10, i * 2.399963
        r = math.sqrt(1 - z * z)
        rays.append(V((math.cos(a) * r, math.sin(a) * r, z)))
    for ob in objs.values():
        vertex_shading(ob, tree, rays)


def vertex_shading(ob, tree, rays):
    mesh = ob.data
    attr = mesh.color_attributes.new(name = 'Col', type = 'FLOAT_COLOR', domain = 'CORNER')
    colors = []
    for v in mesh.vertices:
        p = ob.matrix_world @ v.co
        n = (ob.matrix_world.to_3x3() @ v.normal).normalized()
        q = V((0, 0, 1)).rotation_difference(n)
        hits = sum(tree.ray_cast(p + n * .03, q @ r, .9)[0] != None for r in rays)
        ao = max(.46, 1 - hits * .054)
        macro = .91 + .09 * math.sin(p.z * 1.3 + p.x * .4) * math.cos(p.y * 1.8)
        colors.append((ao * macro, ao * macro, ao * macro, 1))
    for i, loop in enumerate(mesh.loops):
        attr.data[i].color = colors[loop.vertex_index]


materials()
make_parts()
objs = objects()
crevices(objs)
for ob in objs.values():
    ob.select_set(True)
with bpy.context.temp_override(window = bpy.context.window_manager.windows[0]):
    bpy.context.view_layer.objects.active = objs['Colossus_Torso']
    bpy.ops.export_scene.gltf(filepath = str(OUT / 'lizard_reference.glb'),
            export_format = 'GLB', use_selection = True, export_yup = True,
            export_apply = True, export_animations = False, export_vertex_color = 'ACTIVE')
    bpy.context.preferences.filepaths.save_version = 0
    bpy.ops.wm.save_as_mainfile(filepath = str(ROOT / 'tools/art/source/lizard_reference.blend'))
tris = sum(len(f.vertices) - 2 for ob in objs.values() for f in ob.data.polygons)
print('Reference lizard: %d rigid parts, %d triangles' % (len(objs), tris))
