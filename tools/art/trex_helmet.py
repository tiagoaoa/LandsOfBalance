#Replace the supplied alien skull; keep its combat skeleton and body.
import math
from pathlib import Path

import bpy
import bmesh
import numpy as np
from mathutils import Matrix, Vector

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'assets/characters/reptilian'
HEAD = Vector((0, -8.1, 13.68))
JAW = Vector((.27, -9.9, 11.52))
SKULL = [ #forward, half-width, bottom, crown
    (-1.6, .9, -1.1, 1.5), (-.7, 2.35, -1.5, 2.8),
    (.5, 2.85, -1.6, 3.25), (2.0, 2.9, -1.45, 3.05),
    (3.1, 2.65, -1.3, 2.7), (4.3, 2.15, -1.25, 2.15),
    (6.4, 2.0, -1.4, 1.8), (8.25, 2.02, -1.5, 1.75),
    (9.1, 1.8, -1.55, 1.45), (9.6, .9, -1.3, 1.05),
    (9.75, .04, -.35, .25)]
MANDIBLE = [
    (-.1, .6, -2.9, -.8), (.6, 2.3, -3.1, -.8),
    (1.6, 2.6, -3.15, -1.2), (3.4, 2.23, -2.95, -1.7),
    (6.0, 1.9, -2.8, -1.8), (8.5, 1.78, -2.65, -1.8),
    (9.25, 1.35, -2.55, -1.75), (9.65, .03, -2.15, -1.95)]


def coord(x, f, z):
    return HEAD + Vector((x, -f, z))


def mesh(name, verts, faces, mat):
    data = bpy.data.meshes.new(name)
    data.from_pydata(verts, [], faces)
    data.update()
    ob = bpy.data.objects.new(name, data)
    bpy.context.scene.collection.objects.link(ob)
    ob.data.materials.append(mat)
    for p in data.polygons:
        p.use_smooth = True
    return ob


def active(ob):
    bpy.ops.object.select_all(action='DESELECT')
    ob.select_set(True)
    bpy.context.view_layer.objects.active = ob


def bind(ob, bone):
    active(ob)
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    ob.vertex_groups.new(name=bone).add(list(range(len(ob.data.vertices))), 1, 'REPLACE')
    mod = ob.modifiers.new('Combat skeleton', 'ARMATURE')
    mod.object = rig
    ob.parent = rig
    if bone == 'jaw':
        rot = Matrix.Rotation(math.radians(30), 4, 'X')
        for v in ob.data.vertices:
            v.co = JAW + rot @ (v.co - JAW)


def unwrap(ob):
    active(ob)
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_all(action='SELECT')
    bpy.ops.uv.cube_project(cube_size=4.32)
    bpy.ops.object.mode_set(mode='OBJECT')


def normals(ob):
    bm = bmesh.new()
    bm.from_mesh(ob.data)
    bmesh.ops.recalc_face_normals(bm, faces=list(bm.faces))
    bm.to_mesh(ob.data)
    bm.free()


def profile(rows, f):
    #Cubic Hermite interpolation keeps the muzzle and crown continuous.
    a = np.array(rows)
    j = int(np.clip(np.searchsorted(a[:, 0], f) - 1, 0, len(a)-2))
    t = (f-a[j, 0]) / (a[j+1, 0]-a[j, 0])
    slopes = np.gradient(a[:, 1:], a[:, 0], axis=0)
    h = a[j+1, 0]-a[j, 0]
    return ((2*t**3-3*t*t+1)*a[j, 1:] + (t**3-2*t*t+t)*h*slopes[j]
            + (-2*t**3+3*t*t)*a[j+1, 1:] + (t**3-t*t)*h*slopes[j+1])


