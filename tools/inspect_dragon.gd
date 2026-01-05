@tool
extends SceneTree

func _init() -> void:
	# Load the dragon model
	var dragon_scene: PackedScene = load("res://assets/dragon.glb") as PackedScene
	if dragon_scene == null:
		print("ERROR: Could not load dragon.glb")
		quit()
		return

	var dragon: Node3D = dragon_scene.instantiate()
	print("=== DRAGON MODEL STRUCTURE ===")
	_print_tree(dragon, 0)

	# Find skeleton
	var skeleton: Skeleton3D = _find_skeleton(dragon)
	if skeleton:
		print("\n=== SKELETON BONES ===")
		for i in skeleton.get_bone_count():
			var bone_name: String = skeleton.get_bone_name(i)
			var parent_idx: int = skeleton.get_bone_parent(i)
			var parent_name: String = skeleton.get_bone_name(parent_idx) if parent_idx >= 0 else "ROOT"
			print("  [%d] %s (parent: %s)" % [i, bone_name, parent_name])

		# Find wing bones specifically
		print("\n=== WING BONES ===")
		for i in skeleton.get_bone_count():
			var bone_name: String = skeleton.get_bone_name(i).to_lower()
			if "wing" in bone_name or "arm" in bone_name or "shoulder" in bone_name:
				print("  [%d] %s" % [i, skeleton.get_bone_name(i)])

	# Find AnimationPlayer and list animations
	var anim_player: AnimationPlayer = _find_animation_player(dragon)
	if anim_player:
		print("\n=== ANIMATIONS ===")
		for lib_name in anim_player.get_animation_library_list():
			var lib: AnimationLibrary = anim_player.get_animation_library(lib_name)
			for anim_name in lib.get_animation_list():
				var full_name: String = anim_name if lib_name == &"" else str(lib_name) + "/" + str(anim_name)
				var anim: Animation = lib.get_animation(anim_name)
				print("  %s (%.2fs, %d tracks)" % [full_name, anim.length, anim.get_track_count()])

				# Check for fly animation to understand wing bone names
				if "fly" in anim_name.to_lower() or "idle" in anim_name.to_lower():
					print("    Tracks in %s:" % anim_name)
					for t in range(mini(anim.get_track_count(), 20)):
						print("      - %s" % anim.track_get_path(t))

	dragon.queue_free()
	quit()


func _print_tree(node: Node, depth: int) -> void:
	var indent: String = "  ".repeat(depth)
	var type_info: String = node.get_class()
	if node is MeshInstance3D:
		type_info += " (mesh)"
	elif node is Skeleton3D:
		type_info += " (%d bones)" % (node as Skeleton3D).get_bone_count()
	elif node is AnimationPlayer:
		type_info += " (animations)"
	print("%s%s : %s" % [indent, node.name, type_info])

	for child in node.get_children():
		_print_tree(child, depth + 1)


func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node as Skeleton3D
	for child in node.get_children():
		var result: Skeleton3D = _find_skeleton(child)
		if result:
			return result
	return null


func _find_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node as AnimationPlayer
	for child in node.get_children():
		var result: AnimationPlayer = _find_animation_player(child)
		if result:
			return result
	return null
