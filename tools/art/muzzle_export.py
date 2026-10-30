#Save the muzzled boss and export both GLBs the game and tools use:
#reptilian_rex.glb (full body) and reptilian_arena.glb (lower body cut away,
#as tools/art/arena_assets.py does). Run after tools/art/muzzle_helmet.py.
from pathlib import Path

import bmesh
import bpy
from mathutils import Euler

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'assets/characters/reptilian'
BLEND = ROOT / 'tools/art/source/reptilian_rex.blend'


def select_export_set():
    bpy.ops.object.select_all(action='DESELECT')
    for ob in bpy.context.scene.objects:
        if ob.type in ['MESH', 'ARMATURE']:
            ob.select_set(True)
        if ob.type == 'MESH':
            assert all(sum(g.weight for g in v.groups) > .9 for v in ob.data.vertices), ob.name
    bpy.context.view_layer.objects.active = bpy.data.objects['ReptilianRig']


def export(path):
    select_export_set()
    bpy.ops.export_scene.gltf(filepath=str(path), export_format='GLB', use_selection=True,
        export_animations=False, export_extras=True, export_yup=True)


def cut_lower_body():
    ob = bpy.data.objects['Reptilian_Hide']
    bm = bmesh.new()
    bm.from_mesh(ob.data)
    cut = bmesh.ops.bisect_plane(bm, geom=list(bm.verts) + list(bm.edges) + list(bm.faces),
        plane_co=(0, 0, -3), plane_no=(0, 0, 1), clear_inner=True, dist=.0001)
    edges = [e for e in cut['geom_cut'] if isinstance(e, bmesh.types.BMEdge) and e.is_boundary]
    caps = bmesh.ops.holes_fill(bm, edges=edges, sides=0)['faces']
    deform = bm.verts.layers.deform.verify()
    pelvis = ob.vertex_groups['pelvis'].index
    for face in caps:
        face.smooth = False
        for v in face.verts:
            if not v[deform]:
                v[deform][pelvis] = 1
    bmesh.ops.recalc_face_normals(bm, faces=list(bm.faces))
    bm.to_mesh(ob.data)
    bm.free()


if bpy.context.object and bpy.context.object.mode != 'OBJECT':
    bpy.ops.object.mode_set(mode='OBJECT')
#Export the rest pose; the game closes the jaw itself.
bpy.data.objects['ReptilianRig'].pose.bones['jaw'].rotation_euler = Euler((0, 0, 0))
bpy.context.preferences.filepaths.save_version = 0
bpy.ops.wm.save_as_mainfile(filepath=str(BLEND))
export(OUT / 'reptilian_rex.glb')
cut_lower_body()
export(OUT / 'reptilian_arena.glb')
#Back to the saved, uncut source so further edits start from it.
bpy.ops.wm.open_mainfile(filepath=str(BLEND))
print('MUZZLE EXPORT', OUT / 'reptilian_rex.glb', OUT / 'reptilian_arena.glb')
