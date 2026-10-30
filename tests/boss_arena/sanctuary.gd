## Dressed masonry and distant ruins; arena collisions remain in BossArena.
extends Node3D

const KIT := preload("res://assets/environment/sanctuary/sanctuary.glb")
var _meshes := {}


func build(arena: Node3D) -> void:
	name = "Sanctuary"
	var source := KIT.instantiate()
	for mi in source.find_children("*", "MeshInstance3D", true, false):
		_meshes[String(mi.name)] = mi.mesh
	source.free()
	var stone: Material = arena._wet_stone(Color(0.67, 0.66, 0.62), false)
	stone.set_shader_parameter("normal_strength", 0.5)
	stone.set_shader_parameter("tile_m", 4.5)
	var floor_mat: Material = arena._wet_stone(Color(0.69, 0.68, 0.65), true)
	var r: float = arena.radius
	_piece("Dais", Vector3.ZERO, Vector3(r / 6.0, 1, r / 6.0), 0, floor_mat)
	# Piers continue the masonry below the platform into the fog.
	for k in 10:
		var a := TAU * k / 10.0
		_piece("Buttress", Vector3(sin(a) * r * 0.79, -13, cos(a) * r * 0.79),
				Vector3(0.65 * sqrt(r / 6.0), 1, 0.8), a, stone)
	for perch: Dictionary in arena.perches:
		var top: Vector3 = perch.top
		var width: float = float(perch.radius) + 0.25
		_piece("Collar", top + Vector3(0, 0.01, 0), Vector3(width, 1, width), 0, stone)
		_piece("Collar", Vector3(top.x, 0.5, top.z), Vector3(width, 0.7, width), 0, stone)
	# Keep the boss's central silhouette open; architecture frames its flanks.
	var backdrop := preload("res://tests/boss_arena/backdrop.gd").new()
	for k in 7:
		var a := deg_to_rad([-48.0, 47.0, -88.0, 92.0, -138.0, 141.0, 180.0][k])
		var d := r + 22.0 + (k % 3) * 7.0
		var at := Vector3(sin(a) * d, -4.0 - (k % 2) * 3.0, -cos(a) * d)
		var sc := 1.15 + (k % 3) * 0.27
		backdrop.add(self, "ruin", at, Vector3.ONE * sc, -a)
	_meshes.clear()


func _piece(kind: String, at: Vector3, size: Vector3, turn: float, mat: Material) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = _meshes["Sanctuary_" + kind]
	mi.material_override = mat
	mi.position = at
	mi.scale = size
	mi.rotation.y = turn
	add_child(mi)
