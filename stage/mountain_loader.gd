extends Node3D
## Loads the mountain OBJ model with trimesh collision for climbable terrain

const MOUNTAIN_PATH := "res://assets/mountain.obj"

@export var scale_factor: Vector3 = Vector3(5, 5, 5)

var _mountain_instance: MeshInstance3D


func _ready() -> void:
	_load_mountain()


func _load_mountain() -> void:
	# OBJ files import as ArrayMesh, not PackedScene
	var mesh: Mesh = load(MOUNTAIN_PATH)
	if not mesh:
		push_error("Failed to load mountain mesh: " + MOUNTAIN_PATH)
		return

	# Create a MeshInstance3D to display the mesh
	_mountain_instance = MeshInstance3D.new()
	_mountain_instance.name = "MountainModel"
	_mountain_instance.mesh = mesh
	_mountain_instance.scale = scale_factor
	add_child(_mountain_instance)

	# Generate collision that follows the mesh exactly for climbing
	_create_climbable_collision()

	print("Mountain loaded with climbable collision from: ", MOUNTAIN_PATH)


func _create_climbable_collision() -> void:
	if not _mountain_instance or not _mountain_instance.mesh:
		return

	# Use Godot's built-in method which properly handles transforms
	# This creates a StaticBody3D with trimesh collision as a child
	_mountain_instance.create_trimesh_collision()

	# Find the created static body and configure it for terrain
	for child in _mountain_instance.get_children():
		if child is StaticBody3D:
			child.name = "TerrainCollision"
			# Set collision layer to terrain (layer 1) so player can walk/climb on it
			child.collision_layer = 1
			child.collision_mask = 1
			# Ensure physics material allows smooth movement
			var physics_mat = PhysicsMaterial.new()
			physics_mat.friction = 0.8  # Good grip for climbing
			physics_mat.bounce = 0.0    # No bouncing
			child.physics_material_override = physics_mat
			print("  Terrain collision configured for climbing")
			break
