from pathlib import Path

import bpy
import numpy as np
from PIL import Image, ImageFilter
from mathutils import Vector


ROOT = Path("/home/talves/mthings/LandsOfBalance")
OUT_DIR = ROOT / "player/character/thief"
SOURCE = ROOT / "NegoThief.jpg"
CUTOUT = OUT_DIR / "NegoThief_relief_cutout.png"
BLEND = OUT_DIR / "nego_thief_realistic_relief.blend"
GLB = OUT_DIR / "nego_thief_realistic_relief.glb"
RENDER = OUT_DIR / "nego_thief_realistic_relief_render.png"


def reset_scene():
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete()


def make_cutout():
    img = Image.open(SOURCE).convert("RGBA")
    arr = np.asarray(img).astype(np.float32)
    rgb = arr[..., :3]
    h, w = rgb.shape[:2]

    corners = np.concatenate(
        [
            rgb[:90, :90].reshape(-1, 3),
            rgb[:90, -90:].reshape(-1, 3),
            rgb[-90:, :90].reshape(-1, 3),
            rgb[-90:, -90:].reshape(-1, 3),
        ],
        axis=0,
    )
    bg = np.median(corners, axis=0)
    dist = np.linalg.norm(rgb - bg[None, None, :], axis=2)

    # Keep the figure and its contact shadow; suppress only the flat studio background.
    alpha = np.clip((dist - 15.0) / 38.0, 0.0, 1.0)
    yy = np.linspace(0, 1, h)[:, None]
    lower_shadow_keep = np.clip((yy - 0.77) / 0.15, 0.0, 1.0)
    alpha = np.maximum(alpha, lower_shadow_keep * np.clip((dist - 4.0) / 20.0, 0.0, 0.55))
    alpha_img = Image.fromarray((alpha * 255).astype(np.uint8), "L")
    alpha_img = alpha_img.filter(ImageFilter.MaxFilter(3)).filter(ImageFilter.GaussianBlur(0.55))
    img.putalpha(alpha_img)
    img.save(CUTOUT)
    return np.asarray(alpha_img).astype(np.float32) / 255.0


def relief_depth(x, z, alpha):
    if alpha < 0.04:
        return 0.0
    d = 0.040
    # Body zones, tuned to the reference front camera.
    if z > 1.53 and abs(x) < 0.20:
        d = 0.145  # face inside hood
    elif z > 1.47 and abs(x) < 0.35:
        d = 0.120  # hood/collar
    elif 0.84 < z < 1.45 and abs(x) < 0.34:
        d = 0.105  # leather torso
    elif 0.40 < z < 0.86 and abs(x) < 0.23:
        d = 0.075  # trousers
    elif z < 0.42 and abs(x) < 0.24:
        d = 0.090  # boots
    elif 0.92 < z < 1.45:
        d = 0.070  # arms/bracers
    return d * alpha


def make_material():
    mat = bpy.data.materials.new("photo realistic front material")
    mat.use_nodes = True
    mat.blend_method = "OPAQUE"
    nodes = mat.node_tree.nodes
    nodes.clear()
    out = nodes.new("ShaderNodeOutputMaterial")
    emission = nodes.new("ShaderNodeEmission")
    tex = nodes.new("ShaderNodeTexImage")
    tex.image = bpy.data.images.load(str(SOURCE), check_existing=True)
    emission.inputs["Strength"].default_value = 1.0
    mat.node_tree.links.new(tex.outputs["Color"], emission.inputs["Color"])
    mat.node_tree.links.new(emission.outputs["Emission"], out.inputs["Surface"])
    return mat


def make_back_material():
    mat = bpy.data.materials.new("dark relief side material")
    mat.diffuse_color = (0.035, 0.020, 0.012, 1)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
    if bsdf:
        bsdf.inputs["Base Color"].default_value = (0.035, 0.020, 0.012, 1)
        bsdf.inputs["Roughness"].default_value = 0.58
    return mat


