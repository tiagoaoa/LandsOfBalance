import bpy
from pathlib import Path
from mathutils import Vector

ROOT = Path(__file__).resolve().parents[2]
scene = bpy.context.scene
scene.render.engine = 'CYCLES'
scene.cycles.samples = 12
scene.cycles.use_denoising = True
scene.render.resolution_x = 1000
scene.render.resolution_y = 1000
scene.render.resolution_percentage = 100
scene.world = bpy.data.worlds.new('ReviewWorld')
scene.world.use_nodes = True
scene.world.node_tree.nodes['Background'].inputs[0].default_value = (.12, .12, .12, 1)
scene.world.node_tree.nodes['Background'].inputs[1].default_value = .8
cam = bpy.data.objects.new('ReviewCamera', bpy.data.cameras.new('ReviewCamera'))
scene.collection.objects.link(cam)
scene.camera = cam
cam.location = (30, -60, 21)
cam.rotation_euler = (Vector((0, 0, 3)) - cam.location).to_track_quat('-Z', 'Y').to_euler()
cam.data.type = 'ORTHO'
cam.data.ortho_scale = 48
light = bpy.data.objects.new('ReviewKey', bpy.data.lights.new('ReviewKey', 'AREA'))
scene.collection.objects.link(light)
light.data.energy = 40000
light.data.size = 25
light.location = (0, -30, 35)
light.rotation_euler = (Vector((0, 0, 3)) - light.location).to_track_quat('-Z', 'Y').to_euler()
for ob in scene.objects:
    if ob.type == 'MESH':
        print('MODEL', ob.name, tuple(ob.location), tuple(ob.scale), ob.matrix_world)
        mat = ob.data.materials[0]
        bs = mat.node_tree.nodes.get('Principled BSDF')
        for link in list(mat.node_tree.links):
            if link.to_node == bs:
                mat.node_tree.links.remove(link)
        bs.inputs['Base Color'].default_value = (.2, .22, .21, 1)
        bs.inputs['Roughness'].default_value = .75
with bpy.context.temp_override(window = bpy.context.window_manager.windows[0]):
    scene.render.filepath = '/tmp/lob-reptilian-rest.png'
    bpy.ops.render.render(write_still = True)
