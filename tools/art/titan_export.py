"""Export the rigged, helmeted lizard titan for the game.

  blender -b --python tools/art/titan_export.py

From the generation's blend (build_titan.py, then titan_helmet.py, same
TITAN_GEN) writes assets/characters/reptilian/titan_full.glb and
titan_arena.glb, or titan_trellis_full.glb and titan_trellis_arena.glb. The arena copy drops the hide below z = -3, under the
platform and the fog, as tools/art/arena_assets.py does for the rex body.
"""
import math
import os
from pathlib import Path

import bmesh
import bpy
from mathutils import Matrix, Vector

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'assets/characters/reptilian'
BLEND, NAME = {
    'hunyuan': ('tools/art/source/lizard_titan.blend', 'titan'),
    'trellis': ('tools/art/source/lizard_titan_trellis.blend', 'titan_trellis'),
}[os.environ.get('TITAN_GEN', 'hunyuan')]
BLEND = ROOT / BLEND


def export(path):
    bpy.ops.object.select_all(action='DESELECT')
    for ob in bpy.context.scene.objects:
        if ob.type in ('MESH', 'ARMATURE'):
            ob.select_set(True)
        if ob.type == 'MESH':
            light = [v.index for v in ob.data.vertices if sum(g.weight for g in v.groups) <= 0.9]
            assert not light, '%s: %d vertices under-weighted' % (ob.name, len(light))
    bpy.context.view_layer.objects.active = bpy.data.objects['ReptilianRig']
    bpy.ops.export_scene.gltf(filepath=str(path), export_format='GLB', use_selection=True,
        export_animations=False, export_extras=True, export_yup=True)


def body_geometry(bm, ob):
    deform = bm.verts.layers.deform.verify()
    arms = [g.index for g in ob.vertex_groups
            if g.name.split('.')[0] in ('upperarm', 'forearm', 'hand')]
    #Hanging fingertips cross the same plane as the submerged body.
    keep = {v for v in bm.verts if sum(v[deform].get(g, 0) for g in arms) > 0.5}
    geom = [v for v in bm.verts if v not in keep]
    geom += [e for e in bm.edges if not any(v in keep for v in e.verts)]
    geom += [f for f in bm.faces if not any(v in keep for v in f.verts)]
    return geom


def close_cut(bm, edges, ob):
    caps = bmesh.ops.holes_fill(bm, edges=edges, sides=0)['faces']
    deform = bm.verts.layers.deform.verify()
    pelvis = ob.vertex_groups['pelvis'].index
    for face in caps:
        face.smooth = False
        for v in face.verts:
            if not v[deform]:
                v[deform][pelvis] = 1.0
    #The hide is split at UV seams. Recalculating every disconnected patch
    #reversed thousands of intact faces, leaving holes in the rendered skin.
    bm.normal_update()
    for face in caps:
        if face.normal.z > 0:
            face.normal_flip()


def cut_lower_body():
    ob = bpy.data.objects['Reptilian_Hide']
    bm = bmesh.new()
    bm.from_mesh(ob.data)
    cut = bmesh.ops.bisect_plane(bm, geom=body_geometry(bm, ob),
        plane_co=(0, 0, -3), plane_no=(0, 0, 1), clear_inner=True, dist=0.0001)
    edges = [e for e in cut['geom_cut']
             if isinstance(e, bmesh.types.BMEdge) and e.is_boundary]
    close_cut(bm, edges, ob)
    bm.to_mesh(ob.data)
    bm.free()


#The titan stands upright; the arena expects the rex's hunch (hips back
#behind the rim, head out over it). Upright, its belly ran into the
#platform and the terrain guard pushed the whole boss 6 m back. Pitch the
#body 32 degrees forward about the hips, put the hips where the rex's were
#and lift it 3 m: its heavy chest then clears the rim instead of grinding the
#platform. Measured in the 6x arena: anchor 20.5 m from the centre (rex
#19.9), shoulders 17.4 m (rex 17.4), terrain pushback 1.4 m. At 25 degrees
#the shoulders sat too high and a player at the grab spot was out of reach. The rig's head-local points (ReptilianRig.BODIES.titan) are given
#in this hunched frame.
HUNCH_DEG = 32.0
HIPS = Vector((0.0, -3.75, -5.08))
HIPS_TO = Vector((0.0, 4.68, 3.0))


def hunch():
    m = (Matrix.Translation(HIPS_TO) @ Matrix.Rotation(math.radians(HUNCH_DEG), 4, 'X')
         @ Matrix.Translation(-HIPS))
    rig = bpy.data.objects['ReptilianRig']
    rig.data.transform(m)
    for ob in bpy.context.scene.objects:
        if ob.type == 'MESH':
            ob.data.transform(m)
            ob.data.update()


bpy.ops.wm.open_mainfile(filepath=str(BLEND))
for pb in bpy.data.objects['ReptilianRig'].pose.bones:
    pb.matrix_basis.identity()
hunch()
export(OUT / (NAME + '_full.glb'))
cut_lower_body()
export(OUT / (NAME + '_arena.glb'))
print('TITAN EXPORT', OUT / (NAME + '_full.glb'), OUT / (NAME + '_arena.glb'))
