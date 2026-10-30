## Exercise the real rig across attack boundaries at the game's physics rate.
extends Node3D

var arena: BossArena
var boss: ColossusBoss
var failures := 0
var checks := 0


func _ready() -> void:
	seed(301)
	arena = load("res://tests/boss_arena/boss_arena.tscn").instantiate()
	add_child(arena)
	await get_tree().create_timer(1.0).timeout
	boss = arena.boss
	arena.set_physics_process(false)
	arena.set_process(false)
	for p in arena.party():
		p.disable_mode = CollisionObject3D.DISABLE_MODE_KEEP_ACTIVE
		p.process_mode = Node.PROCESS_MODE_DISABLED
		p.position = Vector3(-1.5 if p.is_paladin() else 1.5, 0, 0)
	_check(boss.model_kind == "reptilian" and boss.reptile != null, "stage loads the supplied reptilian model")
	_check(boss.reptile.skel.get_bone_count() == 21, "supplied mesh has the combat skeleton")
	_lower_body_cut()
	_check(arena.find_children("CliffBackdrop*", "MeshInstance3D", true, false).size() == 11,
			"distant cliffs use eleven baked cards")
	_check(boss.has_node("BossFog"), "localized fog follows the boss")
	_check(arena.get_node("Sanctuary").find_children("RuinBackdrop*", "MeshInstance3D", true, false).size() == 7,
			"exterior ruins use seven baked cards")
	var ray := PhysicsRayQueryParameters3D.create(Vector3(0, 3, 0), Vector3(0, -2, 0), 1)
	var ground := get_world_3d().direct_space_state.intersect_ray(ray)
	_check(not ground.is_empty() and absf(ground.position.y) < 0.05, "hidden CSG floor retains its collision")
	await _body_collision()
	_damage_zones()
	await _hitbox_fit()
	_wrist_orientation()
	await _mouth_target()
	await _head_slam()
	await _braziers()
	for chained in [false, true]:
		for hand in 2:
			await _slam(hand, chained)
	for high in [false, true]:
		await _sweep(high)
	for side in [-1.0, 1.0]:
		await _grab(side)
	for side in [-1.0, 1.0]:
		await _grab(side, PI * 0.5)
	boss._anchor_angle = 0.0
	boss._place_on_anchor(true)
	await _melee_contact()
	await _recovery_contact()
	await _descending_contact()
	_check(boss._head != null and boss._jaw != null and boss._tail != null, "head, jaw and tail keep their combat pivots")
	print("[BossAnimation] checks=%d failures=%d" % [checks, failures])
	for voice in Sfx._pool:
		voice.stop()
		voice.stream = null
	arena.queue_free()
	await get_tree().create_timer(0.2).timeout
	get_tree().quit(1 if failures else 0)


## The golden rule from inside: a solid hitbox must not stick out of the
## hide you see, or a player is shoved by (and can cut) thin air. Samples a
## grid on every box face against the skin's winding number, in the poses
## where the skull and claws come lowest.
func _hitbox_fit() -> void:
	var skin: SkinProbe = boss._skin
	if skin == null:
		return
	var acts := [[boss.Act.IDLE, 0.5], [boss.Act.SWEEP, boss.SWEEP_WINDUP + 0.3],
			[boss.Act.SLAM, boss.SLAM_WINDUP + boss.SLAM_STRIKE], [boss.Act.STAGGER, 1.0]]
	var worst := {}
	for a in acts:
		boss._start(a[0], 30.0)
		boss.set_physics_process(true)
		while boss.act_t < float(a[1]):
			await get_tree().physics_frame
		boss.set_physics_process(false)
		skin.update()
		_joint_deformation()
		for part: ColossusPart in [boss._head_body, boss._hand_body[0], boss._hand_body[1]]:
			var cs := part.get_child(0) as CollisionShape3D
			# Every face of the shape (box or hull), sampled at its centroid and
			# halfway to each corner.
			var faces := cs.shape.get_debug_mesh().get_faces()
			var out := 0
			var n := 0
			var leaks := {}
			for t in range(0, faces.size(), 3):
				var cen := (faces[t] + faces[t + 1] + faces[t + 2]) / 3.0
				for q in [cen, cen.lerp(faces[t], 0.5), cen.lerp(faces[t + 1], 0.5), cen.lerp(faces[t + 2], 0.5)]:
					n += 1
					var r := skin.contact(cs.global_transform * q)
					if float(r.depth) < -0.6:
						out += 1
						leaks[r.bone] = int(leaks.get(r.bone, 0)) + 1
			var k := "%s" % part.name
			var frac := float(out) / n
			print("[BossAnimation] fit %s %s: %.0f%% of box surface outside the hide %s"
					% [ColossusBoss.Act.keys()[a[0]], k, frac * 100.0, str(leaks)])
			worst[k] = maxf(float(worst.get(k, 0.0)), frac)
	boss._start(boss.Act.IDLE, 30.0)
	for k in worst:
		# A claw's hull spans its finger gaps (~11% of its surface): that much is
		# the claw's own silhouette. Hand-sized boxes measured 46-86% out.
		_check(float(worst[k]) <= 0.15, "%s hugs the visible hide (worst %.0f%% of its surface >0.6 m out)"
				% [k, float(worst[k]) * 100.0])


