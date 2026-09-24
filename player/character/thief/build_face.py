"""Build the thief's head from the pristine base.  Run from this folder:

    blender -b nego_thief_base.blend --python build_face.py -- <tmpdir>

Sculpts, dumps the mesh, rasterises the position maps, projects the reference
photograph, wires the materials, saves nego_thief.blend and exports the glb.
The base file is never written to, so the whole pass is repeatable.
"""
import os
import subprocess
import sys

import bpy
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
TMP = (sys.argv[sys.argv.index("--") + 1] if "--" in sys.argv else "/tmp/thief")
os.makedirs(TMP, exist_ok=True)

import apply_face
import head_sculpt

head_sculpt.main()

# ---- dump the sculpted mesh for the texture pipeline ----------------------
import bmesh

out = {}
for name in ("Thief_Body", "Thief_Eyes", "Thief_Clothes"):
    ob = bpy.data.objects[name]
    me = ob.data
    M = np.array(ob.matrix_world)
    n = len(me.vertices)
    co = np.empty(n * 3, np.float32)
    me.vertices.foreach_get("co", co)
    co = co.reshape(n, 3) @ M[:3, :3].T + M[:3, 3]
    nor = np.empty(n * 3, np.float32)
    me.vertices.foreach_get("normal", nor)
    nor = nor.reshape(n, 3) @ M[:3, :3].T
    nor /= np.linalg.norm(nor, axis=1, keepdims=True) + 1e-9

    bm = bmesh.new()
    bm.from_mesh(me)
    bm.verts.ensure_lookup_table()
    seen, inner = set(), np.zeros(n, np.float32)
    for v in bm.verts:
        if v.index in seen:
            continue
        st, comp = [v], []
        seen.add(v.index)
        while st:
            c = st.pop()
            comp.append(c.index)
            for e in c.link_edges:
                o = e.other_vert(c)
                if o.index not in seen:
                    seen.add(o.index)
                    st.append(o)
        # teeth and the inner mouth bag are small shells up inside the head
        if len(comp) < 700 and co[comp][:, 2].mean() > 1.55:
            inner[comp] = 1.0
    bm.free()

    nl = len(me.loops)
    uv = np.empty(nl * 2, np.float32)
    me.uv_layers.active.data.foreach_get("uv", uv)
    me.calc_loop_triangles()
    lt = me.loop_triangles
    tl = np.empty(len(lt) * 3, np.int32)
    lt.foreach_get("loops", tl)
    tv = np.empty(len(lt) * 3, np.int32)
    lt.foreach_get("vertices", tv)
    out[name + "_co"] = co.astype(np.float32)
    out[name + "_no"] = nor.astype(np.float32)
    out[name + "_in"] = inner
    out[name + "_uv"] = uv.reshape(nl, 2)
    out[name + "_tl"] = tl.reshape(-1, 3)
    out[name + "_tv"] = tv.reshape(-1, 3)
np.savez(os.path.join(TMP, "meshdata.npz"), **out)

# ---- textures (plain python: bpy's numpy is fine but PIL lives outside) ----
env = dict(os.environ, THIEF_TMP=TMP)
for script in ("posmap.py", "face_project.py"):
    subprocess.run(["python3",
                    os.path.join(HERE, script)], cwd=HERE, env=env, check=True)

apply_face.main()

bpy.ops.wm.save_as_mainfile(filepath=os.path.join(HERE, "nego_thief.blend"))
bpy.ops.object.select_all(action="DESELECT")
for name in ("Armature", "Thief_Body", "Thief_Eyes", "Thief_Clothes"):
    bpy.data.objects[name].select_set(True)
bpy.context.view_layer.objects.active = bpy.data.objects["Armature"]
bpy.ops.export_scene.gltf(filepath=os.path.join(HERE, "nego_thief.glb"),
                          use_selection=True, export_animations=False, export_yup=True)
print("BUILD OK")
