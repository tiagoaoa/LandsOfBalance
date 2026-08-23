import math
from pathlib import Path

import bpy
from mathutils import Vector


ROOT = Path("/home/talves/mthings/LandsOfBalance")
OUT_DIR = ROOT / "player/character/thief"
BLEND_PATH = OUT_DIR / "nego_thief_realistic.blend"
GLB_PATH = OUT_DIR / "nego_thief_realistic.glb"
RENDER_PATH = OUT_DIR / "nego_thief_realistic_render.png"


def reset_scene():
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete()
    bpy.context.scene.frame_set(1)


def mat(name, color, rough=0.6, metallic=0.0, specular=0.5, noise_bump=False):
    material = bpy.data.materials.new(name)
    material.use_nodes = True
    material.diffuse_color = color
    bsdf = material.node_tree.nodes.get("Principled BSDF")
    if bsdf:
        bsdf.inputs["Base Color"].default_value = color
        bsdf.inputs["Roughness"].default_value = rough
        bsdf.inputs["Metallic"].default_value = metallic
        if "Specular IOR Level" in bsdf.inputs:
            bsdf.inputs["Specular IOR Level"].default_value = specular
        elif "Specular" in bsdf.inputs:
            bsdf.inputs["Specular"].default_value = specular
    if noise_bump and bsdf:
        nodes = material.node_tree.nodes
        noise = nodes.new("ShaderNodeTexNoise")
        noise.inputs["Scale"].default_value = 45
        noise.inputs["Detail"].default_value = 10
        noise.inputs["Roughness"].default_value = 0.58
        bump = nodes.new("ShaderNodeBump")
        bump.inputs["Strength"].default_value = 0.055
        bump.inputs["Distance"].default_value = 0.035
        material.node_tree.links.new(noise.outputs["Fac"], bump.inputs["Height"])
        material.node_tree.links.new(bump.outputs["Normal"], bsdf.inputs["Normal"])
    return material


SKIN = mat("warm dark skin", (0.245, 0.138, 0.088, 1), 0.55, specular=0.35, noise_bump=True)
SKIN_DARK = mat("skin shadow", (0.135, 0.072, 0.046, 1), 0.65)
LEATHER = mat("dark glossy leather", (0.038, 0.018, 0.010, 1), 0.34, specular=0.82, noise_bump=True)
LEATHER_EDGE = mat("worn brown leather edge", (0.135, 0.065, 0.032, 1), 0.48, specular=0.65, noise_bump=True)
LINEN = mat("coarse tan linen", (0.50, 0.435, 0.315, 1), 0.88, specular=0.18, noise_bump=True)
PANTS = mat("near black wool pants", (0.030, 0.024, 0.020, 1), 0.82, specular=0.18, noise_bump=True)
BOOT = mat("black riding boot leather", (0.028, 0.012, 0.007, 1), 0.30, specular=0.9, noise_bump=True)
BEARD = mat("short black beard", (0.010, 0.008, 0.006, 1), 0.92, specular=0.12, noise_bump=True)
EYE_WHITE = mat("wet eye white", (0.92, 0.88, 0.80, 1), 0.22, specular=0.9)
IRIS = mat("dark brown iris", (0.035, 0.018, 0.006, 1), 0.2, specular=0.8)
BLACK = mat("black pupil", (0.002, 0.001, 0.001, 1), 0.2, specular=0.5)
BRASS = mat("aged brass", (0.62, 0.38, 0.13, 1), 0.38, metallic=0.7, specular=0.6)
STEEL = mat("dark steel", (0.055, 0.055, 0.052, 1), 0.36, metallic=0.85, specular=0.6)


def shade(obj):
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)
    try:
        bpy.ops.object.shade_smooth()
    except RuntimeError:
        pass
    obj.select_set(False)
    return obj


def add_subsurf(obj, levels=1):
    mod = obj.modifiers.new("soft sculpt subdivision", "SUBSURF")
    mod.levels = levels
    mod.render_levels = levels
    return obj


def add_bevel(obj, width, segments=3):
    mod = obj.modifiers.new("soft bevels", "BEVEL")
    mod.width = width
    mod.segments = segments
    obj.modifiers.new("weighted normals", "WEIGHTED_NORMAL")
    return obj


def sphere(name, loc, scale, material, segments=48, rings=24):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=segments, ring_count=rings, radius=1, location=loc)
    obj = bpy.context.object
    obj.name = name
    obj.scale = scale
    obj.data.materials.append(material)
    shade(obj)
    return obj


