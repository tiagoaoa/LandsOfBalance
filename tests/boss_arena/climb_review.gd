extends "res://tests/boss_arena/attack_review.gd"


func _ready() -> void:
	seed(741)
	arena = load("res://tests/boss_arena/boss_arena.tscn").instantiate()
	add_child(arena)
	boss = arena.boss
	var span := boss.fist_pos(0).distance_to(boss.fist_pos(1)) / boss.sz
	_check(span > 40.0, "starting arms are wide open (%.1f m)" % span)
	await get_tree().create_timer(1.0).timeout
	arena.set_process(false)
	arena.set_physics_process(false)
	boss.set_physics_process(false)
	for p in arena.party():
		p.process_mode = Node.PROCESS_MODE_DISABLED
		for cape in p.find_children("*", "SkeletonModifier3D", true, false):
			cape.active = false
			if cape.has_method("_reset"):
				cape._reset(cape._pose())
				cape._upload()
		p._spawn_immunity_timer = 100.0
	_reset_party()
	cam = Camera3D.new()
	cam.far = 600.0
	add_child(cam)
	cam.make_current()
	boss._start(boss.Act.IDLE, 100.0)
	await _step(3.0)
	span = boss.fist_pos(0).distance_to(boss.fist_pos(1)) / boss.sz
	_check(span > 40.0, "idle arms remain extended (%.1f m)" % span)
	await _shot("idle")
	for hand in 2:
		await _ascent(hand)
	await _shrug()
	print("[BossClimb] peak tick %.1f ms" % (climb_usec / 1000.0))
	print("[BossClimb] checks=%d failures=%d" % [checks, failures])
	get_tree().quit(1 if failures else 0)


func _reset_party() -> void:
	for p in arena.party():
		if boss.is_climbing(p):
			boss._release_climber(p, Vector3.ZERO)
		p.end_climb()
		p.ai_driven = true
		p.is_crouching = false
		p._is_stunned = false
		p.position = Vector3(-2 if p.is_paladin() else 2, 0, 5)
		p.velocity = Vector3.ZERO
	boss._dropped_until.clear()
	boss._ride_t = 0.0
	boss._ride_total = 0.0


func _enter(hand: int) -> void:
	_reset_party()
	boss._hand_i = hand
	boss._pinned_left = [0.0, 0.0]
	boss._start(boss.Act.IDLE, 100.0)
	await _step(3.0)
	boss._stagger(45.0, "climb-test")
	await _step(2.0)
	var edge := boss._climb_edge(hand, arena.center)
	_check(edge.is_finite(), "hand %d has a reachable grip" % hand)
	if not edge.is_finite():
		return
	boss._climb_surface.update()
	var out := boss._flat_dir(boss.global_position, edge)
	for i in arena.party().size():
		var p: Player = arena.party()[i]
		p.global_position = edge + out * 0.65 + out.cross(Vector3.UP) * (i - 0.5) * 1.2
		p.global_position.y = arena.floor_y
		for k in 20:
			if boss._climb_surface.capsule(p.global_position).depth <= 0.0 and _clear_stone(p):
				break
			p.global_position += out * 0.15
		print("[BossClimb] entry ", p.name, " pos=", p.global_position, " edge=", boss._climb_edge(hand, p.global_position), " fist=", boss.climbable_fist(p), " seat=", boss._climb_seat(hand, -0.75 if i == 0 else 0.75))
		_check(boss.try_climb(p), "%s attaches to hand %d" % [p.name, hand])
	boss._shake_due = 100.0


