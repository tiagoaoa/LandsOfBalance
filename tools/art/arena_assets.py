#Bake distant scenery and cut the submerged boss mesh, keeping its combat rig.
import json
import sys
from pathlib import Path

import bpy
import bmesh
from mathutils import Vector

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'assets/environment/arena_backdrops'
OUT.mkdir(parents=True, exist_ok=True)


def clear():
    bpy.ops.object.select_all(action='SELECT')
    bpy.ops.object.delete(use_global=False)


def camera(at, target, height):
    data = bpy.data.cameras.new('Bake')
    ob = bpy.data.objects.new('Bake', data)
    bpy.context.scene.collection.objects.link(ob)
    ob.location = at
    ob.rotation_euler = (target - ob.location).to_track_quat('-Z', 'Y').to_euler()
    data.type, data.ortho_scale, data.clip_end = 'ORTHO', height, 1000
    bpy.context.scene.camera = ob


def light():
    world = bpy.context.scene.world
    world.use_nodes = True
    world.node_tree.nodes['Background'].inputs['Color'].default_value = (.4, .45, .5, 1)
    world.node_tree.nodes['Background'].inputs['Strength'].default_value = .45
    data = bpy.data.lights.new('Moon', 'AREA')
    data.energy, data.shape, data.size = 80000, 'DISK', 50
    ob = bpy.data.objects.new('Moon', data)
    bpy.context.scene.collection.objects.link(ob)
    ob.location = (-35, -45, 65)
    ob.rotation_euler = (-ob.location).to_track_quat('-Z', 'Y').to_euler()


def bake(name):
    bpy.context.view_layer.update()
    obs = [o for o in bpy.context.scene.objects if o.type == 'MESH']
    pts = [o.matrix_world @ Vector(p) for o in obs for p in o.bound_box]
    lo = Vector(tuple(min(p[i] for p in pts) for i in range(3)))
    hi = Vector(tuple(max(p[i] for p in pts) for i in range(3)))
    center = (lo + hi) * .5
    height = (hi.z - lo.z) * 1.04
    width = (hi.x - lo.x) * 1.04
    camera(Vector((center.x, lo.y - 150, center.z)), center, max(width, height))
    light()
    render(name, width, height)
    return dict(width=width, height=height, x=center.x, y=center.z)


def render(name, width, height):
    scene = bpy.context.scene
    scene.render.engine = 'CYCLES'
    scene.cycles.samples = 24
    scene.cycles.use_denoising = True
    scene.render.film_transparent = True
    scene.render.resolution_x = int(1536 * min(1, width / height))
    scene.render.resolution_y = int(1536 * min(1, height / width))
    scene.render.resolution_percentage = 100
    scene.view_settings.view_transform = 'Standard'
    scene.render.image_settings.file_format = 'PNG'
    scene.render.image_settings.color_mode = 'RGBA'
    scene.render.filepath = str(OUT / (name + '.png'))
    bpy.ops.render.render(write_still=True)


def cliffs():
    clear()
    bpy.ops.import_scene.gltf(filepath=str(ROOT / 'assets/environment/mountainside/mountainside_1k.gltf'))
    return bake('cliff')


def ruins():
    clear()
    bpy.ops.import_scene.gltf(filepath=str(ROOT / 'assets/environment/sanctuary/sanctuary.glb'))
    obs = {o.name: o for o in bpy.context.scene.objects if o.type == 'MESH'}
    for side in [-1, 1]:
        ob = obs['Sanctuary_Buttress'].copy()
        ob.data = ob.data.copy()
        bpy.context.scene.collection.objects.link(ob)
        ob.location = (side * 3.4, 0, -12)
        ob.scale = (.7, 1, 1)
    for name, ob in obs.items():
        if name != 'Sanctuary_Arch':
            bpy.data.objects.remove(ob, do_unlink=True)
    stone_material()
    return bake('ruin')


def stone_material():
    mat = bpy.data.materials.new('Baked rain-worn stone')
    mat.use_nodes = True
    nodes, links = mat.node_tree.nodes, mat.node_tree.links
    bsdf = nodes.get('Principled BSDF')
    coord = nodes.new('ShaderNodeTexCoord')
    mapping = nodes.new('ShaderNodeVectorMath')
    mapping.operation = 'SCALE'
    mapping.inputs[3].default_value = 1 / 4.5
    links.new(coord.outputs['Object'], mapping.inputs[0])
    tex = nodes.new('ShaderNodeTexImage')
    tex.image = bpy.data.images.load(str(ROOT / 'assets/textures/arena/castle_wall_varriation_diff_2k.jpg'))
    tex.projection, tex.projection_blend = 'BOX', .15
    links.new(mapping.outputs[0], tex.inputs['Vector'])
    links.new(tex.outputs['Color'], bsdf.inputs['Base Color'])
    bsdf.inputs['Roughness'].default_value = .85
    for ob in bpy.context.scene.objects:
        if ob.type == 'MESH':
            ob.data.materials.clear()
            ob.data.materials.append(mat)


def upper_body():
    bpy.ops.wm.open_mainfile(filepath=str(ROOT / 'tools/art/source/reptilian_rex.blend'))
    ob = bpy.data.objects['Reptilian_Hide']
    before = len(ob.data.polygons)
    bm = bmesh.new()
    bm.from_mesh(ob.data)
    cut = bmesh.ops.bisect_plane(bm, geom=list(bm.verts) + list(bm.edges) + list(bm.faces),
        plane_co=(0, 0, -3), plane_no=(0, 0, 1), clear_inner=True, dist=.0001)
    edges = [e for e in cut['geom_cut'] if isinstance(e, bmesh.types.BMEdge) and e.is_boundary]
    caps = bmesh.ops.holes_fill(bm, edges=edges, sides=0)['faces']
    assign_caps(ob, bm, caps)
    bmesh.ops.recalc_face_normals(bm, faces=list(bm.faces))
    bm.to_mesh(ob.data)
    bm.free()
    print('ARENA hide polygons:', before, '->', len(ob.data.polygons))
    export_boss()


def assign_caps(ob, bm, faces):
    deform = bm.verts.layers.deform.verify()
    pelvis = ob.vertex_groups['pelvis'].index
    for face in faces:
        face.smooth = False
        for v in face.verts:
            if not v[deform]:
                v[deform][pelvis] = 1


def export_boss():
    bpy.ops.object.select_all(action='DESELECT')
    for ob in bpy.context.scene.objects:
        if ob.type in ['MESH', 'ARMATURE']:
            ob.select_set(True)
    bpy.ops.export_scene.gltf(filepath=str(ROOT / 'assets/characters/reptilian/reptilian_arena.glb'),
        export_format='GLB', use_selection=True, export_animations=False, export_extras=True)


metadata = json.loads((OUT / 'sizes.json').read_text()) if '--ruins-only' in sys.argv else {'cliff': cliffs()}
metadata['ruin'] = ruins()
(OUT / 'sizes.json').write_text(json.dumps(metadata, indent=2) + '\n')
if '--ruins-only' not in sys.argv:
    upper_body()
