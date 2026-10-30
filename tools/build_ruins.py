#Broken ruins for the boss arena: fluted columns snapped at jagged heights,
#rubble piles and the stump of an arch, all in the castle-wall scan
#(Poly Haven CC0, assets/textures/arena).  Each piece is its own object
#with its origin at the base centre; the game puts a simple collider on it.
#blender -b --factory-startup -P tools/build_ruins.py
#Writes assets/environment/ruins/ruins.glb (+ preview to the scratchpad).
import bpy
import bmesh
import math
import os
import random
from pathlib import Path
from mathutils import Vector, noise

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'assets/environment/ruins'
TEX = ROOT / 'assets/textures/arena'
PREVIEW = Path(os.environ.get('RUINS_PREVIEW', '/tmp/claude-1000/-home-talves-mthings-LandsOfBalance/07261c89-1cc2-4cd7-9029-7c1b17b3a6a2/scratchpad/ruins.png'))


def material():
    m = bpy.data.materials.new('Ruin_Stone')
    m.use_nodes = True
    nt = m.node_tree
    bsdf = next(n for n in nt.nodes if n.type == 'BSDF_PRINCIPLED')
    def img(name, data=False):
        t = nt.nodes.new('ShaderNodeTexImage')
        t.image = bpy.data.images.load(str(TEX / name))
        if data:
            t.image.colorspace_settings.name = 'Non-Color'
        return t
    d = img('castle_wall_varriation_diff_2k.jpg')
    nt.links.new(d.outputs['Color'], bsdf.inputs['Base Color'])
    r = img('castle_wall_varriation_rough_2k.jpg', True)
    nt.links.new(r.outputs['Color'], bsdf.inputs['Roughness'])
    n = img('castle_wall_varriation_nor_gl_2k.jpg', True)
    nm = nt.nodes.new('ShaderNodeNormalMap')
    nt.links.new(n.outputs['Color'], nm.inputs['Color'])
    nt.links.new(nm.outputs['Normal'], bsdf.inputs['Normal'])
    return m


def column(name, radius, height, seed, flutes=14):
    """A fluted drum stack snapped off at a jagged, leaning break."""
    rng = random.Random(seed)
    bm = bmesh.new()
    sides = flutes * 4
    rings = int(height / 0.18) + 1
    tilt = Vector((rng.uniform(-.35, .35), rng.uniform(-.35, .35), 1)).normalized()
    verts = []
    for k in range(rings + 1):
        z = height * k / rings
        ring = []
        for s in range(sides):
            a = 2 * math.pi * s / sides
            # fluting + weathering + drum joints every ~0.9 m
            r = radius * (1 - 0.06 * (0.5 + 0.5 * math.cos(a * flutes)))
            r *= 1 + 0.035 * noise.noise(Vector((math.cos(a) * 2, math.sin(a) * 2, z * 1.5 + seed)))
            if abs((z % 0.9) - 0.45) > 0.42:
                r *= 0.975
            ring.append(bm.verts.new((math.cos(a) * r, math.sin(a) * r, z)))
        verts.append(ring)
    for k in range(rings):
        for s in range(sides):
            bm.faces.new((verts[k][s], verts[k][(s + 1) % sides], verts[k + 1][(s + 1) % sides],
                          verts[k + 1][s]))
    bm.faces.new(list(reversed(verts[0])))
    # the break: a jagged cap, low on one side, along a tilted plane
    top = verts[-1]
    cap_c = bm.verts.new((0, 0, height))
    for s in range(sides):
        v = top[s]
        a = 2 * math.pi * s / sides
        dz = (math.cos(a) * tilt.x + math.sin(a) * tilt.y) * radius * 1.4
        dz += rng.uniform(-.25, .12)
        v.co.z = height + dz
    cap_c.co.z = height + rng.uniform(-.2, .1)
    for s in range(sides):
        bm.faces.new((top[s], top[(s + 1) % sides], cap_c))
    # jagged inner chunks on the break
    for _ in range(5):
        a = rng.uniform(0, 2 * math.pi)
        rr = radius * rng.uniform(.2, .7)
        c = Vector((math.cos(a) * rr, math.sin(a) * rr, height + rng.uniform(-.15, .2)))
        bmesh.ops.create_icosphere(bm, subdivisions=1, radius=rng.uniform(.12, .3),
                                   matrix=__import__('mathutils').Matrix.Translation(c))
    return finish(bm, name, radius, height)


