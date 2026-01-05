class_name AssetLoader
extends Node3D
## Generic 3D asset loader with automatic collision generation
## Use this for buildings, rocks, terrain pieces, etc.

enum CollisionType {
	TRIMESH,    ## Accurate collision matching mesh geometry (best for buildings, terrain)
	CONVEX,     ## Simplified collision hull (faster, good for props)
	NONE        ## No collision (decorative objects)
}

@export_file("*.glb", "*.gltf", "*.fbx") var asset_path: String = ""
@export var collision_type: CollisionType = CollisionType.TRIMESH
@export var scale_factor: Vector3 = Vector3.ONE
@export var rotation_offset: Vector3 = Vector3.ZERO  ## Degrees
@export var min_mesh_size: float = 0.1  ## Skip meshes smaller than this

var _asset_instance: Node3D


func _ready() -> void:
	if asset_path != "":
		load_asset()


func load_asset() -> void:
	if asset_path == "":
		push_error("AssetLoader: No asset_path specified")
		return

	var scene: PackedScene = load(asset_path)
	if not scene:
		push_error("AssetLoader: Failed to load: " + asset_path)
		return

	_asset_instance = scene.instantiate()
	_asset_instance.name = "Model"
	_asset_instance.scale = scale_factor
	_asset_instance.rotation_degrees = rotation_offset
	add_child(_asset_instance)

	if collision_type != CollisionType.NONE:
		_add_collision_recursive(_asset_instance)

	print("AssetLoader: Loaded ", asset_path, " with ", CollisionType.keys()[collision_type], " collision")


func _add_collision_recursive(node: Node) -> void:
	for child in node.get_children():
		if child is MeshInstance3D:
			_create_collision_for_mesh(child as MeshInstance3D)
		_add_collision_recursive(child)


func _create_collision_for_mesh(mesh_instance: MeshInstance3D) -> void:
	var mesh: Mesh = mesh_instance.mesh
	if not mesh:
		return

	# Skip very small meshes
	var aabb := mesh.get_aabb()
	var size := aabb.size * scale_factor
	if size.x < min_mesh_size and size.y < min_mesh_size and size.z < min_mesh_size:
		return

	var static_body := StaticBody3D.new()
	static_body.name = mesh_instance.name + "_Collision"

	var collision_shape := CollisionShape3D.new()
	collision_shape.name = "CollisionShape"

	var shape: Shape3D
	match collision_type:
		CollisionType.TRIMESH:
			shape = mesh.create_trimesh_shape()
		CollisionType.CONVEX:
			shape = mesh.create_convex_shape()

	if shape:
		collision_shape.shape = shape
		static_body.add_child(collision_shape)
		static_body.transform = mesh_instance.transform
		mesh_instance.get_parent().add_child(static_body)


## Call this to reload the asset at runtime
func reload() -> void:
	if _asset_instance:
		_asset_instance.queue_free()
	load_asset()