def cube(name, loc, scale, material, rot=(0, 0, 0), bevel=0.0):
    bpy.ops.mesh.primitive_cube_add(size=1, location=loc, rotation=rot)
    obj = bpy.context.object
    obj.name = name
    obj.dimensions = scale
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    obj.data.materials.append(material)
    if bevel:
        add_bevel(obj, bevel, 4)
    return obj


def cylinder_between(name, a, b, radius, material, vertices=32, radius2=None):
    a = Vector(a)
    b = Vector(b)
    mid = (a + b) * 0.5
    length = (b - a).length
    if radius2 is None:
        bpy.ops.mesh.primitive_cylinder_add(vertices=vertices, radius=radius, depth=length, location=mid)
    else:
        bpy.ops.mesh.primitive_cone_add(vertices=vertices, radius1=radius, radius2=radius2, depth=length, location=mid)
    obj = bpy.context.object
    obj.name = name
    obj.rotation_euler = (b - a).to_track_quat("Z", "Y").to_euler()
    obj.data.materials.append(material)
    shade(obj)
    return obj


def torus(name, loc, major, minor, material, rot=(0, 0, 0)):
    bpy.ops.mesh.primitive_torus_add(major_segments=72, minor_segments=12, major_radius=major, minor_radius=minor, location=loc, rotation=rot)
    obj = bpy.context.object
    obj.name = name
    obj.data.materials.append(material)
    shade(obj)
    return obj


def panel(name, verts, faces, material, solid=0.0, bevel=0.0):
    mesh = bpy.data.meshes.new(name + "_mesh")
    mesh.from_pydata(verts, [], faces)
    mesh.update()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    obj.data.materials.append(material)
    if solid:
        mod = obj.modifiers.new("thin thickness", "SOLIDIFY")
        mod.thickness = solid
        mod.offset = 0
    if bevel:
        add_bevel(obj, bevel, 3)
    return obj


def curve_tube(name, pts, radius, material, resolution=4):
    curve = bpy.data.curves.new(name, "CURVE")
    curve.dimensions = "3D"
    curve.resolution_u = resolution
    curve.bevel_depth = radius
    curve.bevel_resolution = 5
    spl = curve.splines.new("POLY")
    spl.points.add(len(pts) - 1)
    for p, co in zip(spl.points, pts):
        p.co = (co[0], co[1], co[2], 1)
    obj = bpy.data.objects.new(name, curve)
    bpy.context.collection.objects.link(obj)
    obj.data.materials.append(material)
    return obj


def add_face():
    sphere("head", (0, -0.015, 1.615), (0.112, 0.090, 0.135), SKIN, 64, 32)
    sphere("neck", (0, 0.000, 1.460), (0.070, 0.060, 0.085), SKIN, 40, 16)

    # Cheeks, jaw and brow mass make the face broader and more human than the old base mesh.
    sphere("left cheek", (-0.052, -0.085, 1.610), (0.035, 0.018, 0.032), SKIN, 32, 12)
    sphere("right cheek", (0.052, -0.085, 1.610), (0.035, 0.018, 0.032), SKIN, 32, 12)
    sphere("square chin", (0, -0.087, 1.515), (0.060, 0.026, 0.030), SKIN, 32, 12)
    sphere("brow ridge", (0, -0.086, 1.680), (0.088, 0.014, 0.014), SKIN_DARK, 32, 8)

    # Nose.
    cylinder_between("nose bridge", (0, -0.100, 1.675), (0, -0.118, 1.610), 0.014, SKIN, 20, radius2=0.021)
    sphere("nose tip", (0, -0.128, 1.606), (0.028, 0.019, 0.018), SKIN, 32, 12)
    sphere("left nostril wing", (-0.022, -0.128, 1.600), (0.014, 0.009, 0.008), SKIN_DARK, 16, 8)
    sphere("right nostril wing", (0.022, -0.128, 1.600), (0.014, 0.009, 0.008), SKIN_DARK, 16, 8)

    for side in (-1, 1):
        x = side * 0.038
        sphere(("left" if side < 0 else "right") + " eye white", (x, -0.094, 1.662), (0.022, 0.008, 0.016), EYE_WHITE, 32, 12)
        sphere(("left" if side < 0 else "right") + " iris", (x, -0.101, 1.662), (0.008, 0.003, 0.008), IRIS, 16, 8)
        sphere(("left" if side < 0 else "right") + " pupil", (x, -0.104, 1.662), (0.004, 0.002, 0.004), BLACK, 12, 6)
        curve_tube(("left" if side < 0 else "right") + " upper eyelid", [(x - 0.023 * side, -0.103, 1.675), (x, -0.108, 1.681), (x + 0.023 * side, -0.103, 1.675)], 0.004, SKIN_DARK)
        curve_tube(("left" if side < 0 else "right") + " eyebrow", [(x - 0.031 * side, -0.111, 1.695), (x, -0.116, 1.702), (x + 0.034 * side, -0.111, 1.695)], 0.0055, BEARD)

    # Lips and beard.
    curve_tube("upper lip", [(-0.038, -0.122, 1.575), (0, -0.132, 1.579), (0.038, -0.122, 1.575)], 0.006, SKIN_DARK)
    curve_tube("lower lip", [(-0.030, -0.120, 1.558), (0, -0.130, 1.552), (0.030, -0.120, 1.558)], 0.007, SKIN_DARK)
    curve_tube("moustache left", [(-0.004, -0.134, 1.594), (-0.030, -0.139, 1.591), (-0.056, -0.132, 1.584)], 0.007, BEARD)
    curve_tube("moustache right", [(0.004, -0.134, 1.594), (0.030, -0.139, 1.591), (0.056, -0.132, 1.584)], 0.007, BEARD)
    panel(
        "short beard surface",
        [
            (-0.082, -0.124, 1.575),
            (-0.058, -0.133, 1.520),
            (0, -0.138, 1.492),
            (0.058, -0.133, 1.520),
            (0.082, -0.124, 1.575),
            (0.050, -0.136, 1.548),
            (0, -0.143, 1.530),
            (-0.050, -0.136, 1.548),
        ],
        [(0, 1, 2, 3, 4, 5, 6, 7)],
        BEARD,
        solid=0.004,
        bevel=0.003,
    )


