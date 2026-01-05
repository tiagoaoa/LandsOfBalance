extends Node3D

## Loads only Object_28 from the medieval fortress GLB with proper texture

const FORTRESS_PATH = "res://assets/medieval_fortress_kit.glb"
const OBJECT_28_TEXTURE = "res://assets/medieval_fortress_kit_36.png"

var _mesh_instance: MeshInstance3D


func _ready() -> void:
	_load_object28()


func _load_object28() -> void:
	var scene = load(FORTRESS_PATH) as PackedScene
	if not scene:
		push_error("Failed to load: " + FORTRESS_PATH)
		return

	var instance = scene.instantiate()

	# Find Object_28
	var object28 = _find_node_by_name(instance, "Object_28")
	if not object28:
		push_error("Object_28 not found in fortress")
		instance.queue_free()
		return

	# Find the mesh inside Object_28
	var mesh_node = _find_mesh_in_node(object28)
	if not mesh_node:
		push_error("No mesh found in Object_28")
		instance.queue_free()
		return

	# Clone the mesh
	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.name = "Object28_Mesh"
	_mesh_instance.mesh = mesh_node.mesh

	# Fix material - ensure texture is loaded and opaque
	_fix_material()

	# Create collision
	_mesh_instance.create_trimesh_collision()

	add_child(_mesh_instance)

	# Clean up the full scene
	instance.queue_free()

	print("Object_28 loaded with texture: ", OBJECT_28_TEXTURE)


func _find_node_by_name(node: Node, target_name: String) -> Node:
	if target_name in node.name:
		return node
	for child in node.get_children():
		var found = _find_node_by_name(child, target_name)
		if found:
			return found
	return null


func _find_mesh_in_node(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D:
		return node as MeshInstance3D
	for child in node.get_children():
		var found = _find_mesh_in_node(child)
		if found:
			return found
	return null


func _fix_material() -> void:
	if not _mesh_instance or not _mesh_instance.mesh:
		return

	# Load texture
	var texture = load(OBJECT_28_TEXTURE) as Texture2D

	for i in range(_mesh_instance.mesh.get_surface_count()):
		var mat = _mesh_instance.mesh.surface_get_material(i)
		if mat is StandardMaterial3D:
			var new_mat = mat.duplicate() as StandardMaterial3D
			# Force opaque
			new_mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
			new_mat.cull_mode = BaseMaterial3D.CULL_BACK
			# Ensure texture is set
			if texture and not new_mat.albedo_texture:
				new_mat.albedo_texture = texture
			_mesh_instance.set_surface_override_material(i, new_mat)
