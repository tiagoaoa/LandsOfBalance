import bpy, os, sys, json, math, numpy as np
from bl_ext.blender_org.mpfb.services.targetservice import TargetService
from bl_ext.blender_org.mpfb.services.locationservice import LocationService
S = sys.argv[sys.argv.index("--")+1]
name = sys.argv[sys.argv.index("--")+2]
bm = bpy.data.objects["Human"]
T = LocationService.get_mpfb_data("targets")
wts = json.load(open(os.path.join(S, "fit_weights.json")))
for n, v in wts.items():
    cat = n.split("-")[1] if n.startswith(("l-", "r-")) else n.split("-")[0]
    p = os.path.join(T, cat, n + ".target.gz")
    if not os.path.exists(p):
        p = TargetService.target_full_path(n)
    TargetService.load_target(bm, p, weight=v)
print("APPLIED", len(wts))
exec(open(os.path.join(S, "render_head.py")).read())
render(name)
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(S, name + ".blend"))
