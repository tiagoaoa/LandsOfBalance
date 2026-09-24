extends Node3D

var player: CharacterBody3D
var bobba: CharacterBody3D
var failures := 0
var checks := 0


class Target extends StaticBody3D:
	var hp := 2000.0
	var hits := 0
	var accept := true

	func _ready() -> void:
		collision_layer = 2
		collision_mask = 0
		var shape := CollisionShape3D.new()
		var capsule := CapsuleShape3D.new()
		capsule.radius = 0.35
		capsule.height = 1.8
		shape.shape = capsule
		shape.position.y = 0.9
		add_child(shape)

	func take_hit(damage: float, _kb: Vector3, _blocked: bool,
			_attacker: Node3D = null, _weapon: bool = false) -> bool:
		if not accept:
			return false
		hp -= damage
		hits += 1
		return true


func _ready() -> void:
	seed(405)
	var ground := CSGBox3D.new()
	ground.size = Vector3(80, 1, 80)
	ground.position.y = -0.5
	ground.use_collision = true
	add_child(ground)
	player = load("res://player/player.tscn").instantiate()
	player.enable_multiplayer = false
	add_child(player)
	await get_tree().process_frame
	player.ai_driven = true
	player.global_position = Vector3(0, 0.05, 0)
	await _frames(15)
	_reset()
	await _input_checks()
	await _contact_checks()
	await _skeleton_checks()
	await _bobba_checks()
	await _timing_checks()
	print("[CombatFeel] checks=%d failures=%d" % [checks, failures])
	for voice in Sfx._pool:
		voice.stop()
		voice.stream = null
	for child in get_children():
		child.queue_free()
	var until := Time.get_ticks_usec() + 150000
	while Time.get_ticks_usec() < until:
		await get_tree().process_frame
	get_tree().quit(1 if failures else 0)


func _frames(count: int) -> void:
	for i in range(count):
		await get_tree().physics_frame


func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
	print("[CombatFeel] %s %s" % ["PASS" if ok else "FAIL", message])


func _reset() -> void:
	player.set_physics_process(false)
	player.is_attacking = false
	player.is_rolling = false
	player.is_parrying = false
	player.is_drinking = false
	player.is_casting = false
	player.is_blocking = false
	player._is_stunned = false
	player._guard_recoil = false
	player._attack_cooldown = 0
	player._attack_input_buffer = 0
	player._dodge_input_buffer = 0
	player._buffer_heavy = false
	player._ai_move_vec = Vector2.ZERO
	player._ai_run = false
	player._ai_block = false
	player._drop_lock_on()
	player._spawn_immunity_timer = 0
	player._health.reset_to_full()
	player._stamina.current_stamina = 100
	player.velocity = Vector3.ZERO
	player.global_position = Vector3.ZERO
	player._camera_pivot.rotation = Vector3.ZERO
	player.camera_rotation = Vector2.ZERO
	player._character_model.rotation.y = PI
	player.disable_attack_hitbox()
	player._play_anim(StringName(player._get_current_mode_prefix() + "/Idle"))


