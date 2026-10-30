"""Prepare the supplied boss turnaround for modelling and multiview generation."""
import json
import math
import shutil
from pathlib import Path

import bpy
import numpy as np
from mathutils import Euler

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'tools/art/reference/helmeted_lizard'
SOURCE = Path('/home/talves/Downloads/Photorealistic Helmeted Lizard Turnaround Sheet.png')
# Pixel rectangles exclude labels and neighbouring views, retaining every claw/tail.
VIEWS = {
    'front': (72, 5, 424, 455),
    'left': (551, 5, 1015, 455),
    'back': (1120, 5, 1445, 460),
    'right': (5, 493, 461, 951),
    'front_three_quarter': (572, 493, 1009, 949),
    'back_three_quarter': (1111, 493, 1528, 951),
}


def references():
    OUT.mkdir(parents=True, exist_ok=True)
    shutil.copy2(SOURCE, OUT / 'turnaround.png')
    image = bpy.data.images.load(str(OUT / 'turnaround.png'))
    w, h = image.size
    pixels = np.empty(w*h*4, dtype=np.float32)
    image.pixels.foreach_get(pixels)
    pixels = pixels.reshape(h, w, 4)
    for name, (x0, y0, x1, y1) in VIEWS.items():
        crop = bpy.data.images.new(name, x1-x0, y1-y0, alpha=True)
        crop.pixels.foreach_set(pixels[h-y1:h-y0, x0:x1].ravel())
        crop.filepath_raw = str(OUT / (name + '.png'))
        crop.file_format = 'PNG'
        crop.save()
    (OUT / 'views.json').write_text(json.dumps({
        'source': str(SOURCE), 'size': [w, h], 'rectangles': VIEWS,
        'note': 'Exact pixel crops; no generated or repainted details.',
    }, indent=2) + '\n')


def scene():
    for ob in list(bpy.data.objects):
        bpy.data.objects.remove(ob, do_unlink=True)
    refs = bpy.data.collections.new('Turnaround references')
    bpy.context.scene.collection.children.link(refs)
    # Ten metres from sole to helmet, front faces -Y.
    for name, pos, rot in [
        ('front', (0, 1.5, 5), (1.570796, 0, 0)),
        ('left', (3, 2.65, 5), (1.570796, 0, 1.570796)),
        ('back', (0, -1.5, 5), (1.570796, 0, 3.141593)),
    ]:
        ob = bpy.data.objects.new('Reference_' + name, None)
        refs.objects.link(ob)
        ob.empty_display_type = 'IMAGE'
        ob.data = bpy.data.images[name]
        ob.data.pack()
        ob.location, ob.rotation_euler = pos, Euler(rot)
        ob.empty_display_size = 10.5 * max(ob.data.size) / ob.data.size[1]
        ob.empty_image_depth = 'BACK'
        ob.show_empty_image_orthographic = True
        ob.show_empty_image_perspective = False
        ob.hide_render = True
        ob['source'] = 'User-supplied turnaround; do not reinterpret proportions.'
    for name in VIEWS:
        bpy.data.images[name].pack()
        bpy.data.images[name].use_fake_user = True
    rig_template()
    bpy.context.scene['design'] = 'Anthropomorphic helmeted lizard; compact muzzle, muscular upright body, long tail.'
    bpy.context.scene['status'] = 'Reference and rig template only. Generated mesh, skinning and runtime calibration pending.'
    bpy.context.preferences.filepaths.save_version = 0
    bpy.ops.wm.save_as_mainfile(filepath=str(ROOT / 'tools/art/source/helmeted_lizard_reference.blend'))


def rig_template():
    # Reference-scale landmarks. Refit to the generated mesh before binding.
    joints = {
        'pelvis': ((0, .2, 4.7), (0, .1, 5.8), None),
        'spine': ((0, .1, 5.8), (0, 0, 7.0), 'pelvis'),
        'chest': ((0, 0, 7.0), (0, .05, 8.0), 'spine'),
        'neck': ((0, .05, 8.0), (0, -.1, 8.9), 'chest'),
        'head': ((0, -.1, 8.9), (0, -.85, 9.1), 'neck'),
        'jaw': ((0, -.12, 8.72), (0, -.88, 8.72), 'head'),
        'tail1': ((0, .65, 4.7), (0, 2.5, 2.65), 'pelvis'),
        'tail2': ((0, 2.5, 2.65), (0, 5, 1.1), 'tail1'),
        'tail3': ((0, 5, 1.1), (0, 8.2, .4), 'tail2'),
    }
    for suffix, s in [('.L', -1), ('.R', 1)]:
        def p(x, y, z):
            return (x*s, y, z)
        joints.update({
            'upperarm'+suffix: (p(1.43, 0, 7.3), p(2.4, -.03, 5.65), 'chest'),
            'forearm'+suffix: (p(2.4, -.03, 5.65), p(3.03, -.08, 4.5), 'upperarm'+suffix),
            'hand'+suffix: (p(3.03, -.08, 4.5), p(3.23, -.15, 3.6), 'forearm'+suffix),
            'thigh'+suffix: (p(.8, .2, 4.8), p(1.15, -.1, 2.9), 'pelvis'),
            'shin'+suffix: (p(1.15, -.1, 2.9), p(1.3, .45, 1.0), 'thigh'+suffix),
            'foot'+suffix: (p(1.3, .45, 1.0), p(1.4, -.65, .2), 'shin'+suffix),
        })
    data = bpy.data.armatures.new('BossCombatTemplate')
    rig = bpy.data.objects.new('BossCombatTemplate_UNBOUND', data)
    bpy.context.scene.collection.objects.link(rig)
    bpy.context.view_layer.objects.active = rig
    rig.select_set(True)
    rig.show_in_front = True
    rig['status'] = 'Unbound anatomical template; not a game-ready rig.'
    bpy.ops.object.mode_set(mode='EDIT')
    for name, (head, tail, parent) in joints.items():
        bone = data.edit_bones.new(name)
        bone.head, bone.tail = head, tail
        if parent:
            bone.parent = data.edit_bones[parent]
    bpy.ops.object.mode_set(mode='OBJECT')
    bpy.context.scene.unit_settings.system = 'METRIC'
    # Open directly onto the front reference, with the guide bones visible.
    for screen in bpy.data.screens:
        for area in screen.areas:
            if area.type == 'VIEW_3D':
                view = area.spaces.active.region_3d
                view.view_rotation = Euler((math.pi/2, 0, 0)).to_quaternion()
                view.view_location = (0, 0, 5)
                view.view_distance = 15
                view.view_perspective = 'ORTHO'


references()
scene()
print('TURNAROUND_READY', OUT)
