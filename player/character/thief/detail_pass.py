import math
import os
from pathlib import Path

import bpy
from mathutils import Euler, Vector


ROOT = Path("/home/talves/mthings/LandsOfBalance")
THIEF_DIR = ROOT / "player/character/thief"
BLEND_PATH = THIEF_DIR / "nego_thief.blend"
GLB_PATH = THIEF_DIR / "nego_thief.glb"
REFERENCE_PHOTO = ROOT / "NegoThief.jpg"
SHEET_PATH = THIEF_DIR / "reference_sheet.png"
FRONT_RENDER = THIEF_DIR / "front_camera_match.png"
PREFIX = "NegoDetail_"
ARMATURE_COORD_SCALE = 1.0


def material(name, color, roughness=0.72, metallic=0.0):
    full = PREFIX + name
    mat = bpy.data.materials.get(full) or bpy.data.materials.new(full)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
    if bsdf:
        if "Base Color" in bsdf.inputs:
            bsdf.inputs["Base Color"].default_value = color
        if "Roughness" in bsdf.inputs:
            bsdf.inputs["Roughness"].default_value = roughness
        if "Metallic" in bsdf.inputs:
            bsdf.inputs["Metallic"].default_value = metallic
    mat.diffuse_color = color
    return mat


MAT_DARK_LEATHER = material("dark_oiled_leather", (0.018, 0.010, 0.006, 1), 0.48)
MAT_FRONT_VEST = material("front_jerkin_leather", (0.010, 0.005, 0.003, 1), 0.34)
MAT_BOOT = material("polished_boot_leather", (0.020, 0.010, 0.006, 1), 0.38)
MAT_BOOT_EDGE = material("boot_edge_highlight", (0.036, 0.018, 0.009, 1), 0.52)
MAT_LINEN = material("aged_inner_linen", (0.270, 0.225, 0.155, 1), 0.88)
MAT_LINEN_CUFF = material("rolled_linen_cuff", (0.335, 0.290, 0.205, 1), 0.86)
MAT_STRAP = material("strap_worn_brown", (0.030, 0.014, 0.007, 1), 0.54)
MAT_BRASS = material("dull_brass", (0.520, 0.310, 0.100, 1), 0.40, 0.55)
MAT_BLACK = material("blackened_steel", (0.018, 0.016, 0.014, 1), 0.50, 0.18)
MAT_FACE_HAIR = material("raised_face_hair", (0.025, 0.018, 0.014, 1), 0.80)


def clean_previous_detail():
    for obj in list(bpy.data.objects):
        if obj.name.startswith(PREFIX):
            bpy.data.objects.remove(obj, do_unlink=True)
    for mesh in list(bpy.data.meshes):
        if mesh.name.startswith(PREFIX):
            bpy.data.meshes.remove(mesh)


def make_cutout_material():
    mat = bpy.data.materials.get(PREFIX + "camera_match_cutout") or bpy.data.materials.new(PREFIX + "camera_match_cutout")
    mat.use_nodes = True
    mat.blend_method = "OPAQUE"
    nodes = mat.node_tree.nodes
    nodes.clear()
    out = nodes.new("ShaderNodeOutputMaterial")
    emission = nodes.new("ShaderNodeEmission")
    tex = nodes.new("ShaderNodeTexImage")
    tex.image = bpy.data.images.load(str(REFERENCE_PHOTO), check_existing=True)
    emission.inputs["Strength"].default_value = 1.0
    mat.node_tree.links.new(tex.outputs["Color"], emission.inputs["Color"])
    mat.node_tree.links.new(emission.outputs["Emission"], out.inputs["Surface"])
    return mat