def skull_point(rows, f, theta, sculpt=True):
    w, low, high = profile(rows, f)
    c, s = math.cos(theta), math.sin(theta)
    power = .38 if (s < 0 and rows == SKULL) or (s > 0 and rows == MANDIBLE) else .78
    x = w * math.copysign(abs(c)**power, c)
    z = (low+high)/2 + (high-low)/2 * math.copysign(abs(s)**power, s)
    if sculpt:
        eye = math.exp(-((f-3.3)/.85)**2 - ((z-1.15)/.6)**2)
        cheek = math.exp(-((f-1.0)/1.0)**2 - ((z+.1)/.8)**2)
        x += math.copysign(.19*cheek - .32*eye, x)
        z += .035*math.sin(f*5.7+x*3)*math.sin(x*8.1-z*4.4)
    return coord(x, f, z)


def loft(name, rows, mat):
    nf, nt = 100, 64
    verts = [skull_point(rows, f, 2*math.pi*j/nt)
             for f in np.linspace(rows[0][0], rows[-1][0], nf) for j in range(nt)]
    faces = [(i*nt+j, i*nt+(j+1)%nt, (i+1)*nt+(j+1)%nt, (i+1)*nt+j)
             for i in range(nf-1) for j in range(nt)]
    faces += [tuple(reversed(range(nt))), tuple((nf-1)*nt+j for j in range(nt))]
    ob = mesh(name, verts, faces, mat)
    normals(ob)
    unwrap(ob)
    return ob


def material(name, color, rough=.5, metal=0):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    bs = mat.node_tree.nodes.get('Principled BSDF')
    bs.inputs['Base Color'].default_value = (*color, 1)
    bs.inputs['Roughness'].default_value = rough
    bs.inputs['Metallic'].default_value = metal
    return mat


def ellipsoid(name, at, scale, mat, bone='head'):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=24, ring_count=16, location=at)
    ob = bpy.context.object
    ob.name = name
    ob.scale = scale
    ob.data.materials.append(mat)
    for p in ob.data.polygons:
        p.use_smooth = True
    bind(ob, bone)
    return ob


def tooth(name, at, length, radius, down, bone, rng, broken):
    verts, faces = [], []
    end = rng.uniform(.42,.76) if broken else 1.0
    lean, bend, phase = rng.uniform(-.16,.16), rng.uniform(.1,.34), rng.uniform(0,6)
    for k in range(13):
        t = k/12*end
        r = max(.01, radius*(1-t)**.62)
        for j in range(16):
            a = j*math.tau/16
            rr = r*(1+.045*math.sin(a*5+phase+t*8))
            tip = rng.uniform(-.075,.03) if k == 12 and broken else 0
            verts.append(at+Vector((rr*math.cos(a)+lean*t, bend*length*t*t+rr*.75*math.sin(a), down*length*(t+tip))))
    for k in range(12):
        faces += [(k*16+j, k*16+(j+1)%16, (k+1)*16+(j+1)%16, (k+1)*16+j) for j in range(16)]
    faces += [tuple(reversed(range(16))), tuple(192+j for j in range(16))]
    ob = mesh(name, verts, faces, ivory)
    normals(ob)
    tooth_color(ob,rng)
    bind(ob, bone)


