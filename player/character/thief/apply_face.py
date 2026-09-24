"""Point the head materials at the projected maps and give the skin a skin shader.

Run inside Blender:  blender -b nego_thief.blend --python apply_face.py

Also removes the leftover 2.5D "camera match" layer -- an earlier pass hid the
real meshes from the render and put a photo on a plane in front of them, which
is not a character.
"""
import os
import bpy

HERE = os.path.dirname(os.path.abspath(__file__))


def image(name, colorspace="sRGB"):
    path = os.path.join(HERE, name)
    img = bpy.data.images.load(path, check_existing=False)
    img.name = os.path.splitext(name)[0]
    img.colorspace_settings.name = colorspace
    return img


def clean():
    for ob in list(bpy.data.objects):
        if ob.name.startswith("NegoDetail"):
            bpy.data.objects.remove(ob, do_unlink=True)
    for mat in list(bpy.data.materials):
        if mat.name.startswith("NegoDetail") and mat.users == 0:
            bpy.data.materials.remove(mat)
    for name in ("Thief_Body", "Thief_Eyes", "Thief_Clothes"):
        ob = bpy.data.objects[name]
        ob.hide_render = False
        ob.hide_viewport = False


def wire(mat, diffuse, normal, rough, spec, eye=False):
    mat.use_nodes = True
    nt = mat.node_tree
    bsdf = next(n for n in nt.nodes if n.type == "BSDF_PRINCIPLED")
    for n in [n for n in nt.nodes if n.type in ("TEX_IMAGE", "NORMAL_MAP")]:
        nt.nodes.remove(n)

    def tex(img, x, y):
        n = nt.nodes.new("ShaderNodeTexImage")
        n.image = img
        n.location = (x, y)
        return n

    nt.links.new(tex(diffuse, -700, 300).outputs["Color"], bsdf.inputs["Base Color"])
    nt.links.new(tex(rough, -700, 0).outputs["Color"], bsdf.inputs["Roughness"])
    nt.links.new(tex(spec, -700, 150).outputs["Color"], bsdf.inputs["Specular IOR Level"])
    nm = nt.nodes.new("ShaderNodeNormalMap")
    nm.location = (-400, -300)
    nm.inputs["Strength"].default_value = 1.0 if not eye else 0.0
    nt.links.new(tex(normal, -700, -300).outputs["Color"], nm.inputs["Color"])
    nt.links.new(nm.outputs["Normal"], bsdf.inputs["Normal"])

    if eye:
        bsdf.inputs["Coat Weight"].default_value = 0.12
        bsdf.inputs["Coat Roughness"].default_value = 0.02
        bsdf.inputs["Subsurface Weight"].default_value = 0.0
    else:
        # dark skin: shallow red scatter, no clearcoat
        bsdf.inputs["Specular Tint"].default_value = (1.0, 1.0, 1.0, 1.0)
        bsdf.inputs["Subsurface Weight"].default_value = 0.17
        bsdf.inputs["Subsurface Radius"].default_value = (1.0, 0.34, 0.20)
        bsdf.inputs["Subsurface Scale"].default_value = 0.006
        bsdf.inputs["Coat Weight"].default_value = 0.0


def main():
    clean()
    diffuse = image("Thief_Body_diffuse.png", "sRGB")
    normal = image("Thief_Face_normal.png", "Non-Color")
    rough = image("Thief_Face_rough.png", "Non-Color")
    spec = image("Thief_Face_spec.png", "Non-Color")
    wire(bpy.data.materials["Thief_Skin_MAT"], diffuse, normal, rough, spec)
    wire(bpy.data.materials["Thief_Eye_MAT"], diffuse, normal, rough, spec, eye=True)
    out = os.environ.get("THIEF_OUT")
    if out:
        bpy.ops.wm.save_as_mainfile(filepath=out)
        print("SAVED", out)


if __name__ == "__main__":
    main()
