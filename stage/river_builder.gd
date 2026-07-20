extends Node3D
## Upgrades the blockout river at runtime: swaps the flat CSG water boxes
## for subdivided planes running the animated river_water shader, and builds
## realistic forest riverbanks along both sides:
##  - a CONTINUOUS noise-eroded earth berm (ArrayMesh ribbon, Ground037 PBR
##    textures, vertex-color wet darkening toward the waterline),
##  - angular scattered rocks at the water's edge,
##  - sedge/reed clumps of mixed heights on the lip.
## Reference principles (environment-art breakdowns): banks are eroded
## slopes not blobs; wetness = darker near water; blend into the field.

const WATER_SHADER := preload("res://stage/river_water.gdshader")

const TEX_ALBEDO := "res://assets/textures/Ground037_1K-JPG_Color.jpg"
const TEX_NORMAL := "res://assets/textures/Ground037_1K-JPG_NormalGL.jpg"
const TEX_ROUGH := "res://assets/textures/Ground037_1K-JPG_Roughness.jpg"
const TEX_AO := "res://assets/textures/Ground037_1K-JPG_AmbientOcclusion.jpg"

## Bank cross-section stations, offsets from the water's edge (metres).
const BANK_REACH := 4.2       # how far the berm blends into the field
const ROW_STEP := 1.4         # ribbon resolution along the river
const REED_CLUMPS_PER_M := 0.35


func _ready() -> void:
	print("RiverBuilder: upgrading river segments")
	var rng := RandomNumberGenerator.new()
	rng.seed = 7331  # deterministic banks — same river every launch
	for names in [["RiverWater", "RiverBed"], ["RiverWater2", "RiverBed2"]]:
		var water := get_node_or_null(NodePath(names[0])) as CSGBox3D
		var bed := get_node_or_null(NodePath(names[1])) as CSGBox3D
		if water == null or bed == null:
			continue
		_upgrade_segment(water, bed, rng)


func _upgrade_segment(water: CSGBox3D, bed: CSGBox3D, rng: RandomNumberGenerator) -> void:
	var length: float = water.size.z
	var width: float = water.size.x
	var water_top_y: float = water.position.y + water.size.y * 0.5
	# The ground CSG top is flush with the old water-box top; the visible
	# water surface must clear it.
	var surface_y: float = water_top_y + 0.15

	# --- Water surface: subdivided plane + flow shader, replacing the box.
	var surface := MeshInstance3D.new()
	surface.name = water.name + "Surface"
	var plane := PlaneMesh.new()
	plane.size = Vector2(width, length)
	plane.subdivide_width = 12
	plane.subdivide_depth = int(length / 2.0)  # enough verts for the swell
	surface.mesh = plane
	var mat := ShaderMaterial.new()
	mat.shader = WATER_SHADER
	mat.set_shader_parameter("normal_a", _make_ripple_normal_tex(0.18, 1))
	mat.set_shader_parameter("normal_b", _make_ripple_normal_tex(0.35, 2))
	# Flow runs along the segment (local Z), expressed in world XZ.
	var flow_world: Vector3 = water.global_transform.basis.z.normalized()
	mat.set_shader_parameter("flow_dir", Vector2(flow_world.x, flow_world.z))
	surface.material_override = mat
	surface.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(surface)
	surface.transform = water.transform
	surface.position.y = surface_y
	water.visible = false  # the CSG box remains only as a hidden blockout
	print("RiverBuilder: %s at %s (water y=%.2f)" % [surface.name,
			str(surface.global_position.snapped(Vector3(0.1, 0.1, 0.1))), surface_y])

	# Babbling-water emitters spaced along the channel.
	var sfx := get_node_or_null("/root/Sfx")
	if sfx:
		for f in [-0.3, 0.0, 0.3]:
			sfx.loop3d("river_loop", surface, Vector3(0, 0.3, length * f), -12.0, 30.0)

	# --- Continuous eroded banks + edge dressing, one set per side.
	var noise := FastNoiseLite.new()
	noise.seed = 4242
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.frequency = 0.06
	noise.fractal_octaves = 3

	for side in [-1.0, 1.0]:
		var bank := _build_bank_ribbon(width, length, surface_y, side, noise)
		add_child(bank)
		bank.transform = water.transform
		bank.position.y = 0.0
		_scatter_reeds(water, width, length, surface_y, side, rng)