func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
	print("[BossAnimation] %s %s" % ["PASS" if ok else "FAIL", message])


func _lower_body_cut() -> void:
	var skin := boss._skin
	var arr := skin.mi.mesh.surface_get_arrays(0)
	var points: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var bones: PackedInt32Array = arr[Mesh.ARRAY_BONES]
	var weights: PackedFloat32Array = arr[Mesh.ARRAY_WEIGHTS]
	var stride := bones.size() / points.size()
	var low := 0
	for i in points.size():
		if points[i].y >= -3.01:
			continue
		var arm := 0.0
		for k in stride:
			var name: String = skin.bone_names[bones[i * stride + k]]
			if name.begins_with("hand") or name.begins_with("forearm") or name.begins_with("upperarm"):
				arm += weights[i * stride + k]
		if arm <= 0.5:
			low += 1
	_check(low == 0, "submerged lower body is cut without clipping hanging fingertips")


func _joint_deformation() -> void:
	if ReptilianRig.body_name() not in ["titan", "trellis"]:
		return
	var skin := boss._skin
	var arr := skin.mi.mesh.surface_get_arrays(0)
	var points: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var bones: PackedInt32Array = arr[Mesh.ARRAY_BONES]
	var weights: PackedFloat32Array = arr[Mesh.ARRAY_WEIGHTS]
	var indices: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
	var matrices: Array[Transform3D] = []
	for i in skin.skin.get_bind_count():
		matrices.append(skin.skel.get_bone_global_pose(skin.bind_bone[i]) * skin.skin.get_bind_pose(i))
	var posed := PackedVector3Array()
	posed.resize(points.size())
	var stride := bones.size() / points.size()
	for i in points.size():
		var p := Vector3.ZERO
		for k in stride:
			p += (matrices[bones[i * stride + k]] * points[i]) * weights[i * stride + k]
		posed[i] = p
	#Allow the broad shoulder folds to stretch, but not a short edge to
	#turn into a metre-long spike. The old neck/arm cuts exceeded 10 m.
	var excess := 0.0
	for t in range(0, indices.size(), 3):
		for k in 3:
			var a := indices[t + k]
			var b := indices[t + (k + 1) % 3]
			excess = maxf(excess, posed[a].distance_to(posed[b]) - 4.0 * points[a].distance_to(points[b]))
	_check(excess < 1.0, "%s skin stays joined across neck, shoulders, elbows and wrists (excess %.2f m)"
			% [boss.act_name(), excess])


