extends Node3D
## Builds a realistic medieval castle using Quaternius modular pieces
##
## REQUIRED ASSETS (place in res://assets/quaternius_village/):
## Download from: https://quaternius.com/packs/ultimatemodularmedievalpack.html
##
## Walls:
##   - Wall_UnevenBrick_Straight.gltf
##   - Wall_UnevenBrick_Door_Round.gltf
##   - Wall_UnevenBrick_Window_Wide_Round.gltf
##   - Wall_UnevenBrick_Window_Thin_Round.gltf
##   - Wall_Arch.gltf
##
## Floors:
##   - Floor_WoodDark.gltf
##
## Roofs:
##   - Roof_RoundTiles_6x6.gltf
##   - Roof_Tower_RoundTiles.gltf
##   - Roof_RoundTiles_6x4.gltf
##
## Props:
##   - Door_2_Round.gltf
##   - WindowShutters_Wide_Round_Closed.gltf
##   - Stairs_Exterior_Straight.gltf
##   - Prop_Crate.gltf
##   - Prop_Wagon.gltf
##   - Prop_WoodenFence_Single.gltf
##   - Prop_Vine1.gltf
##   - Prop_Vine2.gltf
##
## If assets are missing, castle building is silently skipped.

const QUAT_PATH := "res://assets/quaternius_village/"

var _loaded: Dictionary = {}

var _assets_available: bool = false

func _ready() -> void:
	# Check if any Quaternius village assets exist
	_assets_available = DirAccess.dir_exists_absolute(QUAT_PATH.replace("res://", "")) and _has_any_gltf()
	if _assets_available:
		call_deferred("_build_castle")

func _has_any_gltf() -> bool:
	var dir := DirAccess.open(QUAT_PATH)
	if dir:
		dir.list_dir_begin()
		var file_name := dir.get_next()
		while file_name != "":
			if file_name.ends_with(".gltf"):
				return true
			file_name = dir.get_next()
	return false

func _load(model_name: String) -> PackedScene:
	if not _assets_available:
		return null
	var path := QUAT_PATH + model_name + ".gltf"
	if _loaded.has(path):
		return _loaded[path]
	if ResourceLoader.exists(path):
		var scene := load(path) as PackedScene
		_loaded[path] = scene
		return scene
	return null

func _place(model_name: String, pos: Vector3, rot_y: float = 0.0, scl: float = 1.0) -> Node3D:
	var scene := _load(model_name)
	if scene == null:
		return null
	var inst := scene.instantiate() as Node3D
	inst.position = pos
	inst.rotation.y = rot_y
	inst.scale = Vector3.ONE * scl
	add_child(inst)
	return inst

func _build_castle() -> void:
	# Castle position - at Realm of Hudson
	var base := Vector3(80, 0.5, -50)
	var scale := 2.5  # Scale up the modular pieces
	var wall_height := 2.0 * scale  # Height per floor
	var wall_width := 2.0 * scale   # Width of wall segments

	print("Building realistic castle at ", base)

	# Build the main keep (central tower)
	_build_keep(base, scale)

	# Build corner towers
	_build_corner_towers(base, scale)

	# Build connecting walls
	_build_walls(base, scale)

	# Build gatehouse
	_build_gatehouse(base + Vector3(0, 0, 25), scale)

	# Add props and details
	_add_castle_props(base, scale)

	print("Realistic castle complete!")

func _build_keep(base: Vector3, scl: float) -> void:
	# Main keep - 3 floors of stone walls
	var floors := 3
	var size := 3  # 3x3 walls

	for floor_idx in range(floors):
		var y := floor_idx * 2.0 * scl

		# Build 4 walls for each floor
		for side in range(4):
			var angle := side * PI / 2
			var dir := Vector3(cos(angle), 0, sin(angle))
			var perp := Vector3(cos(angle + PI/2), 0, sin(angle + PI/2))

			for seg in range(size):
				var offset := (seg - size/2.0 + 0.5) * 2.0 * scl
				var pos := base + dir * (size * scl) + perp * offset + Vector3(0, y, 0)

				# Choose wall type based on position
				var wall_type := "Wall_UnevenBrick_Straight"
				if floor_idx == 0 and seg == size / 2:
					if side == 0:  # Front door
						wall_type = "Wall_UnevenBrick_Door_Round"
				elif floor_idx > 0:
					if seg == size / 2:
						wall_type = "Wall_UnevenBrick_Window_Wide_Round"

				_place(wall_type, pos, angle, scl)

		# Add floor
		if floor_idx > 0:
			for x in range(size):
				for z in range(size):
					var fx := (x - size/2.0 + 0.5) * 2.0 * scl
					var fz := (z - size/2.0 + 0.5) * 2.0 * scl
					_place("Floor_WoodDark", base + Vector3(fx, y, fz), 0, scl)

	# Roof
	var roof_y := floors * 2.0 * scl
	_place("Roof_RoundTiles_6x6", base + Vector3(0, roof_y, 0), 0, scl)

