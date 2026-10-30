extends Node3D


func _ready() -> void:
	var world := WorldEnvironment.new()
	world.environment = Environment.new()
	world.environment.background_mode = Environment.BG_COLOR
	world.environment.background_color = Color(0.12, 0.15, 0.19)
	world.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	world.environment.ambient_light_color = Color(0.8, 0.85, 1)
	world.environment.ambient_light_energy = 0.65
	add_child(world)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-40, -30, 0)
	light.light_energy = 1.7
	add_child(light)
	var camera := Camera3D.new()
	add_child(camera)
	camera.position = Vector3(5, 3.0, 7)
	camera.look_at(Vector3(0, 1.8, 0))
	camera.fov = 42
	camera.current = true
	var boss: Bobba = load("res://enemies/bobba.tscn").instantiate()
	add_child(boss)
	boss.set_physics_process(false)
	boss.position = Vector3.ZERO
	boss._model.rotation = Vector3.ZERO
	var ap := boss._anim_player
	ap.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	for spec in [["AxeIdle", 0.4], ["AxeRun", 0.2], ["AxeAttack", 0.55], ["AxeAttack", 0.85]]:
		ap.play("bobba/" + spec[0], 0)
		ap.advance(0)
		ap.seek(spec[1], true)
		await get_tree().process_frame
		if DisplayServer.get_name() != "headless":
			await RenderingServer.frame_post_draw
			var dir := "res://docs/presentation/bobba-grip"
			DirAccess.make_dir_recursive_absolute(dir)
			get_viewport().get_texture().get_image().save_png("%s/%s-%.2f.png" % [dir, spec[0], spec[1]])
			if spec[0] == "AxeIdle":
				camera.position = boss._axe.global_position + Vector3(1, 0.35, 1.2)
				camera.look_at(boss._axe.global_position)
				await RenderingServer.frame_post_draw
				get_viewport().get_texture().get_image().save_png(dir + "/hand.png")
				camera.position = Vector3(5, 3, 7)
				camera.look_at(Vector3(0, 1.8, 0))
		var skeleton := boss._find_skeleton(boss._model)
		var hand := skeleton.find_bone("mixamorig_RightHand")
		var finger := skeleton.find_bone("mixamorig_RightHandIndex1")
		print("[Finger] %s" % skeleton.get_bone_pose_rotation(finger))
		print("[Axes] %s %s" % [spec[0], (skeleton.global_transform * skeleton.get_bone_global_pose(hand)).basis.orthonormalized()])
		print("[Grip] %s %.2f hand=%s head=%s up=%s" % [spec[0], spec[1],
				boss._right_hand_hitbox.global_position,
				boss._axe.global_transform * Vector3(0, 1.3, 0), boss._axe.global_basis.y.normalized()])
	var sk := boss._find_skeleton(boss._model)
	for i in sk.get_bone_count():
		if "RightHand" in sk.get_bone_name(i):
			print("[Bone] %s rest=%s" % [sk.get_bone_name(i), sk.get_bone_rest(i)])
	get_tree().quit()