func _body_collision() -> void:
	boss.set_physics_process(false)
	await get_tree().physics_frame
	var parts := [boss._torso.get_node("Hit_ARMOR"), boss._head_body,
			boss._ua[0].get_node("Hit_ARMOR"), boss._fa[1].get_node("Hit_ARMOR"),
			boss._hand_body[0], boss._hand_body[1]]
	for p in arena.party():
		var mask: int = p.collision_mask
		_check((mask & 2) != 0, "player movement scans boss bodies")
		p.collision_mask = 2
		for part: ColossusPart in parts:
			if not boss.player_solid(part):
				_check(p.get_collision_exceptions().has(part) and boss._skin != null and boss._skin_solid,
						"%s/%s is hit-only; the visible hide stops %s there" % [part.get_parent().name, part.name, p.name])
				continue
			var center := part.global_position
			var from := center + boss.global_basis.z.normalized() * 25.0 - Vector3.UP * 0.9
			var pose := Transform3D(Basis.IDENTITY, from)
			var hit := KinematicCollision3D.new()
			var blocked: bool = p.test_move(pose, center - Vector3.UP * 0.9 - from, hit)
			_check(blocked and hit.get_collider() is ColossusPart,
					"%s cannot move through %s/%s" % [p.name, part.get_parent().name, part.name])
		p.collision_mask = mask
		_check(p.platform_floor_layers == 0 and p.platform_wall_layers == 0,
				"moving boss parts cannot lend their velocity to the player")


func _hit_damage(part: ColossusPart, arrow: bool) -> float:
	var before := boss.hp
	boss.on_part_hit(part, 40.0, null, arrow, part.global_position)
	return before - boss.hp


func _damage_zones() -> void:
	boss._start(boss.Act.IDLE, 30.0)
	boss.hp = boss.MAX_HP
	boss.poise = 0.0
	var arm := boss._ua[0].get_node("Hit_ARMOR") as ColossusPart
	var mouth := boss._eye.get_node("Hit_MOUTH") as ColossusPart
	for arrow in [false, true]:
		boss._head_open = false
		boss._pinned_left = [0.0, 0.0]
		var arm_dmg := _hit_damage(arm, arrow)
		var head_dmg := _hit_damage(boss._head_body, arrow)
		var mouth_dmg := _hit_damage(mouth, arrow)
		# Swords on the skull cut deep (1.8x); arrows only poke it between
		# openings (0.8x) but still beat the scales several times over.
		_check(is_equal_approx(head_dmg, 32.0 if arrow else 72.0) and head_dmg > arm_dmg * 3,
				"head hits reward precision for %s" % ("arrows" if arrow else "melee"))
		_check(is_equal_approx(mouth_dmg, head_dmg), "closed mouth counts as a head hit")
		boss._pinned_left[0] = 3.0
		var poise := boss.poise
		var hand_dmg := _hit_damage(boss._hand_body[0], arrow)
		_check(hand_dmg < 72.0 * 0.3 and boss.poise > poise,
				"recovering claws take low HP damage but still build stagger")
		boss._head_open = true
		_check(is_equal_approx(_hit_damage(boss._head_body, arrow), 64.0 if arrow else 100.0),
				"exposed head increases the punish (250% blade, 160% arrow)")
	# A skull on the stone after a head slam is as rich as a grounded claw:
	# 320% blade, 180% arrow.
	boss._head_open = false
	boss._start(boss.Act.HEAD_SLAM, 10.0)
	boss._struck = true
	boss.act_t = boss.HEAD_WINDUP + boss.HEAD_STRIKE + 0.5
	_check(boss.head_down() and is_equal_approx(_hit_damage(boss._head_body, false), 128.0)
			and is_equal_approx(_hit_damage(boss._head_body, true), 72.0),
			"the grounded skull takes the punish multipliers")
	boss.hp = boss.MAX_HP
	boss.poise = 0.0
	boss._pinned_left = [0.0, 0.0]
	boss._start(boss.Act.IDLE, 30.0)


func _melee_contact() -> void:
	await _slam(0, false)
	var p: Player
	for member in arena.party():
		if member.is_paladin():
			p = member
	p.global_position = boss.fist_pos(0) + Vector3(0, 0, 2.0)
	p.global_position.y = 0.05
	p.velocity = Vector3.DOWN * 6.0
	for tick in 4:
		p.move_and_slide()
	boss.hp = boss.MAX_HP
	boss.poise = 0.0
	boss._pinned_left[0] = 3.0
	p._swing_targets.clear()
	p._hitbox_active_window = true
	p._on_attack_hitbox_body_entered(boss._hand_body[0])
	var after := boss.hp
	_check(after < boss.MAX_HP, "solid claw remains reachable by the paladin sword")
	p._on_attack_hitbox_body_entered(boss._fa[0].get_node("Hit_ARMOR"))
	p._on_attack_hitbox_body_entered(boss._head_body)
	_check(boss.hp == after, "one swing hitting several boss parts only counts once")
	p._swing_targets.clear()
	p._on_attack_hitbox_body_entered(boss._hand_body[0])
	_check(boss.hp < after, "the next sword swing can hit the boss again")
	p._hitbox_active_window = false


