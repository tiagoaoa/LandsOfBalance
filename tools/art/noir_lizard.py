#Ssethrak: a weathered bipedal reptilian giant, retaining the combat pivots.
#Run through Blender MCP. Source geometry is tools/build_lizard.py's model.
import math
import random
from pathlib import Path

import bpy
import bmesh
import numpy as np
from mathutils import Vector, Matrix
from mathutils.bvhtree import BVHTree

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'assets/characters/lizard'
bpy.ops.wm.open_mainfile(filepath = str(OUT / 'lizard.blend'))
rng = random.Random(311)
V = Vector
parts = [o for o in bpy.context.scene.objects if o.type == 'MESH' and o.name.startswith('Colossus_')]


def groups(mesh):
    adjacency = [[] for v in mesh.vertices]
    for edge in mesh.edges:
        a, b = edge.vertices
        adjacency[a].append(b)
        adjacency[b].append(a)
    unseen = set(range(len(adjacency)))
    while unseen:
        todo = [unseen.pop()]
        component = []
        while todo:
            i = todo.pop()
            component.append(i)
            for j in adjacency[i]:
                if j in unseen:
                    unseen.remove(j)
                    todo.append(j)
        yield component


def material_ids(mesh):
    names = [''] * len(mesh.vertices)
    for face in mesh.polygons:
        for i in face.vertices:
            names[i] = mesh.materials[face.material_index].name
    return names


def reshape_head():
    ob = bpy.data.objects['Colossus_Head']
    mesh = ob.data
    ids = material_ids(mesh)
    inv = ob.matrix_world.inverted()
    #The source applies this head offset and scale before export.
    def hp(p):
        return V((0, -.3, 13.2)) + (V(p) + V((0, -.75, .35)) - V((0, -.3, 13.2))) * 1.15
    eyes = [hp((s * 1.24, -1.42, 14.16)) for s in [-1, 1]]
    gem = hp((0, -1.55, 14.8))
    for component in groups(mesh):
        points = [ob.matrix_world @ mesh.vertices[i].co for i in component]
        center = sum(points, V()) / len(points)
        name = ids[component[0]]
        nearest = min(eyes, key = lambda e: (e - center).length)
        #Eyes, pupils and lids stay together under the overhanging brow.
        if (nearest - center).length < .34 and name in ['Lizard_EyeBall', 'Lizard_Obsidian', 'Colossus_Stone']:
            for i, p in zip(component, points):
                d = p - nearest
                mesh.vertices[i].co = inv @ (nearest + V((d.x * .92, d.y * .87, d.z * .48)))
        if name != 'Colossus_Bronze':
            continue
        #A narrow forehead scar setting, keeping the existing eye interrupt target.
        if (center - gem).length < .75:
            for i, p in zip(component, points):
                d = p - gem
                mesh.vertices[i].co = inv @ (gem + V((d.x * .42, d.y, d.z * .9)))
        elif max(p.z for p in points) > 16.6:
            base = min(points, key = lambda p: p.z)
            for i, p in zip(component, points):
                #Short irregular crown spurs; one side has an old break.
                factor = .47 if center.x > .5 else .62
                mesh.vertices[i].co = inv @ (base + (p - base) * factor)
    eye = bpy.data.objects['Colossus_Eye']
    eye_ids = material_ids(eye.data)
    normal = V((0, -.6, .8))
    tangent = V((0, .8, .6))
    for component in groups(eye.data):
        if eye_ids[component[0]] != 'Lizard_Obsidian':
            continue
        center = sum((eye.data.vertices[i].co for i in component), V()) / len(component)
        for i in component:
            d = eye.data.vertices[i].co - center
            eye.data.vertices[i].co = center + V((d.dot(tangent), 0, 0)) + tangent * d.x * .85 + normal * d.dot(normal)
    for v in eye.data.vertices:
        v.co.x *= .42
        v.co.z *= .9


def weather_texture(matname, amount, saturation):
    mat = bpy.data.materials[matname]
    tex = next(n for n in mat.node_tree.nodes if n.type == 'TEX_IMAGE' and 'albedo' in n.image.name)
    w, h = tex.image.size
    pixels = np.array(tex.image.pixels[:], dtype = np.float32).reshape(h, w, 4)
    y, x = np.mgrid[0:h, 0:w] / np.array([h, w])[:, None, None]
    tone = np.sum(pixels[:, :, :3] * (.2126, .7152, .0722), axis = 2)
    pixels[:, :, :3] = pixels[:, :, :3] * saturation + tone[:, :, None] * (1 - saturation)
    grain = .82 + .16 * np.sin(math.tau * (x * 3 + y * 2)) + .12 * np.cos(math.tau * (y * 5 - x))
    pixels[:, :, :3] *= (grain * amount)[:, :, None]
    #Old healed scratches, with interruptions rather than bright painted stripes.
    scratch = np.exp(-np.sin(math.tau * (x * 2 + y + .014 * np.sin(y * math.tau * 5))) ** 2 * 22000)
    scratch *= np.maximum(0, np.cos(y * math.tau * 3)) ** 12
    pixels[:, :, :3] += scratch[:, :, None] * .024
    image = bpy.data.images.new('Noir_' + matname, w, h)
    image.pixels.foreach_set(pixels.ravel())
    image.filepath_raw = str(OUT / ('noir_' + matname.lower() + '.png'))
    image.file_format = 'PNG'
    image.save()
    tex.image = image


