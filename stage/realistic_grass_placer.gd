extends MultiMeshInstance3D

## Procedurally populates the SimpleGrassTextured node with a dense blade
## field across the open terrain — tall, chaotic, waist-high grass that
## surrounds built-up zones without spilling into them. The old layered
## approaches (tiled `realistic_grass.glb`, scaled-up grass_large tufts,
## hand-painted hundreds-of-instances) are all disabled because none of
## them produced the DS3-ish dense-blade aesthetic we're going for.
##
## Interactive mode is enabled on the SimpleGrass singleton so blades bend
## away as the player walks through them (Player._physics_process feeds
## its world position each frame).
##
## Exclusion zones cover all structured areas: rivers, roads, village,
## castle, training grounds, tower, realm fields, burning peaks. Grass
## only appears on the wild open terrain between them.

const SGT_NODE_PATH: String = "../../SimpleGrassTextured"

@export_group("Blade field")
## One blade per ~40 cm (cornfield-sparse) = ~6 blades/m².
## Rule-spec: root-to-root distance 30-50 cm.
@export_range(0.5, 20.0) var blade_density: float = 6.0
## Half-extents of the dense grass region — centred on origin.
@export var field_half_x: float = 260.0
@export var field_half_z: float = 260.0
## Per-blade size. Height 1.5m = Paladin shoulder (model is ~1.8m tall).
@export var base_blade_size: Vector3 = Vector3(1.0, 1.5, 1.0)
@export var height_variance: float = 0.18
## Where blade roots plant vertically. Paladin's feet settle around Y≈0.55
## after gravity on the default MainGround CSGBox; keep roots just below so
## blades don't clip up through his boots.
@export var grass_root_y: float = 0.45
## When >0, cuts blades drawn further than this from the SGT node's
## origin (NOT the camera). Leave at 0 unless you've repositioned SGT
## to follow the player — otherwise it hides grass in the wrong half
## of the map.
@export var blade_visibility_range: float = 0.0

@export_group("Legacy cover (disabled by default)")
@export var enable_legacy_tufts: bool = false
@export var grass_count: int = 250
@export var ground_half_x: float = 535.0
@export var ground_half_z: float = 572.0
@export var grass_y: float = 0.5
@export var min_scale: float = 0.8
@export var max_scale: float = 1.4

var _exclusion_zones: Array[Rect2] = []


func _ready() -> void:
	_apply_performance_scaling()
	_setup_exclusion_zones()
	_hide_legacy_layers()
	_distribute_legacy_tufts()
	_populate_blade_field()
	_enable_interactive_mode()


## Half the blade density (and disable some niceties) when the game is
## launched with --performance-mode so --test_full_game.sh and similar
## still show grass without the full 1.3M-blade cost.
func _apply_performance_scaling() -> void:
	var gs := get_node_or_null("/root/GameSettings")
	var perf: bool = false
	if gs and "performance_mode" in gs:
		perf = gs.performance_mode
	if not perf and OS.has_feature("mobile"):
		perf = true
	if not perf:
		return
	blade_density = minf(blade_density, 2.5)
	print("RealisticGrassPlacer: performance mode — blade_density lowered to %.1f" % blade_density)


## Every grass-adjacent node from older iterations — hide them so only the
## new blade field renders. Leaves them in the scene in case you want to
## flip them back on manually.
func _hide_legacy_layers() -> void:
	for path in ["../GrassMultiMesh_0", "../GrassMultiMesh_1", "../GrassMultiMesh_2"]:
		var n := get_node_or_null(path)
		if n:
			n.visible = false
	# Also wipe any RealisticGrassField child left over from the tile-grid approach.
	var rgf := get_node_or_null("RealisticGrassField")
	if rgf:
		rgf.queue_free()
	# The multimesh on this node itself used to render low tufts; hide it.
	visible = enable_legacy_tufts


