@tool
extends EditorScript

func _run():
	var scene = load("res://assets/bobba/Maw J Laygo.fbx")
	if scene:
		var inst = scene.instantiate()
		print("=== Bobba Model Structure ===")
		_print_tree(inst, 0)
		inst.queue_free()
	else:
		print("Failed to load model")

func _print_tree(node, depth):
	var indent = ""
	for i in range(depth):
		indent += "  "
	var type_info = node.get_class()
	if node is MeshInstance3D:
		var mi = node as MeshInstance3D
		if mi.mesh:
			type_info += " (surfaces: %d)" % mi.mesh.get_surface_count()
			for i in range(mi.mesh.get_surface_count()):
				var mat = mi.mesh.surface_get_material(i)
				if mat:
					print(indent + "  Surface %d: %s" % [i, mat.get_class()])
					if mat is StandardMaterial3D:
						var std = mat as StandardMaterial3D
						print(indent + "    albedo_texture: %s" % str(std.albedo_texture))
		else:
			type_info += " (no mesh)"
	print(indent + node.name + " [" + type_info + "]")
	for child in node.get_children():
		_print_tree(child, depth + 1)
