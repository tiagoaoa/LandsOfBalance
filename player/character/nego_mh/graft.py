"""Graft the MakeHuman head onto the thief: align on landmarks, cut the archer head
under the collar, blend the neck seam, transfer bone weights, export."""
import bpy, os, sys, math, json, numpy as np, bmesh
from mathutils import Matrix, Vector
from mathutils.bvhtree import BVHTree
S = sys.argv[sys.argv.index("--")+1]
OUT = sys.argv[sys.argv.index("--")+2]
ZCUT = 1.46            # world; the collar tops out at ~1.52-1.53
BAND = 0.045

def smooth(a, b, x): t = np.clip((x - a) / (b - a), 0, 1); return t * t * (3 - 2 * t)

with bpy.data.libraries.load(os.path.join(S, "mh_head.blend")) as (src, dst):
    dst.objects = [n for n in src.objects]
mh = [o for o in dst.objects if o is not None]
for o in mh: bpy.context.scene.collection.objects.link(o)
head = next(o for o in mh if o.name == "Human")

# --- alignment: MakeHuman landmarks -> thief landmarks -----------------------------
mh_lm = np.load(os.path.join(S, "mh_lm3d.npy"))
tb = np.load(os.path.join(S, "thief_body_verts.npy"))
def frontmost(x, z):
    d = np.hypot(tb[:, 0] - x, tb[:, 2] - z); c = np.where(d < 0.008)[0]
    if len(c) == 0: c = np.argsort(d)[:5]
    return tb[c[np.argmin(tb[c, 1])]]
pairs = [(33, (-0.052, 1.666)), (263, (0.052, 1.666)), (133, (-0.020, 1.664)), (362, (0.020, 1.664)),
         (2, (0.0, 1.618)), (61, (-0.030, 1.598)), (291, (0.030, 1.598)), (152, (0.0, 1.552)),
         (234, (-0.072, 1.632)), (454, (0.072, 1.632))]
A = np.array([mh_lm[i] for i, _ in pairs]); B = np.array([frontmost(*xz) for _, xz in pairs])
ca, cb = A.mean(0), B.mean(0); A0, B0 = A - ca, B - cb
U, _, Vt = np.linalg.svd(A0.T @ B0); R = (U @ Vt).T
if np.linalg.det(R) < 0: Vt[-1] *= -1; R = (U @ Vt).T
s = (B0 * (A0 @ R.T)).sum() / (A0 ** 2).sum()
t = cb - s * R @ ca
M = Matrix.Identity(4)
for i in range(3):
    for j in range(3): M[i][j] = s * R[i, j]
    M[i][3] = t[i]
res = np.linalg.norm((s * A @ R.T + t) - B, axis=1)
print(f"ALIGN scale {s:.3f} residual mean {res.mean()*1000:.1f} mm max {res.max()*1000:.1f} mm")
for o in mh: o.matrix_world = M @ o.matrix_world

# --- weights: transfer from the archer head before it is cut ------------------------
body = bpy.data.objects["Thief_Body"]; arm = bpy.data.objects["Armature"]
for o in mh:
    bpy.ops.object.select_all(action="DESELECT")
    body.select_set(True); o.select_set(True); bpy.context.view_layer.objects.active = body
    bpy.ops.object.data_transfer(use_reverse_transfer=False, use_object_transform=True, data_type="VGROUP_WEIGHTS",
                                 vert_mapping="POLYINTERP_NEAREST", layers_select_src="ALL", layers_select_dst="NAME")
    o.parent = arm; o.matrix_parent_inverse = arm.matrix_world.inverted()
    mod = o.modifiers.new("Armature", "ARMATURE"); mod.object = arm
    KEEP = {"mixamorig:Head", "mixamorig:Neck", "mixamorig:Spine2", "mixamorig:Spine1"}
    for vg in list(o.vertex_groups):
        if vg.name not in KEEP: o.vertex_groups.remove(vg)
    # renormalise; anything left with no weight belongs to the head
    headg = o.vertex_groups["mixamorig:Head"]
    for v in o.data.vertices:
        tot = sum(g.weight for g in v.groups)
        if tot < 1e-6: headg.add([v.index], 1.0, "REPLACE")
        else:
            for g in v.groups: o.vertex_groups[g.group].add([v.index], g.weight / tot, "REPLACE")
    print("WEIGHTS", o.name, len(o.vertex_groups))

# --- neck seam: pull the lowest MakeHuman ring onto the archer neck --------------------
dg = bpy.context.evaluated_depsgraph_get()
bvh = BVHTree.FromObject(body, dg)
Mw = head.matrix_world; Mi = Mw.inverted()
for v in head.data.vertices:
    w = Mw @ v.co
    f = 1 - smooth(ZCUT, ZCUT + BAND, w.z)
    if f > 0:
        loc, nrm, idx, dist = bvh.find_nearest(w)
        if loc is not None:
            v.co = Mi @ (w.lerp(loc, f))
# drop what sits inside the collar
b = bmesh.new(); b.from_mesh(head.data)
bmesh.ops.delete(b, geom=[v for v in b.verts if (Mw @ v.co).z < ZCUT - 0.01], context="VERTS")
b.to_mesh(head.data); b.free()

# --- cut the archer head ------------------------------------------------------------
Mb = body.matrix_world
b = bmesh.new(); b.from_mesh(body.data)
bmesh.ops.delete(b, geom=[v for v in b.verts if (Mb @ v.co).z > ZCUT + 0.005], context="VERTS")
b.to_mesh(body.data); b.free()
bpy.data.objects.remove(bpy.data.objects["Thief_Eyes"])
print("CUT body verts left", len(body.data.vertices), "head verts", len(head.data.vertices))

# --- render + save + export -------------------------------------------------------------
sc = bpy.context.scene
cam = bpy.data.cameras.new("c"); cam.type = "ORTHO"; cam.ortho_scale = 0.5
co = bpy.data.objects.new("cam", cam); sc.collection.objects.link(co)
co.location = (0, -3, 1.6); co.rotation_euler = (math.pi/2, 0, 0); sc.camera = co
sun = bpy.data.lights.new("sun", "SUN"); sun.energy = 3
so = bpy.data.objects.new("sun", sun); sc.collection.objects.link(so); so.rotation_euler = (math.radians(60), 0, math.radians(-20))
sc.render.engine = "BLENDER_EEVEE"; sc.render.resolution_x = sc.render.resolution_y = 1024
sc.render.filepath = os.path.join(S, "graft_front.png"); bpy.ops.render.render(write_still=True)
co.location = (-2.5, -1.7, 1.6); co.rotation_euler = (math.pi/2, 0, math.radians(-55))
sc.render.filepath = os.path.join(S, "graft_side.png"); bpy.ops.render.render(write_still=True)
for o in (co, so): bpy.data.objects.remove(o)
bpy.ops.wm.save_as_mainfile(filepath=OUT + ".blend")
bpy.ops.object.select_all(action="SELECT")
bpy.ops.export_scene.gltf(filepath=OUT + ".glb", export_format="GLB", export_apply=True, export_animations=True)
print("SAVED", OUT)