def make_relief_mesh(alpha, material):
    n = 150
    scale = 2.05
    z_center = 0.935
    verts = []
    uvs = []
    alphas = []

    h, w = alpha.shape
    for j in range(n + 1):
        v = j / n
        for i in range(n + 1):
            u = i / n
            ix = min(w - 1, max(0, int(u * (w - 1))))
            iy = min(h - 1, max(0, int(v * (h - 1))))
            a = float(alpha[iy, ix])
            x = (u - 0.5) * scale
            z = z_center + (0.5 - v) * scale
            y = -0.020 - relief_depth(x, z, a)
            verts.append((x, y, z))
            uvs.append((u, 1.0 - v))
            alphas.append(a)

    faces = []
    for j in range(n):
        for i in range(n):
            idx = j * (n + 1) + i
            faces.append((idx, idx + 1, idx + n + 2, idx + n + 1))

    mesh = bpy.data.meshes.new("nego thief relief mesh")
    mesh.from_pydata(verts, [], faces)
    mesh.update()
    uv_layer = mesh.uv_layers.new(name="UVMap")
    for poly in mesh.polygons:
        for loop_index in poly.loop_indices:
            uv_layer.data[loop_index].uv = uvs[mesh.loops[loop_index].vertex_index]

    obj = bpy.data.objects.new("NegoThief realistic relief front", mesh)
    bpy.context.collection.objects.link(obj)
    obj.data.materials.append(material)
    obj.modifiers.new("weighted relief normals", "WEIGHTED_NORMAL")
    return obj


def add_thickness(alpha, material):
    # A dark back plate gives the asset physical thickness in the .blend/.glb.
    obj = make_relief_mesh(alpha, material)
    obj.name = "NegoThief relief back thickness"
    for v in obj.data.vertices:
        v.co.y += 0.140
    obj.hide_render = True
    return obj


def add_camera_and_light():
    scene = bpy.context.scene
    try:
        scene.render.engine = "CYCLES"
        scene.cycles.samples = 80
        scene.cycles.use_denoising = True
    except Exception:
        scene.render.engine = "BLENDER_EEVEE_NEXT"
    scene.render.resolution_x = 1400
    scene.render.resolution_y = 1400
    scene.view_settings.view_transform = "Filmic"
    scene.view_settings.look = "Medium High Contrast"
    scene.view_settings.exposure = 0

    world = bpy.data.worlds.new("neutral studio")
    scene.world = world
    world.use_nodes = True
    bg = world.node_tree.nodes["Background"]
    bg.inputs[0].default_value = (0.72, 0.72, 0.70, 1)
    bg.inputs[1].default_value = 0.8

    for name, loc, energy, size in [
        ("softbox", (-2.5, -3.0, 2.6), 350, 4.0),
        ("fill", (2.2, -2.6, 1.5), 90, 5.0),
    ]:
        light = bpy.data.lights.new(name, "AREA")
        light.energy = energy
        light.size = size
        obj = bpy.data.objects.new(name, light)
        bpy.context.collection.objects.link(obj)
        obj.location = loc
        target = Vector((0, -0.08, 0.9))
        obj.rotation_euler = (target - Vector(loc)).to_track_quat("-Z", "Y").to_euler()

    cam_data = bpy.data.cameras.new("front render camera")
    cam = bpy.data.objects.new("front render camera", cam_data)
    bpy.context.collection.objects.link(cam)
    cam.location = (0, -4.0, 0.935)
    cam.rotation_euler = (Vector((0, -0.10, 0.935)) - Vector(cam.location)).to_track_quat("-Z", "Y").to_euler()
    cam.data.type = "ORTHO"
    cam.data.ortho_scale = 2.05
    scene.camera = cam


def main():
    reset_scene()
    alpha = make_cutout()
    front_mat = make_material()
    back_mat = make_back_material()
    make_relief_mesh(alpha, front_mat)
    add_thickness(alpha, back_mat)
    add_camera_and_light()
    bpy.context.preferences.filepaths.save_version = 0
    bpy.ops.wm.save_as_mainfile(filepath=str(BLEND))
    bpy.ops.export_scene.gltf(filepath=str(GLB), export_format="GLB", export_apply=True)
    bpy.context.scene.render.filepath = str(RENDER)
    bpy.ops.render.render(write_still=True)
    print("saved", BLEND)
    print("exported", GLB)
    print("rendered", RENDER)


if __name__ == "__main__":
    main()
