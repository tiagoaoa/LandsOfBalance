"""Rig the supplied C-List mesh. Run with tools/art/blender_mcp.py."""
import math
from pathlib import Path
import bpy
import bmesh
import numpy as np
from mathutils import Vector

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'assets/characters/reptilian'
OUT.mkdir(exist_ok = True)
ORIGIN = Vector((1.12, 0, -.8))
SCALE = 9.0

# Joint centres measured in the supplied mesh, before normalization.
JOINTS = {
    'pelvis': ((1.13, .52, -.94), (1.12, .25, -.45), None),
    'spine': ((1.12, .25, -.45), (1.12, -.2, .12), 'pelvis'),
    'chest': ((1.12, -.2, .12), (1.08, -.52, .55), 'spine'),
    'neck': ((1.08, -.52, .55), (1.12, -.9, .72), 'chest'),
    'head': ((1.12, -.9, .72), (1.14, -1.82, .70), 'neck'),
    'jaw': ((1.15, -1.10, .48), (1.15, -1.77, .24), 'head'),
    'upperarm.L': ((.51, -.28, .43), (.17, .65, .28), 'chest'),
    'forearm.L': ((.17, .65, .28), (-.47, .86, -.01), 'upperarm.L'),
    'hand.L': ((-.47, .86, -.01), (-.94, 1.41, -.15), 'forearm.L'),
    'upperarm.R': ((1.78, -.35, .17), (2.12, .10, -.10), 'chest'),
    'forearm.R': ((2.12, .10, -.10), (2.72, .12, -.47), 'upperarm.R'),
    'hand.R': ((2.72, .12, -.47), (3.24, .20, -.75), 'forearm.R'),
    'thigh.L': ((.78, .53, -.95), (.69, .32, -1.93), 'pelvis'),
    'shin.L': ((.69, .32, -1.93), (.91, .35, -2.95), 'thigh.L'),
    'foot.L': ((.91, .35, -2.95), (.63, -.13, -3.04), 'shin.L'),
    'thigh.R': ((1.55, .70, -.95), (1.67, 1.54, -1.90), 'pelvis'),
    'shin.R': ((1.67, 1.54, -1.90), (1.52, 1.91, -2.95), 'thigh.R'),
    'foot.R': ((1.52, 1.91, -2.95), (1.54, 1.44, -3.04), 'shin.R'),
    'tail1': ((1.18, 1.00, -1.03), (.75, 1.78, -1.54), 'pelvis'),
    'tail2': ((.75, 1.78, -1.54), (.60, 2.69, -1.60), 'tail1'),
    'tail3': ((.60, 2.69, -1.60), (.21, 3.27, -1.97), 'tail2'),
}


def point(p):
    return (Vector(p) - ORIGIN) * SCALE


def load_mesh():
    for ob in list(bpy.data.objects):
        bpy.data.objects.remove(ob, do_unlink = True)
    bpy.ops.import_scene.gltf(filepath = str(ROOT / 'reptillian_alien.glb'))
    meshes = [o for o in bpy.context.scene.objects if o.type == 'MESH']
    bpy.ops.object.select_all(action = 'DESELECT')
    for ob in meshes:
        ob.data.transform(ob.matrix_world)
        ob.parent = None
        ob.matrix_world.identity()
        ob.select_set(True)
    bpy.context.view_layer.objects.active = meshes[0]
    bpy.ops.object.join()
    ob = bpy.context.object
    ob.name = 'Reptilian_Hide'
    bm = bmesh.new()
    bm.from_mesh(ob.data)
    bmesh.ops.remove_doubles(bm, verts = list(bm.verts), dist = .00005)
    bm.to_mesh(ob.data)
    bm.free()
    mod = ob.modifiers.new('Game mesh', 'DECIMATE')
    mod.ratio = .48
    bpy.ops.object.modifier_apply(modifier = mod.name)
    for poly in ob.data.polygons:
        poly.use_smooth = True
    return ob


