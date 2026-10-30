extends Node3D

var arena: BossArena
var boss: ColossusBoss
var checks := 0
var failures := 0
var cam: Camera3D
var climb_usec := 0


func _ready() -> void:
	seed(741)
	get_window().content_scale_size = Vector2i(1382, 720)
	get_window().content_scale_mode = Window.CONTENT_SCALE_MODE_VIEWPORT
	get_window().content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP
	arena = load("res://tests/boss_arena/boss_arena.tscn").instantiate()
	add_child(arena)
	await get_tree().create_timer(1.0).timeout
	arena.set_process(false)
	arena.set_physics_process(false)
	boss = arena.boss
	boss.combat_event.connect(func(kind: String, data: Dictionary) -> void:
		if kind == "terrain_block":
			print("[BossAttack] terrain ", data))
	boss.set_physics_process(false)
	for p in arena.party():
		p.process_mode = Node.PROCESS_MODE_DISABLED
		p._spawn_immunity_timer = 100.0
		p.position = Vector3(-2 if p.is_paladin() else 2, 0, 5)
	cam = Camera3D.new()
	cam.far = 600.0
	cam.fov = 55.0
	add_child(cam)
	cam.look_at_from_position(Vector3(16, 13, 21), Vector3(0, 4, -6))
	cam.make_current()
	await _wide_pose()
	_far_player()
	await _punch()
	await _other_hand()
	await _centre_punch()
	await _tracking()
	_selection()
	print("[BossAttack] peak climb tick %.1f ms" % (climb_usec / 1000.0))
	print("[BossAttack] checks=%d failures=%d" % [checks, failures])
	for voice in Sfx._pool:
		voice.stop()
		voice.stream = null
	arena.queue_free()
	await get_tree().create_timer(0.2).timeout
	get_tree().quit(1 if failures else 0)


func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
	print("[BossAttack] %s %s" % ["PASS" if ok else "FAIL", message])


func _step(seconds: float) -> void:
	for i in int(seconds * 60.0):
		var climbing := not boss._climbing.is_empty()
		var start := Time.get_ticks_usec()
		boss._physics_process(1.0 / 60.0)
		if climbing:
			climb_usec = maxi(climb_usec, Time.get_ticks_usec() - start)
		await get_tree().physics_frame


