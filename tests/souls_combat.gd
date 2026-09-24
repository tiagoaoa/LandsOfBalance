extends Node3D

var player: CharacterBody3D
var attacker: Node3D
var failures := 0


class FallenAlly extends Node3D:
	var is_dead := true

	func revive_from_death() -> void:
		is_dead = false


func _ready() -> void:
	var ground := CSGBox3D.new()
	ground.size = Vector3(30, 1, 30)
	ground.position.y = -0.5
	ground.use_collision = true
	add_child(ground)
	player = load("res://player/player.tscn").instantiate()
	player.enable_multiplayer = false
	add_child(player)
	await get_tree().process_frame
	player.ai_driven = true
	player.global_position = Vector3(0, 0.05, 0)
	player.velocity = Vector3.ZERO
	for i in range(12):
		await get_tree().physics_frame
	player.set_physics_process(false)
	player.set_process(false)
	player._spawn_immunity_timer = 0.0
	player._character_model.rotation.y = PI
	attacker = Node3D.new()
	add_child(attacker)
	attacker.position = Vector3(0, 0, -2)
	_check(player.is_on_floor(), "player grounded")
	_check(player.is_paladin(), "paladin selected")
	_guard_checks()
	_attack_checks()
	_trigger_checks()
	_roll_checks()
	_stamina_checks()
	_archer_stamina_checks()
	_paladin_stamina_checks()
	_revive_controls_checks()
	await _movement_checks()
	await _lock_checks()
	await _remote_checks()
	await _poise_checks()
	await _lighting_checks()
	print("[SoulsCombat] failures=%d" % failures)
	player.queue_free()
	attacker.queue_free()
	for voice in Sfx._pool:
		voice.stop()
		voice.stream = null
	await get_tree().create_timer(0.1).timeout
	await get_tree().process_frame
	await get_tree().process_frame
	get_tree().quit(1 if failures else 0)