def add_hood():
    # Hood shell: nested arched strips around the skull, open at the face.
    for i, (z, width, y, thick) in enumerate(
        [
            (1.750, 0.125, -0.032, 0.030),
            (1.705, 0.160, -0.050, 0.034),
            (1.650, 0.178, -0.060, 0.035),
            (1.590, 0.158, -0.056, 0.032),
        ]
    ):
        torus(f"hood folded arch {i}", (0, y, z), width, thick, LEATHER_EDGE, rot=(math.radians(90), 0, 0))
    panel(
        "deep hood back cloth",
        [
            (-0.165, -0.010, 1.545),
            (-0.178, -0.025, 1.640),
            (-0.145, -0.020, 1.745),
            (0, -0.010, 1.830),
            (0.145, -0.020, 1.745),
            (0.178, -0.025, 1.640),
            (0.165, -0.010, 1.545),
            (0.110, 0.060, 1.575),
            (0, 0.085, 1.770),
            (-0.110, 0.060, 1.575),
        ],
        [(0, 1, 2, 3, 4, 5, 6, 7, 8, 9)],
        LEATHER_EDGE,
        solid=0.018,
        bevel=0.012,
    )
    curve_tube("hood center seam", [(0, -0.115, 1.805), (0, -0.126, 1.725), (0, -0.120, 1.645)], 0.0045, LEATHER)