func _recovery_contact() -> void:
	await _settle()
	boss._stagger(4.0, "contact review")
	boss.set_physics_process(true)
	await get_tree().create_timer(3.5).timeout
	var p: Player = arena.party()[0]
	# Approach from open ground; the small arena's lowered head covers its centre.
	var approach := 0.0 if arena.area_factor >= 6.0 else arena.radius * 0.65
	p.global_position = Vector3(0, 0.05, approach)
	# Stand beside the visible claw, clear of the longer replacement muzzle.
	var fist := boss.fist_pos(0)
	#The small weapon hull excludes the long fingers. Start beside the
	#visible finger at player height, not beneath the raised palm hull.
	boss._skin.update()
	var from := arena.center + Vector3.UP
	var point := Vector3.INF
	var best := INF
	for i in boss._skin.pos.size():
		if boss._skin.bone_names[boss._skin.dominant[i]] != "hand.L":
			continue
		var q: Vector3 = boss._skin.pos[i]
		if q.y < 0.3 or q.y > 1.8:
			continue
		var at := q + boss._flat_dir(fist, arena.center) * 0.5
		at.y = 0.01
		if boss._flat_dist(at, arena.center) > arena.radius - 0.6 or not boss._climb_stone_free(at):
			continue
		var d := q.distance_squared_to(from)
		if d < best:
			best = d
			point = at
	_check(point.is_finite(), "braced claw has visible skin within a standing player's reach")
	if not point.is_finite():
		boss.set_physics_process(false)
		return
	point.y = 0.01
	#The wide brace lies beyond the perches. Test contact at its clear
	#approach, rather than stopping the probe on a pillar along the way.
	p.global_position = point
	# The lowered skull is hit-only now: the walk-in can end inside it, and the
	# hide sets the player outside on the next tick. Drift counts from there.
	await get_tree().create_timer(0.1).timeout
	var start := p.global_position
	var contact := boss._skin_contact(p)
	print("[BossAnimation] recovery probe at %s fist %s contact %s depth %.2f" % [
			start.snapped(Vector3.ONE * 0.01), fist.snapped(Vector3.ONE * 0.01), contact.bone, float(contact.depth)])
	_check(String(contact.bone) == "hand.L" and absf(float(contact.depth)) < 1.0,
			"recovery probe stands beside the claw, outside the muzzle")
	var drift := 0.0
	var low := p.global_position.y
	for tick in int(2.0 * Engine.physics_ticks_per_second):
		await get_tree().physics_frame
		p.velocity = Vector3.DOWN
		p.move_and_slide()
		drift = maxf(drift, p.global_position.distance_to(start))
		low = minf(low, p.global_position.y)
	print("[BossAnimation] recovery contact drift=%.4f lowest_y=%.4f" % [drift, low])
	_check(low > -0.1 and boss._flat_dist(p.global_position, arena.center) < arena.radius,
			"recovering limbs keep a touching player above the arena floor")
	if arena.area_factor >= 6.0:
		_check(drift < 0.4, "claws lift clear before withdrawing past a standing player")
	boss.set_physics_process(false)


func _descending_contact() -> void:
	await _settle()
	var p: Player = arena.party()[0]
	p.global_position = Vector3(0, 0.01, -arena.radius * 0.4)
	p._spawn_immunity_timer = 5.0
	boss._hand_i = 0
	boss._chained = false
	boss._slam_windup = boss.SLAM_WINDUP
	boss._target = p.global_position + Vector3.UP * boss.FIST_HALF_THICK * boss.sz
	boss._start(boss.Act.SLAM, boss.SLAM_WINDUP + boss.SLAM_STRIKE + 0.1)
	var dt := 1.0 / Engine.physics_ticks_per_second
	var low := p.global_position.y
	for tick in int((boss.SLAM_WINDUP + boss.SLAM_STRIKE + 0.2) / dt):
		await get_tree().physics_frame
		boss._physics_process(dt)
		p.velocity = Vector3.DOWN
		p.move_and_slide()
		low = minf(low, p.global_position.y)
	_check(low > -0.1 and boss._flat_dist(p.global_position, arena.center) < arena.radius,
			"a descending solid claw cannot push a player through the floor")


