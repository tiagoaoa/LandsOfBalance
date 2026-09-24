import bpy, os, sys, math
from bl_ext.blender_org.mpfb.services.humanservice import HumanService
from bl_ext.blender_org.mpfb.services.locationservice import LocationService
S = sys.argv[sys.argv.index("--")+1]; name = sys.argv[sys.argv.index("--")+2]
bm = bpy.data.objects["Human"]
D = LocationService.get_user_data()
skin = os.path.join(D, "skins", "young_african_male", "young_african_male.mhmat")
HumanService.set_character_skin(skin, bm, skin_type="MAKESKIN")
# swap the diffuse for the projected one
img = bpy.data.images.load(os.path.join(S, "nego_skin_diffuse.png"))
for m in bm.data.materials:
    for n in m.node_tree.nodes:
        if n.type == "TEX_IMAGE" and n.image and "diffuse" in n.image.name.lower():
            n.image = img; print("SWAPPED", m.name, n.name)
for sub, f in [("eyes", "high-poly/high-poly.mhclo"), ("eyebrows", "eyebrow001/eyebrow001.mhclo"),
               ("eyelashes", "eyelashes01/eyelashes01.mhclo"), ("teeth", "teeth_base/teeth_base.mhclo")]:
    p = os.path.join(D, sub, f)
    try:
        HumanService.add_mhclo_asset(p, bm, asset_type=sub.capitalize() if sub != "eyes" else "Eyes")
        print("ASSET", sub)
    except Exception as e:
        print("ASSET FAIL", sub, e)
# eye colour
eye = bpy.data.objects.get("Human.high-poly") or next((o for o in bpy.data.objects if "poly" in o.name.lower()), None)
print("EYEOBJ", eye.name if eye else None)
# EEVEE front render of the head
sc = bpy.context.scene
cam = bpy.data.cameras.new("c"); cam.type = "ORTHO"; cam.ortho_scale = 0.36
co = bpy.data.objects.new("cam", cam); sc.collection.objects.link(co)
co.location = (0, -3, 1.635); co.rotation_euler = (math.pi/2, 0, 0); sc.camera = co
sun = bpy.data.lights.new("sun", "SUN"); sun.energy = 3.0
so = bpy.data.objects.new("sun", sun); sc.collection.objects.link(so); so.rotation_euler = (math.radians(60), 0, math.radians(-20))
w = bpy.data.worlds.new("w") if sc.world is None else sc.world; sc.world = w
w.use_nodes = True; w.node_tree.nodes["Background"].inputs[0].default_value = (0.5, 0.5, 0.5, 1); w.node_tree.nodes["Background"].inputs[1].default_value = 0.6
sc.render.engine = "BLENDER_EEVEE"; sc.render.resolution_x = sc.render.resolution_y = 1024
sc.render.filepath = os.path.join(S, name + "_tex.png"); bpy.ops.render.render(write_still=True)
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(S, name + "_tex.blend"))
print("SAVED")