def tooth_color(ob, rng):
    attr = ob.data.color_attributes.new(name='Enamel',type='FLOAT_COLOR',domain='POINT')
    tint = rng.uniform(.62,1.0)
    for i, value in enumerate(attr.data):
        t, a = (i//16)/12, (i%16)/16*math.tau
        root = math.exp(-t*6)
        stain = .75+.2*math.sin(a*3+t*6+rng.uniform(0,.2))
        crack = .48 if i%16 in [3,11] and .2<t<.85 else 1
        rgb = np.array([.55,.45,.29])*(1-root)+np.array([.13,.072,.025])*root
        value.color = (*np.clip(rgb*tint*stain*crack,0,1),1)


def teeth(rows, bone, down):
    rng = np.random.default_rng(415 if down < 0 else 810)
    for side in [-1, 1]:
        for i, f in enumerate(np.linspace(1.5, 9.05, 15)):
            f += rng.uniform(-.11,.11) + (.12 if down > 0 else 0)
            w, low, high = profile(rows, f)
            z = low+.20 if down < 0 else high-.15
            length = (.40+.52*math.sin(math.pi*(i+1)/17))*(1 if down < 0 else .7)
            length *= rng.uniform(.7,1.3)
            tooth('Rex_Tooth', coord(side*w*.78, f, z), length, rng.uniform(.13,.23),
                  down,bone,rng,rng.random()<.24)


def curve(name, points, radius, mat, bone='head'):
    data = bpy.data.curves.new(name, 'CURVE')
    data.dimensions = '3D'
    data.bevel_depth, data.bevel_resolution = radius, 3
    spline = data.splines.new('POLY')
    spline.points.add(len(points)-1)
    for p, co in zip(spline.points, points):
        p.co = (*co, 1)
    ob = bpy.data.objects.new(name, data)
    bpy.context.scene.collection.objects.link(ob)
    ob.data.materials.append(mat)
    active(ob)
    bpy.ops.object.convert(target='MESH')
    bind(ob, bone)
    return ob


def plate(name, verts, faces, mat):
    ob = mesh(name, verts, faces, mat)
    normals(ob)
    active(ob)
    mod = ob.modifiers.new('Forged thickness', 'SOLIDIFY')
    mod.thickness = .16
    bpy.ops.object.modifier_apply(modifier=mod.name)
    mod = ob.modifiers.new('Worn edges', 'BEVEL')
    mod.width, mod.segments = .075, 3
    bpy.ops.object.modifier_apply(modifier=mod.name)
    unwrap(ob)
    bind(ob, 'head')
    return ob


def helm_point(f, u):
    #About 70% facial coverage: the crown wraps below the cheek midline.
    #The jaw stays separate, and sockets are cut through the face plates.
    angle = math.radians(-18)
    t = angle + (math.pi-2*angle)*u
    p = skull_point(SKULL, f, t, False)
    p.x *= 1.095
    p.z += .24
    n = Vector((math.cos(t),0,math.sin(t)))
    d = .012*math.sin(f*8+u*21)*math.sin(f*3-u*27)
    for df, du, depth, fw, uw in [(2.1,.25,.16,.8,.15),(5.4,.67,.19,.9,.15),
            (7.2,.2,.12,.5,.11),(.1,.6,.15,.5,.13),(4.2,.41,.11,.45,.1)]:
        d -= depth*math.exp(-((f-df)/fw)**2-((u-du)/uw)**2)
    p += n*d
    for df, du in [(2.3,0),(7.0,0),(4.8,1),(8.6,1)]:
        chip = max(0,1-abs(f-df)/.16)*math.exp(-((u-du)/.06)**2)
        p.z += .19*chip
    return p


def helmet():
    nf, nt = 64, 40
    verts = [helm_point(f, j/(nt-1)) for f in np.linspace(-.9, 9.58, nf) for j in range(nt)]
    faces = [(i*nt+j, i*nt+j+1, (i+1)*nt+j+1, (i+1)*nt+j) for i in range(nf-1) for j in range(nt-1)]
    cap = plate('Iron_Crown', verts, faces, iron)
    for s in [-1,1]:
        carve(cap,coord(s*2.55,3.3,1.18),(1.0,.91,.59))
        carve(cap,coord(s*1.94,8.45,.65),(.72,.54,.32))
    scars(cap)
    unwrap(cap)
    #Boolean cut walls need the same rigid skull weight as the plate.
    cap.vertex_groups['head'].add(list(range(len(cap.data.vertices))),1,'REPLACE')
    fasteners()
    for f in [-.85, 1.2, 6.55, 9.55]:
        curve('Crown_Seam', [helm_point(f+.025*math.sin(u*25+f),u)+Vector((0,0,.025)) for u in np.linspace(0,1,48)], .035, edge)
    ridge = [helm_point(f,.5)+Vector((x,0,.12)) for f in np.linspace(-.9,8.9,40) for x in [-.3,.3]]
    plate('Iron_Nasal_Reinforcement', ridge, [(2*i,2*i+1,2*i+3,2*i+2) for i in range(39)], iron)


def fasteners():
    rng = np.random.default_rng(536)
    for u in [0,1]:
        for a,b in [(-.9,2.22),(2.40,6.94),(7.1,9.58)]:
            curve('Helmet_Worn_Hem',[helm_point(f,u) for f in np.linspace(a,b,40)],.047,edge)
        for i,f in enumerate(np.linspace(-.65,9.25,16)):
            f += rng.uniform(-.06,.06)
            at = helm_point(f,u*.94+.03)+Vector((0,0,.04))
            if (i+int(u)*3)%9 == 4:
                ellipsoid('Broken_Rivet',at,(.067,.073,.028),rust)
                continue
            r = rng.uniform(.065,.095)
            ellipsoid('Iron_Rivet',at,(r,r*rng.uniform(.8,1.1),r*.6),edge if i%5 else rust)


def scars(cap):
    for f,u,df,du in [(4.7,.23,1.4,.15),(4.9,.21,1.1,.15),
                      (1.8,.73,.8,-.20),(7.0,.3,.55,.11)]:
        pts = [helm_point(f+df*t,u+du*t)+Vector((0,0,.01)) for t in np.linspace(0,1,26)]
        cutter = curve('Old_Blade_Gouge',pts,.038,rust)
        active(cap)
        mod = cap.modifiers.new('Old blade cut','BOOLEAN')
        mod.operation,mod.solver,mod.object = 'DIFFERENCE','EXACT',cutter
        bpy.ops.object.modifier_apply(modifier=mod.name)
        bpy.data.objects.remove(cutter,do_unlink=True)


def cheeks():
    for s in [-1, 1]:
        points = [(s*2.65,-.7,1.8),(s*3.06,.7,2.0),(s*3.02,1.5,.45),
                  (s*2.83,1.0,-.95),(s*2.5,-.6,-1.2)]
        pts = [coord(p[0]+s*.3,p[1],p[2]) for p in points]
        plate('Iron_Temple_Guard', pts, [(0,1,2,3,4)], iron)
        curve('Temple_Rim', pts+[pts[0]], .075, edge)
        for p in [pts[0],pts[1],pts[3],pts[4]]:
            ellipsoid('Temple_Rivet', p+Vector((s*.075,0,0)), (.1,.12,.12), edge)


def iron_texture(mat):
    rng = np.random.default_rng(318)
    n = 1024
    grain = rng.random((n,n))
    blot = .65*cloud(rng,12,n)+.25*cloud(rng,45,n)+.1*cloud(rng,180,n)
    oxidation = np.clip((blot-.34)*5.5,0,1)
    damage = scratches(rng,n)
    base = rust_colour(rng,grain,oxidation,damage)
    rough = np.clip(.57+.12*grain+.28*oxidation-.12*damage,0,1)
    metal = .82*(1-oxidation)+.025*oxidation
    flakes = cloud(rng,250,n)
    height = grain*.045+oxidation*(flakes*.3+(flakes>.57)*.14)
    height -= damage*.12+(grain<.045)*(.15+.3*oxidation)
    gy,gx = np.gradient(height)
    normal = np.stack((-gx*1.5,-gy*1.5,np.ones_like(gx)),axis=2)
    normal /= np.linalg.norm(normal,axis=2)[:,:,None]
    maps = [('albedo',base),('roughness',np.repeat(rough[:,:,None],3,axis=2)),
            ('metallic',np.repeat(metal[:,:,None],3,axis=2)),('normal',normal*.5+.5)]
    for kind,values in maps:
        save_texture(mat, kind, values)


def rust_colour(rng,grain,oxidation,damage):
    n = grain.shape[0]
    iron = np.array([.05,.058,.062])*(.7+.4*grain[:,:,None])
    shade = cloud(rng,65,n)[:,:,None]
    #Dense brown oxide with scattered ochre flakes, rather than orange paint.
    rust = np.array([.14,.037,.012])*(.55+.65*grain[:,:,None])
    rust += shade**3*np.array([.20,.085,.022])
    rust += (grain>.94)[:,:,None]*np.array([.04,.018,.006])
    coat = oxidation[:,:,None]
    return iron*(1-coat)+rust*coat+damage[:,:,None]*np.array([.028,.026,.022])


def cloud(rng, size, n):
    vals = rng.random((size,size))
    vals[-1,:] = vals[0,:]
    vals[:,-1] = vals[:,0]
    t = np.linspace(0,size-1,n)
    rows = np.array([np.interp(t,np.arange(size),row) for row in vals])
    return np.array([np.interp(t,np.arange(size),col) for col in rows.T]).T


def scratches(rng,n):
    out = np.zeros((n,n))
    for i in range(450):
        x,y = rng.integers(0,n,2)
        length = int(rng.integers(8,150))
        angle = rng.uniform(-.6,.6) if i%3 else rng.uniform(0,math.tau)
        for k in range(length):
            xx = int(x+k*math.cos(angle))%n
            yy = int(y+k*math.sin(angle))%n
            out[yy,xx] = rng.uniform(.25,.85)
    return out


def save_texture(mat, kind, values):
    n = values.shape[0]
    img = bpy.data.images.new('rex_iron_'+kind, width=n,height=n)
    rgba = np.ones((n,n,4),dtype=np.float32)
    rgba[:,:,:3] = values
    img.filepath_raw = str(OUT/('rex_iron_'+kind+'.png'))
    img.file_format = 'PNG'
    if kind != 'albedo':
        img.colorspace_settings.name = 'Non-Color'
    img.pixels.foreach_set(rgba.ravel())
    img.save()
    tex = mat.node_tree.nodes.new('ShaderNodeTexImage')
    tex.image = img
    socket = {'albedo':'Base Color','roughness':'Roughness','metallic':'Metallic','normal':'Normal'}[kind]
    output = tex.outputs['Color']
    if kind == 'normal':
        node = mat.node_tree.nodes.new('ShaderNodeNormalMap')
        node.inputs['Strength'].default_value = .45
        mat.node_tree.links.new(output,node.inputs['Color'])
        output = node.outputs['Normal']
    mat.node_tree.links.new(output,mat.node_tree.nodes['Principled BSDF'].inputs[socket])


def cut_head(ob):
    bm = bmesh.new()
    bm.from_mesh(ob.data)
    geom = list(bm.verts)+list(bm.edges)+list(bm.faces)
    cut = bmesh.ops.bisect_plane(bm,geom=geom,dist=.00001,
        plane_co=(0,-8.25,0),plane_no=(0,-1,0),clear_outer=True)
    edges = [e for e in cut['geom_cut'] if isinstance(e,bmesh.types.BMEdge) and e.is_boundary]
    bmesh.ops.holes_fill(bm,edges=edges,sides=0)
    bmesh.ops.recalc_face_normals(bm,faces=list(bm.faces))
    bm.to_mesh(ob.data)
    bm.free()


def carve(ob, at, size):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=32,ring_count=24,location=at)
    cutter = bpy.context.object
    cutter.scale = size
    active(ob)
    mod = ob.modifiers.new('Sculpted socket', 'BOOLEAN')
    mod.operation, mod.solver, mod.object = 'DIFFERENCE', 'EXACT', cutter
    bpy.ops.object.modifier_apply(modifier=mod.name)
    bpy.data.objects.remove(cutter,do_unlink=True)


