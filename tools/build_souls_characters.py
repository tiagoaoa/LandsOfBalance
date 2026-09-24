#Layered armor and travelling mantles on the existing Mixamo bind.
#blender -b --factory-startup -P tools/build_souls_characters.py
import bpy
import math
import sys
from pathlib import Path
from mathutils import Vector
from mathutils.bvhtree import BVHTree


ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'assets/characters'
BODY = None


def front(x, z, offset = .012):
    hit = BODY.ray_cast(Vector((x, -2, z)), Vector((0, 1, 0)))[0]
    return hit.y - offset if hit else -.12


def material(name, color, metal, rough):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get('Principled BSDF')
    bsdf.inputs['Base Color'].default_value = (*color, 1)
    bsdf.inputs['Metallic'].default_value = metal
    bsdf.inputs['Roughness'].default_value = rough
    return mat


def bind(obj, arm, bone):
    obj.parent = arm
    group = obj.vertex_groups.new(name = 'mixamorig_' + bone)
    group.add(list(range(len(obj.data.vertices))), 1, 'REPLACE')
    mod = obj.modifiers.new('Skin', 'ARMATURE')
    mod.object = arm


def surface(name, verts, faces, mat, arm, bone, thick = .004):
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata(verts, [], faces)
    mesh.update()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    obj.data.materials.append(mat)
    bpy.context.view_layer.objects.active = obj
    mod = obj.modifiers.new('Edge', 'SOLIDIFY')
    mod.thickness = thick
    bpy.ops.object.modifier_apply(modifier = mod.name)
    mod = obj.modifiers.new('Rolled edge', 'BEVEL')
    mod.width = .002
    mod.segments = 2
    bpy.ops.object.modifier_apply(modifier = mod.name)
    bind(obj, arm, bone)
    for poly in mesh.polygons:
        poly.use_smooth = True
    return obj


def grid_faces(rows, cols):
    faces = []
    for j in range(rows - 1):
        for i in range(cols - 1):
            a = j * cols + i
            faces += [(a, a + 1, a + cols + 1, a + cols)]
    return faces


def rivet(pos, mat, arm, bone):
    bpy.ops.mesh.primitive_uv_sphere_add(segments = 8,
            ring_count = 4, radius = .006, location = pos)
    obj = bpy.context.object
    obj.name = 'Rivet'
    bpy.ops.object.transform_apply(location = True,
            rotation = True, scale = True)
    obj.data.materials.append(mat)
    bind(obj, arm, bone)


def breastplate(arm, steel, bronze):
    #Convex front; the tabard stays visible below the waist.
    verts = []
    for j in range(9):
        t = j / 8
        z = 1.08 + .34 * t
        w = .155 + .035 * math.sin(t * math.pi)
        for i in range(17):
            x = (i / 8 - 1) * w
            z1 = z - .035 * (1 - t) * (1 - abs(x / w))
            verts += [(x, front(x, z1), z1)]
    surface('Forged cuirass', verts, grid_faces(9, 17),
            steel, arm, 'Spine1', .008)
    for j in [0, 8]:
        for i in [2, 5, 8, 11, 14]:
            x, y, z = verts[j * 17 + i]
            rivet((x, y - .007, z), bronze, arm, 'Spine1')
    for side in [-1, 1]:
        inlay(arm, bronze, side)


def inlay(arm, mat, side):
    points = [(.014, 1.14), (.020, 1.345), (.10, 1.385)]
    for a, b in zip(points, points[1:]):
        verts = []
        for i in range(13):
            t = i / 12
            x = (a[0] * (1 - t) + b[0] * t) * side
            z = a[1] * (1 - t) + b[1] * t
            for dx in [-.0025, .0025]:
                verts += [(x + dx, front(x + dx, z, .026), z)]
        surface('Cuirass inlay', verts, grid_faces(13, 2),
                mat, arm, 'Spine1', .001)


def shoulders(arm, steel, bronze):
    for side, bone in [(1, 'LeftArm'), (-1, 'RightArm')]:
        for layer in range(3):
            verts = []
            for j in range(3):
                x = side * (.17 + layer * .051 + j * .033)
                for i in range(13):
                    y = -.075 + i / 12 * .24
                    hit = BODY.ray_cast(Vector((x, y, 2)),
                            Vector((0, 0, -1)))[0]
                    z = max(hit.z, 1.38) if hit else 1.38
                    z += .009 + (2 - layer) * .003
                    verts += [(x, y, z)]
            surface('Articulated pauldron', verts, grid_faces(3, 13),
                    steel, arm, bone)
            for i in [1, 11]:
                rivet(verts[26 + i], bronze, arm, bone)


