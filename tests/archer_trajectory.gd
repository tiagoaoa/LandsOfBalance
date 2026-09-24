extends Node3D

var player: CharacterBody3D
var arrow: Arrow
var failures := 0


class Target extends StaticBody3D:
	var damage := 0.0

	func take_damage_flat(amount: float) -> void:
		damage += amount


func _ready() -> void:
	var floor := CSGBox3D.new()
	floor.size = Vector3(10, 1, 10)
	floor.position.y = -0.5
	floor.use_collision = true
	add_child(floor)
	player = load("res://player/player.tscn").instantiate()
	player.enable_multiplayer = false
	add_child(player)
	await get_tree().process_frame
	player._switch_character_class(1)
	player.global_position = Vector3(0, 0.05, 0)
	await get_tree().create_timer(.2).timeout
	player.set_physics_process(false)
	player._camera.reparent(self, true)
	player._camera.global_position = Vector3(1.2, 2.1, 2)
	child_entered_tree.connect(_spawned)
	Input.action_press("aim")
	player._start_bow_draw(true, true)
	player._update_bow_draw(.5)
	player._restore_aim_pose()
	await get_tree().process_frame
	for pos in [Vector3(0, 1.6, -3), Vector3(0, 1.6, -25),
			Vector3(0, 1.6, -160), Vector3(8, 15, -30)]:
		await _target_check(pos)
	await _sky_check()
	await _strength_checks()
	await _network_checks()
	await _impact_checks()
	Input.action_release("aim")
	print("[ArcherTrajectory] failures=%d" % failures)
	player.queue_free()
	for voice in Sfx._pool:
		voice.stop()
		voice.stream = null
	await get_tree().create_timer(.1).timeout
	get_tree().quit(1 if failures else 0)


func _spawned(node: Node) -> void:
	if node is Arrow:
		arrow = node


func _check(ok: bool, label: String) -> void:
	print("[ArcherTrajectory] %s %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		failures += 1


func _target_check(pos: Vector3) -> void:
	var target := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	shape.shape = SphereShape3D.new()
	target.add_child(shape)
	add_child(target)
	target.position = pos
	player._camera.look_at(pos)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var aim: Dictionary = player.crosshair_target()
	_check(aim.collider == target, "crosshair resolves target at %s" % pos)
	player._shoot_arrow()
	var expected: Vector3 = (aim.point - arrow.global_position).normalized()
	var launched := arrow.linear_velocity.normalized()
	_check(launched.dot(expected) > .99999, "launch points at crosshair at %s" % pos)
	_check(is_equal_approx(arrow.linear_velocity.length(), 75.0),
			"aimed launch speed is 75 m/s")
	_check((-arrow.global_basis.z).dot(launched) > .99999,
			"arrow mesh faces launch direction immediately")
	var held := player.find_child("NockedArrow", true, false) as Node3D
	_check(arrow.global_position.distance_to(held.global_position) < .02,
			"projectile leaves the held arrow")
	arrow.queue_free()
	target.queue_free()
	await get_tree().process_frame


func _sky_check() -> void:
	player._camera.look_at(Vector3(0, 80, -80))
	var aim: Dictionary = player.crosshair_target()
	_check(not aim.hit, "sky ray is clear")
	player._shoot_arrow()
	var expected: Vector3 = (aim.point - arrow.global_position).normalized()
	_check(arrow.linear_velocity.normalized().dot(expected) > .99999,
			"sky shot converges on crosshair direction")
	var initial := arrow.linear_velocity.y
	await get_tree().create_timer(.1).timeout
	_check(arrow.linear_velocity.y < initial, "gravity still affects flight")
	arrow.queue_free()
	await get_tree().process_frame


func _strength_checks() -> void:
	player._camera.look_at(Vector3(0, 100, -100))
	await get_tree().create_timer(.25).timeout
	player._shoot_arrow()
	var aimed := arrow
	var start := aimed.global_position
	var initial := aimed.linear_velocity
	_check(is_equal_approx(aimed._compute_flat_arrow_damage(null), 52.5),
			"full-speed aimed impact deals 52.5 damage")
	player._bow_aimed = false
	player._shoot_arrow()
	var quick := arrow
	_check(is_equal_approx(quick.linear_velocity.length(), 50.0),
			"quick arrow retains 50 m/s launch speed")
	_check(is_equal_approx(quick._compute_flat_arrow_damage(null), 35.0),
			"full-speed quick impact retains 35 damage")
	await get_tree().create_timer(.6).timeout
	var aimed_range := Vector2(aimed.position.x - start.x, aimed.position.z - start.z).length()
	var quick_range := Vector2(quick.position.x - start.x, quick.position.z - start.z).length()
	_check(absf(aimed_range / quick_range - 1.5) < .03,
			"stronger arrow covers 50 percent more horizontal distance per second")
	_check(aimed.position.y > quick.position.y + 8,
			"vertical launch strength lifts the aimed arrow higher")
	_check(absf(aimed.linear_velocity.x - initial.x) < .01 \
			and absf(aimed.linear_velocity.z - initial.z) < .01,
			"gravity preserves horizontal velocity")
	_check(aimed._compute_flat_arrow_damage(null) < 52.5,
			"climbing trades vertical speed and impact damage for height")
	aimed.airborne_shot = true
	var expected := 35.0 * aimed._flight_velocity.length() / 50.0 * .5
	_check(is_equal_approx(aimed._compute_flat_arrow_damage(null), expected),
			"airborne penalty is applied once to impact damage")
	aimed.queue_free()
	quick.queue_free()
	await get_tree().process_frame


func _network_checks() -> void:
	var protocol := preload("res://multiplayer/protocol.gd")
	var network := get_node("/root/NetworkManager")
	network.arrow_spawned.connect(player._on_network_arrow_spawned)
	for power in [1.5, 1.0, .75, .5]:
		var data := protocol.ArrowData.new()
		data.arrow_id = 42
		data.shooter_id = 998
		data.set_position(Vector3(0, 20, 0))
		data.set_direction(Vector3(0, 1, -1).normalized() * power)
		var packet := protocol.build_arrow_spawn_msg(1, 998, data)
		network._handle_arrow_spawn(packet)
		_check(is_equal_approx(arrow.linear_velocity.length(), 50.0 * power),
				"network spawn retains %.2f launch strength" % power)
		_check(arrow.linear_velocity.normalized().dot(Vector3(0, 1, -1).normalized()) > .9999,
				"network spawn retains flight direction")
		arrow.queue_free()
		await get_tree().process_frame
	network.arrow_spawned.disconnect(player._on_network_arrow_spawned)


func _impact_checks() -> void:
	var target := Target.new()
	var shape := CollisionShape3D.new()
	shape.shape = BoxShape3D.new()
	shape.shape.size = Vector3(2, 4, .1)
	target.add_child(shape)
	add_child(target)
	target.position = Vector3(0, 20, -12)
	for power in [1.0, 1.5]:
		target.damage = 0.0
		var shot: Arrow = load("res://player/arrow.tscn").instantiate()
		shot.shot_power = power
		shot.shooter = player
		add_child(shot)
		shot.position = Vector3(0, 20, 0)
		shot.launch(Vector3.FORWARD)
		await get_tree().create_timer(.35).timeout
		_check(target.damage > 34.0 * power and target.damage < 36.0 * power,
				"%.1fx arrow hits a thin target with its incoming-speed damage" % power)
	target.queue_free()
	await get_tree().process_frame
