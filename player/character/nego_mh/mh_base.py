import bpy, os, sys, json, math, numpy as np
from bl_ext.blender_org.mpfb.services.humanservice import HumanService
S = sys.argv[sys.argv.index("--")+1]
bpy.ops.wm.read_homefile(use_empty=True)
macro = {"gender": 0.95, "age": 0.5, "muscle": 0.6, "weight": 0.5, "proportions": 0.5,
         "height": 0.5, "cupsize": 0.5, "firmness": 0.5,
         "race": {"asian": 0.0, "caucasian": 0.0, "african": 1.0}}
bm = HumanService.create_human(mask_helpers=True, detailed_helpers=False, macro_detail_dict=macro)
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(S, "mpfb_base.blend"))

def render(name):
    kb = bm.data.shape_keys.key_blocks
    n = len(bm.data.vertices)
    def co(k):
        b = [0.0] * (n * 3); k.data.foreach_get("co", b); return np.array(b).reshape(n, 3)
    basis = co(kb[0]); vs = basis.copy()
    for k in kb[1:]:
        if k.value:
            vs += k.value * (co(k) - basis)
    np.save(os.path.join(S, name + "_verts.npy"), vs)
    head = vs[(vs[:, 2] > 1.45) & (vs[:, 2] < 1.9)]
    cz = (head[:, 2].min() + head[:, 2].max()) / 2
    cam = bpy.data.cameras.new("c"); cam.type = "ORTHO"; cam.ortho_scale = 0.36
    co = bpy.data.objects.new("cam", cam); bpy.context.scene.collection.objects.link(co)
    co.location = (0, -3, cz); co.rotation_euler = (math.pi/2, 0, 0)
    sc = bpy.context.scene; sc.camera = co
    sc.render.engine = "BLENDER_WORKBENCH"; sc.render.resolution_x = sc.render.resolution_y = 1024
    sc.display.shading.light = "STUDIO"; sc.display.shading.color_type = "SINGLE"
    sc.display.shading.single_color = (0.8, 0.6, 0.5)
    sc.render.film_transparent = False
    sc.world = bpy.data.worlds.new("w") if sc.world is None else sc.world
    sc.render.filepath = os.path.join(S, name + "_front.png"); bpy.ops.render.render(write_still=True)
    json.dump({"cz": cz, "ortho": 0.36, "res": 1024}, open(os.path.join(S, name + "_cam.json"), "w"))
    print("RENDER", name, "cz", cz, "head z", head[:, 2].min(), head[:, 2].max(), "nverts", len(vs))
render("base")
