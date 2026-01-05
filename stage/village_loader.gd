extends Node3D
## Loads the Village of Eights GLB model with proper collision detection
## Creates StaticBody3D with trimesh collision for all building meshes

const VILLAGE_PATH := "res://assets/village_of_eights.fbx"

var _village_instance: Node3D


func _ready() -> void:
	_load_village()


func _load_village() -> void:
	# Load the FBX as a PackedScene
	var village_scene: PackedScene = load(VILLAGE_PATH)
	if not village_scene:
		push_error("Failed to load village: " + VILLAGE_PATH)
		return

	# Instance the village
	_village_instance = village_scene.instantiate()
	_village_instance.name = "VillageModel"
	add_child(_village_instance)

	# Generate collision for all meshes
	_add_collision_to_meshes(_village_instance)

	print("Village of Eights loaded with collision from: ", VILLAGE_PATH)


func _add_collision_to_meshes(node: Node) -> void:
	# Recursively find all MeshInstance3D nodes and add collision
	for child in node.get_children():
		if child is MeshInstance3D:
			_create_static_body_for_mesh(child as MeshInstance3D)
		# Recurse into children
		_add_collision_to_meshes(child)


func _create_static_body_for_mesh(mesh_instance: MeshInstance3D) -> void:
	var mesh: Mesh = mesh_instance.mesh
	if not mesh:
		return

	# Skip very small meshes (likely decorative details)
	var aabb := mesh.get_aabb()
	var size := aabb.size
	if size.x < 0.1 and size.y < 0.1 and size.z < 0.1:
		return

	# Create a StaticBody3D for collision
	var static_body := StaticBody3D.new()
	static_body.name = mesh_instance.name + "_Collision"

	# Create trimesh collision shape from the mesh
	var collision_shape := CollisionShape3D.new()
	collision_shape.name = "CollisionShape"

	# Use create_trimesh_shape for accurate collision with building geometry
	var shape := mesh.create_trimesh_shape()
	if shape:
		collision_shape.shape = shape
		static_body.add_child(collision_shape)

		# Add static body as sibling to mesh (not child, to avoid transform issues)
		# Copy the mesh's transform to the static body
		static_body.transform = mesh_instance.transform
		mesh_instance.get_parent().add_child(static_body)