def add_torso():
    sphere("ribcage under tunic", (0, 0.000, 1.205), (0.235, 0.115, 0.270), LINEN, 64, 24)
    sphere("belly under tunic", (0, 0.005, 1.010), (0.205, 0.105, 0.160), LINEN, 48, 18)

    panel(
        "left dark leather vest panel",
        [
            (-0.260, -0.125, 0.890),
            (-0.030, -0.145, 0.890),
            (-0.038, -0.150, 1.220),
            (-0.080, -0.145, 1.405),
            (-0.165, -0.132, 1.500),
            (-0.285, -0.115, 1.430),
            (-0.310, -0.120, 1.085),
        ],
        [(0, 1, 2, 3, 4, 5, 6)],
        LEATHER,
        solid=0.018,
        bevel=0.010,
    )
    panel(
        "right dark leather vest panel",
        [
            (0.030, -0.145, 0.890),
            (0.260, -0.125, 0.890),
            (0.310, -0.120, 1.085),
            (0.285, -0.115, 1.430),
            (0.165, -0.132, 1.500),
            (0.080, -0.145, 1.405),
            (0.038, -0.150, 1.220),
        ],
        [(0, 1, 2, 3, 4, 5, 6)],
        LEATHER,
        solid=0.018,
        bevel=0.010,
    )
    panel(
        "linen front split",
        [(-0.045, -0.160, 0.875), (0.045, -0.160, 0.875), (0.035, -0.160, 1.055), (-0.035, -0.160, 1.055)],
        [(0, 1, 2, 3)],
        LINEN,
        solid=0.006,
        bevel=0.003,
    )

    # Shoulder leather caps.
    for side in (-1, 1):
        panel(
            ("left" if side < 0 else "right") + " shoulder leather cap",
            [
                (side * 0.165, -0.115, 1.425),
                (side * 0.405, -0.108, 1.388),
                (side * 0.372, -0.090, 1.485),
                (side * 0.205, -0.105, 1.525),
            ],
            [(0, 1, 2, 3)] if side > 0 else [(3, 2, 1, 0)],
            LEATHER,
            solid=0.014,
            bevel=0.010,
        )

    # Belts and straps.
    torus("wide waist belt", (0, -0.012, 1.015), 0.258, 0.023, LEATHER_EDGE, rot=(math.radians(90), 0, 0))
    curve_tube("diagonal chest strap", [(-0.220, -0.185, 1.510), (-0.080, -0.196, 1.350), (0.075, -0.196, 1.185), (0.225, -0.185, 1.035)], 0.020, LEATHER_EDGE)
    cube("front brass buckle", (0, -0.185, 1.020), (0.105, 0.018, 0.070), BRASS, bevel=0.005)
    cube("chest strap buckle", (0.065, -0.210, 1.295), (0.060, 0.015, 0.060), BRASS, rot=(0, 0, math.radians(-35)), bevel=0.004)

    # Lacing and rivets.
    for i, z in enumerate([1.170, 1.220, 1.270, 1.320, 1.370]):
        curve_tube(f"left crossing lace {i}", [(-0.032, -0.186, z + 0.018), (0.030, -0.192, z - 0.010)], 0.003, LEATHER_EDGE)
        curve_tube(f"right crossing lace {i}", [(0.032, -0.186, z + 0.018), (-0.030, -0.192, z - 0.010)], 0.003, LEATHER_EDGE)
    for i, x in enumerate([-0.235, -0.180, -0.125, 0.125, 0.180, 0.235]):
        sphere(f"belt brass rivet {i}", (x, -0.196, 1.035), (0.010, 0.004, 0.010), BRASS, 12, 6)


def add_arms():
    for side in (-1, 1):
        prefix = "left" if side < 0 else "right"
        shoulder = Vector((side * 0.280, -0.020, 1.390))
        elbow = Vector((side * 0.515, -0.060, 1.235))
        wrist = Vector((side * 0.720, -0.095, 1.085))
        hand = Vector((side * 0.805, -0.118, 1.030))

        cylinder_between(prefix + " upper linen sleeve", shoulder, elbow, 0.060, LINEN, 32, radius2=0.073)
        cylinder_between(prefix + " dark leather bracer", elbow, wrist, 0.046, LEATHER, 32, radius2=0.037)
        torus(prefix + " rolled linen cuff", elbow, 0.065, 0.015, LINEN, rot=(0, math.radians(90), math.radians(8 * side)))
        torus(prefix + " wrist cuff", wrist, 0.044, 0.010, LEATHER_EDGE, rot=(0, math.radians(90), math.radians(8 * side)))
        sphere(prefix + " palm", hand, (0.047, 0.019, 0.029), SKIN, 24, 10)
        for f in range(4):
            base_x = hand.x + side * (0.016 + f * 0.012)
            start = (base_x, hand.y - 0.016, hand.z - 0.010)
            end = (base_x + side * 0.018, hand.y - 0.030, hand.z - 0.030 - f * 0.002)
            cylinder_between(f"{prefix} finger {f}", start, end, 0.006, SKIN, 10, radius2=0.004)
        cylinder_between(prefix + " thumb", (hand.x - side * 0.030, hand.y - 0.010, hand.z + 0.000), (hand.x - side * 0.065, hand.y - 0.030, hand.z - 0.020), 0.007, SKIN, 10, radius2=0.005)
        for i in range(5):
            sphere(f"{prefix} bracer rivet {i}", tuple(elbow.lerp(wrist, 0.18 + i * 0.16) + Vector((0, -0.045, 0.026))), (0.007, 0.003, 0.007), BRASS, 10, 5)