func _input_checks() -> void:
	player._do_attack(true)
	_check(player._current_anim == &"armed/HeavyAttack", "heavy uses its own readable animation timing")
	_check(player._stamina.current_stamina == 68, "heavy costs 32 stamina")
	_check(player._current_attack.poise_damage == 85, "heavy threatens enemy posture")
	_reset()
	player._ai_move_vec = Vector2(0, -1)
	player._try_dodge()
	player._roll_timer = 0.12
	player._do_attack()
	player.set_physics_process(true)
	await _frames(25)
	_check(player.is_attacking, "late attack press comes out after dodge recovery")
	_reset()
	player._is_stunned = true
	player._stun_timer = 0.08
	player._try_dodge()
	player.set_physics_process(true)
	await _frames(22)
	_check(player.is_rolling, "dodge buffered during hit recovery starts when free")
	_reset()
	player._switch_character_class(1)
	player._start_bow_draw(true, true)
	_check(player.is_drawing_bow, "archer entered a real bow draw")
	player._try_dodge()
	_check(player.is_rolling and not player.is_drawing_bow and not player.is_holding_bow,
			"archer can dodge out of a held draw")
	_check(is_equal_approx(player._stamina.current_stamina, 91.2), "draw cancellation keeps archer dodge discount")
	_reset()
	player._start_bow_draw(true, true)
	player._stamina.current_stamina = 0
	player._try_dodge()
	_check(player.is_drawing_bow and not player.is_rolling, "unaffordable dodge does not cancel bow")
	player._cancel_bow_draw()
	player._switch_character_class(0)
	_reset()
	player._health.damage_flat(60)
	player.estus_charges = 3
	player._try_estus()
	player._try_dodge()
	var hp: float = player.current_health
	player.set_physics_process(true)
	await _frames(145)
	_check(not player.is_drinking and player.current_health == hp and player.estus_charges == 2,
			"dodging cancels heal and keeps the spent flask spent")
	_reset()
	player._start_combo_swing(0)
	player._attack_anim_progress = 0.8
	player._ai_block = true
	player._update_block_state()
	_check(player.is_blocking and not player.is_attacking, "held guard cancels legal sword recovery")
	var enemy := Target.new()
	add_child(enemy)
	enemy.position.z = -2
	player.take_hit(20, Vector3.ZERO, false, enemy, true)
	player._update_block_state()
	player.take_hit(20, Vector3.ZERO, false, enemy, true)
	_check(is_equal_approx(player.current_health, player.max_health - 6), "shield remains raised through block recoil")
	enemy.free()
	_reset()
	player.ai_driven = false
	var stick := InputEventJoypadMotion.new()
	stick.axis = JOY_AXIS_LEFT_Y
	stick.axis_value = -1
	Input.parse_input_event(stick)
	Input.flush_buffered_events()
	player.set_physics_process(true)
	await _frames(70)
	_check(not player.is_running and player._stamina.current_stamina == 100,
			"full analog stick moves without automatic sprint drain")
	stick.axis_value = 0
	Input.parse_input_event(stick)
	Input.flush_buffered_events()
	player.ai_driven = true
	_reset()
	player.ai_driven = false
	var heavy := InputEventJoypadButton.new()
	heavy.button_index = JOY_BUTTON_RIGHT_SHOULDER
	heavy.pressed = true
	Input.parse_input_event(heavy)
	Input.flush_buffered_events()
	_check(player._current_anim == &"armed/HeavyAttack" and player._stamina.current_stamina == 68,
			"RB starts exactly one heavy attack through real gamepad input")
	var release := heavy.duplicate() as InputEventJoypadButton
	release.pressed = false
	Input.parse_input_event(release)
	Input.flush_buffered_events()
	player.ai_driven = true
	_reset()
	player._start_combo_swing(0)
	player._do_attack()
	player._try_dodge()
	_check(player._attack_input_buffer == 0 and player._combo_clicks_buffered == 0,
			"buffered dodge takes priority over an earlier combo press")
	player._current_anim_player.seek(player._current_anim_player.current_animation_length * 0.65, true)
	player._update_attack_hitbox_timing()
	player._try_dodge()
	_check(player.is_rolling, "queued combo cannot steal the dodge recovery window")
	_reset()
	var button := InputEventJoypadButton.new()
	button.button_index = JOY_BUTTON_RIGHT_STICK
	_check(InputMap.event_is_action(button, &"lock_on"), "R3 is bound to lock-on")
	var left := Target.new()
	var right := Target.new()
	add_child(left)
	add_child(right)
	left.add_to_group("skeletons")
	right.add_to_group("skeletons")
	left.position = Vector3(-2, 0, -4)
	right.position = Vector3(2, 0, -4)
	player._lock_target = left
	player._switch_lock_target(1)
	_check(player._lock_target == right, "right flick selects enemy on the right")
	player._switch_lock_target(-1)
	_check(player._lock_target == left, "left flick selects enemy on the left")
	player._is_stunned = true
	player._stun_timer = 0.5
	player.set_physics_process(true)
	var yaw: float = player._camera_pivot.rotation.y
	await _frames(10)
	_check(absf(player._camera_pivot.rotation.y - yaw) > 0.05,
			"camera continues tracking the enemy during hit recovery")
	player.set_physics_process(false)
	player._drop_lock_on()
	left.free()
	right.free()


