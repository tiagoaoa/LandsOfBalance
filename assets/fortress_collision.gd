@tool
extends Node3D

## Generates trimesh collision for all meshes in the fortress
## Also fixes transparent materials

func _ready() -> void:
	# Wait one frame for the model to be fully loaded
	await get_tree().process_frame

	# Fix materials (runs in editor and game)
	_fix_materials_recursive(self)

	# Only generate collision at runtime (not in editor)
	if not Engine.is_editor_hint():
		_add_collision_recursive(self)
		print("Fortress collision generated")


func _add_collision_recursive(node: Node) -> void:
	if node is MeshInstance3D:
		var mesh_instance = node as MeshInstance3D
		if mesh_instance.mesh:
			# Use built-in method to create trimesh collision
			mesh_instance.create_trimesh_collision()

	for child in node.get_children():
		_add_collision_recursive(child)


func _fix_materials_recursive(node: Node) -> void:
	if node is MeshInstance3D:
		var mesh_instance = node as MeshInstance3D
		if mesh_instance.mesh:
			for i in range(mesh_instance.mesh.get_surface_count()):
				var mat = mesh_instance.mesh.surface_get_material(i)
				if mat is StandardMaterial3D:
					var std_mat = mat as StandardMaterial3D
					# Force opaque rendering
					std_mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
					std_mat.cull_mode = BaseMaterial3D.CULL_BACK
		# Also check material_override
		if mesh_instance.material_override and mesh_instance.material_override is StandardMaterial3D:
			var mat = mesh_instance.material_override as StandardMaterial3D
			mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED

	for child in node.get_children():
		_fix_materials_recursive(child)
