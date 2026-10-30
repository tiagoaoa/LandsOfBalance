"""Clean the TRELLIS.2 lizard titan before it is rigged.

  blender -b --python tools/art/prepare_trellis.py

TRELLIS.2 writes every UV island as its own shell and leaves a flat ghost
card of the reference image standing on the floor behind the hips, fused to
the tail. Welds the seams, cuts the card out and caps the holes it leaves.
The loose shells after welding are horns, studs, claw tips and tail spikes,
so they stay. Decimated to the Hunyuan titan's budget (FACES): the arena
runs on integrated GPUs. Writes tools/art/source/lizard_titan/trellis_clean.glb in the
generator's own frame (snout -Y, Z up, about a metre long).
"""
from pathlib import Path

import bmesh
import bpy

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / 'tools/art/source/lizard_titan/vast_trellis/trellis_three_quarter_7.glb'
OUT = ROOT / 'tools/art/source/lizard_titan/trellis_clean.glb'

# The card: a sheet facing +-Y at y -0.08..-0.13, between the shins.
CARD_Y = (-0.135, -0.075)
CARD_X = 0.2
CARD_TOP = -0.10
FACES = 150000


def in_card(f):
    p = f.calc_center_median()
    return CARD_Y[0] < p.y < CARD_Y[1] and abs(p.x) < CARD_X and p.z < CARD_TOP


def cut_card(bm):
    seeds = [f for f in bm.faces if abs(f.normal.y) > 0.98 and in_card(f)]
    card = set(seeds)
    todo = list(seeds)
    while todo:
        f = todo.pop()
        for e in f.edges:
            for g in e.link_faces:
                if g not in card and abs(g.normal.y) > 0.9 and in_card(g):
                    card.add(g)
                    todo.append(g)
    bmesh.ops.delete(bm, geom=list(card), context='FACES')
    loose = [v for v in bm.verts if not v.link_faces]
    bmesh.ops.delete(bm, geom=loose, context='VERTS')
    edges = [e for e in bm.edges if e.is_boundary]
    caps = bmesh.ops.holes_fill(bm, edges=edges, sides=64)['faces']
    return len(card), len(caps)


def main():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=str(SRC))
    ob = next(o for o in bpy.data.objects if o.type == 'MESH')
    bm = bmesh.new()
    bm.from_mesh(ob.data)
    before = len(bm.verts)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-6)
    welded = before - len(bm.verts)
    cut, caps = cut_card(bm)
    bm.to_mesh(ob.data)
    bm.free()
    ob.data.update()
    bpy.context.view_layer.objects.active = ob
    mod = ob.modifiers.new('Budget', 'DECIMATE')
    mod.ratio = min(1.0, FACES / len(ob.data.polygons))
    bpy.ops.object.modifier_apply(modifier=mod.name)
    # Welding drops the per-island normals: without this the hide renders faceted.
    for f in ob.data.polygons:
        f.use_smooth = True
    bpy.ops.object.select_all(action='SELECT')
    bpy.ops.export_scene.gltf(filepath=str(OUT), export_format='GLB', use_selection=True)
    print('TRELLIS clean: %d verts welded, %d card faces cut, %d caps, %d faces -> %s'
          % (welded, cut, caps, len(ob.data.polygons), OUT))


main()