func _mouth_target() -> void:
	boss.set_physics_process(false)
	await get_tree().physics_frame
	# The iron muzzle: even a roar only strains the jaw a degree or two.
	boss._start(boss.Act.ROAR, 5.0)
	var widest := -INF
	for k in 30:
		boss.act_t = 0.05 * k
		boss._tick_jaw(1.0 / 60.0)
		widest = maxf(widest, boss._jaw.rotation.x)
	_check(widest < deg_to_rad(float(boss.reptile.spec.jaw_closed) + 3.0) and not boss.mouth_open(),
			"the muzzle keeps the jaw shut through a roar")
	_check(boss.get_node_or_null("AcidVomit") == null and not ("_vomit" in boss),
			"no acid: the muzzled boss has no vomit attack")
	boss._start(boss.Act.IDLE, 30.0)
	var cores := 0
	for p in get_tree().get_nodes_in_group("colossus_parts"):
		if boss.is_ancestor_of(p) and p.kind == ColossusPart.Kind.CORE:
			cores += 1
	boss.hp = boss.MAX_HP * 0.1
	_check(cores == 0 and not boss.core_open() and boss._shutters.is_empty(),
			"no chest weak point or shutters, including low health")
	boss.hp = boss.MAX_HP


## The head slam with real physics: it rears, drives the muzzle's lock onto
## the ring, hits a player standing there, leaves the skull down as a punish
## window, puts out a brazier beside the ring and lifts back to rest.
func _head_slam() -> void:
	await _settle()
	boss._anchor_angle = 0.0
	boss._place_on_anchor(true)
	await _settle()
	var p: Player = arena.party()[0]
	var toward := boss._flat_dir(arena.center, boss.global_position)
	var spot := arena.center + toward * arena.radius * 0.6
	p.process_mode = Node.PROCESS_MODE_INHERIT
	p.is_dead = false
	p._health.reset_to_full()
	p._spawn_immunity_timer = 0.0
	p.global_position = Vector3(spot.x, arena.floor_y + 0.05, spot.z)
	p.velocity = Vector3.ZERO
	# Stand still in the ring: its own brain would (rightly) roll out of it.
	var ai := p.get_node_or_null("CompanionAI")
	if ai != null:
		ai.process_mode = Node.PROCESS_MODE_DISABLED
	p._ai_move_vec = Vector2.ZERO
	var near: ArenaBrazier = null
	for b: ArenaBrazier in arena.braziers:
		b.kindle()
	# A brazier moved beside the ring: the shockwave has to reach it.
	if not arena.braziers.is_empty():
		near = arena.braziers[0]
		near.global_position = Vector3(spot.x, arena.floor_y, spot.z) + toward.cross(Vector3.UP) * 3.5
	_check(boss._head_can_reach(spot), "a player in the near band is within the head slam's reach")
	var hp := p.current_health
	boss.set_physics_process(true)
	boss._begin_head_slam([p])
	_check(boss.act == boss.Act.HEAD_SLAM, "head slam starts against a reachable player")
	var seen: Dictionary = boss.strike_eta_for(p)
	_check(String(seen.kind) == "slam" and float(seen.eta) > 1.0, "bots read the head slam as a slam to dodge")
	var dt := 1.0 / Engine.physics_ticks_per_second
	var landed := INF
	var reared := -INF
	var rest_y: float = boss._head.global_position.y
	while boss.act == boss.Act.HEAD_SLAM and boss.act_t < boss.HEAD_WINDUP + boss.HEAD_STRIKE + 0.6:
		await get_tree().physics_frame
		reared = maxf(reared, boss._head.global_position.y)
		if boss._struck:
			var lock: Vector3 = boss._head.global_transform * boss.head_contact()
			if landed == INF:
				var chest := p.global_position + Vector3.UP
				print("[BossAnimation] head impact: player %.2f m from the ring centre, %.2f m from the skull, lock at %s, target %s" % [
						boss._flat_dist(p.global_position, boss._target),
						boss.part_surface_point(boss._head_body, chest).distance_to(chest), lock, boss._target])
			landed = minf(landed, lock.y - arena.floor_y)
	print("[BossAnimation] head slam: reared %.2f m, lock %.2f m over the floor, hp %.0f -> %.0f" % [
			reared - rest_y, landed, hp, p.current_health])
	_check(reared > rest_y + 0.8, "the skull rears up before the blow")
	_check(landed < 1.0 and landed > -0.3, "the muzzle's lock comes down onto the stone")
	_check(p.current_health < hp, "a player standing in the ring is hit by the skull")
	_check(boss.head_down() and boss.head_open(), "the skull stays down: a punish window")
	_joint_deformation()
	_check(near == null or not near.lit, "the blow's shockwave puts out a brazier beside the ring")
	while boss.act == boss.Act.HEAD_SLAM:
		await get_tree().physics_frame
	_check(not boss.head_down(), "the punish window closes when the head lifts")
	boss.set_physics_process(false)
	if ai != null:
		ai.process_mode = Node.PROCESS_MODE_INHERIT
	p._spawn_immunity_timer = 100.0
	p.process_mode = Node.PROCESS_MODE_DISABLED
	if near != null:
		near.kindle()