def tube(points, radii, sides = 18):
    verts, faces = [], []
    for k, point in enumerate(points):
        p = V(point)
        direction = V(points[min(k + 1, len(points) - 1)]) - V(points[max(k - 1, 0)])
        q = V((0, 0, 1)).rotation_difference(direction.normalized())
        for j in range(sides):
            a = math.tau * j / sides
            radius = radii[k] * (1 + .025 * math.sin(a * 5 + k))
            verts.append(p + q @ V((math.cos(a) * radius, math.sin(a) * radius * .85, 0)))
    for k in range(len(points) - 1):
        for j in range(sides):
            a, b = k * sides + j, k * sides + (j + 1) % sides
            faces.append((a, b, b + sides, a + sides))
    faces += [tuple(reversed(range(sides))), tuple((len(points) - 1) * sides + j for j in range(sides))]
    return verts, faces


def limb(name, parent, pivot, points, radii, matname = 'Colossus_Stone'):
    verts, faces = tube(points, radii)
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata([v - V(pivot) for v in verts], [], faces)
    mesh.materials.append(bpy.data.materials[matname])
    uv = mesh.uv_layers.new(name = 'UVMap')
    for poly in mesh.polygons:
        poly.use_smooth = True
        for li in poly.loop_indices:
            vi = mesh.loops[li].vertex_index
            uv.data[li].uv = (vi % 18 / 18 * 2, vi // 18 * .23)
    ob = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(ob)
    ob.parent = parent
    ob.matrix_world = Matrix.Translation(pivot)
    parts.append(ob)
    return ob


def legs():
    for s, side in [(-1, 'L'), (1, 'R')]:
        hip = (s * 2.0, .2, .3)
        knee = (s * 2.4, -.7, -4.8)
        thigh = limb('Lizard_Thigh_' + side, None, hip,
                     [hip, (s * 2.2, 0, -1.3), (s * 2.4, -.6, -3.6), knee], [1.85, 1.7, 1.3, 1.02])
        shin = limb('Lizard_Shin_' + side, thigh, knee,
                    [knee, (s * 2.5, .3, -6.5), (s * 2.6, .7, -8.3), (s * 2.6, -.1, -9.4)], [1.05, 1.2, .68, .65])
        for toe in range(3):
            x = s * 2.6 + (toe - 1) * .6
            limb('Lizard_Toe_%s_%d' % (side, toe), shin, knee,
                 [(x, -.05, -9.25), (x, -1.05, -9.65), (x, -2.0, -9.7)], [.45, .32, .13])
            limb('Lizard_Claw_%s_%d' % (side, toe), shin, knee,
                 [(x, -1.8, -9.64), (x, -2.3, -9.72), (x, -2.65, -9.82)], [.18, .11, .015], 'Lizard_Teeth')


def bake_crevices():
    verts, faces = [], []
    for ob in parts:
        start = len(verts)
        verts.extend(ob.matrix_world @ v.co for v in ob.data.vertices)
        faces.extend(tuple(start + i for i in p.vertices) for p in ob.data.polygons)
    tree = BVHTree.FromPolygons(verts, faces)
    rays = []
    for i in range(12):
        z = (i + .5) / 12
        a = i * 2.399963
        rays.append(V((math.cos(a) * math.sqrt(1 - z*z), math.sin(a) * math.sqrt(1 - z*z), z)))
    for ob in parts:
        mesh = ob.data
        colors = mesh.color_attributes.new(name = 'Col', type = 'FLOAT_COLOR', domain = 'CORNER')
        occlusion = []
        normal_matrix = ob.matrix_world.to_3x3().inverted().transposed()
        for v in mesh.vertices:
            p = ob.matrix_world @ v.co
            n = (normal_matrix @ v.normal).normalized()
            q = V((0, 0, 1)).rotation_difference(n) if n.length_squared > .1 else None
            hits = 0
            if q:
                for ray in rays:
                    hits += tree.ray_cast(p + n * .025, q @ ray, 1.8)[0] != None
            occlusion.append(max(.34, 1 - hits / 12 * .66))
        for li, loop in enumerate(mesh.loops):
            ao = occlusion[loop.vertex_index]
            colors.data[li].color = (ao, ao, ao, 1)
        print('Crevice shading:', ob.name)


reshape_head()
weather_texture('Colossus_Stone', .88, .32)
weather_texture('Colossus_Bronze', .40, .20)
weather_texture('Lizard_Belly', .59, .22)
for name, color, rough in [('Lizard_Teeth', (.25, .225, .18, 1), .57),
                          ('Lizard_EyeBall', (.24, .15, .045, 1), .22),
                          ('Lizard_Mouth', (.047, .018, .015, 1), .55)]:
    bsdf = bpy.data.materials[name].node_tree.nodes.get('Principled BSDF')
    bsdf.inputs['Base Color'].default_value = color
    bsdf.inputs['Roughness'].default_value = rough
for name in ['Colossus_Ember', 'Colossus_Eye']:
    bsdf = bpy.data.materials[name].node_tree.nodes.get('Principled BSDF')
    bsdf.inputs['Base Color'].default_value = (.21, .18, .085, 1)
    bsdf.inputs['Emission Color'].default_value = (.32, .28, .09, 1)
    bsdf.inputs['Emission Strength'].default_value = .4
legs()
bpy.context.view_layer.update()
bake_crevices()
for ob in bpy.context.scene.objects:
    ob.select_set(ob in parts)
with bpy.context.temp_override(window = bpy.context.window_manager.windows[0]):
    bpy.context.view_layer.objects.active = bpy.data.objects['Colossus_Torso']
    bpy.ops.export_scene.gltf(filepath = str(OUT / 'lizard_noir.glb'), export_format = 'GLB',
            use_selection = True, export_yup = True, export_apply = True, export_animations = False,
            export_vertex_color = 'ACTIVE')
    bpy.context.preferences.filepaths.save_version = 0
    bpy.ops.wm.save_as_mainfile(filepath = str(ROOT / 'tools/art/source/lizard_noir.blend'))
print('Noir lizard exported: %d parts, bipedal, no wings' % len(parts))
