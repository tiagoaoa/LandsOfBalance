extends "res://tests/combat_arena/arena.gd"

var title: Label
var clock := 0.0
var running := false
var next_attack := 0.0
var dodged := false
var counters := 0
var damage_received := 0.0
var last_hp := 150.0
var player_view := false
var peak_frame_ms := 0.0


func _ready() -> void:
	get_tree().root.content_scale_size = Vector2i(1280, 720)
	get_tree().root.content_scale_mode = Window.CONTENT_SCALE_MODE_VIEWPORT
	super._ready()
	# This scripted review never supplies a human rating or writes the fun log.
	_rating_pending = true
	await get_tree().process_frame
	await get_tree().process_frame
	_player.ai_driven = true
	_player.global_position = Vector3(0, 0.02, 0)
	_player._character_model.rotation.y = PI
	_player._camera_pivot.rotation.y = 0
	_player.camera_rotation = Vector2.ZERO
	_player._spawn_immunity_timer = 0
	_bobba.global_position = Vector3(0, 0.02, -3.3)
	_bobba._model.rotation.y = 0
	_bobba.target = _player
	_player._lock_target = _bobba
	_player._show_lock_indicator()
	# A side view shows both the blade and the dodge destination.
	var camera := Camera3D.new()
	add_child(camera)
	camera.position = Vector3(5.2, 3.0, 5.5)
	camera.look_at(Vector3(0, 1.2, -1.3))
	camera.fov = 48
	camera.current = true
	_round_label.text = "COMBAT REVIEW"
	title = Label.new()
	title.position = Vector2(24, 100)
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_outline_color", Color.BLACK)
	title.add_theme_constant_override("outline_size", 5)
	_round_label.get_parent().add_child(title)
	await get_tree().create_timer(0.5).timeout
	running = true


func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	if not running:
		return
	clock += delta
	if clock > 12.0 and not player_view:
		player_view = true
		_player._camera.current = true
	peak_frame_ms = maxf(peak_frame_ms, Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
	var hp: float = _player.current_health
	damage_received += maxf(0, last_hp - hp)
	last_hp = hp
	_player._ai_move_vec = Vector2.ZERO
	_player._ai_block = false
	if clock > 24 or _bobba.health <= 0 or _player.is_dead:
		print("[CombatReview] elapsed=%.2f counters=%d boss_hp=%.0f player_hp=%.0f damage_received=%.0f peak_frame_ms=%.1f" % [
				clock, counters, _bobba.health, hp, damage_received, peak_frame_ms])
		running = false
		_finish_review.call_deferred()
		return
	var offset: Vector3 = _bobba.global_position - _player.global_position
	var dist := offset.length()
	var busy: bool = _player.is_rolling or _player._is_stunned or _player.is_attacking
	if _bobba.state == _bobba.State.ATTACKING:
		var progress: float = _bobba._attack_anim_progress
		var start: float = _bobba._current_attack_data().window.x
		if progress < 0.08:
			dodged = false
		title.text = "Read the windup, dodge across the strike"
		if not dodged and not busy and progress > start - 0.065:
			_player._ai_move_vec = Vector2(1, -0.2)
			_player._try_dodge()
			dodged = _player.is_rolling
	elif _bobba._punish_left > 0 or _bobba.state == _bobba.State.STUNNED or _bobba.attack_cooldown > 0:
		title.text = "Counter during recovery  |  Heavy blows break posture"
		if dist > 1.5 and not busy:
			_player._ai_move_vec = Vector2(0, -1)
		elif not busy and clock > next_attack and _player._stamina.current_stamina >= 32:
			_player._do_attack(counters % 3 == 0)
			if _player.is_attacking:
				counters += 1
				next_attack = clock + 0.3
	else:
		title.text = "Release guard to recover stamina"
		if dist > 2.7 and not busy:
			_player._ai_move_vec = Vector2(0, -0.7)


func _finish_review() -> void:
	for voice in Sfx._pool:
		voice.stop()
		voice.stream = null
	for child in get_children():
		child.queue_free()
	var until := Time.get_ticks_usec() + 150000
	while Time.get_ticks_usec() < until:
		await get_tree().process_frame
	get_tree().quit()