## A real burning arrow into a dead brazier lights it; a lit one lets shots by.
func _braziers() -> void:
	_check(arena.braziers.size() >= 4, "the platform has its ring of braziers")
	var b: ArenaBrazier = arena.braziers[0]
	b.kindle()
	b.douse()
	_check(not b.lit and not b.is_in_group("brazier_light") and arena.light_at(b.global_position) < 1.0,
			"a doused brazier stops lighting the platform")
	var archer: Player = null
	for m in arena.party():
		if not m.is_paladin():
			archer = m
	# Dropped in from above: on the small field a level shot crosses a perch.
	var from := b.aim_point() + Vector3(0.0, 5.0, 1.5)
	var arrow: RigidBody3D = Player.ArrowScene.instantiate() if archer != null else null
	if arrow == null:
		_check(false, "an arrow can be spawned")
		return
	arrow.shooter = archer
	get_tree().current_scene.add_child(arrow)
	arrow.global_position = from
	arrow.launch(b.aim_point() - from)
	for k in 60:
		await get_tree().physics_frame
		if b.lit:
			break
	_check(b.lit and b.is_in_group("brazier_light"), "a burning arrow in the bowl relights the brazier")
	_check(b.collision_layer == 0, "a lit brazier lets arrows pass")
	b.douse()
	b._out_t = b.EMBER_RELIGHT - 0.05
	for k in 12:
		await get_tree().physics_frame
	_check(b.lit, "untended embers catch again on their own")


func _settle() -> void:
	boss.set_physics_process(true)
	boss._pinned_left = [0.0, 0.0]
	boss._start(ColossusBoss.Act.IDLE, 30.0)
	await get_tree().create_timer(1.0).timeout
	boss.set_physics_process(false)


func _slam(hand: int, chained: bool) -> void:
	await _settle()
	boss._chained = chained
	boss._slam_windup = 1.0 if chained else boss.SLAM_WINDUP
	boss._hand_i = hand
	boss._target = Vector3(-2.5 if hand == 0 else 2.5, boss.FIST_HALF_THICK * boss.sz, -1.0)
	boss._punch_hold = boss._slam_windup + boss.SLAM_STRIKE + boss.PUNCH_OPEN
	boss._start(ColossusBoss.Act.SLAM, boss._punch_hold + boss.SLAM_RECOVER)
	var dt := 1.0 / Engine.physics_ticks_per_second
	var prev: Vector3 = boss._hand[hand].global_position
	var step := 0.0
	var gap := 0.0
	for tick in int((boss._slam_windup + boss.SLAM_STRIKE + 0.06) / dt):
		boss.act_t = (tick + 1) * dt
		boss._tick_slam(dt)
		boss._apply_pose(dt)
		if absf(boss.act_t - boss._slam_windup) < dt * 1.5:
			step = maxf(step, prev.distance_to(boss._hand[hand].global_position))
		prev = boss._hand[hand].global_position
		if boss.act_t >= boss._slam_windup + boss.SLAM_STRIKE:
			gap = maxf(gap, boss.fist_pos(hand).distance_to(boss._target))
		_check_finite()
	print("[BossAnimation] slam hand=%d chained=%s boundary_step=%.4f contact_gap=%.4f" % [hand, chained, step, gap])
	_check(step < 0.35 * boss.sz, "slam enters its strike without a wrist jump")
	#The wrist must sit above the floor by the real palm thickness. Its old
	#0.9 m pivot target buried the new claw; contact now follows the skin.
	var probe := Marker3D.new()
	add_child(probe)
	probe.global_position = boss._target - Vector3.UP * boss.FIST_HALF_THICK * boss.sz
	boss._skin.update()
	_check(boss._arm_stopped[hand] or boss._claw_touches(hand, probe),
			"slam meets its target or stops against stone")
	_check(not boss._terrain.blocked(["hand.L" if hand == 0 else "hand.R"]),
			"the landed claw stays outside arena geometry")
	probe.queue_free()
	var bn := boss.reptile.skel.find_bone("hand.L" if hand == 0 else "hand.R")
	var bone := boss.reptile.skel.global_transform * boss.reptile.skel.get_bone_global_pose(bn)
	_check(bone.origin.distance_to(boss._hand[hand].global_position) < 0.01,
			"skinned wrist follows the collision pivot")
	if not chained:
		_joint_deformation()
	_wrist_orientation()