def add_legs():
    for side in (-1, 1):
        prefix = "left" if side < 0 else "right"
        hip = Vector((side * 0.105, 0.000, 0.905))
        knee = Vector((side * 0.115, -0.010, 0.515))
        ankle = Vector((side * 0.125, -0.010, 0.145))
        cylinder_between(prefix + " upper black trouser", hip, knee, 0.083, PANTS, 36, radius2=0.070)
        cylinder_between(prefix + " lower black trouser", knee, ankle, 0.067, PANTS, 36, radius2=0.055)
        cylinder_between(prefix + " tall boot shaft", (side * 0.125, -0.012, 0.115), (side * 0.125, -0.018, 0.565), 0.072, BOOT, 36, radius2=0.085)
        torus(prefix + " boot top fold", (side * 0.125, -0.018, 0.570), 0.082, 0.020, BOOT, rot=(math.radians(90), 0, 0))
        sphere(prefix + " boot foot", (side * 0.125, -0.105, 0.055), (0.065, 0.145, 0.045), BOOT, 36, 12)
        cube(prefix + " square boot heel", (side * 0.125, 0.020, 0.030), (0.080, 0.055, 0.050), BLACK, bevel=0.008)
        curve_tube(prefix + " boot front crease", [(side * 0.125, -0.088, 0.125), (side * 0.125, -0.095, 0.545)], 0.004, LEATHER_EDGE)

    # Hip gear, pouches and dagger/scabbard.
    for side, x in [("left", -0.320), ("right", 0.320)]:
        cube(side + " hip pouch body", (x, -0.165, 0.935), (0.125, 0.055, 0.120), LEATHER_EDGE, bevel=0.015)
        cube(side + " hip pouch flap", (x, -0.198, 0.965), (0.112, 0.020, 0.055), LEATHER, bevel=0.008)
        sphere(side + " pouch brass button", (x, -0.212, 0.935), (0.010, 0.004, 0.010), BRASS, 10, 5)
    cylinder_between("right hip scabbard", (0.390, -0.132, 0.930), (0.455, -0.110, 0.560), 0.018, STEEL, 14, radius2=0.014)
    cylinder_between("dagger handle", (0.370, -0.145, 0.965), (0.340, -0.155, 1.050), 0.014, LEATHER_EDGE, 14)
    cube("dagger guard", (0.380, -0.155, 0.950), (0.080, 0.016, 0.014), BRASS, rot=(0, 0, math.radians(-10)), bevel=0.004)


def add_lighting_and_camera():
    scene = bpy.context.scene
    try:
        scene.render.engine = "CYCLES"
        scene.cycles.samples = 96
        scene.cycles.use_denoising = True
    except Exception:
        scene.render.engine = "BLENDER_EEVEE_NEXT"
    scene.render.resolution_x = 1400
    scene.render.resolution_y = 1800
    scene.view_settings.view_transform = "Filmic"
    scene.view_settings.look = "Medium High Contrast"
    scene.view_settings.exposure = -0.25
    scene.view_settings.gamma = 1.0

    world = bpy.data.worlds.new("soft grey studio")
    scene.world = world
    world.use_nodes = True
    bg = world.node_tree.nodes["Background"]
    bg.inputs[0].default_value = (0.72, 0.72, 0.70, 1)
    bg.inputs[1].default_value = 0.65

    for name, loc, energy, size in [
        ("large softbox left", (-2.8, -3.2, 2.6), 700, 4.0),
        ("soft fill right", (2.8, -3.4, 1.7), 180, 5.0),
        ("rim strip", (0.0, 2.8, 2.2), 260, 3.5),
    ]:
        light = bpy.data.lights.new(name, "AREA")
        light.energy = energy
        light.size = size
        obj = bpy.data.objects.new(name, light)
        bpy.context.collection.objects.link(obj)
        obj.location = loc
        target = Vector((0, -0.06, 1.00))
        obj.rotation_euler = (target - Vector(loc)).to_track_quat("-Z", "Y").to_euler()

    cam_data = bpy.data.cameras.new("front portrait camera")
    cam = bpy.data.objects.new("front portrait camera", cam_data)
    bpy.context.collection.objects.link(cam)
    cam.location = (0, -4.15, 0.950)
    cam.rotation_euler = (Vector((0, -0.050, 0.965)) - Vector(cam.location)).to_track_quat("-Z", "Y").to_euler()
    cam.data.type = "ORTHO"
    cam.data.ortho_scale = 2.05
    scene.camera = cam

    # Ground shadow.
    plane = cube("matte studio floor", (0, 0, -0.018), (3.0, 3.0, 0.012), mat("matte grey floor", (0.58, 0.57, 0.55, 1), 0.72))
    return cam


def main():
    reset_scene()
    add_torso()
    add_legs()
    add_arms()
    add_face()
    add_hood()
    add_lighting_and_camera()

    bpy.ops.wm.save_as_mainfile(filepath=str(BLEND_PATH))
    bpy.ops.export_scene.gltf(filepath=str(GLB_PATH), export_format="GLB", export_apply=True)
    bpy.context.scene.render.filepath = str(RENDER_PATH)
    bpy.ops.render.render(write_still=True)
    print("saved", BLEND_PATH)
    print("exported", GLB_PATH)
    print("rendered", RENDER_PATH)


if __name__ == "__main__":
    main()
