#Inspect the supplied static mesh before adding a combat skeleton.
import math
from pathlib import Path
import bpy
from mathutils import Vector

ROOT = Path(__file__).resolve().parents[2]
OUT = Path('/tmp/lob-reptilian-inspect')
OUT.mkdir(exist_ok = True)
for ob in list(bpy.data.objects):
    bpy.data.objects.remove(ob, do_unlink = True)
with bpy.context.temp_override(window = bpy.context.window_manager.windows[0]):
    bpy.ops.import_scene.gltf(filepath = str(ROOT / 'reptillian_alien.glb'))
meshes = [o for o in bpy.context.scene.objects if o.type == 'MESH']
points = [o.matrix_world @ v.co for o in meshes for v in o.data.vertices]
lo = Vector(tuple(min(p[i] for p in points) for i in range(3)))
hi = Vector(tuple(max(p[i] for p in points) for i in range(3)))
center = (lo + hi) / 2
print('BOUNDS', tuple(lo), tuple(hi))
for ob in meshes:
    print('MESH', ob.name, len(ob.data.vertices), len(ob.data.polygons))
    for mat in ob.data.materials:
        mat.use_nodes = True
        shader = mat.node_tree.nodes.get('Principled BSDF')
        shader.inputs['Base Color'].default_value = (.22, .25, .23, 1)
        shader.inputs['Roughness'].default_value = .7
scene = bpy.context.scene
scene.render.engine = 'CYCLES'
scene.cycles.samples = 8
scene.cycles.use_denoising = True
scene.render.resolution_x = 800
scene.render.resolution_y = 800
scene.render.resolution_percentage = 100
scene.world = bpy.data.worlds.new('InspectWorld')
scene.world.use_nodes = True
scene.world.node_tree.nodes['Background'].inputs[0].default_value = (.15, .15, .15, 1)
scene.world.node_tree.nodes['Background'].inputs[1].default_value = .65


def aim(ob, target):
    ob.rotation_euler = (target - ob.location).to_track_quat('-Z', 'Y').to_euler()


camera = bpy.data.cameras.new('InspectCamera')
cam = bpy.data.objects.new('InspectCamera', camera)
scene.collection.objects.link(cam)
scene.camera = cam
camera.type = 'ORTHO'
camera.ortho_scale = max(hi - lo) * 1.14
lamp = bpy.data.lights.new('InspectLight', 'AREA')
lamp.energy, lamp.size = 1300, 6
light = bpy.data.objects.new('InspectLight', lamp)
scene.collection.objects.link(light)
with bpy.context.temp_override(window = bpy.context.window_manager.windows[0]):
    for label, p in [('front', (0, -14, 2)), ('side', (14, 0, 2)), ('back', (0, 14, 2))]:
        cam.location = center + Vector(p)
        aim(cam, center)
        light.location = cam.location + Vector((-3, -2, 5))
        aim(light, center)
        scene.render.filepath = str(OUT / (label + '.png'))
        bpy.ops.render.render(write_still = True)
bpy.context.preferences.filepaths.save_version = 0
with bpy.context.temp_override(window = bpy.context.window_manager.windows[0]):
    bpy.ops.wm.save_as_mainfile(filepath = str(ROOT / 'tools/art/source/reptilian_inspect.blend'))
