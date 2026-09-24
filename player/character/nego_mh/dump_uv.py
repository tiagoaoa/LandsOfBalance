import bpy, os, sys, json, numpy as np
S = sys.argv[sys.argv.index("--")+1]
bm = bpy.data.objects["Human"]
me = bm.data
uv = me.uv_layers.active.data
polys, uvs, mats = [], [], []
for p in me.polygons:
    idx = list(p.vertices); lo = list(p.loop_indices)
    for k in range(1, len(idx) - 1):                 # fan-triangulate quads
        polys.append((idx[0], idx[k], idx[k+1]))
        uvs.append((uv[lo[0]].uv[:], uv[lo[k]].uv[:], uv[lo[k+1]].uv[:]))
        mats.append(p.material_index)
np.savez(os.path.join(S, "uvmesh.npz"), tris=np.array(polys), uvs=np.array(uvs), mats=np.array(mats))
# vertex groups (helpers vs body) — which verts are body
vg = {g.index: g.name for g in bm.vertex_groups}
body = np.zeros(len(me.vertices), bool)
for v in me.vertices:
    for g in v.groups:
        if vg[g.group] == "body" and g.weight > 0.5: body[v.index] = True
np.save(os.path.join(S, "body_mask.npy"), body)
print("TRIS", len(polys), "materials", [m.name if m else None for m in me.materials], "body verts", body.sum())
for m in me.materials:
    if m and m.node_tree:
        for n in m.node_tree.nodes:
            if n.type == "TEX_IMAGE" and n.image:
                print("IMG", m.name, n.name, n.label, n.image.filepath, n.image.size[:])
print("GROUPS", sorted(vg.values())[:40])