def sockets(ob):
    for s in [-1,1]:
        carve(ob,coord(s*2.55,3.3,1.18),(.63,.72,.52))
        carve(ob,coord(s*1.94,8.45,.65),(.38,.43,.22))


def lids():
    out = []
    for s in [-1,1]:
        for upper in [True,False]:
            ts = np.linspace(0,math.pi,32) if upper else np.linspace(math.pi,math.tau,32)
            pts = [coord(s*(2.61-.07*math.sin(t)),3.3+.66*math.cos(t),1.18+.43*math.sin(t)) for t in ts]
            ob = curve('Rex_Orbital_Ridge',pts,.17 if upper else .075,skin)
            unwrap(ob)
            out.append(ob)
    return out


def join_skin(parts):
    active(hide)
    for ob in parts:
        ob.select_set(True)
    bpy.ops.object.join()
    #One material/surface lets SkinProbe fit the skull to this new mesh.
    for p in hide.data.polygons:
        p.material_index = 0
    while len(hide.data.materials) > 1:
        hide.data.materials.pop(index=1)


def export():
    bpy.ops.object.select_all(action='DESELECT')
    for ob in bpy.context.scene.objects:
        if ob.type in ['MESH','ARMATURE']:
            ob.select_set(True)
        if ob.type == 'MESH':
            assert all(sum(g.weight for g in v.groups) > .9 for v in ob.data.vertices), ob.name
    bpy.context.view_layer.objects.active = rig
    bpy.ops.export_scene.gltf(filepath=str(OUT/'reptilian_rex.glb'),export_format='GLB',
        use_selection=True,export_animations=False,export_extras=True,export_yup=True)
    bpy.context.preferences.filepaths.save_version = 0
    bpy.ops.wm.save_as_mainfile(filepath=str(ROOT/'tools/art/source/reptilian_rex.blend'))