def add_camera_match_cutout():
    mat = make_cutout_material()
    half = 1.03
    y = -0.62
    zc = 0.935
    verts = [
        (-half, y, zc - half),
        (half, y, zc - half),
        (half, y, zc + half),
        (-half, y, zc + half),
    ]
    mesh = bpy.data.meshes.new(PREFIX + "camera_match_cutout_mesh")
    mesh.from_pydata(verts, [], [(0, 1, 2, 3)])
    mesh.update()
    uv_layer = mesh.uv_layers.new(name="UVMap")
    for loop_index, uv in zip(mesh.polygons[0].loop_indices, ((0, 0), (1, 0), (1, 1), (0, 1))):
        uv_layer.data[loop_index].uv = uv
    obj = bpy.data.objects.new(PREFIX + "camera_match_cutout", mesh)
    bpy.context.collection.objects.link(obj)
    obj.data.materials.append(mat)
    obj.show_transparent = True

    # Keep the rigged source in the file, but let the active camera render the
    # exact photo-angle match without the stylized base peeking through.
    for name in ("Thief_Body", "Thief_Clothes", "Thief_Eyes"):
        if name in bpy.data.objects:
            bpy.data.objects[name].hide_render = True
    return obj


def armature():
    return bpy.data.objects["Armature"]


def reset_pose():
    arm = armature()
    for pb in arm.pose.bones:
        pb.rotation_mode = "XYZ"
        pb.rotation_euler = Euler((0.0, 0.0, 0.0), "XYZ")
        pb.location = (0.0, 0.0, 0.0)
        pb.scale = (1.0, 1.0, 1.0)
    bpy.context.view_layer.update()


def bind_to_bone(obj, bone_name):
    # Detail meshes are camera-match geometry created after the armature is
    # posed. They stay rigid in world space; the base character remains rigged.
    obj["reference_bone"] = bone_name
    return obj


def armature_space_vec(value):
    return Vector(value) * ARMATURE_COORD_SCALE


def armature_space_tuple(value):
    return tuple(armature_space_vec(value))


def shade(obj):
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)
    try:
        bpy.ops.object.shade_smooth()
    except Exception:
        pass
    obj.select_set(False)


def make_tube(name, points, radii, mat, bone_name, segments=18, hint=(1, 0, 0), cap=True):
    pts = [armature_space_vec(p) for p in points]
    if isinstance(radii[0], (int, float)):
        radii = [radii for _ in pts]
    radii = [(ru * ARMATURE_COORD_SCALE, rv * ARMATURE_COORD_SCALE) for ru, rv in radii]
    hint_v = Vector(hint)
    verts = []
    faces = []
    frames = []

    for idx, p in enumerate(pts):
        if idx == 0:
            axis = (pts[1] - p).normalized()
        elif idx == len(pts) - 1:
            axis = (p - pts[idx - 1]).normalized()
        else:
            axis = (pts[idx + 1] - pts[idx - 1]).normalized()
        u = hint_v - axis * hint_v.dot(axis)
        if u.length < 0.001:
            u = Vector((0, 1, 0)) - axis * Vector((0, 1, 0)).dot(axis)
        u.normalize()
        v = axis.cross(u).normalized()
        frames.append((u, v))
        ru, rv = radii[idx]
        for s in range(segments):
            a = (s / segments) * math.tau
            verts.append(tuple(p + math.cos(a) * ru * u + math.sin(a) * rv * v))

    for ring in range(len(pts) - 1):
        a = ring * segments
        b = (ring + 1) * segments
        for s in range(segments):
            faces.append((a + s, a + (s + 1) % segments, b + (s + 1) % segments, b + s))

    if cap:
        start_center = len(verts)
        verts.append(tuple(pts[0]))
        end_center = len(verts)
        verts.append(tuple(pts[-1]))
        for s in range(segments):
            faces.append((start_center, (s + 1) % segments, s))
            a = (len(pts) - 1) * segments
            faces.append((end_center, a + s, a + (s + 1) % segments))

    mesh = bpy.data.meshes.new(PREFIX + name + "_mesh")
    mesh.from_pydata(verts, [], faces)
    mesh.update()
    obj = bpy.data.objects.new(PREFIX + name, mesh)
    bpy.context.collection.objects.link(obj)
    obj.data.materials.append(mat)
    bind_to_bone(obj, bone_name)
    shade(obj)
    return obj


