extends Node3D

const WATER_SHADER := preload("res://stage/river_water.gdshader")
const DEPTH := 1.4
const BANK_REACH := 4.0
const ROW_STEP := 2.0
const CHUNK_LENGTH := 64.0

var water_y := .32
var ground_y := .5
var bounds := Rect2(-535.2693, -572.4915, 1070.5386, 1144.983)
var water_material: ShaderMaterial
var earth_material: StandardMaterial3D
var bridges: Array[Node3D] = []


func _ready() -> void:
	var ground := get_node("../Ground/MainGround") as CSGBox3D
	ground_y = ground.global_position.y + ground.size.y * .5
	water_y = ground_y - .18
	bounds = Rect2(Vector2(ground.global_position.x, ground.global_position.z)
			- Vector2(ground.size.x, ground.size.z) * .5, Vector2(ground.size.x, ground.size.z))
	#Replace the flat slab with land and channel meshes sharing their bank vertices.
	ground.use_collision = false
	ground.hide()
	_materials()
	var z := bounds.position.y
	while z < bounds.end.y:
		var end := minf(z + CHUNK_LENGTH, bounds.end.y)
		_build_chunk(z, end, ground.material)
		z = end
	_bridges()
	_reeds()
	var label := get_node_or_null("RiverLabel") as Node3D
	if label:
		label.position = Vector3(center_x(30), 3, 30)
	print("River: %.1fm across the map, %.1fm deep" % [bounds.size.y, DEPTH])


static func center_x(z: float) -> float:
	return 16.0 - .62 * z + 8.0 * sin(z / 65.0)


static func half_width(z: float) -> float:
	return 5.5 + .55 * sin(z / 37.0) + .25 * sin(z / 11.0)


func contains_bank(x: float, z: float) -> bool:
	return z >= bounds.position.y and z <= bounds.end.y \
			and absf(x - center_x(z)) < half_width(z) + BANK_REACH


func _materials() -> void:
	water_material = ShaderMaterial.new()
	water_material.shader = WATER_SHADER
	water_material.set_shader_parameter("normal_a", _normal_texture(.035, 71))
	water_material.set_shader_parameter("normal_b", _normal_texture(.075, 132))
	earth_material = StandardMaterial3D.new()
	earth_material.albedo_texture = load("res://assets/textures/Ground037_1K-JPG_Color.jpg")
	earth_material.albedo_color = Color(.68, .64, .53)
	earth_material.vertex_color_use_as_albedo = true
	earth_material.normal_enabled = true
	earth_material.normal_texture = load("res://assets/textures/Ground037_1K-JPG_NormalGL.jpg")
	earth_material.normal_scale = 1.3
	earth_material.roughness_texture = load("res://assets/textures/Ground037_1K-JPG_Roughness.jpg")
	earth_material.roughness = .85
	earth_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC


func _build_chunk(start: float, end: float, land_material: Material) -> void:
	var count := int(ceil((end - start) / ROW_STEP))
	var land := SurfaceTool.new()
	var bed := SurfaceTool.new()
	var water := SurfaceTool.new()
	for st in [land, bed, water]:
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for row in range(count):
		var a := lerpf(start, end, float(row) / count)
		var b := lerpf(start, end, float(row + 1) / count)
		var ra := _bank_row(a)
		var rb := _bank_row(b)
		for i in range(ra.size() - 1):
			_quad(bed, ra[i], ra[i + 1], rb[i], rb[i + 1])
		for side in [-1, 1]:
			var index := 0 if side < 0 else ra.size() - 1
			var x := bounds.position.x if side < 0 else bounds.end.x
			var fa := Vector3(x, ground_y, a)
			var fb := Vector3(x, ground_y, b)
			if side < 0:
				_quad(land, fa, ra[index], fb, rb[index])
			else:
				_quad(land, ra[index], fa, rb[index], fb)
		for col in range(16):
			var u := float(col) / 16
			var v := float(col + 1) / 16
			_quad(water, _water_point(a, u), _water_point(a, v),
					_water_point(b, u), _water_point(b, v), true)
	_mesh(land, "RiverLand", land_material, true)
	_mesh(bed, "RiverChannel", earth_material, true)
	_mesh(water, "RiverWaterSurface", water_material, false)
	#Each section can be culled separately, and carries one spatial water loop.
	var sfx := get_node_or_null("/root/Sfx")
	if sfx:
		var z := (start + end) * .5
		sfx.loop3d("river_loop", self, Vector3(center_x(z), water_y + .2, z), -16.0, 48.0)


func _bank_row(z: float) -> PackedVector3Array:
	var w := half_width(z)
	var x := center_x(z)
	var crest := ground_y + .12 + .035 * sin(z * .7)
	return PackedVector3Array([
		Vector3(x - w - BANK_REACH, ground_y, z),
		Vector3(x - w - 1.2, crest, z),
		Vector3(x - w, water_y, z),
		Vector3(x - w + 2.5, water_y - DEPTH, z),
		Vector3(x + w - 2.5, water_y - DEPTH, z),
		Vector3(x + w, water_y, z),
		Vector3(x + w + 1.2, crest, z),
		Vector3(x + w + BANK_REACH, ground_y, z),
	])


func _water_point(z: float, u: float) -> Vector3:
	return Vector3(center_x(z) + (u * 2 - 1) * half_width(z), water_y, z)


