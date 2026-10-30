extends Node3D

var player: Player
var archer: Player
var boss: Bobba
var failures := 0
var checks := 0


func _ready() -> void:
	seed(905)
	var ground := CSGBox3D.new()
	ground.size = Vector3(100, 1, 100)
	ground.position.y = -0.5
	ground.use_collision = true
	add_child(ground)
	player = load("res://player/player.tscn").instantiate()
	player.enable_multiplayer = false
	add_child(player)
	await _frames(2)
	player.ai_driven = true
	player.global_position = Vector3.ZERO
	await _frames(10)
	player.set_physics_process(false)
	player._spawn_immunity_timer = 0
	boss = load("res://enemies/bobba.tscn").instantiate()
	add_child(boss)
	boss.set_physics_process(false)
	boss.position = Vector3(0, 0, -15)
	await _frames(2)
	await _visibility_checks()
	await _archer_checks()
	await _fire_checks()
	await _swing_checks()
	await _pressure_checks()
	await _rt_parry_checks()
	print("[NightHunt] checks=%d failures=%d" % [checks, failures])
	for voice in Sfx._pool:
		voice.stop()
		voice.stream = null
	for child in get_children():
		child.queue_free()
	await get_tree().create_timer(0.2).timeout
	get_tree().quit(1 if failures else 0)


func _frames(count: int) -> void:
	for i in count:
		await get_tree().physics_frame


func _pressure_checks() -> void:
	for fire in get_tree().get_nodes_in_group("ground_fire"):
		fire.queue_free()
	await _frames(2)
	boss.health = boss.MAX_HEALTH
	player.position = Vector3.ZERO
	player._health.reset_to_full()
	player.is_blocking = false
	boss.position = Vector3(0, 0, -2.2)
	boss._model.rotation = Vector3.ZERO
	boss.target = player
	boss.state = Bobba.State.CHASING
	boss.attack_cooldown = 0
	boss._punish_left = 0
	boss.set_physics_process(true)
	var swings := 0
	var hits := 0
	var previous := ""
	var progress := 1.0
	for i in 12 * Engine.physics_ticks_per_second:
		await _frames(1)
		var clip := String(boss._anim_player.current_animation)
		if boss.state == Bobba.State.ATTACKING and (clip != previous or boss._attack_anim_progress < progress):
			swings += 1
		if player.current_health < player.max_health:
			hits += 1
			player._health.reset_to_full()
		previous = clip
		progress = boss._attack_anim_progress
	boss.set_physics_process(false)
	print("[NightHunt] pressure: %d swings, %d contacts in 12 seconds" % [swings, hits])
	_check(swings >= 5 and hits >= 3, "Bobba keeps attacking an idle paladin instead of waiting")


func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
	print("[NightHunt] %s %s" % ["PASS" if ok else "FAIL", message])


func _rt_parry_checks() -> void:
	player.position = Vector3.ZERO
	player._character_model.rotation.y = PI
	player._health.reset_to_full()
	player._stamina.current_stamina = 100
	player._attack_cooldown = 0
	player._attack_input_buffer = 0
	player._is_stunned = false
	player._stun_timer = 0
	player.is_attacking = false
	player.is_parrying = false
	player.is_blocking = false
	player.velocity = Vector3.ZERO
	player.ai_driven = false
	player.set_physics_process(true)
	boss.position = Vector3(0, 0, -3.2)
	boss._model.rotation = Vector3.ZERO
	boss._start_axe_attack()
	boss.set_physics_process(true)
	var pressed := false
	for i in 2 * Engine.physics_ticks_per_second:
		await _frames(1)
		if not pressed and boss._attack_anim_progress >= 0.29:
			var rt := InputEventJoypadMotion.new()
			rt.axis = JOY_AXIS_TRIGGER_RIGHT
			rt.axis_value = .9
			Input.parse_input_event(rt)
			Input.flush_buffered_events()
			pressed = true
		if boss.is_riposte_ready():
			break
	_check(pressed and boss.is_riposte_ready() and player.current_health == player.max_health,
			"real RT input parries Bobba's animated axe and opens a riposte")
	var release := InputEventJoypadMotion.new()
	release.axis = JOY_AXIS_TRIGGER_RIGHT
	Input.parse_input_event(release)
	Input.flush_buffered_events()
	player.ai_driven = true
	player.set_physics_process(false)
	boss.set_physics_process(false)