def mantle(arm, cloth, archer):
    verts = []
    rows, cols = 15, 17
    for j in range(rows):
        t = j / (rows - 1)
        w = .23 + .08 * t
        for i in range(cols):
            u = i / (cols - 1)
            x = (u * 2 - 1) * w
            y = .14 + .13 * t + .025 * math.cos(u * math.tau * 4)
            z = 1.45 - (.70 if archer else .85) * t
            z += .045 * math.sin(u * math.pi * 5) * t ** 8
            verts += [(x, y, z)]
    obj = surface('Weathered mantle', verts, grid_faces(rows, cols),
            cloth, arm, 'Spine2', .002)
    #Blend the hem to the pelvis, avoiding a rigid board on the shoulders.
    top = obj.vertex_groups.get('mixamorig_Spine2')
    hips = obj.vertex_groups.new(name = 'mixamorig_Hips')
    for v in obj.data.vertices:
        w = min(.85, max(0, (1.3 - v.co.z) / .55))
        top.add([v.index], 1 - w, 'REPLACE')
        hips.add([v.index], w, 'REPLACE')


def load_base(name):
    global BODY
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath = str(OUT / (name + '_v2.glb')))
    arm = next(o for o in bpy.data.objects if o.type == 'ARMATURE')
    for obj in list(bpy.data.objects):
        if obj.type == 'MESH' and obj.parent != arm:
            bpy.data.objects.remove(obj, do_unlink = True)
    body = max((o for o in bpy.data.objects if o.type == 'MESH'),
            key = lambda o: len(o.data.vertices))
    verts = [body.matrix_world @ v.co for v in body.data.vertices]
    BODY = BVHTree.FromPolygons(verts, [p.vertices[:] for p in body.data.polygons])
    return arm


def build(name):
    arm = load_base(name)
    original = set(bpy.data.objects)
    steel = material('Tempered steel', (.105, .135, .15), .82, .38)
    bronze = material('Aged brass', (.30, .19, .07), .75, .43)
    archer = name == 'archer'
    color = (.045, .065, .05) if archer else (.085, .027, .023)
    cloth = material('Weathered wool', color, 0, .93)
    mantle(arm, cloth, archer)
    if not archer:
        breastplate(arm, steel, bronze)
        shoulders(arm, steel, bronze)
    join_parts(original)
    if archer:
        split_bow_string()
    save(name)


def split_bow_string():
    bow = next(o for o in bpy.data.objects if o.type == 'MESH'
            and any(m.name == 'Bow_MAT' for m in o.data.materials))
    bpy.ops.object.select_all(action = 'DESELECT')
    bow.select_set(True)
    bpy.context.view_layer.objects.active = bow
    bpy.ops.object.mode_set(mode = 'EDIT')
    bpy.ops.mesh.select_all(action = 'SELECT')
    bpy.ops.mesh.remove_doubles(threshold = .00001)
    bpy.ops.mesh.separate(type = 'LOOSE')
    bpy.ops.object.mode_set(mode = 'OBJECT')
    parts = list(bpy.context.selected_objects)
    bow = max(parts, key = lambda o: len(o.data.vertices))
    bow.select_set(False)
    bpy.context.view_layer.objects.active = next(o for o in parts if o != bow)
    bpy.ops.object.join()
    bpy.context.object.name = 'BowString'


def join_parts(original):
    bpy.ops.object.select_all(action = 'DESELECT')
    for obj in set(bpy.data.objects) - original:
        obj.select_set(True)
        bpy.context.view_layer.objects.active = obj
    bpy.ops.object.join()
    bpy.context.object.name = 'Armor and mantle'


def save(name):
    source = OUT / 'source'
    source.mkdir(exist_ok = True)
    (source / '.gdignore').touch()
    bpy.context.preferences.filepaths.save_version = 0
    bpy.ops.wm.save_as_mainfile(filepath = str(source / (name + '_v3.blend')))
    bpy.ops.export_scene.gltf(filepath = str(OUT / (name + '_v3.glb')),
            export_format = 'GLB', export_animations = False,
            export_skins = True, export_yup = True)
    print('Wrote', name + '_v3.glb')


names = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else []
for name in names or ['paladin_armed', 'paladin_unarmed', 'archer']:
    build(name)