func _contact_checks() -> void:
	_reset()
	var first := Target.new()
	var second := Target.new()
	add_child(first)
	add_child(second)
	first.position = Vector3(-0.25, 0, -1.5)
	second.position = Vector3(0.25, 0, -1.5)
	await _frames(3)
	player._start_combo_swing(0)
	player._hitbox_active_window = true
	player._on_attack_hitbox_body_entered(first)
	player._on_attack_hitbox_body_entered(first)
	player._on_attack_hitbox_body_entered(second)
	_check(first.hits == 1 and second.hits == 1, "one sword swing cleaves two targets exactly once each")
	var ally := Target.new()
	add_child(ally)
	ally.add_to_group("companion")
	ally.position = Vector3(0, 0, -1)
	player._on_attack_hitbox_body_entered(ally)
	_check(ally.hits == 0, "cleave still excludes allies")
	ally.collision_layer = 1
	await _frames(3)
	_check(player._lock_visible(first), "ally between player and enemy does not block combat targeting")
	ally.free()
	var wall := CSGBox3D.new()
	wall.size = Vector3(4, 3, 0.2)
	wall.position = Vector3(0, 1.5, -0.7)
	wall.use_collision = true
	add_child(wall)
	await _frames(3)
	player.enable_attack_hitbox()
	player._hitbox_active_window = true
	player._on_attack_hitbox_body_entered(first)
	_check(first.hits == 1, "sword cannot damage through solid walls")
	wall.queue_free()
	await _frames(3)
	var attack := preload("res://combat/attack_data.gd").new()
	attack.damage = 100
	first.accept = false
	_check(attack.apply_to(first, player) == 0 and first.hits == 1,
			"blocked damage does not report a successful hit")
	first.accept = true
	first.position = Vector3(0, 0, 1)
	second.position.x = 20
	await _frames(3)
	var sweep := preload("res://combat/blade_sweep.gd").new()
	var space := get_world_3d().direct_space_state
	var from := Transform3D(Basis.IDENTITY, Vector3(-1, 1, 0))
	var to := Transform3D(Basis.IDENTITY, Vector3(1, 1, 0))
	_check(sweep.contacts(space, from, [player.get_rid()]).is_empty(), "sweep starts outside target")
	_check(sweep.contacts(space, to, [player.get_rid()]).has(first), "sweep catches target between blade poses")
	first.position = Vector3(0, 0, -1.5)
	first.hits = 0
	_reset()
	player.set_physics_process(true)
	await _frames(5)
	player._do_attack()
	await _frames(105)
	_check(first.hits == 1, "real animated opener connects with target 1.5 metres ahead")
	first.free()
	second.free()


func _skeleton_checks() -> void:
	_reset()
	var enemy = load("res://enemies/skeleton.gd").new()
	add_child(enemy)
	enemy.set_physics_process(false)
	enemy.position = Vector3(0, 0, -1.5)
	enemy._target = player
	enemy._start_attack()
	_check(is_equal_approx(enemy._anim.speed_scale, 1), "skeleton contact clock matches animation playback")
	enemy._strike()
	_check(player.current_health < player.max_health, "skeleton frontal strike connects")
	player._is_stunned = false
	player.global_position = Vector3(0, 0, -3)
	var hp: float = player.current_health
	enemy._strike()
	_check(player.current_health == hp, "skeleton cannot hit behind its committed facing")
	enemy._start_attack()
	enemy.take_hit(10, Vector3.ZERO, false, player, true)
	_check(enemy._attack_left == 0 and enemy._attack_dealt, "stagger retires interrupted skeleton attack")
	enemy.on_parried(player)
	_check(enemy.is_riposte_ready() and enemy._attack_left == 0, "skeleton parry opens a critical and stops the strike")
	enemy.consume_riposte()
	_check(not enemy.is_riposte_ready(), "skeleton critical can be consumed only once")
	var second = load("res://enemies/skeleton.gd").new()
	add_child(second)
	second.set_physics_process(false)
	second._target = player
	enemy._start_attack()
	_check(not second._attack_slot_available(), "pack staggers its attack starts")
	enemy._attack_left = 0.5
	_check(second._attack_slot_available(), "second pack attacker may join after the tell")
	var third = load("res://enemies/skeleton.gd").new()
	add_child(third)
	third.set_physics_process(false)
	third._target = player
	second._start_attack()
	second._attack_left = 0.5
	_check(not third._attack_slot_available(), "pack limits simultaneous attacks to two")
	enemy.free()
	second.free()
	third.free()