func _visibility_checks() -> void:
	_check(not Perception.can_see(player, boss), "darkness hides a distant enemy")
	_check(not player._lock_visible(boss), "lock-on cannot discover an unlit enemy")
	var fire := Node3D.new()
	fire.add_to_group("ground_fire")
	add_child(fire)
	fire.position = Vector3(4, 0, -15)
	_check(Perception.can_see(player, boss), "a fire reveals the distant enemy")
	var wall := CSGBox3D.new()
	wall.position = Vector3(0, 2, -7)
	wall.size = Vector3(6, 4, 1)
	wall.use_collision = true
	add_child(wall)
	await _frames(3)
	_check(not Perception.can_see(player, boss), "fire does not grant sight through a wall")
	wall.free()
	fire.free()
	boss.position.z = -4
	await _frames(2)
	_check(Perception.can_see(player, boss), "nearby danger remains readable without fire")
	boss.position = Vector3(35, 0, 35)


func _archer_checks() -> void:
	archer = load("res://player/player.tscn").instantiate()
	archer.is_ai_companion = true
	archer.companion_class_override = 1
	archer.enable_multiplayer = false
	add_child(archer)
	archer._switch_character_class(1)
	archer.ai_driven = true
	archer.position = Vector3(3, 0.05, 3)
	var companion_ai := archer.get_node_or_null("CompanionAI")
	if companion_ai:
		companion_ai.set_physics_process(false)
	await _frames(12)
	_check(archer.get_node_or_null("BowHUD") == null and archer.get_node_or_null("GothicHUD") == null,
			"companion does not put its own HUD on the paladin's screen")
	var brain := SquadBrain.new()
	add_child(brain)
	brain.set_process(false)
	brain.set_physics_process(false)
	var mate := SquadBrain.Ally.new()
	mate.node = player
	mate.pos = player.global_position
	mate.is_paladin = true
	brain.allies = [mate]
	brain.contacts.clear()
	var role := ArcherRole.new()
	role.setup(archer, brain)
	player.velocity = Vector3(3, 0, 0)
	_check(role._advance_heading(mate).dot(Vector3.RIGHT) > 0.99,
			"archer scouts along the paladin's movement")
	player.velocity = Vector3.ZERO
	player._camera_pivot.rotation = Vector3.ZERO
	_check(role._advance_heading(mate).dot(Vector3.FORWARD) > 0.99,
			"when stationary, archer scouts along the player's view")
	var point := role._search_point(mate)
	_check(point.z < -12 and point.distance_to(mate.pos) < 26,
			"search fire lands ahead of the party on reachable ground")
	archer.position = Vector3(28, 0, 0)
	_check(role.choose_tactic() == "regroup", "distant archer returns before scouting")
	archer.position = Vector3(3, 0.05, 3)
	var contact := SquadBrain.Contact.new()
	contact.node = boss
	contact.pos = Vector3(0, 0, -2)
	contact.seen_now = true
	contact.lit = true
	contact.last_seen = brain.now
	contact.hunting = player
	brain.contacts = [contact]
	_check(role.choose_tactic() == "suppress", "archer keeps helping against a lit enemy in melee")
	brain.contacts.clear()
	role._arrow_cd = 0
	role._order_shot(Vector3(0, 0.05, -16), 2, "test path")
	var drew := false
	for i in 100:
		role._serve_shot(1.0 / 60.0)
		drew = drew or archer.is_drawing_bow
		await _frames(1)
		if role.shots_fired > 0:
			break
	_check(drew and role.shots_fired == 1, "support arrow uses the bow's draw and release")
	for arrow in get_tree().get_nodes_in_group("fire_arrows"):
		_check(arrow.get_collision_exceptions().has(player), "support arrow passes through the paladin")
		arrow.queue_free()
	archer.set_physics_process(false)
	brain.free()


