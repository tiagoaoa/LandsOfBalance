import bpy, os, sys, math, json, numpy as np
S = sys.argv[sys.argv.index("--")+1]
sc = bpy.context.scene
cam = bpy.data.cameras.new("c"); cam.type = "ORTHO"; cam.ortho_scale = 0.5
co = bpy.data.objects.new("cam", cam); sc.collection.objects.link(co)
co.location = (0, -3, 1.6); co.rotation_euler = (math.pi/2, 0, 0); sc.camera = co
sun = bpy.data.lights.new("sun", "SUN"); sun.energy = 3
so = bpy.data.objects.new("sun", sun); sc.collection.objects.link(so); so.rotation_euler = (math.radians(60), 0, math.radians(-20))
sc.render.engine = "BLENDER_EEVEE"; sc.render.resolution_x = sc.render.resolution_y = 1024
sc.render.filepath = os.path.join(S, "thief_front.png"); bpy.ops.render.render(write_still=True)
# collar: clothes vertices near the neck axis, highest ones around x≈0 front
cl = bpy.data.objects["Thief_Clothes"]; M = np.array(cl.matrix_world)
vs = np.array([v.co[:] for v in cl.data.vertices]) @ M[:3,:3].T + M[:3,3]
front = vs[(np.abs(vs[:,0]) < 0.03) & (vs[:,1] < 0.0) & (vs[:,2] > 1.35) & (vs[:,2] < 1.55)]
print("COLLAR front samples z:", np.round(np.sort(front[:,2])[-8:], 3).tolist())
# thief body world verts for alignment
bo = bpy.data.objects["Thief_Body"]; M = np.array(bo.matrix_world)
bv = np.array([v.co[:] for v in bo.data.vertices]) @ M[:3,:3].T + M[:3,3]
np.save(os.path.join(S, "thief_body_verts.npy"), bv)
print("BODY y range at eye height:", bv[(bv[:,2]>1.64)&(bv[:,2]<1.69)][:,1].min().round(3), "chin front z/y:", bv[np.argmin(bv[:,1] + 0*bv[:,2])].round(3).tolist())