func _bobba_checks() -> void:
	_reset()
	bobba = load("res://enemies/bobba.tscn").instantiate()
	add_child(bobba)
	bobba.set_physics_process(false)
	bobba.position = Vector3(0, 0, -2)
	bobba.target = player
	bobba._model.rotation.y = 0
	bobba._start_axe_attack()
	bobba._attack_anim_progress = 0.36
	var heading: float = bobba._model.rotation.y
	player.position.x = 2
	bobba._handle_attacking(0.1)
	_check(is_equal_approx(heading, bobba._model.rotation.y), "Bobba cannot turn his axe during contact")
	_check(bobba.velocity.x == 0, "Bobba lunge keeps committed heading")
	bobba._on_animation_finished(bobba.AXE_ATTACK.anim)
	bobba._handle_chasing(0.1, 2)
	_check(Vector2(bobba.velocity.x, bobba.velocity.z).length() == 0 and bobba.attack_cooldown >= 1.1,
			"spent axe gives a stationary counterattack opening")
	bobba.is_blocking = true
	bobba._start_combo_attack(0)
	_check(not bobba.is_blocking, "Bobba cannot attack with invulnerable guard raised")
	bobba._poise.current_poise = 100
	var light = player._get_combo_attack(0)
	light.apply_to(bobba, player)
	_check(bobba.state == bobba.State.ATTACKING, "light hit does not erase an armored windup")
	player._get_heavy_attack().apply_to(bobba, player)
	_check(bobba.state == bobba.State.STUNNED and bobba.is_riposte_ready() and not bobba._hitbox_active_window,
			"posture break interrupts attack and opens a critical")
	bobba.state = bobba.State.CHASING
	bobba._riposte_ready = false
	bobba._poise.current_poise = 100
	bobba.is_blocking = true
	player.position = Vector3(0, 0, 0)
	var hp: float = bobba.health
	_check(light.apply_to(bobba, player) == 0 and bobba.health == hp, "Bobba frontal guard honestly deflects light hit")
	player.position = Vector3(0, 0, -3)
	_check(light.apply_to(bobba, player) > 0 and bobba.health < hp, "flanking bypasses Bobba guard")
	bobba.state = bobba.State.CHASING
	bobba.is_blocking = true
	bobba._poise.current_poise = 100
	player.position = Vector3.ZERO
	_check(player._get_heavy_attack().apply_to(bobba, player) > 0 and not bobba.is_blocking,
			"heavy breaks a full frontal guard")
	bobba.health = 250
	bobba._time_since_damage = 20
	bobba.target = player
	bobba.state = bobba.State.CHASING
	bobba._physics_process(0.1)
	_check(bobba.health == 250 and not bobba._is_fleeing, "wounded boss neither heals nor flees during encounter")
	bobba.free()


func _timing_checks() -> void:
	_reset()
	CombatFX.hitstop(0.04, 0.05)
	var until := Time.get_ticks_usec() + 120000
	while Time.get_ticks_usec() < until:
		await get_tree().process_frame
	_check(is_equal_approx(Engine.time_scale, 1), "optional hitstop ends on real time instead of stretching twentyfold")
	var remote = load("res://multiplayer/remote_player.tscn").instantiate()
	remote.character_class = 0
	remote.player_id = 91
	add_child(remote)
	await _frames(3)
	remote.current_anim_name = "armed/HeavyAttack"
	remote._update_animation()
	_check(remote._anim_player.current_animation == "paladin/HeavyAttack", "remote player displays heavy attack")
	_check(is_equal_approx(remote._anim_player.get_animation("paladin/HeavyAttack").length /
			remote._anim_player.get_playing_speed(), 1.08), "remote heavy matches local duration")
	remote.free()
