extends Node3D

var arena: BossArena
var boss: ColossusBoss
var solids: Array[Node3D] = []
var worst := {}
var frames := 0
var failures := 0
var blocks := 0
var pose_usec := 0
var pose_frames := 0
var hz := 60


func _ready() -> void:
	seed(301)
	if OS.get_environment("LOB_TERRAIN_HZ") != "":
		hz = int(OS.get_environment("LOB_TERRAIN_HZ"))
	Engine.physics_ticks_per_second = hz
	arena = load("res://tests/boss_arena/boss_arena.tscn").instantiate()
	add_child(arena)
	await get_tree().create_timer(1.0).timeout
	arena.set_process(false)
	arena.set_physics_process(false)
	boss = arena.boss
	boss.died.disconnect(arena._on_boss_died)
	boss.combat_event.connect(func(kind: String, _data: Dictionary) -> void:
		if kind == "terrain_block":
			blocks += 1)
	boss.set_physics_process(false)
	for p in arena.party():
		p.process_mode = Node.PROCESS_MODE_DISABLED
	for cs in arena.find_children("*", "CollisionShape3D", true, false):
		# Braziers are not stone: a claw raking through the bowl is how a
		# fire gets knocked out (the terrain guard ignores them too).
		if cs.get_parent() is StaticBody3D and not boss.is_ancestor_of(cs) \
				and not cs.get_parent() is ArenaBrazier:
			solids.append(cs)
	for angle in [0.0, 62.0, -62.0, 140.0]:
		boss._anchor_angle = deg_to_rad(angle)
		boss._place_on_anchor(true)
		boss._sink = 0.0
		boss._sink_goal = 0.0
		boss._start(boss.Act.IDLE, 30.0)
		await _run("idle", 1.0)
		# Near the boss's side of the centre, then the centre itself: the far
		# punch rears, lunges, leans and uncoils the arm, all of it against
		# the same stone.
		for to_centre in [3.0, 0.0]:
			for hand in 2:
				boss._hand_i = hand
				boss._target = arena.center + boss.global_basis.z.normalized() * -to_centre
				boss._target.y = boss.FIST_HALF_THICK * boss.sz
				boss._punch_hold = boss.SLAM_WINDUP + boss.SLAM_STRIKE + boss.PUNCH_OPEN
				boss._start(boss.Act.SLAM, boss._punch_hold + boss.SLAM_RECOVER)
				boss.plan_slam_reach(boss._target)
				await _run("slam" if to_centre > 0.0 else "slam_centre", boss._punch_hold + boss.SLAM_RECOVER)
		for high in [false, true]:
			boss._begin_sweep()
			boss._sweep_high = high
			await _run("sweep", 4.3)
		var player: Player = arena.party()[0]
		player.is_dead = false
		player._health.reset_to_full()
		player.global_position = arena.center + boss._flat_dir(arena.center, boss.global_position) * arena.radius * 0.85
		boss._begin_grab([player])
		await _run("grab", 3.5)
		if boss._victim != null:
			boss._release_victim(true)
		boss._head_cd = 0.0
		player.global_position = arena.center + boss._flat_dir(arena.center, boss.global_position) * arena.radius * 0.6
		boss._begin_head_slam([player])
		await _run("head_slam", boss.act_len)
		boss._stagger(2.0, "test")
		await _run("stagger", 3.5)
		boss._begin_shift()
		await _run("shift", 6.0)
	boss._relocate_from = boss._anchor_angle
	boss._anchor_goal = boss._anchor_angle + 1.9
	boss._start(boss.Act.RELOCATE, 7.0)
	await _run("relocate", 8.0)
	boss._die()
	await _run("death", 8.0)
	print("[BossTerrain] frames=%d failures=%d blocked=%d pose_ms=%.2f" % [
			frames, failures, blocks, float(pose_usec) / maxi(1, pose_frames) / 1000.0])
	for voice in Sfx._pool:
		voice.stop()
		voice.stream = null
	arena.queue_free()
	await get_tree().create_timer(0.2).timeout
	get_tree().quit(1 if failures else 0)


func _run(label: String, seconds: float) -> void:
	worst.clear()
	for k in int(seconds * hz):
		var begin := Time.get_ticks_usec()
		boss._physics_process(1.0 / hz)
		pose_usec += Time.get_ticks_usec() - begin
		pose_frames += 1
		if k % 6 == 0:
			_sample()
		#Physics broadphase and CSG updates still need a frame to settle.
		if k % 3 == 0:
			await get_tree().physics_frame
	var depth := 0.0
	for key in worst:
		depth = maxf(depth, worst[key])
	if depth > 0.12:
		failures += 1
	print("[BossTerrain] %s angle=%.0f depth=%.3f back=%.2f %s" % [
			label, rad_to_deg(boss._anchor_angle), depth, boss._terrain_back, str(worst)])
	if boss._terrain_back > boss.reach():
		failures += 1
		print("[BossTerrain] FAIL boss retreated beyond arm reach")


func _sample() -> void:
	frames += 1
	boss._skin.update()
	for n in solids:
		var inv := n.global_transform.affine_inverse()
		for i in boss._skin.pos.size():
			var p: Vector3 = inv * boss._skin.pos[i]
			var d := _depth(n, p)
			if d <= 0.025:
				continue
			var key := "%s/%s" % [n.name, boss._skin.bone_names[boss._skin.dominant[i]]]
			worst[key] = maxf(worst.get(key, 0.0), d)


func _depth(n: Node3D, p: Vector3) -> float:
	if n is CollisionShape3D and n.shape is BoxShape3D:
		var edge: Vector3 = n.shape.size * 0.5 - p.abs()
		return minf(edge.x, minf(edge.y, edge.z))
	if n is CSGBox3D:
		var edge: Vector3 = n.size * 0.5 - p.abs()
		return minf(edge.x, minf(edge.y, edge.z))
	var r: float = n.radius if n is CSGCylinder3D else n.shape.radius
	var h: float = n.height if n is CSGCylinder3D else n.shape.height
	return minf(r - Vector2(p.x, p.z).length(), h * 0.5 - absf(p.y))