def skin_material(ob):
    # Cube UVs are in source metres, so the fine scales keep the same size.
    bpy.ops.object.mode_set(mode = 'EDIT')
    bpy.ops.mesh.select_all(action = 'SELECT')
    bpy.ops.uv.cube_project(cube_size = .48)
    bpy.ops.object.mode_set(mode = 'OBJECT')
    mat = bpy.data.materials.new('Reptilian_DarkScales')
    mat.use_nodes = True
    bs = mat.node_tree.nodes.get('Principled BSDF')
    bs.inputs['Roughness'].default_value = .52
    for channel, socket in [('albedo', 'Base Color'), ('roughness', 'Roughness'), ('normal', 'Normal')]:
        tex = mat.node_tree.nodes.new('ShaderNodeTexImage')
        path = ROOT / ('assets/characters/lizard/ssethrak_hide_%s.png' % channel)
        tex.image = bpy.data.images.load(str(path), check_existing = True)
        if channel != 'albedo':
            tex.image.colorspace_settings.name = 'Non-Color'
        output = tex.outputs['Color']
        if channel == 'normal':
            normal = mat.node_tree.nodes.new('ShaderNodeNormalMap')
            normal.inputs['Strength'].default_value = .65
            mat.node_tree.links.new(output, normal.inputs['Color'])
            output = normal.outputs['Normal']
        mat.node_tree.links.new(output, bs.inputs[socket])
    ob.data.materials.clear()
    ob.data.materials.append(mat)


def make_rig():
    data = bpy.data.armatures.new('ReptilianSkeleton')
    rig = bpy.data.objects.new('ReptilianRig', data)
    bpy.context.scene.collection.objects.link(rig)
    bpy.context.view_layer.objects.active = rig
    rig.select_set(True)
    bpy.ops.object.mode_set(mode = 'EDIT')
    for name, (a, b, parent) in JOINTS.items():
        bone = data.edit_bones.new(name)
        bone.head, bone.tail = point(a), point(b)
        if parent:
            bone.parent = data.edit_bones[parent]
    bpy.ops.object.mode_set(mode = 'OBJECT')
    return rig


def weights(ob, rig):
    p = np.array([tuple(v.co) for v in ob.data.vertices])
    names = list(JOINTS)
    dist = np.zeros((len(p), len(names)))
    for i, (a, b, _) in enumerate(JOINTS.values()):
        a, b = np.array(a), np.array(b)
        d = b - a
        t = np.clip((p - a) @ d / (d @ d), .05, .95)
        dist[:, i] = np.linalg.norm(p - a - t[:, None] * d, axis = 1)
    # Teeth and the lower lip follow the mandible, without pulling the skull.
    jaw = (p[:, 1] < -1.06) & (p[:, 2] < .48 + (p[:, 1] + 1.1) * .18)
    head = (p[:, 1] < -.94) & ~jaw & (p[:, 2] > .15)
    dist[~jaw, names.index('jaw')] = 100
    dist[jaw] = 100
    dist[jaw, names.index('jaw')] = .01
    dist[head] = 100
    dist[head, names.index('head')] = .01
    order = np.argsort(dist, axis = 1)[:, :4]
    w = 1 / np.maximum(np.take_along_axis(dist, order, axis = 1), .035) ** 6
    w /= w.sum(axis = 1)[:, None]
    groups = [ob.vertex_groups.new(name = name) for name in names]
    for v in ob.data.vertices:
        for k in range(4):
            if w[v.index, k] > .005:
                groups[order[v.index, k]].add([v.index], float(w[v.index, k]), 'REPLACE')
        v.co = point(v.co)
    mod = ob.modifiers.new('Combat skeleton', 'ARMATURE')
    mod.object = rig
    ob.parent = rig


def export(ob, rig):
    bpy.ops.object.select_all(action = 'DESELECT')
    ob.select_set(True)
    rig.select_set(True)
    bpy.context.view_layer.objects.active = rig
    bpy.ops.export_scene.gltf(filepath = str(OUT / 'reptilian_dark.glb'),
        export_format = 'GLB', use_selection = True, export_animations = False,
        export_extras = True, export_yup = True)
    bpy.context.preferences.filepaths.save_version = 0
    bpy.ops.wm.save_as_mainfile(filepath = str(ROOT / 'tools/art/source/reptilian_dark.blend'))
    print('REPTILIAN', len(ob.data.vertices), len(ob.data.polygons), 'triangles', len(JOINTS), 'bones')


with bpy.context.temp_override(window = bpy.context.window_manager.windows[0]):
    mesh = load_mesh()
    skin_material(mesh)
    rig = make_rig()
    weights(mesh, rig)
    rig['source'] = 'Reptillian Alien by C-List, CC-BY-4.0. See NOTICE.md.'
    export(mesh, rig)