func _setup_exclusion_zones() -> void:
	var stage := get_node_or_null("../..")
	if stage == null:
		return

	for branch_path in ["River", "Roads"]:
		var branch := stage.get_node_or_null(branch_path)
		if branch == null:
			continue
		var margin: float = 5.0 if branch_path == "River" else 3.0
		for child in branch.get_children():
			if child is CSGBox3D:
				var box: CSGBox3D = child as CSGBox3D
				var pos: Vector3 = box.global_position
				var bsize: Vector3 = box.size
				_exclusion_zones.append(Rect2(
					pos.x - bsize.x * 0.5 - margin, pos.z - bsize.z * 0.5 - margin,
					bsize.x + margin * 2.0, bsize.z + margin * 2.0
				))

	var structured: Array = [
		["VillageOfEights", 55.0, 55.0],
		["CommonGround", 35.0, 35.0],
		["TowerOfHakutnas", 32.0, 32.0],
		["RealmOfHudson", 45.0, 45.0],
		["RealisticCastle", 70.0, 70.0],
		["VillageDecorator", 50.0, 50.0],
		["BurningPeaks", 60.0, 60.0],
	]
	for entry in structured:
		var node_path: String = entry[0]
		var hx: float = entry[1]
		var hz: float = entry[2]
		var n := stage.get_node_or_null(node_path) as Node3D
		if n == null:
			continue
		var p: Vector3 = n.global_position
		_exclusion_zones.append(Rect2(p.x - hx, p.z - hz, hx * 2.0, hz * 2.0))
	print("RealisticGrassPlacer: %d exclusion zones registered" % _exclusion_zones.size())


func _is_excluded(x: float, z: float) -> bool:
	for zone in _exclusion_zones:
		if zone.has_point(Vector2(x, z)):
			return true
	return false


## Legacy: the low-poly sparse tuft sprinkle. Kept behind a flag for
## fallback testing; off by default because the new blade field covers it.
func _distribute_legacy_tufts() -> void:
	if not enable_legacy_tufts or not multimesh:
		return

	multimesh.instance_count = grass_count
	multimesh.visible_instance_count = grass_count

	var placed := 0
	var attempts := 0
	var max_attempts := grass_count * 3

	while placed < grass_count and attempts < max_attempts:
		attempts += 1
		var x := randf_range(-ground_half_x, ground_half_x)
		var z := randf_range(-ground_half_z, ground_half_z)
		if _is_excluded(x, z):
			continue
		var scale_val := randf_range(min_scale, max_scale)
		var rot := randf() * TAU
		var xform := Transform3D()
		xform = xform.scaled(Vector3(scale_val, scale_val, scale_val))
		xform = xform.rotated(Vector3.UP, rot)
		xform.origin = Vector3(x, grass_y, z)
		multimesh.set_instance_transform(placed, xform)
		placed += 1

	if placed < grass_count:
		multimesh.visible_instance_count = placed
	print("RealisticGrassPlacer: Placed %d legacy tufts" % placed)


