extends StaticBody3D

## Generates collision mesh from the HillsMesh child at runtime

func _ready() -> void:
	# Find the mesh instance child
	var mesh_instance: MeshInstance3D = $HillsMesh
	if mesh_instance and mesh_instance.mesh:
		# Create trimesh collision from the mesh
		mesh_instance.create_trimesh_collision()

		# The create_trimesh_collision() creates a new StaticBody3D sibling
		# We need to move the collision shape to this node instead
		await get_tree().process_frame

		# Find the auto-generated static body and steal its collision shape
		for child in mesh_instance.get_children():
			if child is StaticBody3D:
				for collision in child.get_children():
					if collision is CollisionShape3D:
						collision.reparent(self)
				child.queue_free()
				break

		# Remove the placeholder collision shape if it exists
		if has_node("HillsCollision"):
			$HillsCollision.queue_free()