func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, water := false) -> void:
	for p in [a, b, c, b, d, c]:
		if water:
			var offset: float = p.x - center_x(p.z)
			var u: float = .5 + offset / (half_width(p.z) * 2.0)
			st.set_uv(Vector2(offset / 4.0, p.z / 4.0))
			st.set_color(Color(u, clampf((half_width(p.z) - absf(offset)) / 2.5, 0, 1), 0, 1))
		else:
			st.set_uv(Vector2(p.x, p.z) / 2.6)
			var shade: float = lerpf(.45, 1.0, smoothstep(water_y - .2, ground_y + .1, p.y))
			st.set_color(Color(shade, shade, shade))
		st.add_vertex(p)


func _mesh(st: SurfaceTool, label: String, material: Material, collision: bool) -> void:
	st.generate_normals()
	st.generate_tangents()
	st.index()
	var mesh := MeshInstance3D.new()
	mesh.name = label
	mesh.mesh = st.commit()
	mesh.material_override = material
	add_child(mesh)
	if collision:
		mesh.create_trimesh_collision()
	else:
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mesh.extra_cull_margin = .1


func _bridges() -> void:
	var roads := get_node_or_null("../Roads")
	if not roads:
		return
	for road in roads.get_children():
		if not road is CSGBox3D:
			continue
		var forward: Vector3 = road.global_basis.z.normalized()
		var a: Vector3 = road.global_position - forward * road.size.z * .5
		var b: Vector3 = road.global_position + forward * road.size.z * .5
		if (a.x - center_x(a.z)) * (b.x - center_x(b.z)) >= 0:
			continue
		for i in range(20):
			var mid := (a + b) * .5
			if (a.x - center_x(a.z)) * (mid.x - center_x(mid.z)) > 0:
				a = mid
			else:
				b = mid
		var crossing := (a + b) * .5
		var slope := (center_x(crossing.z + .5) - center_x(crossing.z - .5))
		var length := (half_width(crossing.z) + 3.2) * 2 / absf(forward.x - slope * forward.z)
		#The buried blockout road must not leave a shelf across the riverbed.
		road.use_collision = false
		road.hide()
		var bridge := Node3D.new()
		bridge.name = road.name + "Bridge"
		add_child(bridge)
		bridge.global_position = Vector3(crossing.x, ground_y + .2, crossing.z)
		bridge.global_basis = road.global_basis.orthonormalized()
		bridges.append(bridge)
		var wood := StandardMaterial3D.new()
		wood.albedo_color = Color(.22, .135, .068)
		wood.roughness = .9
		#One smooth collision deck; individual planks carry the visible joints.
		var deck := StaticBody3D.new()
		bridge.add_child(deck)
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(5.2, .25, length)
		shape.shape = box
		shape.position.y = -.125
		deck.add_child(shape)
		var planks := int(ceil(length / .32))
		for i in range(planks):
			_box(bridge, Vector3(5.2, .25, length / planks - .012),
					Vector3(0, -.125, -length * .5 + (i + .5) * length / planks), wood)
		_bridge_ramps(bridge, length, wood)
		for side in [-1.0, 1.0]:
			_box(bridge, Vector3(.13, .14, length), Vector3(side * 2.5, .95, 0), wood)
			for i in range(int(length / 2.5) + 1):
				_box(bridge, Vector3(.18, 1.2, .18),
						Vector3(side * 2.5, .45, -length * .5 + i * 2.5), wood)


func _bridge_ramps(bridge: Node3D, length: float, material: Material) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for side in [-1.0, 1.0]:
		var a := Vector3(-2.6, 0, side * length * .5)
		var b := Vector3(2.6, 0, a.z)
		var c := Vector3(-2.6, -.2, a.z + side * 2.0)
		var d := Vector3(2.6, -.2, c.z)
		if side > 0:
			_quad(st, a, b, c, d)
		else:
			_quad(st, c, d, a, b)
	st.generate_normals()
	var ramps := MeshInstance3D.new()
	ramps.name = "ApproachRamps"
	ramps.mesh = st.commit()
	ramps.material_override = material
	bridge.add_child(ramps)
	ramps.create_trimesh_collision()


func _box(parent: Node3D, size: Vector3, at: Vector3, material: Material) -> void:
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mesh.mesh = box
	mesh.material_override = material
	mesh.position = at
	parent.add_child(mesh)


func _reeds() -> void:
	var blade := SurfaceTool.new()
	blade.begin(Mesh.PRIMITIVE_TRIANGLES)
	for v in [Vector3(-.035, 0, 0), Vector3(.035, 0, 0), Vector3(.08, 1, 0)]:
		blade.add_vertex(v)
	blade.generate_normals()
	var mesh := blade.commit()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(.17, .24, .085)
	mat.roughness = .95
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.surface_set_material(0, mat)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7331
	var z := bounds.position.y
	while z < bounds.end.y:
		var count := mini(180, int((bounds.end.y - z) * 3))
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = mesh
		mm.instance_count = count
		for i in range(count):
			var pz := z + float(i) / 3.0
			var side := -1.0 if i % 2 else 1.0
			var px := center_x(pz) + side * (half_width(pz) + rng.randf_range(.4, 1.1))
			var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(1, rng.randf_range(.45, 1.1), 1))
			mm.set_instance_transform(i, Transform3D(basis, Vector3(px, ground_y + .01, pz)))
		var reeds := MultiMeshInstance3D.new()
		reeds.name = "BankReeds"
		reeds.multimesh = mm
		reeds.visibility_range_end = 110.0
		add_child(reeds)
		z += 60.0


func _normal_texture(frequency: float, seed_value: int) -> NoiseTexture2D:
	var noise := FastNoiseLite.new()
	noise.seed = seed_value
	noise.frequency = frequency
	noise.fractal_octaves = 3
	var tex := NoiseTexture2D.new()
	tex.width = 256
	tex.height = 256
	tex.seamless = true
	tex.as_normal_map = true
	tex.bump_strength = 3.5
	tex.noise = noise
	return tex