func _fire_checks() -> void:
	boss.target = player
	boss.state = boss.State.CHASING
	boss._fire_break_cd = 0
	boss._start_axe_attack()
	boss._attack_anim_progress = 0.15
	boss.take_arrow_hit(Vector3.FORWARD)
	_check(boss.is_riposte_ready() and not boss._hitbox_active_window,
			"fire during the windup opens a melee counterattack")
	boss._start_axe_attack()
	boss._attack_anim_progress = 0.15
	boss.take_arrow_hit(Vector3.FORWARD)
	_check(boss.state == boss.State.ATTACKING, "repeated fire cannot keep interrupting the boss")
	boss._fire_break_cd = 0
	boss._attack_anim_progress = 0.6
	boss.take_arrow_hit(Vector3.FORWARD)
	_check(boss.state == boss.State.ATTACKING, "fire does not interrupt a completed strike")
	boss.is_blocking = false
	boss._poise.current_poise = 100
	boss._poise._unstoppable_timer = 0
	var hp := boss.health
	boss.take_hit(50, Vector3.ZERO, false, player, false, 20)
	_check(is_equal_approx(hp - boss.health, 60), "a paladin following the fire mark gains damage")
	_check(is_equal_approx(boss._poise.current_poise, 71), "fire helps the paladin break posture")
	var arrow: RigidBody3D = load("res://player/arrow.tscn").instantiate()
	arrow.shooter = archer
	add_child(arrow)
	arrow._create_body_fire(boss)
	arrow._create_body_fire(boss)
	await _frames(2)
	var burns := 0
	for child in boss.get_children():
		if child.is_in_group("body_fire"):
			burns += 1
			_check(child.get_node("GroundFireAura").damage_per_sec == 6,
					"body fire supports the fight without replacing melee damage")
			child.queue_free()
	_check(burns == 1, "repeated arrows cannot stack body fires")
	arrow.queue_free()
	await _frames(2)


func _swing_checks() -> void:
	archer.position = Vector3(30, 0, 30)
	for move in ["axe", "swipe", "punch", "slam"]:
		boss.position = Vector3(0, 0, -3.2 if move == "axe" else -2.2)
		boss._model.rotation = Vector3.ZERO
		boss.target = player
		player.position = Vector3.ZERO
		player._health.reset_to_full()
		player.is_blocking = false
		player._is_stunned = false
		player.is_rolling = false
		boss._punish_left = 0
		boss.attack_cooldown = 0
		boss._stun_timer = 0
		if move == "axe":
			boss._start_axe_attack()
		else:
			boss._start_combo_attack(["swipe", "punch", "slam"].find(move))
		boss._combo_limit = 1
		boss.set_physics_process(true)
		for i in 180:
			await _frames(1)
			if boss.state != boss.State.ATTACKING:
				break
		boss.set_physics_process(false)
		_check(player.current_health < player.max_health, "%s reaches a stationary player in front" % move)
	boss.position = Vector3(0, 0, -3.2)
	boss._model.rotation = Vector3.ZERO
	player.position = Vector3.ZERO
	player._health.reset_to_full()
	boss._start_axe_attack()
	boss.set_physics_process(true)
	var stepped := false
	for i in 180:
		await _frames(1)
		if not stepped and boss._attack_anim_progress > 0.24:
			player.position.x = -3
			stepped = true
		if boss.state != boss.State.ATTACKING:
			break
	boss.set_physics_process(false)
	_check(stepped and player.current_health == player.max_health,
			"stepping aside after the tell avoids the committed axe")
	boss.position = Vector3(20, 0, 20)
	player.position = Vector3.ZERO
	await _frames(2)
	var sweep := preload("res://combat/strike_sweep.gd").new()
	var space := get_world_3d().direct_space_state
	sweep.contacts(space, Vector3(-2, 1, 0), 0.35, false, [])
	_check(sweep.contacts(space, Vector3(2, 1, 0), 0.35, true, []).has(player),
			"fast weapon motion cannot pass through a player between frames")
	_check(not sweep.contacts(space, Vector3(3, 1, 0), 0.35, true, []).has(player),
			"weapon sweep does not hit someone outside its path")
