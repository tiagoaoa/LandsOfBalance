extends Node3D
## Decorates the game world with 3D assets from Kenney packs

const CASTLE_KIT_PATH := "res://assets/medieval_village/castle_kit/Models/GLB format/"
const NATURE_KIT_PATH := "res://assets/medieval_village/nature_kit/Models/GLTF format/"
const RETRO_MEDIEVAL_PATH := "res://assets/medieval_village/retro_medieval_kit/Models/GLB format/"
const GRAVEYARD_KIT_PATH := "res://assets/medieval_village/graveyard_kit/Models/GLB format/"

# Asset cache
var _loaded_assets: Dictionary = {}

func _ready() -> void:
	# Disabled - medieval_village assets were removed
	# call_deferred("_decorate_world")
	pass

func _decorate_world() -> void:
	_add_village_buildings()
	_add_castle_structures()
	_add_nature_elements()
	_add_village_decorations()
	_add_graveyard_elements()
	print("World decoration complete!")

func _load_asset(path: String) -> PackedScene:
	if _loaded_assets.has(path):
		return _loaded_assets[path]

	if ResourceLoader.exists(path):
		var scene := load(path) as PackedScene
		_loaded_assets[path] = scene
		return scene
	else:
		push_warning("Asset not found: " + path)
		return null

func _spawn_asset(asset_path: String, pos: Vector3, rot_y: float = 0.0, scale_factor: float = 1.0) -> Node3D:
	var scene := _load_asset(asset_path)
	if scene == null:
		return null

	var instance := scene.instantiate() as Node3D
	instance.position = pos
	instance.rotation.y = rot_y
	instance.scale = Vector3.ONE * scale_factor
	add_child(instance)
	return instance

## Village of Eights - Add fantasy houses and structures
func _add_village_buildings() -> void:
	var village_center := Vector3(0, 0, 0)

	# Fantasy houses around the village
	var house_positions: Array[Dictionary] = [
		{"pos": Vector3(-12, 0.2, -8), "rot": 0.3, "type": "house1"},
		{"pos": Vector3(-4, 0.2, -12), "rot": 0.5, "type": "house2"},
		{"pos": Vector3(8, 0.2, -6), "rot": -0.4, "type": "house1"},
		{"pos": Vector3(12, 0.2, 4), "rot": 0.8, "type": "house2"},
		{"pos": Vector3(-8, 0.2, 10), "rot": -0.2, "type": "house1"},
	]

	# Castle kit buildings
	for data: Dictionary in house_positions:
		# Add tower base as house
		_spawn_asset(CASTLE_KIT_PATH + "tower-square-base.glb", data.pos, data.rot, 2.0)
		_spawn_asset(CASTLE_KIT_PATH + "tower-square-mid.glb", data.pos + Vector3(0, 4, 0), data.rot, 2.0)
		_spawn_asset(CASTLE_KIT_PATH + "tower-square-roof.glb", data.pos + Vector3(0, 8, 0), data.rot, 2.0)
		# Add door
		_spawn_asset(CASTLE_KIT_PATH + "door.glb", data.pos + Vector3(0, 0, 2.5), data.rot, 2.0)

	# Central area props (using retro medieval kit)
	_spawn_asset(RETRO_MEDIEVAL_PATH + "barrels.glb", village_center + Vector3(6, 0.2, -2), 0.0, 2.5)

	# Barrels and crates around firepit
	_spawn_asset(RETRO_MEDIEVAL_PATH + "detail-crate.glb", village_center + Vector3(3, 0.2, 8), 0.0, 2.0)
	_spawn_asset(RETRO_MEDIEVAL_PATH + "detail-barrel.glb", village_center + Vector3(-3, 0.2, 8), PI, 2.0)

	# Market stands
	_spawn_asset(RETRO_MEDIEVAL_PATH + "detail-crate.glb", village_center + Vector3(-6, 0.2, 0), 0.2, 3.0)
	_spawn_asset(RETRO_MEDIEVAL_PATH + "detail-barrel.glb", village_center + Vector3(-7, 0.2, 1), 0.0, 3.0)
	_spawn_asset(RETRO_MEDIEVAL_PATH + "barrels.glb", village_center + Vector3(8, 0.2, 2), 0.5, 2.5)

	# Keeper's seat - Add stone structure
	_spawn_asset(CASTLE_KIT_PATH + "stairs-stone.glb", village_center + Vector3(0, 0.2, 4), 0.0, 2.0)

