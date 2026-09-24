"""From fit1_tex.blend: bake the fitted shape, keep head+neck, plain glTF materials."""
import bpy, os, sys, json, numpy as np, bmesh
S = sys.argv[sys.argv.index("--")+1]
bm = bpy.data.objects["Human"]
bpy.context.view_layer.objects.active = bm
# bake shape keys into the mesh
bm.shape_key_add(name="baked", from_mix=True)
for k in list(bm.data.shape_keys.key_blocks)[:-1]:
    bm.shape_key_remove(k)
bm.shape_key_remove(bm.data.shape_keys.key_blocks[0])
# drop all modifiers (mask/armature) but apply nothing else; helpers get deleted below
for m in list(bm.modifiers): bm.modifiers.remove(m)
# delete helpers + everything below the neck cut
body = np.load(os.path.join(S, "body_mask.npy"))
ZCUT = float(os.environ.get("ZCUT", "1.44"))
me = bm.data; b = bmesh.new(); b.from_mesh(me)
b.verts.ensure_lookup_table()
kill = [v for v in b.verts if (not body[v.index]) or v.co.z < ZCUT]
bmesh.ops.delete(b, geom=kill, context="VERTS"); b.to_mesh(me); b.free()
# landmarks (mediapipe idx -> vertex) in the baked mesh: vids refer to the full index space,
# so record positions before we lose the indices
V = np.load(os.path.join(S, "fit1_verts.npy"))
vid = np.array(json.load(open(os.path.join(S, "fit_landmarks.json")))["vid"])
np.save(os.path.join(S, "mh_lm3d.npy"), V[vid])
# simple materials: one image each
def plain(name, img, alpha=False):
    m = bpy.data.materials.new(name); m.use_nodes = True
    nt = m.node_tree; bsdf = nt.nodes["Principled BSDF"]
    t = nt.nodes.new("ShaderNodeTexImage"); t.image = img
    nt.links.new(t.outputs["Color"], bsdf.inputs["Base Color"]); bsdf.inputs["Roughness"].default_value = 0.35 if "poly" in name else 0.55
    if alpha:
        nt.links.new(t.outputs["Alpha"], bsdf.inputs["Alpha"]); m.surface_render_method = "BLENDED"
    return m
skin_img = bpy.data.images.load(os.path.join(S, "nego_skin_diffuse.png"), check_existing=True)
me.materials.clear(); me.materials.append(plain("Nego_MH_Skin", skin_img))
keep = {"Human"}
for o in list(bpy.data.objects):
    if o.type != "MESH": continue
    n = o.name.lower()
    if "poly" in n or "teeth" in n:
        keep.add(o.name)
        for m in list(o.modifiers): o.modifiers.remove(m)
        if o.data.shape_keys:
            o.shape_key_add(name="baked", from_mix=True)
            for k in list(o.data.shape_keys.key_blocks)[:-1]: o.shape_key_remove(k)
            o.shape_key_remove(o.data.shape_keys.key_blocks[0])
        if "poly" in n:   # drop the cornea shell: its faces map to the blue disc at UV (0.9, 0.1)
            uvl = o.data.uv_layers.active.data; eb = bmesh.new(); eb.from_mesh(o.data); eb.faces.ensure_lookup_table()
            kill = []
            for f in eb.faces:
                us = [uvl[l].uv for l in o.data.polygons[f.index].loop_indices]
                cu = sum(u.x for u in us) / len(us); cv = sum(u.y for u in us) / len(us)
                if cu > 0.8 and cv < 0.2: kill.append(f)
            bmesh.ops.delete(eb, geom=kill, context="FACES"); eb.to_mesh(o.data); eb.free()
            print("CORNEA faces removed", len(kill), "left", len(o.data.polygons))
        imgs = [nd.image for mt in o.data.materials if mt and mt.node_tree for nd in mt.node_tree.nodes if nd.type == "TEX_IMAGE" and nd.image]
        print("PART", o.name, len(o.data.vertices), [i.name for i in imgs])
        o.data.materials.clear()
        if "poly" in n: imgs = [bpy.data.images.load(os.path.join(S, "brown_eye_dark.png"), check_existing=True)]
        if imgs: o.data.materials.append(plain("Nego_MH_" + o.name, imgs[0]))
        else:
            m = bpy.data.materials.new("Nego_MH_" + o.name); m.use_nodes = True
            m.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (0.9, 0.9, 0.9, 1); o.data.materials.append(m)
for o in list(bpy.data.objects):
    if o.name not in keep: bpy.data.objects.remove(o)
print("HEAD verts", len(me.vertices), "objs", sorted(keep))
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(S, "mh_head.blend"))