def join_details():
    for mat in [iron,edge,rust,ivory,gum,socket,eye,pupil]:
        parts = [ob for ob in bpy.context.scene.objects
                 if ob.type == 'MESH' and ob != hide and ob.data.materials[0] == mat]
        if not parts:
            continue
        active(parts[0])
        for ob in parts[1:]:
            ob.select_set(True)
        bpy.ops.object.join()
        bpy.context.object.name = mat.name


bpy.ops.wm.open_mainfile(filepath=str(ROOT/'tools/art/source/reptilian_dark.blend'))
rig = bpy.data.objects['ReptilianRig']
hide = bpy.data.objects['Reptilian_Hide']
skin = hide.data.materials[0]
cut_head(hide)
iron = material('Rex_Blackened_Iron',(.1,.115,.13),.48,.87)
iron_texture(iron)
edge = iron.copy()
edge.name = 'Rex_Worn_Iron'
rust = material('Rex_Old_Rust',(.095,.033,.01),.93,.1)
ivory = material('Rex_Old_Ivory',(1,1,1),.56)
enamel = ivory.node_tree.nodes.new('ShaderNodeVertexColor')
enamel.layer_name = 'Enamel'
ivory.node_tree.links.new(enamel.outputs['Color'],ivory.node_tree.nodes['Principled BSDF'].inputs['Base Color'])
gum = material('Rex_Mouth',(.065,.012,.015),.43)
socket = material('Rex_Socket',(.012,.017,.012),.68)
eye = material('Rex_Amber',(.13,.075,.022),.3)
pupil = material('Rex_Pupil',(.003,.005,.002),.24)
skull = loft('Rex_Skull',SKULL,skin)
sockets(skull)
bind(skull,'head')
jaw = loft('Rex_Mandible',MANDIBLE,skin)
bind(jaw,'jaw')
join_skin([skull,jaw]+lids())
teeth(SKULL,'head',-1)
teeth(MANDIBLE,'jaw',1)
for s in [-1,1]:
    ellipsoid('Rex_Eye_Socket',coord(s*2.19,3.3,1.18),(.34,.34,.30),socket)
    ellipsoid('Rex_Eye',coord(s*2.48,3.34,1.2),(.10,.17,.16),eye)
    ellipsoid('Rex_Pupil',coord(s*2.573,3.37,1.21),(.02,.07,.08),pupil)
    ellipsoid('Rex_Nostril',coord(s*1.70,8.45,.65),(.08,.34,.15),socket)
ellipsoid('Rex_Tongue',coord(0,5.6,-1.93),(1.2,2.8,.2),gum,'jaw')
helmet()
cheeks()
join_details()
rig['head_design'] = 'Tyrannosaur skull, articulated mandible and forged iron helmet'
export()
print('REX BUILD',len(hide.data.vertices),'skin vertices',len(rig.data.bones),'bones')