func _shot(label: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	var layers: Array[CanvasLayer] = []
	for layer: CanvasLayer in get_tree().root.find_children("*", "CanvasLayer", true, false):
		if layer.visible:
			layers.append(layer)
			layer.visible = false
	await RenderingServer.frame_post_draw
	var path := OS.get_environment("LOB_PERF_SHOT").get_basename()
	get_viewport().get_texture().get_image().save_png(path + "-" + label + ".png")
	for layer in layers:
		layer.visible = true


## No acid: someone standing past every claw's reach makes the muzzled boss
## move round the rim toward them, never spit.
func _far_player() -> void:
	var p: Player = arena.party()[0]
	var away := boss._flat_dir(boss.global_position, arena.center)
	p.global_position = arena.center + away * arena.radius * 0.85
	var q: Player = arena.party()[1]
	q.global_position = p.global_position + Vector3(1.5, 0, 0)
	_check(not boss._in_slam_reach(p.global_position), "the far rim is out of every claw's reach")
	var shifts := 0
	var other := {}
	for i in 12:
		boss._grace = 0.0
		boss._shift_cd = 0.0
		boss._start(boss.Act.IDLE, 1.0)
		boss._choose_next()
		if boss.act == boss.Act.SHIFT:
			shifts += 1
			var c := arena.center
			var at := atan2(p.global_position.x - c.x, -(p.global_position.z - c.z))
			var before := absf(wrapf(at - boss._shift_from, -PI, PI))
			var after := absf(wrapf(at - boss._shift_to, -PI, PI))
			other[after < before] = true
		else:
			other[boss.act_name()] = true
		boss._anchor_angle = boss._shift_from if boss.act == boss.Act.SHIFT else boss._anchor_angle
		boss._start(boss.Act.IDLE, 1.0)
	_check(shifts >= 9 and not other.has(false), "it wades round the rim toward a player out of reach (%d/12)" % shifts)
	_check(not other.has("SPIT") and not ("SPIT" in ColossusBoss.Act.keys()), "no acid attack exists any more")
	q.position = Vector3(2, 0, 5)
	p.position = Vector3(-2, 0, 5)


func _punch() -> void:
	var p: Player = arena.party()[0]
	var toward := boss._flat_dir(arena.center, boss.global_position)
	p.global_position = arena.center + toward * arena.radius * 0.65
	p.velocity = Vector3.ZERO
	boss._start(boss.Act.IDLE, 100.0)
	boss._pinned_left = [0.0, 0.0]
	await _step(0.8)
	boss._begin_slam([p], [p])
	_check(not boss.punch_open(), "raising a fist does not expose its recovery weak point")
	await _step(boss.SLAM_WINDUP + boss.SLAM_STRIKE + 0.1)
	print("[BossAttack] punch target=", boss._target, " fist=", boss.fist_pos(boss._hand_i),
			" stopped=", boss._arm_stopped, " hand=", boss._hand_i)
	_check(boss.punch_open(), "downward impact opens a punish and climb window")
	var contact := boss.fist_pos(boss._hand_i)
	_check(boss.act_len - boss.act_t > 4.5, "punch commits to recovery before another attack")
	var hp := boss.hp
	boss.poise = 0.0
	boss.on_part_hit(boss._hand_body[boss._hand_i], 40, null, false, boss.fist_pos(boss._hand_i))
	_check(is_equal_approx(hp - boss.hp, 50.0), "blade deals 125 percent damage to the grounded punching hand")
	_check(is_equal_approx(boss._skull_mult(false), 3.2), "head is most vulnerable during punch recovery")
	await _shot("punch")
	await _climb_pair()
	var serial := boss.act_serial
	await _step(0.7)
	_check(boss.act_serial == serial and boss.punch_open(), "boss stays committed while both players mount")
	_check(contact.distance_to(boss.fist_pos(boss._hand_i)) < 1.0,
			"punching hand stays at its actual ground contact through recovery")
	await _shot("climbers")
	await _step(boss.PUNCH_OPEN + boss.SLAM_RECOVER)
	_check(not boss.punch_open(), "hand and head bonuses close when punch recovery ends")
	p.global_position = arena.center + toward * arena.radius * 0.65
	p.velocity = Vector3.ZERO
	boss._last_slammed.clear()
	boss._begin_slam([p], [p])
	boss.act_t = boss.SLAM_WINDUP + boss.SLAM_STRIKE
	boss._parried_this_slam = true
	boss._slam_impact(boss._hand_i)
	_check(is_equal_approx(boss._pinned_left[boss._hand_i], boss.PUNCH_PARRIED),
			"a parry extends the recovery and climb window to 5.2 seconds")


## The downward punch reaches the platform's centre from the rim: the body
## rears and lunges and the arm uncoils. Its arc from this anchor is clear
## of the towers, so the claw must land on the player standing there.
func _centre_punch() -> void:
	await _step(boss.SLAM_RECOVER + 0.5)
	for body in arena.party():
		body.global_position = arena.center + Vector3(2, 0, 5)
	boss._ride_t = 0.0
	var p: Player = arena.party()[0]
	p.global_position = Vector3(arena.center.x, arena.floor_y, arena.center.z)
	p.velocity = Vector3.ZERO
	p._health.reset_to_full()
	p._spawn_immunity_timer = 0.0
	boss._start(boss.Act.IDLE, 100.0)
	boss._pinned_left[0] = 0.0
	boss._pinned_left[1] = 0.0
	boss._last_slammed.clear()
	await _step(1.0)
	_check(boss._in_slam_reach(p.global_position), "the platform centre is within the downward punch's reach")
	var hp := p.current_health
	boss._begin_slam([p], [p])
	await _step(boss.SLAM_WINDUP + boss.SLAM_STRIKE + 0.1)
	var gap := boss._flat_dist(boss.fist_pos(boss._hand_i), boss._target)
	print("[BossAttack] centre punch far=%.2f stretch=%s lunge=%.2f gap=%.2f hp %.0f -> %.0f" % [
			boss._slam_far, boss.arm_stretch, boss._lunge, gap, hp, p.current_health])
	if arena.area_factor > 1.0:
		_check(p.current_health < hp and gap < 1.0, "a punch from the rim lands on a player at the centre")
	else:
		# The small field's perches crowd the centre; the claw may meet one.
		_check(gap < 2.5, "a punch from the rim gets to the centre of the small field")
	p._spawn_immunity_timer = 100.0
	p.global_position = Vector3(-2, 0, 5)
	await _step(boss.PUNCH_OPEN + boss.SLAM_RECOVER + 0.5)


func _climb_pair() -> void:
	var edge := boss._climb_edge(boss._hand_i, arena.center)
	_check(edge != Vector3.INF, "the grounded claw has a reachable climbing surface")
	if edge == Vector3.INF:
		return
	var away := boss._flat_dir(boss.global_position, edge)
	for i in arena.party().size():
		var p: Player = arena.party()[i]
		p.global_position = edge + away * 0.65 + away.cross(Vector3.UP) * (i - 0.5)
		p.global_position.y = arena.floor_y
		for step in 20:
			if boss._skin_free(p.global_position) and _clear_stone(p):
				break
			p.global_position += away * 0.15
		print("[BossAttack] climb ", p.name, " pos=", p.global_position, " edge=", edge,
				" pinned=", boss._pinned_left, " slammed=", boss._last_slammed.get(p, -99))
		_check(boss.try_climb(p), "%s can climb the exposed hand from its outside surface" % p.name)
	if boss._climbing.size() < 2:
		await _step(0.8)
		return
	var a: Player = arena.party()[0]
	var b: Player = arena.party()[1]
	_check(boss._climbing[a].seat != boss._climbing[b].seat,
			"two climbers reserve different shoulder positions")
	var depth := -INF
	var jump := 0.0
	var stone_hits := 0
	for frame in int((0.8) * 60.0):
		var before := [a.global_position, b.global_position]
		await _step(1.0 / 60.0)
		for i in 2:
			var p: Player = arena.party()[i]
			depth = maxf(depth, float(boss._climb_surface.capsule(p.global_position).depth))
			if not _clear_stone(p):
				stone_hits += 1
			jump = maxf(jump, p.global_position.distance_to(before[i]))
			if p.global_position.distance_to(before[i]) > 1.0:
				print("[BossAttack] climb step frame=", frame, " player=", i,
						" from=", before[i], " to=", p.global_position,
						" climbing=", boss.is_climbing(p), " pad=", boss.on_pad(p))
		if frame in [24, 60, 47]:
			await _shot("climb-%d-%d" % [boss._hand_i, frame])
	_check(stone_hits == 0, "climbers stay clear of the arena stone (%d overlaps)" % stone_hits)
	_check(depth <= 0.08, "feet, torso and head stay outside the hide throughout climbing (%.3f m)" % depth)
	_check(jump < 1.0, "climb follows the arm without snapping (largest step %.2f m)" % jump)
	_check(boss.is_climbing(a) and boss.is_climbing(b), "both players can start a surface climb during recovery")
	_check(a.global_position.distance_to(b.global_position) > 0.6, "climbing players do not overlap")
	for p in arena.party():
		boss._release_climber(p, Vector3.ZERO)
		p._is_stunned = false
		p.position = Vector3(-2 if p.is_paladin() else 2, 0, 5)


func _selection() -> void:
	var p: Player = arena.party()[0]
	p.global_position = arena.center + boss._flat_dir(arena.center, boss.global_position) * arena.radius * 0.65
	var slams := 0
	for i in 24:
		boss._grace = 0.0
		boss.hp = boss.MAX_HP
		boss._last_slammed.clear()
		boss._start(boss.Act.IDLE, 1.0)
		boss._choose_next()
		if boss.act == boss.Act.SLAM:
			slams += 1
	_check(slams >= 12, "downward punches dominate reachable attack choices (%d/24)" % slams)
	var heads := 0
	for i in 40:
		boss._grace = 0.0
		boss._head_cd = 0.0
		boss._last_slammed.clear()
		boss._last_acts.clear()
		boss._start(boss.Act.IDLE, 1.0)
		boss._choose_next()
		if boss.act == boss.Act.HEAD_SLAM:
			heads += 1
		boss._start(boss.Act.IDLE, 1.0)
	_check(heads >= 4, "the head slam is part of its close repertoire (%d/40)" % heads)


func _wide_pose() -> void:
	boss._start(boss.Act.IDLE, 100.0)
	await _step(3.0)
	var span := absf((boss.fist_pos(1) - boss.fist_pos(0)).dot(boss.global_basis.x.normalized())) / boss.sz
	_check(span > 40.0, "resting palms leave an open stance (%.2f m apart)" % span)
	await _shot("idle")
	boss._stagger(7.0, "test")
	await _step(2.0)
	span = absf((boss.fist_pos(1) - boss.fist_pos(0)).dot(boss.global_basis.x.normalized())) / boss.sz
	_check(span > 10.0, "staggered arms stay spread (%.2f m apart)" % span)
	for i in 2:
		var edge := boss._climb_edge(i, arena.center)
		print("[BossAttack] stagger hand=", i, " wrist=", boss._hand[i].global_position,
				" elbow=", boss._fa[i].global_position, " edge=", edge, " obstacle=", boss._terrain.last_hit)
		_check(edge.is_finite(), "staggered hand %d stays reachable from the floor" % i)
	await _shot("stagger")
	boss._start(boss.Act.IDLE, 100.0)
	boss._pinned_left = [0.0, 0.0]
	await _step(2.0)


func _other_hand() -> void:
	for p in arena.party():
		p.position = Vector3(-2 if p.is_paladin() else 2, 0, 5)
		p.velocity = Vector3.ZERO
	boss._last_slammed.clear()
	boss._climbing.clear()
	boss._pinned_left = [0.0, 0.0]
	boss._start(boss.Act.IDLE, 100.0)
	await _step(3.0)
	var p: Player = arena.party()[0]
	p.global_position = arena.center + boss._flat_dir(arena.center, boss.global_position) * arena.radius * 0.65
	boss._begin_slam([p], [p])
	boss._hand_i = 0
	await _step(boss.SLAM_WINDUP + boss.SLAM_STRIKE + 0.1)
	await _climb_pair()
	await _step(0.3)
	_check(boss.punch_open(), "the left hand keeps its recovery window after a climber lets go")


func _tracking() -> void:
	boss._pinned_left = [0.0, 0.0]
	boss._last_slammed.clear()
	boss._start(boss.Act.IDLE, 100.0)
	var p: Player = arena.party()[0]
	p.global_position = arena.center
	await _step(2.0)
	boss._begin_slam([p], [p])
	var start := boss._target
	p.global_position += boss.global_basis.x.normalized() * 3.0
	await _step(0.65)
	_check(boss._target.distance_to(start) > 2.0, "punch windup follows a player moving across the arena")
	await _step(0.25)
	var committed := boss._target
	p.global_position -= boss.global_basis.x.normalized() * 6.0
	await _step(0.5)
	_check(boss._target.distance_to(committed) < 0.01, "punch target locks before the strike so a late dodge works")


func _clear_stone(p: Player) -> bool:
	var shape := CapsuleShape3D.new()
	shape.radius = 0.28
	shape.height = 1.72
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = shape
	q.transform.origin = p.global_position + Vector3.UP * 0.9
	q.collision_mask = 1
	q.exclude = boss._terrain.query.exclude
	return get_world_3d().direct_space_state.intersect_shape(q, 1).is_empty()
