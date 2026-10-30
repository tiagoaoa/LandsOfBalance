"""Open the generated lizard-titan meshes side by side for review.

  blender --python tools/art/review_titan_generations.py

Hunyuan3D-2mv results from tools/art/source/lizard_titan/vast_la/ (textured,
both seeds) stand at the same 10 m height in front of the turnaround sheet,
with the viewport in Material Preview so the generated textures show.
"""
from pathlib import Path

import bpy
from mathutils import Vector

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / 'tools/art/source/lizard_titan/vast_la'
SHEET = ROOT / 'tools/art/reference/lizard_titan/turnaround.png'
HEIGHT = 10.0


def clear():
    for ob in list(bpy.data.objects):
        bpy.data.objects.remove(ob, do_unlink=True)


def bounds(obs):
    lo, hi = Vector((1e9,) * 3), Vector((-1e9,) * 3)
    for ob in obs:
        for c in ob.bound_box:
            w = ob.matrix_world @ Vector(c)
            lo = Vector(map(min, lo, w))
            hi = Vector(map(max, hi, w))
    return lo, hi


def place(path, x, label):
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=str(path))
    new = [ob for ob in bpy.data.objects if ob not in before]
    root = bpy.data.objects.new(label, None)
    bpy.context.scene.collection.objects.link(root)
    for ob in new:
        if ob.parent is None:
            ob.parent = root
    bpy.context.view_layer.update()
    lo, hi = bounds([o for o in new if o.type == 'MESH'])
    k = HEIGHT / (hi.z - lo.z)
    root.scale = (k, k, k)
    bpy.context.view_layer.update()
    lo, hi = bounds([o for o in new if o.type == 'MESH'])
    root.location += Vector((x - (lo.x + hi.x) / 2, -(lo.y + hi.y) / 2, -lo.z))
    text = bpy.data.curves.new(label, 'FONT')
    text.body = label
    text.size = 0.6
    t = bpy.data.objects.new(label + '_label', text)
    bpy.context.scene.collection.objects.link(t)
    t.location = (x - 2.5, -4.0, 0.02)
    return root


def sheet():
    img = bpy.data.images.load(str(SHEET))
    ob = bpy.data.objects.new('Turnaround_sheet', None)
    bpy.context.scene.collection.objects.link(ob)
    ob.empty_display_type = 'IMAGE'
    ob.data = img
    ob.empty_display_size = 24.0
    ob.location = (0, 9.0, 8.0)
    ob.rotation_euler = (1.5708, 0, 0)


clear()
models = [('textured_20261024.glb', 'Hunyuan seed 20261024'), ('textured_11.glb', 'Hunyuan seed 11'),
          ('shape_20261024.glb', 'Shape only (seed 20261024)')]
for i, (name, label) in enumerate(models):
    if (SRC / name).is_file():
        place(SRC / name, (i - 1) * 9.0, label)
sheet()
light = bpy.data.objects.new('Key', bpy.data.lights.new('Key', 'SUN'))
light.data.energy = 3.0
light.rotation_euler = (0.9, 0.2, -0.6)
bpy.context.scene.collection.objects.link(light)
for area in bpy.context.screen.areas if bpy.context.screen else []:
    if area.type == 'VIEW_3D':
        for space in area.spaces:
            if space.type == 'VIEW_3D':
                space.shading.type = 'MATERIAL'
                space.overlay.show_floor = True
        with bpy.context.temp_override(area=area, region=area.regions[-1]):
            bpy.ops.view3d.view_all()
print('TITAN REVIEW READY')
