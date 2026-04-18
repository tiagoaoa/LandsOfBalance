extends SceneTree

## Convert an FBX (or any Godot-importable scene) to GLB. Used by
## tools/edit_asset.sh to work around Blender 5.0 rejecting FBX v6100.
##
## Invocation:
##   godot --headless --script tools/godot_fbx_to_glb.gd -- <source> <dest>

func _init():
	var args := OS.get_cmdline_user_args()
	if args.size() < 2:
		printerr("Usage: godot --headless --script %s -- <src.fbx> <dst.glb>" % [OS.get_cmdline_args()[-1]])
		quit(2)
		return

	var src: String = args[0]
	var dst: String = args[1]

	var packed := load(src) as PackedScene
	if packed == null:
		printerr("Failed to load ", src)
		quit(1)
		return

	var root := packed.instantiate()
	if root == null:
		printerr("Failed to instantiate ", src)
		quit(1)
		return

	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_scene(root, state)
	if err != OK:
		printerr("append_from_scene failed: ", err)
		quit(1)
		return

	err = doc.write_to_filesystem(state, dst)
	if err != OK:
		printerr("write_to_filesystem failed: ", err)
		quit(1)
		return

	print("[godot_fbx_to_glb] Wrote ", dst)
	quit(0)
