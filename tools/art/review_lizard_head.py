#Match the user's three-quarter head reference in an isolated sculpt review.
import math
from pathlib import Path

import bpy
from mathutils import Vector


ROOT = Path(__file__).resolve().parents[2]
OUT = Path('/tmp/lob-lizard-head')
OUT.mkdir(exist_ok = True)
bpy.ops.wm.open_mainfile(filepath = str(ROOT / 'tools/art/source/lizard_reference.blend'))
scene = bpy.context.scene
scene.render.engine = 'CYCLES'
scene.cycles.samples = 12
scene.cycles.use_denoising = True
scene.render.resolution_x = 960
scene.render.resolution_y = 800
scene.render.resolution_percentage = 100
scene.render.image_settings.file_format = 'PNG'
scene.world = bpy.data.worlds.new('ReviewWorld')
scene.world.use_nodes = True
scene.world.node_tree.nodes['Background'].inputs[0].default_value = (.11, .12, .13, 1)
scene.world.node_tree.nodes['Background'].inputs[1].default_value = .45
scene.view_settings.view_transform = 'AgX'


def aim(ob, target):
    ob.rotation_euler = (Vector(target) - ob.location).to_track_quat('-Z', 'Y').to_euler()


def area(name, loc, energy, size):
    data = bpy.data.lights.new(name, 'AREA')
    data.energy, data.shape, data.size = energy, 'DISK', size
    ob = bpy.data.objects.new(name, data)
    scene.collection.objects.link(ob)
    ob.location = loc
    aim(ob, (0, -1, 14))


camera = bpy.data.cameras.new('HeadCamera')
cam = bpy.data.objects.new('HeadCamera', camera)
scene.collection.objects.link(cam)
scene.camera = cam
cam.location = (12, -15, 17)
aim(cam, (0, -1.4, 14.3))
camera.type = 'ORTHO'
camera.ortho_scale = 8.0
area('Key', (4, -8, 22), 2400, 7)
area('Fill', (-5, -7, 16), 650, 9)
area('Rim', (2, 5, 19), 2700, 5)


with bpy.context.temp_override(window = bpy.context.window_manager.windows[0]):
    for label, angle in [('open', 62), ('closed', 0)]:
        bpy.data.objects['Colossus_Jaw'].rotation_euler.x = math.radians(angle)
        scene.render.filepath = str(OUT / (label + '.png'))
        bpy.ops.render.render(write_still = True)
print('Head study:', OUT)