## Realm of Hudson - Castle structures
func _add_castle_structures() -> void:
	var castle_pos := Vector3(80, 0.3, -50)

	# Castle walls
	for i: int in range(4):
		var angle: float = i * PI / 2
		var wall_pos: Vector3 = castle_pos + Vector3(cos(angle) * 22, 0, sin(angle) * 22)
		_spawn_asset(CASTLE_KIT_PATH + "wall.glb", wall_pos, angle, 3.0)
		_spawn_asset(CASTLE_KIT_PATH + "wall.glb", wall_pos + Vector3(cos(angle + PI/2) * 6, 0, sin(angle + PI/2) * 6), angle, 3.0)
		_spawn_asset(CASTLE_KIT_PATH + "wall.glb", wall_pos - Vector3(cos(angle + PI/2) * 6, 0, sin(angle + PI/2) * 6), angle, 3.0)

	# Corner towers
	var tower_offsets: Array[Vector3] = [
		Vector3(-22, 0, -22), Vector3(22, 0, -22),
		Vector3(-22, 0, 22), Vector3(22, 0, 22)
	]
	for offset: Vector3 in tower_offsets:
		var tower_pos: Vector3 = castle_pos + offset
		_spawn_asset(CASTLE_KIT_PATH + "tower-hexagon-base.glb", tower_pos, 0.0, 2.5)
		_spawn_asset(CASTLE_KIT_PATH + "tower-hexagon-mid.glb", tower_pos + Vector3(0, 5, 0), 0.0, 2.5)
		_spawn_asset(CASTLE_KIT_PATH + "tower-hexagon-top.glb", tower_pos + Vector3(0, 10, 0), 0.0, 2.5)
		_spawn_asset(CASTLE_KIT_PATH + "tower-hexagon-roof.glb", tower_pos + Vector3(0, 14, 0), 0.0, 2.5)

	# Gate
	_spawn_asset(CASTLE_KIT_PATH + "gate.glb", castle_pos + Vector3(0, 0, 22), 0.0, 3.5)

	# Flags
	_spawn_asset(CASTLE_KIT_PATH + "flag-banner-long.glb", castle_pos + Vector3(5, 18, 22), 0.0, 3.0)
	_spawn_asset(CASTLE_KIT_PATH + "flag-banner-long.glb", castle_pos + Vector3(-5, 18, 22), 0.0, 3.0)

	# Bridge/drawbridge
	_spawn_asset(CASTLE_KIT_PATH + "bridge-straight.glb", castle_pos + Vector3(0, 0.2, 28), 0.0, 3.0)

	# Siege weapons for decoration (training grounds)
	_spawn_asset(CASTLE_KIT_PATH + "siege-catapult.glb", castle_pos + Vector3(-30, 0.3, 10), 0.5, 2.5)
	_spawn_asset(CASTLE_KIT_PATH + "siege-ballista.glb", castle_pos + Vector3(-35, 0.3, 5), 0.3, 2.5)

## Tower of Hakutnas - Training grounds
func _add_training_structures() -> void:
	var tower_pos := Vector3(-80, 0, -60)

	# Walls with narrow variants
	_spawn_asset(CASTLE_KIT_PATH + "wall-narrow.glb", tower_pos + Vector3(-15, 0.5, -10), 0.0, 3.0)
	_spawn_asset(CASTLE_KIT_PATH + "wall-narrow.glb", tower_pos + Vector3(-15, 0.5, 0), 0.0, 3.0)
	_spawn_asset(CASTLE_KIT_PATH + "wall-narrow.glb", tower_pos + Vector3(-15, 0.5, 10), 0.0, 3.0)

	# Training dummies (using rocks as stand-ins)
	_spawn_asset(CASTLE_KIT_PATH + "rocks-small.glb", tower_pos + Vector3(5, 0.5, 18), 0.0, 3.0)
	_spawn_asset(CASTLE_KIT_PATH + "rocks-small.glb", tower_pos + Vector3(-5, 0.5, 22), 0.4, 3.0)