func _sweep(high: bool) -> void:
	await _settle()
	boss._begin_sweep()
	boss._sweep_high = high
	var i := boss._hand_i
	var dt := 1.0 / Engine.physics_ticks_per_second
	var prev: Vector3 = boss._hand[i].global_position
	var step := 0.0
	for tick in int((boss.SWEEP_WINDUP + boss.SWEEP_TIME) / dt):
		boss.act_t = (tick + 1) * dt
		boss._tick_sweep(dt)
		boss._apply_pose(dt)
		if absf(boss.act_t - boss.SWEEP_WINDUP) < dt * 1.5:
			step = maxf(step, prev.distance_to(boss._hand[i].global_position))
		prev = boss._hand[i].global_position
		_check_finite()
	print("[BossAnimation] sweep high=%s boundary_step=%.4f" % [high, step])
	_check(step < 0.35 * boss.sz, "sweep enters its hit window without a height jump")
	_wrist_orientation()


func _check_finite() -> void:
	for node in [boss._torso, boss._head, boss._jaw, boss._tail, boss._hand[0], boss._hand[1]]:
		if not node.global_transform.is_finite():
			_check(false, "nonfinite body pose: " + String(node.name))


func _wrist_orientation() -> void:
	if ReptilianRig.body_name() not in ["titan", "trellis"]:
		return
	var rig := boss.reptile
	for i in 2:
		var name := "hand.L" if i == 0 else "hand.R"
		var rest: Transform3D = rig._rest[name]
		#In the source A-pose, each palm faces the body, along +/-X.
		var palm := Vector3.RIGHT if i == 0 else Vector3.LEFT
		palm = (palm - rest.basis.y * palm.dot(rest.basis.y)).normalized()
		var pose := rig.skel.get_bone_global_pose(rig.skel.find_bone(name))
		var world := rig.skel.global_basis * pose.basis
		palm = (world * rest.basis.inverse() * palm).normalized()
		var down := boss._hand[i].global_basis.z.normalized()
		_check(palm.dot(down) > 0.75,
				"%s palm follows the contact side during %s" % [name, boss.act_name()])