## Build `blade_count` transforms across the open terrain and drop them
## onto the SimpleGrassTextured multimesh in one batch.
func _populate_blade_field() -> void:
	var sgt := get_node_or_null(SGT_NODE_PATH)
	if sgt == null:
		push_warning("RealisticGrassPlacer: SimpleGrassTextured node not found at %s" % SGT_NODE_PATH)
		return

	# Swap SGT's default bushy cross-quad for a thin tapered single blade
	# so each instance reads as one distinct grass blade — cornfield-style
	# sparse rather than clumpy-bush dense.
	if "mesh" in sgt:
		sgt.mesh = _build_blade_mesh()
	if "texture_albedo" in sgt:
		sgt.texture_albedo = _build_blade_texture()
	if "albedo" in sgt:
		# Bright enough to read under the dark NIGHT ambient while still
		# looking like a field green — pure mid-saturation.
		sgt.albedo = Color(0.55, 0.72, 0.32)
	if "alpha_scissor_threshold" in sgt:
		sgt.alpha_scissor_threshold = 0.0  # solid blade, no transparent pixels
	if "light_mode" in sgt:
		# Lambert lights the whole blade from one side rather than by
		# blade-inclination — reads much better under weak moonlight than
		# the "Normal grass" mode which only catches light at the tips.
		sgt.light_mode = 0
	if "scale_h" in sgt:
		sgt.scale_h = 1.0
	if "scale_w" in sgt:
		sgt.scale_w = 1.0
	if "scale_var" in sgt:
		sgt.scale_var = 0.0
	if "grass_strength" in sgt:
		sgt.grass_strength = 0.88  # very rigid — cornfield stalks don't sway
	if "interactive" in sgt:
		sgt.interactive = true
	# Blades part lightly around the player — a gentle sway, not a wide
	# clearing. interactive_level_y stays 0 so blades don't flatten.
	if "interactive_level_xz" in sgt:
		sgt.interactive_level_xz = 0.3
	if "interactive_level_y" in sgt:
		sgt.interactive_level_y = 0.0
	if "sgt_dist_min" in sgt:
		sgt.sgt_dist_min = 0.0

	# Reset whatever the editor painted in the scene so our procedural
	# distribution replaces it cleanly.
	if sgt.has_method("clear_all"):
		sgt.clear_all()

	var rng := RandomNumberGenerator.new()
	rng.seed = 9001

	# Grid spacing matches the rule: roots 30-50 cm apart. Use the density
	# to derive spacing (6 blades/m² ≈ 40 cm). Jitter each root slightly
	# within its cell so rows don't read as perfect lines.
	var spacing: float = 1.0 / sqrt(blade_density)  # ≈ 0.41m at density 6
	var jitter_amount: float = spacing * 0.25       # keep spacing within 30-50cm band
	var cells_x: int = int((field_half_x * 2.0) / spacing)
	var cells_z: int = int((field_half_z * 2.0) / spacing)
	var target_count: int = cells_x * cells_z

	var transforms: Array = []
	transforms.resize(target_count)
	var placed: int = 0
	var rejected: int = 0

	for ix in cells_x:
		for iz in cells_z:
			if placed >= target_count:
				break
			var cx: float = -field_half_x + (ix + 0.5) * spacing
			var cz: float = -field_half_z + (iz + 0.5) * spacing
			var bx: float = cx + rng.randf_range(-jitter_amount, jitter_amount)
			var bz: float = cz + rng.randf_range(-jitter_amount, jitter_amount)
			if _is_excluded(bx, bz):
				rejected += 1
				continue
			var sy: float = base_blade_size.y * rng.randf_range(1.0 - height_variance, 1.0 + height_variance)
			var y_rot: float = rng.randf() * TAU
			# Extra forward lean around a random horizontal axis (±15°)
			# on top of the baked mesh curve. Different direction per blade
			# → the field looks wind-tossed rather than like a fence.
			var tilt_angle: float = rng.randf_range(-0.26, 0.26)  # ±15°
			var tilt_theta: float = rng.randf() * TAU
			var tilt_axis: Vector3 = Vector3(cos(tilt_theta), 0, sin(tilt_theta))
			var basis := Basis().rotated(Vector3.UP, y_rot)
			basis = basis.rotated(tilt_axis, tilt_angle)
			basis = basis.scaled(Vector3(base_blade_size.x, sy, base_blade_size.z))
			transforms[placed] = Transform3D(basis, Vector3(bx, grass_root_y, bz))
			placed += 1

	transforms.resize(placed)
	if sgt is MultiMeshInstance3D:
		var sgt_node: MultiMeshInstance3D = sgt
		if blade_visibility_range > 0.0:
			sgt_node.visibility_range_end = blade_visibility_range
			sgt_node.visibility_range_end_margin = 15.0
		sgt_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Disabled: SGT's optimization_by_distance shrinks blades to zero with
	# distance — with our uniform field that reads as a mowed patch around
	# the player rather than tall grass. Leave perf tuning for later.
	if "optimization_by_distance" in sgt:
		sgt.optimization_by_distance = false

	# Write directly to the multimesh. The addon's add_grass_batch() queues
	# into an internal buffer and flushes in _process, which silently
	# drops 1M+ transforms, so we skip it.
	var mm: MultiMesh = MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = sgt.mesh if sgt.mesh else sgt.multimesh.mesh
	mm.instance_count = placed
	for i in placed:
		mm.set_instance_transform(i, transforms[i])
	mm.visible_instance_count = placed
	sgt.multimesh = mm
	# Clear any leftover buffer so the addon's _process doesn't try to
	# merge painted remnants back in on top of our distribution.
	if "_buffer_add" in sgt:
		sgt._buffer_add.clear()

	print("RealisticGrassPlacer: Uniform blade field %d blades (target %d, rejected %d by exclusion, area %.0fm × %.0fm @ %.1f blades/m²)"
		% [placed, target_count, rejected, field_half_x * 2.0, field_half_z * 2.0, blade_density])