func _check(ok: bool, label: String) -> void:
	print("[SoulsCombat] %s %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		failures += 1


func _reset() -> void:
	player.is_attacking = false
	player.is_rolling = false
	player.is_parrying = false
	player.is_drinking = false
	player._is_stunned = false
	player._stun_timer = 0.0
	player._attack_cooldown = 0.0
	player._attack_input_buffer = 0.0
	player._dodge_input_buffer = 0.0
	player._stamina.current_stamina = 100.0
	player._health.reset_to_full()
	player.disable_attack_hitbox()


func _guard_checks() -> void:
	_reset()
	player.is_blocking = true
	player.take_hit(20.0, Vector3.ZERO, true, attacker, true)
	_check(is_equal_approx(player.current_health, player.max_health - 3.0),
			"front guard applies weapon chip")
	_check(is_equal_approx(player._stamina.current_stamina, 84.0),
			"guard impact spends stamina")
	attacker.position.z = 2
	player.take_hit(20.0, Vector3.ZERO, true, attacker, true)
	_check(is_equal_approx(player.current_health, player.max_health - 23.0),
			"rear hit bypasses guard")
	_reset()
	attacker.position.z = -2
	player.is_blocking = true
	player._stamina.current_stamina = 5
	player.take_hit(20.0, Vector3.ZERO, true, attacker, true)
	_check(player._stamina.current_stamina == 0 and not player.is_blocking,
			"guard break drains remainder and drops shield")
	_check(player._is_stunned and player._stun_timer > 1.0,
			"guard break leaves a punish window")


func _trigger(value: float) -> void:
	var event := InputEventJoypadMotion.new()
	event.axis = JOY_AXIS_TRIGGER_LEFT
	event.axis_value = value
	Input.parse_input_event(event)
	Input.flush_buffered_events()


func _trigger_checks() -> void:
	_reset()
	player.ai_driven = false
	_trigger(.15)
	_check(not player.is_attacking, "LT drift does not attack")
	_trigger(.8)
	_check(player.is_attacking and player._combo_step == 0, "LT starts paladin sword attack")
	_check(is_equal_approx(player._stamina.current_stamina, 75), "LT keeps paladin stamina cost")
	_trigger(.95)
	_trigger(.49)
	_trigger(.8)
	_check(player._combo_clicks_buffered == 0, "holding LT and threshold jitter do not queue swings")
	_trigger(.1)
	_check(player._combo_clicks_buffered == 0, "LT release does not attack")
	_trigger(.9)
	_check(player._combo_clicks_buffered == 1, "another LT press queues one combo follow-up")
	_trigger(0)
	player.ai_driven = true
	_reset()


func _seek(ratio: float) -> void:
	var anim: AnimationPlayer = player._current_anim_player
	anim.pause()
	anim.seek(anim.current_animation_length * ratio, true)
	player._update_attack_hitbox_timing()


func _attack_checks() -> void:
	_reset()
	_check(player._start_combo_swing(0), "opener starts")
	_seek(0.1)
	_check(not player._hitbox_active_window, "windup cannot damage")
	player._try_dodge()
	_check(player.is_attacking and not player.is_rolling,
			"roll cannot cancel windup")
	player._dodge_input_buffer = 0
	_seek(0.40)
	_check(player._hitbox_active_window, "blade contact is active")
	_seek(0.65)
	_check(not player._hitbox_active_window, "follow-through cannot damage")
	player._do_attack()
	player._do_attack()
	_check(player._combo_clicks_buffered == 1, "mashing buffers only one step")
	_seek(0.76)
	_check(player._combo_step == 1 and player._attack_input_buffer == 0,
			"one buffered follow-up starts in recovery")
	player._do_attack()
	player._attack_input_buffer = 0
	_seek(0.85)
	_check(player._combo_step == 1, "expired input does not chain")
	player._stamina.current_stamina = 0
	player._try_dodge()
	_check(player.is_attacking and not player.is_rolling,
			"unaffordable roll cannot cancel a swing")
	player._stamina.current_stamina = 30
	player._try_dodge()
	_check(player.is_rolling and not player.is_attacking,
			"paid recovery roll cancels swing")


func _roll_checks() -> void:
	_reset()
	player.is_blocking = false
	player.is_rolling = true
	player._roll_timer = player.ROLL_DURATION - 0.15
	var hp: float = player.current_health
	var landed: bool = player.take_hit(20, Vector3.ZERO, false, attacker)
	_check(not landed and player.current_health == hp, "roll iframe negates hit")
	player._roll_timer = player.ROLL_DURATION - 0.50
	landed = player.take_hit(20, Vector3.ZERO, false, attacker)
	_check(landed and player.current_health < hp, "roll recovery is vulnerable")


func _stamina_checks() -> void:
	var stamina = player._stamina
	stamina.current_stamina = 40
	stamina._recover_timer = 0
	stamina.committed = true
	stamina._process(1.0)
	_check(stamina.current_stamina == 40, "committed action pauses recovery")
	stamina.committed = false
	stamina.blocking = false
	stamina._process(0.7)
	stamina._process(0.5)
	_check(stamina.current_stamina > 40, "stamina recovers after commitment")


func _frames(count: int) -> void:
	for i in range(count):
		await get_tree().physics_frame


func _archer_stamina_checks() -> void:
	player._switch_character_class(1)
	_reset()
	player._try_dodge()
	_check(player.is_rolling and is_equal_approx(player._stamina.current_stamina, 91.2),
			"archer dodge costs 8.8 stamina")
	_reset()
	player._stamina.current_stamina = 9.0
	player._try_dodge()
	_check(player.is_rolling and is_equal_approx(player._stamina.current_stamina, .2),
			"archer dodge affordability uses the reduced cost")
	_reset()
	player._stamina.try_spend(player.SPRINT_DRAIN * 2.0)
	_check(is_equal_approx(player._stamina.current_stamina, 89.6),
			"archer sprint costs 5.2 stamina per second")
	_reset()
	player.is_blocking = true
	player._character_model.rotation.y = PI
	player.take_hit(20.0, Vector3.ZERO, true, attacker, true)
	_check(is_equal_approx(player._stamina.current_stamina, 93.6),
			"archer blocked hits drain 60 percent less stamina")
	player._stamina.current_stamina = 40
	player._stamina._recover_timer = 0
	player._stamina.blocking = false
	player._stamina._process(1.0)
	_check(is_equal_approx(player._stamina.current_stamina, 70),
			"archer recovery rate is unchanged")


func _paladin_stamina_checks() -> void:
	player._switch_character_class(0)
	_reset()
	player.is_blocking = false
	player._try_dodge()
	_check(player.is_rolling and is_equal_approx(player._stamina.current_stamina, 78),
			"switching back restores the paladin's 22 stamina dodge")
	_reset()
	player._try_parry()
	_check(player.is_parrying and is_equal_approx(player._stamina.current_stamina, 88),
			"paladin parry still costs 12 stamina")
	_reset()
	player._stamina.try_spend(player.SPRINT_DRAIN * 2.0)
	_check(is_equal_approx(player._stamina.current_stamina, 74),
			"paladin sprint still costs 13 stamina per second")


func _revive_controls_checks() -> void:
	var ally := FallenAlly.new()
	add_child(ally)
	ally.add_to_group("companion")
	ally.global_position = player.global_position + Vector3.RIGHT
	player.ai_driven = false
	_pad_y(true)
	_check(Input.is_action_pressed(&"revive") and not Input.is_action_pressed(&"reset_position"),
			"gamepad Y revives without resetting position")
	player._update_revive(1.0)
	_check(player.is_reviving and ally.is_dead, "holding Y starts the revive channel")
	_pad_y(false)
	player._update_revive(.1)
	_check(not player.is_reviving and player._revive_progress == 0,
			"releasing Y interrupts the revive")
	_pad_y(true)
	player._update_revive(player.REVIVE_TIME)
	_check(not ally.is_dead, "holding Y for the full channel revives the ally")
	_pad_y(false)
	player.ai_driven = true
	ally.free()


func _pad_y(pressed: bool) -> void:
	var event := InputEventJoypadButton.new()
	event.button_index = JOY_BUTTON_Y
	event.pressed = pressed
	Input.parse_input_event(event)
	Input.flush_buffered_events()


func _movement_checks() -> void:
	_reset()
	player.is_blocking = false
	player._ai_move_vec = Vector2(0, -1)
	player._ai_block = true
	player.set_physics_process(true)
	await _frames(90)
	_check(Vector2(player.velocity.x, player.velocity.z).length() < 1.8,
			"guard slows actual movement")
	player._ai_block = false
	player._ai_crouch = true
	await _frames(90)
	_check(Vector2(player.velocity.x, player.velocity.z).length() < 1.9,
			"crouch slows actual movement")
	player._ai_crouch = false
	player._ai_run = true
	await _frames(60)
	_check(player._stamina.current_stamina < 98, "sprinting drains stamina")
	player._ai_run = false
	player._ai_move_vec = Vector2.ZERO
	player.set_physics_process(false)


func _lock_checks() -> void:
	player.global_position = Vector3.ZERO
	attacker.position = Vector3(0, 0, -5)
	attacker.add_to_group("skeletons")
	player._acquire_lock_target()
	_check(player._lock_target == attacker, "lock-on acquires skeleton group")
	var wall := CSGBox3D.new()
	wall.size = Vector3(4, 3, 0.3)
	wall.position = Vector3(0, 1.5, -2)
	wall.use_collision = true
	add_child(wall)
	await _frames(3)
	player._update_lock_on(0.4)
	_check(player._lock_target == null, "wall breaks obscured lock")
	player._acquire_lock_target()
	_check(player._lock_target == null, "cannot acquire through wall")
	wall.queue_free()


func _remote_checks() -> void:
	var remote = load("res://multiplayer/remote_player.tscn").instantiate()
	remote.character_class = 0
	remote.player_id = 73
	add_child(remote)
	await _frames(3)
	_check(remote._anim_player.has_animation("paladin/Attack2"),
			"remote player loads finisher")
	remote.current_anim_name = "armed/Attack2"
	remote._update_animation()
	_check(is_equal_approx(remote._anim_player.get_playing_speed(),
			remote._anim_player.get_animation("paladin/Attack2").length / player.COMBO_DURATIONS[2]),
			"remote finisher matches local duration")
	remote._start_spell_vfx()
	remote._stop_spell_vfx()
	remote.queue_free()
	await get_tree().process_frame


func _poise_checks() -> void:
	var bobba = load("res://enemies/bobba.tscn").instantiate()
	add_child(bobba)
	bobba.set_physics_process(false)
	bobba.set_process(false)
	bobba.is_blocking = false
	var attack := preload("res://combat/attack_data.gd").new()
	attack.damage = 90
	attack.poise_damage = 60
	attack.apply_to(bobba, player)
	_check(bobba._poise.current_poise == 40, "finisher applies authored poise damage")
	attack.apply_to(bobba, player)
	_check(bobba._poise.current_poise == 100 and bobba._stun_timer > 0.333,
			"repeated heavy blows stagger enemy")
	bobba.queue_free()
	await get_tree().process_frame


func _lighting_checks() -> void:
	var stage := Node3D.new()
	add_child(stage)
	var world := WorldEnvironment.new()
	world.environment = Environment.new()
	stage.add_child(world)
	var sun := DirectionalLight3D.new()
	stage.add_child(sun)
	var moon := Node3D.new()
	moon.name = "Moon"
	stage.add_child(moon)
	var light := preload("res://stage/lighting_manager.gd").new()
	light.transition_duration = 0.06
	stage.add_child(light)
	var daylight := world.environment.ambient_light_energy
	light.set_time(1)
	_check(is_equal_approx(world.environment.ambient_light_energy, daylight),
			"lighting transition starts at current brightness")
	await get_tree().create_timer(0.1).timeout
	_check(is_equal_approx(world.environment.ambient_light_energy, 0.55),
			"lighting transition reaches night preset")
	light.set_time(0, true)
	stage.queue_free()
	await get_tree().process_frame
