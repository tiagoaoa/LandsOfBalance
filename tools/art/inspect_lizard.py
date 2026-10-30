import bpy
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
bpy.ops.wm.open_mainfile(filepath = str(ROOT / 'assets/characters/lizard/lizard.blend'))
for ob in bpy.context.scene.objects:
    if ob.type == 'MESH':
        print(ob.name, len(ob.data.vertices), tuple(ob.location), [m.name for m in ob.data.materials])
print('HEAD', bpy.data.objects['Colossus_Head'].matrix_world)