## Nature - Trees, grass, rocks throughout the world
func _add_nature_elements() -> void:
	# Trees around the village edges
	var tree_types := [
		"tree_oak.glb", "tree_default.glb", "tree_detailed.glb",
		"tree_simple.glb", "tree_tall.glb"
	]
	var pine_types := [
		"tree_pineDefaultA.glb", "tree_pineDefaultB.glb",
		"tree_pineTallA.glb", "tree_pineTallB.glb"
	]

	# Trees near Village of Eights
	var village_tree_positions: Array[Vector3] = [
		Vector3(20, 0, 8), Vector3(22, 0, -5), Vector3(-18, 0, 12),
		Vector3(-20, 0, -10), Vector3(15, 0, 16), Vector3(-15, 0, -15),
		Vector3(25, 0, 0), Vector3(-25, 0, 5), Vector3(18, 0, -12),
	]
	for i: int in range(village_tree_positions.size()):
		var tree_type: String = tree_types[i % tree_types.size()]
		_spawn_asset(NATURE_KIT_PATH + tree_type, village_tree_positions[i], randf() * TAU, 2.5)

	# Pine forest near Silent Woods (supplement existing trees)
	var woods_pos := Vector3(120, 0, 0)
	for i: int in range(20):
		var angle: float = randf() * TAU
		var dist: float = randf_range(25, 45)
		var pos: Vector3 = woods_pos + Vector3(cos(angle) * dist, 0, sin(angle) * dist)
		var pine_type: String = pine_types[i % pine_types.size()]
		_spawn_asset(NATURE_KIT_PATH + pine_type, pos, randf() * TAU, 2.0 + randf() * 1.0)

	# Trees along roads
	var road_tree_positions: Array[Vector3] = [
		Vector3(-50, 0, -40), Vector3(-55, 0, -35), Vector3(-45, 0, -45),
		Vector3(30, 0, -35), Vector3(35, 0, -30), Vector3(50, 0, -40),
	]
	for pos: Vector3 in road_tree_positions:
		var tree_type: String = tree_types[randi() % tree_types.size()]
		_spawn_asset(NATURE_KIT_PATH + tree_type, pos, randf() * TAU, 2.2)

	# Grass patches throughout
	var grass_positions: Array[Vector3] = [
		Vector3(10, 0.1, 20), Vector3(-15, 0.1, 25), Vector3(30, 0.1, 10),
		Vector3(-30, 0.1, -10), Vector3(40, 0.1, 30), Vector3(-40, 0.1, 35),
		Vector3(5, 0.1, 40), Vector3(-10, 0.1, 45), Vector3(55, 0.1, -15),
	]
	for pos: Vector3 in grass_positions:
		_spawn_asset(NATURE_KIT_PATH + "grass_large.glb", pos, randf() * TAU, 3.0)
		# Add some flowers nearby
		if randf() > 0.5:
			var flower_types := ["flower_redA.glb", "flower_yellowA.glb", "flower_purpleA.glb"]
			_spawn_asset(NATURE_KIT_PATH + flower_types[randi() % 3], pos + Vector3(randf_range(-2, 2), 0, randf_range(-2, 2)), 0.0, 2.0)

	# Rocks scattered around
	var rock_positions: Array[Vector3] = [
		Vector3(45, 0, 25), Vector3(-50, 0, 20), Vector3(60, 0, -35),
		Vector3(-35, 0, -55), Vector3(25, 0, 50), Vector3(-25, 0, -40),
	]
	for pos: Vector3 in rock_positions:
		_spawn_asset(CASTLE_KIT_PATH + "rocks-large.glb", pos, randf() * TAU, 2.0)
		_spawn_asset(CASTLE_KIT_PATH + "rocks-small.glb", pos + Vector3(3, 0, 2), randf() * TAU, 2.0)

	# Trees near the hills
	var hills_pos := Vector3(-30, 0, 20)
	for i: int in range(8):
		var angle: float = randf() * TAU
		var dist: float = randf_range(20, 35)
		var pos: Vector3 = hills_pos + Vector3(cos(angle) * dist, 0, sin(angle) * dist)
		var tree_type: String = tree_types[i % tree_types.size()]
		_spawn_asset(NATURE_KIT_PATH + tree_type, pos, randf() * TAU, 2.0)

