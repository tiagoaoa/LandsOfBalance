extends SceneTree
## Dump what an imported FBX actually contains: clips, length, bones touched.
##
## Run:  godot --path . --headless --script tools/inspect_fbx_anim.gd -- <res://path.fbx>
##
## Written because "does this Mixamo download match our skeleton?" is a
## question that is cheap to answer and expensive to guess at.


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var path: String = args[0] if args.size() > 0 else "res://assets/bobba/axe_attack_downward.fbx"
	var scene: PackedScene = load(path) as PackedScene
	if scene == null:
		print("FAILED to load ", path)
		quit(1)
		return

	var inst: Node = scene.instantiate()
	print("=== ", path, " ===")
	_tree(inst, 0)

	var ap: AnimationPlayer = _find(inst, "AnimationPlayer") as AnimationPlayer
	if ap == null:
		print("no AnimationPlayer")
		quit(1)
		return

	for lib_name in ap.get_animation_library_list():
		var lib: AnimationLibrary = ap.get_animation_library(lib_name)
		for name in lib.get_animation_list():
			var a: Animation = lib.get_animation(name)
			var bones := {}
			var keys := 0
			for t in range(a.get_track_count()):
				keys += a.track_get_key_count(t)
				var p := str(a.track_get_path(t))
				var c := p.rfind(":")
				if c != -1:
					bones[p.substr(c + 1)] = true
			print("\nclip '%s/%s'  length=%.3f s  tracks=%d  keys=%d  bones=%d"
					% [lib_name, name, a.length, a.get_track_count(), keys, bones.size()])
			var sorted := bones.keys()
			sorted.sort()
			print("  bones: ", ", ".join(sorted))

	inst.queue_free()
	quit(0)


func _find(node: Node, cls: String) -> Node:
	if node.get_class() == cls:
		return node
	for c in node.get_children():
		var r := _find(c, cls)
		if r:
			return r
	return null


func _tree(node: Node, depth: int) -> void:
	var extra := ""
	if node is Skeleton3D:
		extra = " (%d bones)" % (node as Skeleton3D).get_bone_count()
	print("  ".repeat(depth), node.name, " [", node.get_class(), "]", extra)
	for c in node.get_children():
		_tree(c, depth + 1)
