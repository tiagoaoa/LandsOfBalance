extends Node3D

var player: CharacterBody3D
var shots := 0
var failures := 0
var last_power := 0.0
var last_hand := Vector3.ZERO
var max_hand_step := 0.0
var track_recovery := false
var foot := Vector3.ZERO


func _ready() -> void:
	var floor := CSGBox3D.new()
	floor.size = Vector3(40, 1, 40)
	floor.position.y = -0.5
	floor.use_collision = true
	add_child(floor)
	player = load("res://player/player.tscn").instantiate()
	player.enable_multiplayer = false
	add_child(player)
	await get_tree().process_frame
	player._switch_character_class(1)
	player.global_position = Vector3(0, 0.05, 0)
	CloudInput.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	child_entered_tree.connect(_arrow_spawned)
	player._bow_draw_visual.aim.modification_processed.connect(_pose_sample)
	await _wait(.15)
	await _trigger_checks()
	await _quick_shot_checks()
	await _mouse_checks()
	print("[ArcherAim] failures=%d" % failures)
	player.queue_free()
	for voice in Sfx._pool:
		voice.stop()
		voice.stream = null
	await get_tree().create_timer(0.1).timeout
	get_tree().quit(1 if failures else 0)


func _arrow_spawned(node: Node) -> void:
	if node is Arrow:
		shots += 1
		last_power = node.shot_power
		node.queue_free()


func _pose_sample() -> void:
	var draw: Node3D = player._bow_draw_visual
	var hand: Vector3 = draw._hand_point(draw.right)
	if track_recovery:
		max_hand_step = maxf(max_hand_step, hand.distance_to(last_hand))
	last_hand = hand
	var bone: int = draw.skeleton.find_bone("mixamorig_LeftFoot")
	foot = draw.skeleton.get_bone_global_pose(bone).origin


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout
	await get_tree().process_frame


func _check(ok: bool, label: String) -> void:
	print("[ArcherAim] %s %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		failures += 1


func _trigger(value: float) -> void:
	var event := InputEventJoypadMotion.new()
	event.axis = JOY_AXIS_TRIGGER_LEFT
	event.axis_value = value
	Input.parse_input_event(event)


func _trigger_checks() -> void:
	_trigger(0.8)
	await _wait(.05)
	_check(player.is_drawing_bow and player._bow_hold_release, "LT starts held draw")
	_trigger(1.0)
	await _wait(.6)
	_check(player.is_holding_bow and shots == 0, "full draw waits for release")
	_check(player._camera.fov < 45 and player._spring_arm.spring_length < 1.8,
			"held LT zooms camera")
	_check(not player._archer_anim_player.is_playing(), "drawn pose remains held")
	var arrow := player.find_child("NockedArrow", true, false) as Node3D
	_check(arrow != null and arrow.is_visible_in_tree(), "arrow is visible in drawing hand")
	_trigger(0.9)
	await _wait(.05)
	_check(player.is_holding_bow and shots == 0, "trigger motion keeps draw held")
	await _pose_checks()
	if "--capture-aim" in OS.get_cmdline_user_args():
		await _capture()
	track_recovery = true
	_trigger(0.0)
	await _wait(.05)
	_check(shots == 1 and not player.is_holding_bow, "LT release fires one arrow")
	_check(is_equal_approx(last_power, 1.5), "aimed shot gets 50 percent more strength")
	_check(not arrow.is_visible_in_tree(), "nocked arrow disappears on release")
	_check(player._archer_anim_player.current_animation == "archer/Loose",
			"release plays the continuous arm recovery")
	await _snapshot("release")
	_trigger(0.1)
	_trigger(0.0)
	await _wait(.25)
	_check(player._camera.fov < 45 and player._crosshair.visible,
			"release holds zoom and sight while the arrow flies")
	await _wait(.45)
	_check(player._camera.fov > 44.2 and player._camera.fov < 51,
			"camera eases outward during recovery")
	await _snapshot("recovery")
	await _wait(.8)
	track_recovery = false
	_check(max_hand_step < .12, "release has no discontinuous hand jump")
	_check(player._archer_anim_player.current_animation == "archer/Idle",
			"arms return to idle after recovery")
	await _snapshot("idle")
	_check(shots == 1, "release noise cannot fire twice")
	_check(player._camera.fov > 54, "release restores camera")
	_trigger(1.0)
	await _wait(.03)
	_check(player.is_drawing_bow, "next LT press starts a new draw")
	_trigger(0.0)
	await _wait(.4)
	_check(shots == 1 and not player.is_drawing_bow, "early release cancels draw")


func _quick_shot_checks() -> void:
	var event := InputEventJoypadButton.new()
	event.button_index = JOY_BUTTON_RIGHT_SHOULDER
	event.pressed = true
	Input.parse_input_event(event)
	await _wait(.05)
	event = event.duplicate()
	event.pressed = false
	Input.parse_input_event(event)
	await _wait(.8)
	_check(shots == 2, "RB still fires a quick shot")
	_check(is_equal_approx(last_power, 1.0), "quick shot retains normal strength")


func _mouse_checks() -> void:
	await _wait(.8)
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_RIGHT
	event.pressed = true
	Input.parse_input_event(event)
	await _wait(.6)
	_check(player.is_holding_bow and shots == 2, "right mouse still holds draw")
	event = event.duplicate()
	event.pressed = false
	Input.parse_input_event(event)
	await _wait(.05)
	_check(shots == 3, "right mouse release still fires")
	_check(is_equal_approx(last_power, 1.5), "mouse aimed shot gets the same strength")


func _pose_checks() -> void:
	var held: Node3D = player._bow_draw_visual.arrow
	var planted := foot
	for pitch in [0.0, .5, -.5]:
		player._camera_pivot.rotation.x = pitch
		await _wait(.25)
		var sight: Vector3 = player._bow_aim_direction(held.global_position)
		_check((-held.global_basis.z).dot(sight) > .998,
				"torso and hands follow sight at pitch %.2f" % pitch)
		_check(foot.distance_to(planted) < .005,
				"aim correction keeps the feet planted")
	player._camera_pivot.rotation.x = 0.0
	await _wait(.25)


func _capture() -> void:
	var world := WorldEnvironment.new()
	world.environment = Environment.new()
	world.environment.background_mode = Environment.BG_COLOR
	world.environment.background_color = Color(0.12, 0.15, 0.20)
	world.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	world.environment.ambient_light_color = Color(0.7, 0.75, 0.85)
	world.environment.ambient_light_energy = 0.7
	add_child(world)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-40, -30, 0)
	add_child(sun)
	var camera := Camera3D.new()
	add_child(camera)
	camera.position = Vector3(2.7, 1.8, -2.2)
	camera.look_at(Vector3(0, 1.2, 0))
	camera.fov = 40
	camera.current = true
	var poses := {"draw": 0.0, "aim-up": .5, "aim-down": -.5}
	for pose in poses:
		player._camera_pivot.rotation.x = poses[pose]
		await _wait(.25)
		await _snapshot(pose)
	player._camera_pivot.rotation.x = 0.0
	await _wait(.25)


func _snapshot(pose: String) -> void:
	if "--capture-aim" not in OS.get_cmdline_user_args():
		return
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("/tmp/lob-archer-%s.png" % pose)