func _ascent(hand: int) -> void:
	await _enter(hand)
	if boss._climbing.size() != 2:
		return
	var a: Player = arena.party()[0]
	if hand == 0:
		a.ai_driven = false
		var start := a.global_position
		await _step(0.5)
		_check(a.global_position.distance_to(start) < 0.15, "neutral input holds the grip")
		Input.action_press("move_forward")
		await _step(0.7)
		Input.action_release("move_forward")
		_check(a.global_position.distance_to(start) > 0.3, "forward input moves along the surface")
		a.ai_driven = true
	var depth := -INF
	var gap := 0.0
	var gap_at := Vector3.ZERO
	var gap_progress := Vector2.ZERO
	var step := 0.0
	var separation := INF
	var stone := 0
	for frame in 1200:
		var before: Array = arena.party().map(func(p: Player) -> Vector3: return p.global_position)
		await _step(1.0 / 60.0)
		for i in arena.party().size():
			var p: Player = arena.party()[i]
			step = maxf(step, p.global_position.distance_to(before[i]))
			if not _clear_stone(p):
				stone += 1
			if frame % 10 == 0 and boss.is_climbing(p):
				var d: float = boss._climb_surface.capsule(p.global_position).depth
				depth = maxf(depth, d)
				if frame > 60 and p.global_position.y > arena.floor_y + 0.3:
					if -d > gap:
						gap_at = p.global_position
						var c: Dictionary = boss._climbing[p]
						gap_progress = Vector2(c.distance, c.get("length", 0.0))
					gap = maxf(gap, -d)
		separation = minf(separation, arena.party()[0].global_position.distance_to(arena.party()[1].global_position))
		if frame in [120, 360, 600]:
			await _shot("climb-%d-%d" % [hand, frame])
		if boss._climbing.is_empty():
			break
	for p in arena.party():
		_check(boss.on_pad(p) and not boss.is_climbing(p), "%s reaches shoulder %d" % [p.name, hand])
		print("[BossClimb] final ", p.name, " ", p.global_position, " distance=", boss._climbing.get(p, {}).get("distance", -1))
	_check(depth <= 0.04, "whole capsule stays outside the mesh (%.3f m)" % depth)
	_check(gap < 0.65, "climbers stay close to the visible surface (%.3f m gap)" % gap)
	print("[BossClimb] widest gap at ", gap_at, " progress=", gap_progress)
	_check(stone == 0, "climbing clears arena stone (%d overlaps)" % stone)
	_check(step < 0.4, "climbing moves continuously (%.3f m largest step)" % step)
	_check(separation > 0.6, "two climbers remain separated (%.3f m)" % separation)
	await _shot("mounted-%d" % hand)


func _shrug() -> void:
	await _enter(0)
	await _step(2.0)
	var a: Player = arena.party()[0]
	var b: Player = arena.party()[1]
	a.is_crouching = true
	boss._ride_t = 4.0
	boss._shake_due = 3.0
	await _step(1.0 / 60.0)
	_check(boss.act == boss.Act.SHAKE, "the boss reacts while players are still ascending")
	_check(boss.strike_eta_for(a).kind == "shake", "climbers receive the shrug warning")
	await _step(boss.SHAKE_WINDUP - 0.03)
	var before := b.global_position
	await _step(0.06)
	_check(not boss.is_climbing(b) and b.velocity.length() > 2.0, "an unbraced climber is thrown off")
	_check(before.distance_to(b.global_position) < 0.5, "the throw starts at the climber's position")
	_check(boss.is_climbing(a), "a crouching climber holds on")
	await _step(0.2)
	_check(absf(boss._roll) > 0.03, "the shrug visibly rolls the shoulders")
	_check(boss._climb_surface.capsule(a.global_position).depth <= 0.04,
			"a clinging player stays outside the moving shoulder")
	await _shot("shrug")
	if boss.is_climbing(a):
		a.ai_driven = false
		Input.action_press("jump")
		await _step(0.1)
		Input.action_release("jump")
		_check(not boss.is_climbing(a) and a.velocity.y > 0.0, "jump releases a grip with an outward leap")


func _step(seconds: float) -> void:
	for i in int(seconds * 60.0):
		var start := Time.get_ticks_usec()
		boss._physics_process(1.0 / 60.0)
		if not boss._climbing.is_empty():
			climb_usec = maxi(climb_usec, Time.get_ticks_usec() - start)
		for p in arena.party():
			if p._current_anim_player:
				p._current_anim_player.advance(1.0 / 60.0)
			if DisplayServer.get_name() != "headless":
				for cape in p.find_children("*", "SkeletonModifier3D", true, false):
					if cape.has_method("_reset"):
						cape._process_modification_with_delta(1.0 / 60.0)
		await get_tree().physics_frame


func _shot(label: String) -> void:
	for node in get_tree().root.find_children("*", "Light3D", true, false):
		node.visible = false
	for node in get_tree().root.find_children("*", "FogVolume", true, false):
		node.visible = false
	for node in get_tree().root.find_children("*", "GPUParticles3D", true, false):
		node.visible = false
	var env := get_world_3d().environment
	env.fog_enabled = false
	env.volumetric_fog_enabled = false
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.24, 0.26, 0.29)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.65, 0.67, 0.72)
	env.ambient_light_energy = 1.0
	env.ambient_light_sky_contribution = 0.0
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.adjustment_enabled = false
	var focus := boss.global_position + Vector3(0, 11, 8)
	var offset := Vector3(0, 6, 52)
	if label.begins_with("climb") or label.begins_with("mounted") or label == "shrug":
		focus = boss.pad_pos(boss._hand_i).lerp(boss.fist_pos(boss._hand_i), 0.45)
		offset = Vector3(10 if boss._hand_i == 1 else -10, 4, 15)
	cam.look_at_from_position(focus + offset, focus)
	cam.fov = 55.0
	var light := DirectionalLight3D.new()
	add_child(light)
	light.light_energy = 1.8
	light.rotation = cam.rotation
	light.shadow_enabled = false
	await super._shot(label)
	light.queue_free()
