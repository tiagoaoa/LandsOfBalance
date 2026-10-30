#Head and helmet under neutral light, including the acid jaw opening.
import math
from pathlib import Path

import bpy
from mathutils import Matrix, Vector

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'docs/presentation/rex-helmet'
OUT.mkdir(exist_ok=True)
bpy.ops.wm.open_mainfile(filepath=str(ROOT/'tools/art/source/reptilian_rex.blend'))
scene = bpy.context.scene
scene.render.engine = 'CYCLES'
scene.cycles.samples = 32
scene.cycles.use_denoising = True
scene.render.resolution_x, scene.render.resolution_y = 1200, 900
scene.render.resolution_percentage = 100
scene.world = bpy.data.worlds.new('HeadStudy')
scene.world.use_nodes = True
scene.world.node_tree.nodes['Background'].inputs[0].default_value = (.055,.07,.09,1)
scene.world.node_tree.nodes['Background'].inputs[1].default_value = .6
scene.view_settings.view_transform = 'AgX'
at = Vector((0,-12.5,13.5))
mat = bpy.data.materials['Reptilian_DarkScales']
uv = mat.node_tree.nodes.new('ShaderNodeTexCoord')
scale = mat.node_tree.nodes.new('ShaderNodeVectorMath')
scale.operation = 'SCALE'
scale.inputs[3].default_value = 2.5
mat.node_tree.links.new(uv.outputs['UV'],scale.inputs[0])
for node in list(mat.node_tree.nodes):
    if node.type == 'TEX_IMAGE':
        mat.node_tree.links.new(scale.outputs['Vector'],node.inputs['Vector'])
    if node.type == 'NORMAL_MAP':
        node.inputs['Strength'].default_value = .22


def aim(ob):
    ob.rotation_euler = (at-ob.location).to_track_quat('-Z','Y').to_euler()


def light(name, pos, power, size, color):
    ob = bpy.data.objects.new(name,bpy.data.lights.new(name,'AREA'))
    scene.collection.objects.link(ob)
    ob.location = pos
    ob.data.energy, ob.data.size, ob.data.color = power, size, color
    aim(ob)


cam = bpy.data.objects.new('HeadCamera',bpy.data.cameras.new('HeadCamera'))
scene.collection.objects.link(cam)
scene.camera = cam
cam.data.type = 'ORTHO'
cam.data.ortho_scale = 16
light('Key',(9,-25,27),18000,10,(.85,.92,1))
light('Rim',(-8,-3,22),18000,8,(.55,.72,1))
light('Fill',(-12,-25,12),5000,10,(1,.8,.57))
rig = bpy.data.objects['ReptilianRig']
rest = rig.data.bones['jaw'].matrix_local
pivot = Vector((.27,-9.9,11.52))
for name, pos, angle in [('closed',(17,-31,19),-30),('profile',(30,-12.5,16),-30),
                         ('open',(17,-31,19),4),('front',(0,-38,17),-30)]:
    rot = Matrix.Translation(pivot) @ Matrix.Rotation(math.radians(angle),4,'X') @ Matrix.Translation(-pivot)
    rig.pose.bones['jaw'].matrix_basis = rest.inverted() @ rot @ rest
    cam.location = pos
    aim(cam)
    scene.render.filepath = str(OUT/('sculpt_'+name+'.png'))
    bpy.ops.render.render(write_still=True)