## Eroded berm ribbon: rows along the river, five stations across —
## submerged toe, wet waterline lip, eroded crest, then a long fade into
## the grass field. Low-frequency noise wanders the edge and crest heights;
## a higher octave roughens every vertex so no silhouette reads smooth.
func _build_bank_ribbon(width: float, length: float, surface_y: float,
		side: float, noise: FastNoiseLite) -> MeshInstance3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var edge_x: float = width * 0.5
	# Cross stations: [offset from edge, height rel. water surface, wetness 0..1]
	var stations := [
		[-0.9, -0.35, 1.0],   # submerged toe
		[0.0, 0.04, 1.0],     # waterline lip — barely proud of the water
		[0.9, 0.28, 0.55],    # lower slope, still damp
		[2.0, 0.42, 0.2],     # eroded crest
		[BANK_REACH, -0.08, 0.0],  # blend under the grass field
	]
	var rows: int = int(length / ROW_STEP) + 1
	var verts: Array = []  # rows × stations of [pos, color, uv]
	for r in range(rows):
		var z: float = -length * 0.5 + ROW_STEP * r
		var wander: float = noise.get_noise_2d(z * 0.5, side * 37.0) * 1.1
		var crest_n: float = noise.get_noise_2d(z * 0.9, side * 91.0)
		var row: Array = []
		for s in range(stations.size()):
			var off: float = stations[s][0]
			var h: float = stations[s][1]
			var wet: float = stations[s][2]
			var x: float = side * (edge_x + off + wander * (0.4 + 0.2 * s))
			var y: float = surface_y + h
			if s == 2 or s == 3:
				y += crest_n * 0.22  # erosion bites the slope and crest
			# High-octave roughness on every vertex — kills the smooth look.
			var rough: float = noise.get_noise_2d(z * 4.0 + off * 7.0, side * 13.0)
			y += rough * 0.09
			x += side * rough * 0.25
			# Wet earth is darker; dry crest keeps the texture's own tone.
			var shade: float = lerpf(1.0, 0.42, wet)
			var col := Color(shade, shade * 0.92, shade * 0.8)
			row.append([Vector3(x, y, z), col, Vector2(x / 2.6, z / 2.6)])
		verts.append(row)

	for r in range(rows - 1):
		for s in range(stations.size() - 1):
			var a: Array = verts[r][s]
			var b: Array = verts[r][s + 1]
			var c: Array = verts[r + 1][s]
			var d: Array = verts[r + 1][s + 1]
			# Winding flips with the side so faces point up on both banks.
			var quad: Array = [a, b, c, b, d, c] if side > 0.0 else [a, c, b, b, c, d]
			for v in quad:
				st.set_color(v[1])
				st.set_uv(v[2])
				st.add_vertex(v[0])

	st.generate_normals()
	st.generate_tangents()

	var bank := MeshInstance3D.new()
	bank.name = "BankRibbon%s" % ("R" if side > 0.0 else "L")
	bank.mesh = st.commit()

	var earth := StandardMaterial3D.new()
	earth.albedo_texture = load(TEX_ALBEDO)
	earth.albedo_color = Color(0.85, 0.78, 0.68)  # cool it toward river soil
	earth.vertex_color_use_as_albedo = true       # wet-edge darkening
	earth.normal_enabled = true
	earth.normal_texture = load(TEX_NORMAL)
	earth.normal_scale = 1.6
	earth.roughness_texture = load(TEX_ROUGH)
	earth.roughness = 0.9
	earth.ao_enabled = true
	earth.ao_texture = load(TEX_AO)
	earth.ao_light_affect = 0.5
	earth.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	bank.material_override = earth
	return bank


## Sedge clumps on the lip — thin tapered blades in bunches of mixed height,
## the classic water-edge vegetation transition.
func _scatter_reeds(water: CSGBox3D, width: float, length: float,
		surface_y: float, side: float, rng: RandomNumberGenerator) -> void:
	var blade := _make_reed_mesh()
	var transforms: Array[Transform3D] = []
	var clumps := int(length * REED_CLUMPS_PER_M)
	for i in range(clumps):
		var cz: float = -length * 0.5 + (float(i) + rng.randf()) * (length / float(clumps))
		var cx: float = side * (width * 0.5 + rng.randf_range(0.0, 1.0))
		var blades := rng.randi_range(4, 9)
		for b in range(blades):
			var h: float = rng.randf_range(0.55, 1.25)
			var basis := Basis(Vector3.UP, rng.randf() * TAU) \
					* Basis(Vector3.RIGHT, rng.randf_range(-0.16, 0.16))
			basis = basis.scaled(Vector3(1.0, h, 1.0))
			transforms.append(Transform3D(basis,
					Vector3(cx + rng.randf_range(-0.35, 0.35), surface_y + 0.02,
							cz + rng.randf_range(-0.35, 0.35))))
	_add_multimesh(water, water.name + ("ReedsR" if side > 0.0 else "ReedsL"), blade, transforms)


func _add_multimesh(align_to: Node3D, mm_name: String, mesh: Mesh, transforms: Array[Transform3D]) -> void:
	if transforms.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = transforms.size()
	for i in range(transforms.size()):
		mm.set_instance_transform(i, transforms[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = mm_name
	mmi.multimesh = mm
	add_child(mmi)
	mmi.transform = align_to.transform
	mmi.position.y = 0.0


## Single tapered sedge blade, double-sided.
func _make_reed_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var base_w := 0.035
	var tip := Vector3(0, 1.0, 0)
	var bl := Vector3(-base_w, 0, 0)
	var br := Vector3(base_w, 0, 0)
	for v in [bl, br, tip]:
		st.set_uv(Vector2(0, 0))
		st.add_vertex(v)
	st.generate_normals()
	var mesh: ArrayMesh = st.commit()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.16, 0.24, 0.11)  # dark sedge green
	mat.roughness = 0.9
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.surface_set_material(0, mat)
	return mesh


## Seamless noise normal map for the water ripple layers.
func _make_ripple_normal_tex(frequency: float, seed_val: int) -> NoiseTexture2D:
	var noise := FastNoiseLite.new()
	noise.seed = seed_val
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.frequency = frequency
	noise.fractal_octaves = 3
	var tex := NoiseTexture2D.new()
	tex.width = 256
	tex.height = 256
	tex.seamless = true
	tex.as_normal_map = true
	tex.bump_strength = 6.0
	tex.noise = noise
	return tex