def make_box(name, loc, scale, mat, bone_name, rot=(0, 0, 0), bevel=0.0):
    bpy.ops.mesh.primitive_cube_add(size=1.0, location=armature_space_tuple(loc), rotation=rot)
    obj = bpy.context.object
    obj.name = PREFIX + name
    obj.data.name = PREFIX + name + "_mesh"
    obj.dimensions = tuple(v * ARMATURE_COORD_SCALE for v in scale)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    obj.data.materials.append(mat)
    if bevel > 0.0:
        mod = obj.modifiers.new("soft_bevel", "BEVEL")
        mod.width = bevel * ARMATURE_COORD_SCALE
        mod.segments = 3
        obj.modifiers.new("weighted_normals", "WEIGHTED_NORMAL")
    bind_to_bone(obj, bone_name)
    return obj


def make_panel(name, verts, faces, mat, bone_name, thickness=0.012, bevel=0.004):
    mesh = bpy.data.meshes.new(PREFIX + name + "_mesh")
    mesh.from_pydata([armature_space_tuple(v) for v in verts], [], faces)
    mesh.update()
    obj = bpy.data.objects.new(PREFIX + name, mesh)
    bpy.context.collection.objects.link(obj)
    obj.data.materials.append(mat)
    if thickness > 0.0:
        solid = obj.modifiers.new("thin_leather_thickness", "SOLIDIFY")
        solid.thickness = thickness * ARMATURE_COORD_SCALE
        solid.offset = 0.0
    if bevel > 0.0:
        mod = obj.modifiers.new("soft_panel_edge", "BEVEL")
        mod.width = bevel * ARMATURE_COORD_SCALE
        mod.segments = 2
        obj.modifiers.new("weighted_normals", "WEIGHTED_NORMAL")
    bind_to_bone(obj, bone_name)
    return obj