func _build_corner_towers(base: Vector3, scl: float) -> void:
	# 4 corner towers
	var tower_offsets: Array[Vector3] = [
		Vector3(-12, 0, -12), Vector3(12, 0, -12),
		Vector3(-12, 0, 12), Vector3(12, 0, 12)
	]

	for offset: Vector3 in tower_offsets:
		var tower_base := base + offset * scl

		# Build cylindrical tower using walls arranged in octagon
		for floor_idx in range(4):
			var y := floor_idx * 2.0 * scl

			# 8-sided tower approximation using 4 walls
			for side in range(4):
				var angle := side * PI / 2
				var wall_type := "Wall_UnevenBrick_Straight"
				if floor_idx > 1:
					wall_type = "Wall_UnevenBrick_Window_Thin_Round"

				var dir := Vector3(cos(angle), 0, sin(angle)) * 1.5 * scl
				_place(wall_type, tower_base + dir + Vector3(0, y, 0), angle, scl * 0.8)

		# Tower roof
		_place("Roof_Tower_RoundTiles", tower_base + Vector3(0, 4 * 2.0 * scl, 0), 0, scl)

func _build_walls(base: Vector3, scl: float) -> void:
	# Connect corner towers with walls
	var wall_configs: Array[Dictionary] = [
		{"start": Vector3(-12, 0, -12), "end": Vector3(12, 0, -12), "angle": 0.0},
		{"start": Vector3(12, 0, -12), "end": Vector3(12, 0, 12), "angle": PI/2},
		{"start": Vector3(12, 0, 12), "end": Vector3(-12, 0, 12), "angle": PI},
		{"start": Vector3(-12, 0, 12), "end": Vector3(-12, 0, -12), "angle": -PI/2},
	]

	for config: Dictionary in wall_configs:
		var start: Vector3 = config.start * scl
		var end: Vector3 = config.end * scl
		var angle: float = config.angle
		var dir := (end - start).normalized()
		var length := (end - start).length()
		var segments := int(length / (2.0 * scl))

		for i in range(segments):
			if i == 0 or i == segments - 1:
				continue  # Skip corners (towers are there)

			var t := float(i) / segments
			var pos := base + start + dir * length * t

			# Build 2-story curtain wall
			for floor_idx in range(2):
				var y := floor_idx * 2.0 * scl
				var wall_type := "Wall_UnevenBrick_Straight"
				if floor_idx == 1 and i == segments / 2:
					wall_type = "Wall_UnevenBrick_Window_Thin_Round"
				_place(wall_type, pos + Vector3(0, y, 0), angle, scl)

func _build_gatehouse(base: Vector3, scl: float) -> void:
	# Gatehouse with arch
	_place("Wall_Arch", base, 0, scl * 1.5)

	# Side walls
	_place("Wall_UnevenBrick_Straight", base + Vector3(-3 * scl, 0, 0), 0, scl)
	_place("Wall_UnevenBrick_Straight", base + Vector3(3 * scl, 0, 0), 0, scl)

	# Upper floor
	_place("Wall_UnevenBrick_Window_Wide_Round", base + Vector3(0, 2.0 * scl, 0), 0, scl)
	_place("Wall_UnevenBrick_Straight", base + Vector3(-3 * scl, 2.0 * scl, 0), 0, scl)
	_place("Wall_UnevenBrick_Straight", base + Vector3(3 * scl, 2.0 * scl, 0), 0, scl)

	# Roof
	_place("Roof_RoundTiles_6x4", base + Vector3(0, 4.0 * scl, 0), 0, scl)

func _add_castle_props(base: Vector3, scl: float) -> void:
	# Add doors
	_place("Door_2_Round", base + Vector3(0, 0, 7.5 * scl), 0, scl)

	# Add windows with shutters to keep
	_place("WindowShutters_Wide_Round_Closed", base + Vector3(0, 4 * scl, 7.5 * scl), 0, scl)

	# Stairs to entrance
	_place("Stairs_Exterior_Straight", base + Vector3(0, 0, 8.5 * scl), PI, scl)

	# Props around courtyard - using available assets
	_place("Prop_Crate", base + Vector3(-5 * scl, 0, 5 * scl), 0.3, scl)
	_place("Prop_Crate", base + Vector3(5 * scl, 0, 5 * scl), 0.2, scl)
	_place("Prop_Wagon", base + Vector3(8 * scl, 0, 0), 0.5, scl)

	# Wooden fences
	_place("Prop_WoodenFence_Single", base + Vector3(-8 * scl, 0, 3 * scl), 0, scl)
	_place("Prop_WoodenFence_Single", base + Vector3(-8 * scl, 0, 6 * scl), 0, scl)

	# Vines on walls for realism
	_place("Prop_Vine1", base + Vector3(7 * scl, 1 * scl, 0), PI/2, scl)
	_place("Prop_Vine2", base + Vector3(-7 * scl, 1.5 * scl, 0), -PI/2, scl)