def rubble(name, spread, seed, count=14):
    rng = random.Random(seed)
    bm = bmesh.new()
    from mathutils import Matrix
    for i in range(count):
        a = rng.uniform(0, 2 * math.pi)
        d = spread * math.sqrt(rng.uniform(0, 1))
        s = rng.uniform(.25, .7) * (1.4 if i < 3 else 1.0)
        m = Matrix.Translation((math.cos(a) * d, math.sin(a) * d, s * .35)) @ \
            Matrix.Rotation(rng.uniform(0, 3), 4, 'Z') @ Matrix.Diagonal((s, s * rng.uniform(.6, 1.4), s * .6, 1))
        bmesh.ops.create_cube(bm, size=1.0, matrix=m)
    bmesh.ops.bevel(bm, geom=bm.edges[:], offset=.06, segments=1)
    return finish(bm, name, spread, 1.0)


def arch_stump(name, seed):
    """Two broken jambs and the spring of an arch between them."""
    rng = random.Random(seed)
    bm = bmesh.new()
    from mathutils import Matrix
    for side in (-1, 1):
        h = rng.uniform(3.6, 5.2)
        bmesh.ops.create_cube(bm, size=1.0, matrix=Matrix.Translation((side * 2.2, 0, h / 2)) @
                              Matrix.Diagonal((1.1, 1.1, h, 1)))
        # voussoirs springing inward, the arch broken partway
        n = rng.randint(2, 4)
        for k in range(n):
            a = math.radians(10 + k * 18)
            x = side * (2.2 - 1.6 * (1 - math.cos(a)) - .3)
            z = h + 1.6 * math.sin(a) * .9
            bmesh.ops.create_cube(bm, size=1.0, matrix=Matrix.Translation((x, 0, z)) @
                                  Matrix.Rotation(-side * a, 4, 'Y') @ Matrix.Diagonal((.75, 1.05, .55, 1)))
    bmesh.ops.bevel(bm, geom=bm.edges[:], offset=.05, segments=1)
    return finish(bm, name, 3.0, 5.0)


def finish(bm, name, radius, height):
    # weathering: push every vertex a little along noise
    bm.normal_update()
    for v in bm.verts:
        n = noise.noise(v.co * 1.7) * .05 + noise.noise(v.co * 5.0) * .015
        v.co += v.normal * n
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    ob = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(ob)
    for p in me.polygons:
        p.use_smooth = True
    me.materials.append(MAT)
    # box-projected UVs in metres (the scan tiles every 2.5 m)
    uvl = me.uv_layers.new(name='UVMap').data
    for p in me.polygons:
        nrm = p.normal
        for li in p.loop_indices:
            co = me.vertices[me.loops[li].vertex_index].co
            if abs(nrm.z) > .7:
                uv = (co.x, co.y)
            elif abs(nrm.x) > abs(nrm.y):
                uv = (co.y, co.z)
            else:
                uv = (co.x, co.z)
            uvl[li].uv = (uv[0] / 2.5, uv[1] / 2.5)
    ob['collider_radius'] = radius
    ob['collider_height'] = height
    return ob


bpy.ops.wm.read_factory_settings(use_empty=True)
MAT = material()
objs = []
for i, (r, h) in enumerate(((.95, 3.4), (.85, 4.6), (1.05, 2.4), (.8, 3.9))):
    o = column('Ruin_Column_%d' % i, r, h, 10 + i)
    o.location.x = i * 4.0
    objs.append(o)
for i in range(2):
    o = rubble('Ruin_Rubble_%d' % i, 1.6, 30 + i)
    o.location = (i * 4.0, 5, 0)
    objs.append(o)
o = arch_stump('Ruin_Arch_0', 50)
o.location = (10, 6, 0)
objs.append(o)
OUT.mkdir(parents=True, exist_ok=True)
# origins at the base: export at the origin, the game places them
for o in objs:
    o.location = (0, 0, 0)
bpy.ops.export_scene.gltf(filepath=str(OUT / 'ruins.glb'), export_format='GLB',
                          export_extras=True, export_materials='EXPORT')
print('ruins exported', [o.name for o in objs])