## Build a thin, tapered blade with 3 vertical segments and a baked curve.
## The tip leans +X (local) by `BEND_AMOUNT`, mid-row leans half that —
## gives each blade a permanent natural arc. Combined with per-instance
## Y-rotation at placement time, the arcs point in random directions
## across the field instead of all bending the same way.
func _build_blade_mesh() -> ArrayMesh:
	const BASE_W: float = 0.09   # half-width at root (18cm total)
	const MID_W: float = 0.055   # half-width at mid
	const TIP_W: float = 0.02    # half-width at tip (~4cm)
	const HEIGHT: float = 1.0
	const BEND_AMOUNT: float = 0.12  # tip offset in +X (local) — natural arc

	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()

	# Plane A: in the XY plane (faces ±Z thanks to cull_disabled).
	_push_curved_strip(verts, uvs, normals, indices,
		BASE_W, MID_W, TIP_W, HEIGHT, BEND_AMOUNT,
		Vector3(0, 0, 1), 0)  # strip along X axis
	# Plane B: perpendicular (in the ZY plane, faces ±X).
	_push_curved_strip(verts, uvs, normals, indices,
		BASE_W, MID_W, TIP_W, HEIGHT, BEND_AMOUNT,
		Vector3(1, 0, 0), 1)  # strip along Z axis

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Append a 3-segment tapered strip forming one face of the blade cross.
## `axis`: 0 = strip lies along world X (plane A), 1 = along Z (plane B).
## The bend is always applied in +X local so after per-instance Y-rotation
## the field shows blades arcing in every direction.
func _push_curved_strip(verts: PackedVector3Array, uvs: PackedVector2Array,
		normals: PackedVector3Array, indices: PackedInt32Array,
		base_w: float, mid_w: float, tip_w: float, h: float, bend: float,
		n: Vector3, axis: int) -> void:
	# Six vertices: base L/R, mid L/R, tip L/R.
	var base_idx: int = verts.size()
	var mid_off: float = bend * 0.35  # quarter-bend at mid for smooth arc
	var tip_off: float = bend
	if axis == 0:
		# Strip in XY plane, widths along X, bend shifts X
		verts.append(Vector3(-base_w, 0, 0))
		verts.append(Vector3(base_w, 0, 0))
		verts.append(Vector3(-mid_w + mid_off, h * 0.5, 0))
		verts.append(Vector3(mid_w + mid_off, h * 0.5, 0))
		verts.append(Vector3(-tip_w + tip_off, h, 0))
		verts.append(Vector3(tip_w + tip_off, h, 0))
	else:
		# Strip in ZY plane, widths along Z, bend still shifts X so the
		# two planes curve in the same global direction (so the cross
		# reads as a single bent blade instead of a T).
		verts.append(Vector3(0, 0, -base_w))
		verts.append(Vector3(0, 0, base_w))
		verts.append(Vector3(mid_off, h * 0.5, -mid_w))
		verts.append(Vector3(mid_off, h * 0.5, mid_w))
		verts.append(Vector3(tip_off, h, -tip_w))
		verts.append(Vector3(tip_off, h, tip_w))
	# UVs — V along height (0 root → 1 tip), U across width.
	uvs.append(Vector2(0, 0)); uvs.append(Vector2(1, 0))
	uvs.append(Vector2(0, 0.5)); uvs.append(Vector2(1, 0.5))
	uvs.append(Vector2(0, 1)); uvs.append(Vector2(1, 1))
	for _i in 6:
		normals.append(n)
	# Two quads → four triangles.
	# Bottom quad: 0,1,3 and 0,3,2
	indices.append(base_idx + 0); indices.append(base_idx + 1); indices.append(base_idx + 3)
	indices.append(base_idx + 0); indices.append(base_idx + 3); indices.append(base_idx + 2)
	# Top quad: 2,3,5 and 2,5,4
	indices.append(base_idx + 2); indices.append(base_idx + 3); indices.append(base_idx + 5)
	indices.append(base_idx + 2); indices.append(base_idx + 5); indices.append(base_idx + 4)


## Tiny gradient texture with a mild darker root — subtle shading so
## blades don't look like flat cardboard. Kept bright overall so the
## material's `albedo` tint controls the final colour.
func _build_blade_texture() -> ImageTexture:
	var img := Image.create(4, 16, false, Image.FORMAT_RGBA8)
	for y in 16:
		# y=0 is TIP (full bright), y=15 is ROOT (slight tint)
		var t: float = float(y) / 15.0
		var brightness: float = lerpf(1.0, 0.8, t)  # only 20% darker at root
		var v: int = int(255 * brightness)
		for x in 4:
			img.set_pixel(x, y, Color8(v, v, v, 255))
	return ImageTexture.create_from_image(img)


## Tell the SimpleGrass singleton to run its interactive height-map pipe
## so blades bend away from the player.
func _enable_interactive_mode() -> void:
	var singleton := get_node_or_null("/root/SimpleGrass")
	if singleton == null:
		return
	if singleton.has_method("set_interactive"):
		singleton.set_interactive(true)
	elif "interactive" in singleton:
		singleton.interactive = true