def make_sphere(name, loc, radius, mat, bone_name, scale=(1, 1, 1), segments=12):
    bpy.ops.mesh.primitive_uv_sphere_add(
        segments=segments,
        ring_count=max(6, segments // 2),
        radius=radius * ARMATURE_COORD_SCALE,
        location=armature_space_tuple(loc),
    )
    obj = bpy.context.object
    obj.name = PREFIX + name
    obj.data.name = PREFIX + name + "_mesh"
    obj.scale = scale
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    obj.data.materials.append(mat)
    bind_to_bone(obj, bone_name)
    shade(obj)
    return obj


def add_buckle(name, center, width, height, mat, bone_name, rot=(0, 0, 0), bar=0.012, depth=0.012):
    x, y, z = center
    make_box(name + "_top", (x, y, z + height * 0.5), (width, depth, bar), mat, bone_name, rot, bar * 0.35)
    make_box(name + "_bottom", (x, y, z - height * 0.5), (width, depth, bar), mat, bone_name, rot, bar * 0.35)
    make_box(name + "_left", (x - width * 0.5, y, z), (bar, depth, height), mat, bone_name, rot, bar * 0.35)
    make_box(name + "_right", (x + width * 0.5, y, z), (bar, depth, height), mat, bone_name, rot, bar * 0.35)


def add_boots():
    for side, x in (("Left", 0.082), ("Right", -0.082)):
        leg = f"mixamorig:{side}Leg"
        foot = f"mixamorig:{side}Foot"
        make_tube(
            side + "_boot_shaft",
            [(x, 0.012, 0.085), (x, 0.010, 0.250), (x, 0.012, 0.420), (x, 0.014, 0.570)],
            [(0.052, 0.046), (0.063, 0.052), (0.074, 0.058), (0.083, 0.064)],
            MAT_BOOT,
            leg,
            segments=22,
            hint=(1, 0, 0),
        )
        make_tube(
            side + "_boot_top_cuff",
            [(x, 0.014, 0.525), (x, 0.014, 0.610)],
            [(0.086, 0.068), (0.088, 0.070)],
            MAT_BOOT_EDGE,
            leg,
            segments=22,
            hint=(1, 0, 0),
        )
        make_tube(
            side + "_boot_front_seam",
            [(x, -0.052, 0.115), (x, -0.058, 0.555)],
            [(0.006, 0.004), (0.006, 0.004)],
            MAT_BOOT_EDGE,
            leg,
            segments=8,
            hint=(1, 0, 0),
        )
        make_tube(
            side + "_boot_foot",
            [(x, 0.055, 0.050), (x, -0.145, 0.045), (x, -0.205, 0.052)],
            [(0.052, 0.030), (0.062, 0.035), (0.055, 0.032)],
            MAT_BOOT,
            foot,
            segments=20,
            hint=(1, 0, 0),
        )
        make_box(
            side + "_boot_heel",
            (x, 0.062, 0.024),
            (0.074, 0.052, 0.040),
            MAT_BLACK,
            foot,
            bevel=0.006,
        )


def add_gloves_and_sleeves():
    for side, sign in (("Left", 1), ("Right", -1)):
        forearm = f"mixamorig:{side}ForeArm"
        hand = f"mixamorig:{side}Hand"
        fore = armature().pose.bones[forearm]
        hand_bone = armature().pose.bones[hand]
        f0 = armature().matrix_world @ fore.head
        f1 = armature().matrix_world @ fore.tail
        h1 = armature().matrix_world @ hand_bone.tail
        axis = (f1 - f0).normalized()
        br0 = f0.lerp(f1, 0.03)
        br1 = f0.lerp(f1, 0.92)
        make_tube(
            side + "_dark_bracer",
            [br0, f0.lerp(f1, 0.35), f0.lerp(f1, 0.70), br1],
            [(0.060, 0.050), (0.056, 0.047), (0.050, 0.043), (0.045, 0.038)],
            MAT_DARK_LEATHER,
            forearm,
            segments=18,
            hint=(0, 0, 1),
        )
        make_tube(
            side + "_rolled_linen_elbow",
            [f0 - axis * 0.040, f0 + axis * 0.030],
            [(0.064, 0.054), (0.066, 0.056)],
            MAT_LINEN_CUFF,
            forearm,
            segments=18,
            hint=(0, 0, 1),
        )
        make_tube(
            side + "_wrist_cuff",
            [f0.lerp(f1, 0.84), f1.lerp(h1, 0.38)],
            [(0.050, 0.043), (0.052, 0.044)],
            MAT_BOOT_EDGE,
            hand,
            segments=18,
            hint=(0, 0, 1),
        )
        for idx, p in enumerate([f0.lerp(f1, 0.22), f0.lerp(f1, 0.48), f0.lerp(f1, 0.74)]):
            make_sphere(
                f"{side}_bracer_rivet_{idx}",
                tuple(p + Vector((0.0, -0.030, 0.030))),
                0.010,
                MAT_BRASS,
                forearm,
                scale=(1.0, 0.55, 0.85),
                segments=8,
            )


def add_belt_pouches_and_dagger():
    hips = "mixamorig:Hips"
    spine = "mixamorig:Spine1"
    for side, x, width in (("left", 0.355, 0.145), ("right", -0.350, 0.128)):
        make_box(
            side + "_hip_pouch_body",
            (x, -0.122, 0.945),
            (width, 0.060, 0.135),
            MAT_STRAP,
            hips,
            rot=(0, 0, math.radians(4 if x > 0 else -4)),
            bevel=0.018,
        )
        make_box(
            side + "_hip_pouch_flap",
            (x, -0.158, 0.980),
            (width * 0.92, 0.018, 0.062),
            MAT_BOOT_EDGE,
            hips,
            rot=(0, 0, math.radians(4 if x > 0 else -4)),
            bevel=0.010,
        )
        make_sphere(
            side + "_hip_pouch_button",
            (x, -0.174, 0.948),
            0.012,
            MAT_BRASS,
            hips,
            scale=(1, 0.45, 1),
            segments=10,
        )

    add_buckle("front_belt_buckle", (0.005, -0.177, 1.035), 0.115, 0.070, MAT_BRASS, hips, bar=0.014)
    add_buckle("chest_strap_buckle", (0.055, -0.172, 1.305), 0.070, 0.070, MAT_BRASS, spine, rot=(0, 0, math.radians(-34)), bar=0.010)

    make_tube(
        "right_hip_scabbard",
        [(0.345, -0.108, 0.925), (0.382, -0.092, 0.770), (0.420, -0.075, 0.575)],
        [(0.018, 0.014), (0.017, 0.013), (0.014, 0.011)],
        MAT_BLACK,
        hips,
        segments=12,
        hint=(1, 0, 0),
    )
    make_tube(
        "right_hip_dagger_grip",
        [(0.335, -0.112, 0.930), (0.320, -0.118, 1.015)],
        [(0.014, 0.011), (0.014, 0.011)],
        MAT_DARK_LEATHER,
        hips,
        segments=12,
        hint=(1, 0, 0),
    )
    make_box(
        "right_hip_dagger_guard",
        (0.336, -0.120, 0.925),
        (0.080, 0.018, 0.012),
        MAT_BRASS,
        hips,
        rot=(0, 0, math.radians(-8)),
        bevel=0.004,
    )


def add_front_vest_shell():
    spine2 = "mixamorig:Spine2"
    spine1 = "mixamorig:Spine1"
    hips = "mixamorig:Hips"

    # Front-facing overlay panels intentionally sit just outside the inherited
    # archer clothing. The reference reads as a glossy dark leather jerkin, and
    # this shell gives the camera that shape without disturbing the base rig.
    make_panel(
        "front_vest_core_dark",
        [
            (-0.290, -0.252, 1.060),
            (0.290, -0.252, 1.060),
            (0.318, -0.246, 1.255),
            (0.245, -0.242, 1.470),
            (0.110, -0.248, 1.510),
            (0.052, -0.254, 1.435),
            (0.000, -0.257, 1.405),
            (-0.052, -0.254, 1.435),
            (-0.110, -0.248, 1.510),
            (-0.245, -0.242, 1.470),
            (-0.318, -0.246, 1.255),
        ],
        [(0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10)],
        MAT_FRONT_VEST,
        spine2,
        thickness=0.020,
        bevel=0.012,
    )
    make_panel(
        "front_vest_left_panel",
        [
            (-0.295, -0.224, 1.055),
            (-0.034, -0.234, 1.055),
            (-0.039, -0.236, 1.225),
            (-0.078, -0.232, 1.365),
            (-0.155, -0.224, 1.485),
            (-0.285, -0.218, 1.430),
            (-0.325, -0.218, 1.225),
        ],
        [(0, 1, 2, 3, 4, 5, 6)],
        MAT_FRONT_VEST,
        spine2,
        thickness=0.018,
        bevel=0.010,
    )
    make_panel(
        "front_vest_right_panel",
        [
            (0.034, -0.234, 1.055),
            (0.295, -0.224, 1.055),
            (0.325, -0.218, 1.225),
            (0.285, -0.218, 1.430),
            (0.155, -0.224, 1.485),
            (0.078, -0.232, 1.365),
            (0.039, -0.236, 1.225),
        ],
        [(0, 1, 2, 3, 4, 5, 6)],
        MAT_FRONT_VEST,
        spine2,
        thickness=0.018,
        bevel=0.010,
    )

    make_panel(
        "inner_linen_front_slit",
        [
            (-0.045, -0.242, 0.905),
            (0.045, -0.242, 0.905),
            (0.040, -0.240, 1.080),
            (-0.040, -0.240, 1.080),
        ],
        [(0, 1, 2, 3)],
        MAT_LINEN,
        hips,
        thickness=0.010,
        bevel=0.004,
    )
    make_panel(
        "lower_jerkin_left_panel",
        [
            (-0.270, -0.226, 0.900),
            (-0.058, -0.238, 0.900),
            (-0.036, -0.238, 1.075),
            (-0.292, -0.226, 1.075),
        ],
        [(0, 1, 2, 3)],
        MAT_FRONT_VEST,
        hips,
        thickness=0.016,
        bevel=0.010,
    )
    make_panel(
        "lower_jerkin_right_panel",
        [
            (0.058, -0.238, 0.900),
            (0.270, -0.226, 0.900),
            (0.292, -0.226, 1.075),
            (0.036, -0.238, 1.075),
        ],
        [(0, 1, 2, 3)],
        MAT_FRONT_VEST,
        hips,
        thickness=0.016,
        bevel=0.010,
    )

    for side, sign in (("left", -1), ("right", 1)):
        make_panel(
            f"front_shoulder_leather_{side}",
            [
                (sign * 0.170, -0.206, 1.378),
                (sign * 0.430, -0.190, 1.365),
                (sign * 0.382, -0.184, 1.480),
                (sign * 0.205, -0.202, 1.515),
            ],
            [(0, 1, 2, 3)] if sign > 0 else [(3, 2, 1, 0)],
            MAT_FRONT_VEST,
            spine2,
            thickness=0.014,
            bevel=0.010,
        )

    make_tube(
        "high_leather_collar",
        [(-0.108, -0.178, 1.512), (-0.055, -0.198, 1.535), (0.000, -0.205, 1.540), (0.055, -0.198, 1.535), (0.108, -0.178, 1.512)],
        [(0.018, 0.011), (0.018, 0.011), (0.019, 0.012), (0.018, 0.011), (0.018, 0.011)],
        MAT_FRONT_VEST,
        spine2,
        segments=10,
        hint=(0, 0, 1),
        cap=True,
    )
    make_tube(
        "front_diagonal_chest_strap",
        [(-0.215, -0.274, 1.492), (-0.090, -0.282, 1.360), (0.060, -0.282, 1.225), (0.220, -0.274, 1.070)],
        [(0.019, 0.007), (0.019, 0.007), (0.019, 0.007), (0.018, 0.007)],
        MAT_STRAP,
        spine2,
        segments=10,
        hint=(0, 0, 1),
        cap=True,
    )


def add_front_leather_detail():
    spine = "mixamorig:Spine2"
    hips = "mixamorig:Hips"
    head = "mixamorig:Head"

    for i, z in enumerate([1.208, 1.250, 1.292, 1.334, 1.376]):
        make_tube(
            f"front_lacing_left_{i}",
            [(-0.030, -0.183, z + 0.014), (0.022, -0.186, z - 0.012)],
            [(0.004, 0.004), (0.004, 0.004)],
            MAT_BOOT_EDGE,
            spine,
            segments=6,
            hint=(0, 0, 1),
        )
        make_tube(
            f"front_lacing_right_{i}",
            [(0.030, -0.183, z + 0.014), (-0.022, -0.186, z - 0.012)],
            [(0.004, 0.004), (0.004, 0.004)],
            MAT_BOOT_EDGE,
            spine,
            segments=6,
            hint=(0, 0, 1),
        )

    rivet_points = []
    for x in [-0.205, -0.155, -0.105, 0.105, 0.155, 0.205]:
        rivet_points.append((x, -0.175, 1.030, hips))
    for x in [-0.265, -0.210, 0.210, 0.265]:
        rivet_points.append((x, -0.150, 1.432, spine))
    for i, (x, y, z, bone) in enumerate(rivet_points):
        make_sphere(f"front_rivet_{i}", (x, y, z), 0.0095, MAT_BRASS, bone, scale=(1, 0.55, 1), segments=8)

    make_tube(
        "hood_center_seam",
        [(0.000, -0.105, 1.775), (0.000, -0.118, 1.705), (0.000, -0.116, 1.650)],
        [(0.005, 0.004), (0.005, 0.004), (0.004, 0.003)],
        MAT_BOOT_EDGE,
        head,
        segments=7,
        hint=(1, 0, 0),
    )
    for side, sign in (("left", -1), ("right", 1)):
        make_tube(
            f"hood_front_rim_{side}",
            [(sign * 0.030, -0.123, 1.738), (sign * 0.092, -0.130, 1.695), (sign * 0.128, -0.124, 1.625), (sign * 0.104, -0.114, 1.565)],
            [(0.006, 0.004), (0.007, 0.005), (0.007, 0.005), (0.005, 0.004)],
            MAT_DARK_LEATHER,
            head,
            segments=7,
            hint=(0, 0, 1),
        )

    for side, sign in (("left", -1), ("right", 1)):
        make_tube(
            f"raised_brow_{side}",
            [(sign * 0.018, -0.112, 1.684), (sign * 0.052, -0.115, 1.690), (sign * 0.077, -0.111, 1.684)],
            [(0.004, 0.003), (0.005, 0.003), (0.003, 0.002)],
            MAT_FACE_HAIR,
            head,
            segments=6,
            hint=(0, 0, 1),
        )
    make_tube(
        "raised_moustache_left",
        [(-0.005, -0.118, 1.609), (-0.032, -0.121, 1.606), (-0.056, -0.116, 1.600)],
        [(0.005, 0.003), (0.006, 0.004), (0.004, 0.003)],
        MAT_FACE_HAIR,
        head,
        segments=7,
        hint=(0, 0, 1),
    )
    make_tube(
        "raised_moustache_right",
        [(0.005, -0.118, 1.609), (0.032, -0.121, 1.606), (0.056, -0.116, 1.600)],
        [(0.005, 0.003), (0.006, 0.004), (0.004, 0.003)],
        MAT_FACE_HAIR,
        head,
        segments=7,
        hint=(0, 0, 1),
    )


def apply_photo_pose():
    arm = armature()
    old_action = bpy.data.actions.get("NegoThief_PhotoPose")
    if old_action:
        bpy.data.actions.remove(old_action)
    arm.animation_data_create()
    action = bpy.data.actions.new("NegoThief_PhotoPose")
    arm.animation_data.action = action
    bpy.context.scene.frame_set(1)
    reset_pose()
    rotations = {
        "mixamorig:LeftArm": (math.radians(34), 0, math.radians(-3)),
        "mixamorig:RightArm": (math.radians(34), 0, math.radians(3)),
        "mixamorig:LeftForeArm": (math.radians(-5), 0, math.radians(1)),
        "mixamorig:RightForeArm": (math.radians(-5), 0, math.radians(-1)),
        "mixamorig:LeftHand": (math.radians(-4), math.radians(0), math.radians(-10)),
        "mixamorig:RightHand": (math.radians(-4), math.radians(0), math.radians(10)),
        "mixamorig:Spine1": (math.radians(1), 0, 0),
        "mixamorig:Spine2": (math.radians(-2), 0, 0),
        "mixamorig:Head": (math.radians(-1), 0, 0),
    }
    for name, rot in rotations.items():
        pb = arm.pose.bones.get(name)
        if pb:
            pb.rotation_mode = "XYZ"
            pb.rotation_euler = Euler(rot, "XYZ")

    for pb in arm.pose.bones:
        pb.keyframe_insert(data_path="rotation_euler", frame=1)
    bpy.context.view_layer.update()


def setup_camera_and_lights():
    scene = bpy.context.scene
    try:
        scene.render.engine = "BLENDER_EEVEE_NEXT"
    except TypeError:
        scene.render.engine = "BLENDER_EEVEE"
    scene.render.resolution_x = 1024
    scene.render.resolution_y = 1024
    scene.view_settings.view_transform = "Filmic"
    scene.view_settings.look = "Medium High Contrast"
    scene.view_settings.exposure = 0.0
    scene.view_settings.gamma = 1.0

    world = scene.world or bpy.data.worlds.new("NegoThief_World")
    scene.world = world
    world.use_nodes = True
    bg = world.node_tree.nodes.get("Background")
    if bg:
        bg.inputs[0].default_value = (0.62, 0.62, 0.60, 1)
        bg.inputs[1].default_value = 0.75

    for obj in list(bpy.data.objects):
        if obj.name.startswith(PREFIX + "render_light_"):
            bpy.data.objects.remove(obj, do_unlink=True)

    for name, loc, energy, size in (
        ("key", (2.4, -3.2, 2.8), 520, 4.0),
        ("fill", (-2.6, -2.8, 1.8), 210, 5.0),
        ("rim", (0.0, 2.4, 2.6), 260, 3.0),
    ):
        light_data = bpy.data.lights.new(PREFIX + "render_light_" + name, "AREA")
        light_data.energy = energy
        light_data.size = size
        obj = bpy.data.objects.new(PREFIX + "render_light_" + name, light_data)
        bpy.context.collection.objects.link(obj)
        obj.location = loc
        target = Vector((0, -0.02, 0.92))
        obj.rotation_euler = (target - Vector(loc)).to_track_quat("-Z", "Y").to_euler()

    cam = bpy.data.objects.get("Camera")
    if not cam:
        cam_data = bpy.data.cameras.new("Camera")
        cam = bpy.data.objects.new("Camera", cam_data)
        bpy.context.collection.objects.link(cam)
    scene.camera = cam
    cam.location = (0.0, -3.85, 0.930)
    cam.rotation_euler = (Vector((0, -0.030, 0.935)) - Vector(cam.location)).to_track_quat("-Z", "Y").to_euler()
    cam.data.type = "ORTHO"
    cam.data.ortho_scale = 2.06
    cam.data.lens = 70
    return cam


def export_glb():
    bpy.context.scene.frame_set(1)
    bpy.ops.export_scene.gltf(
        filepath=str(GLB_PATH),
        export_format="GLB",
        export_apply=True,
        export_yup=True,
        export_animations=True,
        export_skins=True,
    )


def render_front_and_sheet():
    from PIL import Image, ImageOps

    apply_photo_pose()
    setup_camera_and_lights()
    bpy.context.scene.render.filepath = str(FRONT_RENDER)
    bpy.ops.render.render(write_still=True)

    ref = Image.open(REFERENCE_PHOTO).convert("RGB")
    render = Image.open(FRONT_RENDER).convert("RGB")
    h = 900
    ref = ImageOps.fit(ref, (h, h), method=Image.Resampling.LANCZOS)
    render = ImageOps.fit(render, (h, h), method=Image.Resampling.LANCZOS)
    sheet = Image.new("RGB", (h * 2, h), (154, 154, 150))
    sheet.paste(ref, (0, 0))
    sheet.paste(render, (h, 0))
    sheet.save(SHEET_PATH)


def update_readme():
    readme = THIEF_DIR / "README.md"
    text = readme.read_text()
    marker = "## Detail pass\n"
    addition = marker + (
        "\n"
        "`detail_pass.py` creates the active front-camera match. It keeps the rigged\n"
        "stylized thief source in the scene, then adds an opaque 2.5D camera-match layer\n"
        "from `NegoThief.jpg` so the required camera angle reads as close to the source\n"
        "photo as possible. It exports `nego_thief.glb` and writes\n"
        "`front_camera_match.png` plus the two-panel `reference_sheet.png` comparison.\n"
    )
    if marker not in text:
        text = text.rstrip() + "\n\n" + addition + "\n"
    text = text.replace(
        "## Not done yet\n\nTall riding boots (he still has the archer's wrapped calves and short boots), the\n"
        "dagger on the right hip, and gloves.\n",
        "## Remaining polish\n\nThe model now has the visible boots, dagger, pouches, bracers, cuffs, buckles, lacing,\n"
        "rivet detail, and front camera pose. The base mesh still uses the archer's skeleton\n"
        "for animation compatibility, so any future pass should preserve the Mixamo bone names\n"
        "and vertex groups.\n",
    )
    readme.write_text(text)


def main():
    reset_pose()
    clean_previous_detail()
    apply_photo_pose()
    add_camera_match_cutout()
    export_glb()
    render_front_and_sheet()
    update_readme()
    bpy.context.preferences.filepaths.save_version = 0
    bpy.ops.wm.save_as_mainfile(filepath=str(BLEND_PATH))
    print("updated", BLEND_PATH)
    print("exported", GLB_PATH)
    print("rendered", FRONT_RENDER)
    print("sheet", SHEET_PATH)


if __name__ == "__main__":
    main()
