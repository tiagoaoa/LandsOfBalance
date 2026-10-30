"""Fit Bobba's finger bones to the replacement mesh and weight the right hand.

blender --factory-startup -b -P tools/rig_bobba_hand.py
"""
from pathlib import Path

import bpy
import numpy as np
from mathutils import Vector

ROOT = Path(__file__).resolve().parents[1]
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=str(ROOT / "assets/bobba/bobba_v2.glb"))
arm = next(o for o in bpy.data.objects if o.type == 'ARMATURE')
body = max((o for o in bpy.data.objects if o.type == 'MESH'),
           key=lambda o: len(o.data.vertices))
hand = arm.data.bones['mixamorig_RightHand']
frame = hand.matrix_local.copy()
inv = frame.inverted()

bpy.context.view_layer.objects.active = arm
bpy.ops.object.mode_set(mode='EDIT')
for bone in arm.data.edit_bones:
    if not bone.name.startswith('mixamorig_RightHand') or bone.name == hand.name:
        continue
    bone.use_connect = False
    for attr in ('head', 'tail'):
        p = inv @ getattr(bone, attr)
        p.y = p.y * .45 + .02
        p.z = p.z * .65 - .015
        setattr(bone, attr, frame @ p)
bpy.ops.object.mode_set(mode='OBJECT')

bones = [b for b in arm.data.bones if b.name.startswith('mixamorig_RightHand')
         and not b.name.endswith('4')]
heads = np.array([list(inv @ b.head_local) for b in bones])
tails = np.array([list(inv @ b.tail_local) for b in bones])
#The palm influence ends at the knuckles, not the old oversized hand tip.
tails[0] = [0, .095, -.015]
seg = tails - heads
length = np.maximum((seg * seg).sum(1), 1e-8)
groups = [body.vertex_groups.get(b.name) or body.vertex_groups.new(name=b.name)
          for b in bones]
hand_idx = body.vertex_groups['mixamorig_RightHand'].index
to_hand = inv @ arm.matrix_world.inverted() @ body.matrix_world
count = 0
for v in body.data.vertices:
    weight = next((g.weight for g in v.groups if g.group == hand_idx), 0)
    if weight < .5:
        continue
    p = np.array(to_hand @ v.co)
    t = np.clip(((p - heads) * seg).sum(1) / length, 0, 1)
    dist = np.linalg.norm(p - heads - t[:, None] * seg, axis=1)
    w = 1 / np.maximum(dist, .005) ** 6
    keep = np.argsort(-w)[:3]
    w /= w[keep].sum()
    body.vertex_groups['mixamorig_RightHand'].remove([v.index])
    for i in keep:
        groups[i].add([v.index], float(w[i] * weight), 'REPLACE')
    count += 1

out = ROOT / 'assets/bobba/bobba_grip.glb'
bpy.ops.export_scene.gltf(filepath=str(out), export_format='GLB',
                          export_animations=False)
print('Weighted %d right-hand vertices: %s' % (count, out))