## A REAL swing on the braced claw: the knight stands where the bot stands
## (a step off the claw's visible surface), faces it and attacks, physics
## running. The sims had him swinging there for whole holds at zero rescue.
func _rescue_swing(victim: Player, i: int) -> void:
	var k: Player = null
	for m in arena.party():
		if m != victim and m.is_paladin():
			k = m
	if k == null:
		return
	var claw := boss.fist_pos(1 - i)
	var out := boss._flat_dir(claw, arena.center)
	k.process_mode = Node.PROCESS_MODE_INHERIT
	k.is_dead = false
	k._health.reset_to_full()
	var surf := boss.claw_melee_pos(claw, claw + out * 6.0)
	k.global_position = Vector3(surf.x, 0.05, surf.z) + out * 0.6
	k.velocity = Vector3.ZERO
	# The test swings for him: his own brain would turn him toward the skull
	# or walk him off mid-check.
	var ai := k.get_node_or_null("CompanionAI")
	if ai != null:
		ai.process_mode = Node.PROCESS_MODE_DISABLED
	k._ai_move_vec = Vector2.ZERO
	k._ai_run = false
	k._ai_block = false
	k._ai_climb = false
	k._stamina.current_stamina = k._stamina.max_stamina
	var before := float(boss._rescue_dmg)
	var dealt := 0.0
	var dt := 1.0 / Engine.physics_ticks_per_second
	for tick in int(2.4 / dt):
		boss.act_t = minf(boss.act_t + dt, boss.GRAB_WINDUP + boss.GRAB_REACH + 2.0)
		boss._tick_grab(dt)
		boss._apply_pose(dt)
		# Aim as the bot does: aim_at turns the camera pivot.
		var to := boss.claw_melee_pos(claw, k.global_position) - k.global_position
		k._camera_pivot.rotation.y = atan2(-to.x, -to.z)
		if tick % 40 == 0:
			k._do_attack()
		await get_tree().physics_frame
		dealt += maxf(0.0, float(boss._rescue_dmg) - before)
		# Keep the captive for the separate arrow-release check below.
		boss._rescue_dmg = before
	print("[BossAnimation] rescue swing from %.2f m off the claw: rescue damage %.1f" % [
			k.global_position.distance_to(boss.claw_melee_pos(claw, k.global_position)), dealt])
	_check(dealt > 0.0, "a knight swinging beside the braced claw cuts it (rescue damage lands)")
	if ai != null:
		ai.process_mode = Node.PROCESS_MODE_INHERIT
	k.process_mode = Node.PROCESS_MODE_DISABLED
	boss._rescue_dmg = before


func _grab(side: float, angle: float = 0.0) -> void:
	boss._anchor_angle = angle
	boss._place_on_anchor(true)
	await _settle()
	var p: Player = arena.party()[0]
	p.is_dead = false
	p._health.reset_to_full()
	p.is_rolling = false
	var toward := boss._flat_dir(arena.center, boss.global_position)
	var dist := 0.65 if angle == 0.0 else 0.85
	var width := 2.0 if angle == 0.0 else 0.25
	p.global_position = arena.center + toward * arena.radius * dist \
			+ boss.global_basis.x.normalized() * side * width
	boss._begin_grab([p])
	_check(boss.act == ColossusBoss.Act.GRAB, "grab starts against a reachable player")
	if boss.act != ColossusBoss.Act.GRAB:
		return
	var i := boss._hand_i
	var dt := 1.0 / Engine.physics_ticks_per_second
	var prev: Vector3 = boss._hand[i].global_position
	var step := 0.0
	for tick in int((boss.GRAB_WINDUP + boss.GRAB_REACH + 0.8) / dt):
		boss.act_t = (tick + 1) * dt
		boss._tick_grab(dt)
		boss._apply_pose(dt)
		if absf(boss.act_t - boss.GRAB_WINDUP) < dt * 1.5:
			step = maxf(step, prev.distance_to(boss._hand[i].global_position))
		prev = boss._hand[i].global_position
		_check_finite()
	var gap := boss.fist_pos(1 - i).distance_to(boss._brace_point)
	print("[BossAnimation] grab side=%s boundary_step=%.4f brace_gap=%.4f" % [side, step, gap])
	_check(step < 0.35 * boss.sz, "grab reach starts without a wrist jump")
	_wrist_orientation()
	if boss._victim == null:
		_check(boss._arm_stopped[i], "the missed grab was stopped by arena geometry")
		_check(boss._victim == null, "a pillar or ramp blocks the grab before it captures a player")
		_check(angle == 0.0, "the grab remains usable from the open side of the arena")
		return
	_check(boss._victim == p and boss._flat_dist(boss.fist_pos(1 - i), boss._brace_point) < 0.5,
			"opposite hand braces on its own side within rescue reach")
	await _rescue_swing(p, i)
	boss.on_part_hit(boss._hand_body[1 - i], 70.0, arena.party()[1], true, boss.brace_hand_pos())
	boss._tick_grab(dt)
	_check(boss._victim == null and not boss.core_open(), "arrows into the braced claw free the captive without a chest opening")