## Village props and decorations
func _add_village_decorations() -> void:
	var village_center := Vector3(0, 0, 0)

	# Retro medieval props
	# Crates near houses
	_spawn_asset(RETRO_MEDIEVAL_PATH + "detail-crate-small.glb", village_center + Vector3(-10, 0.2, -5), 0.3, 2.5)
	_spawn_asset(RETRO_MEDIEVAL_PATH + "detail-crate-ropes.glb", village_center + Vector3(10, 0.2, 6), 0.5, 2.5)

	# Columns at keeper's seat
	_spawn_asset(RETRO_MEDIEVAL_PATH + "column.glb", village_center + Vector3(-3, 0.2, -3), 0.0, 2.0)
	_spawn_asset(RETRO_MEDIEVAL_PATH + "column.glb", village_center + Vector3(3, 0.2, -3), 0.0, 2.0)

	# Fences around some areas
	for i: int in range(5):
		_spawn_asset(RETRO_MEDIEVAL_PATH + "fence.glb", village_center + Vector3(-18 + i * 3, 0.2, -18), 0.0, 2.5)

	# Ladders and pulleys
	_spawn_asset(RETRO_MEDIEVAL_PATH + "ladder.glb", village_center + Vector3(-11, 0.2, -6), 0.0, 2.0)

	# Castle kit props
	_spawn_asset(CASTLE_KIT_PATH + "flag.glb", village_center + Vector3(0, 10, 0), 0.0, 3.0)

## Graveyard elements near the Silent Woods
func _add_graveyard_elements() -> void:
	var graveyard_pos := Vector3(100, 0, 30)  # Near Silent Woods

	# Tombstones
	var tombstone_positions: Array[Vector3] = [
		Vector3(0, 0, 0), Vector3(3, 0, 0), Vector3(6, 0, 0),
		Vector3(0, 0, 4), Vector3(3, 0, 4), Vector3(6, 0, 4),
		Vector3(0, 0, 8), Vector3(3, 0, 8), Vector3(6, 0, 8),
	]
	var tombstone_types: Array[String] = [
		"gravestone-cross.glb", "gravestone-decorative.glb", "gravestone-roof.glb",
		"gravestone-round.glb", "gravestone-wide.glb"
	]
	for i: int in range(tombstone_positions.size()):
		var pos: Vector3 = graveyard_pos + tombstone_positions[i]
		var tomb_type: String = tombstone_types[i % tombstone_types.size()]
		_spawn_asset(GRAVEYARD_KIT_PATH + tomb_type, pos, randf_range(-0.2, 0.2), 2.0)

	# Fence around graveyard
	for i: int in range(4):
		_spawn_asset(GRAVEYARD_KIT_PATH + "iron-fence-bar.glb", graveyard_pos + Vector3(-3 + i * 4, 0, -2), 0.0, 2.0)
		_spawn_asset(GRAVEYARD_KIT_PATH + "iron-fence-bar.glb", graveyard_pos + Vector3(-3 + i * 4, 0, 12), 0.0, 2.0)

	# Stone border columns on sides
	_spawn_asset(GRAVEYARD_KIT_PATH + "iron-fence-border-column.glb", graveyard_pos + Vector3(-4, 0, 5), PI/2, 2.0)
	_spawn_asset(GRAVEYARD_KIT_PATH + "iron-fence-border-column.glb", graveyard_pos + Vector3(12, 0, 5), PI/2, 2.0)

	# Dead tree trunks
	_spawn_asset(GRAVEYARD_KIT_PATH + "trunk-long.glb", graveyard_pos + Vector3(-6, 0, 0), 0.0, 2.5)
	_spawn_asset(GRAVEYARD_KIT_PATH + "trunk.glb", graveyard_pos + Vector3(14, 0, 8), 0.3, 2.5)

	# Altar
	_spawn_asset(GRAVEYARD_KIT_PATH + "altar-stone.glb", graveyard_pos + Vector3(3, 0, 10), 0.0, 2.5)
