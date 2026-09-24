extends Node3D

var failures := 0
var paladin: CharacterBody3D
var archer: CharacterBody3D
var camera: Camera3D


func _ready() -> void:
	_environment()
	_bank_checks()
	_voice_checks()
	await _spell_checks()
	if "--capture-presentation" in OS.get_cmdline_user_args():
		await _record_demo()
	print("[Presentation] failures=%d" % failures)
	Sfx.muted = true
	_stop_audio(get_tree().root)
	await get_tree().create_timer(.1).timeout
	get_tree().quit(1 if failures else 0)


func _check(ok: bool, label: String) -> void:
	print("[Presentation] %s %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		failures += 1


func _bank_checks() -> void:
	var healthy := true
	for event in Sfx.BANK:
		for stream in Sfx.BANK[event]:
			healthy = healthy and stream is AudioStreamWAV and stream.get_length() > .02
	_check(healthy, "every event has playable recordings")
	var last: AudioStream
	var repeats := 0
	for i in range(30):
		var stream: AudioStream = Sfx._get_stream("hit_flesh")
		repeats += int(stream == last)
		last = stream
	_check(repeats == 0, "successive impacts never repeat the same recording")
	var loop: AudioStreamWAV = Sfx._get_stream("river_loop", true)
	var shot: AudioStreamWAV = Sfx._get_stream("river_loop", false)
	_check(loop != shot and shot.loop_mode == AudioStreamWAV.LOOP_DISABLED,
			"loop setup does not mutate one-shot resources")
	_check(loop.loop_end == roundi(loop.get_length() * loop.mix_rate),
			"loop length uses sample frames")
	var buses := true
	for bus in ["Combat", "Magic", "Foley", "Ambience"]:
		buses = buses and AudioServer.get_bus_index(bus) > 0
	_check(buses, "combat, magic, movement and ambience have separate mixer buses")
	_check(AudioServer.get_bus_effect(0, 0) is AudioEffectHardLimiter,
			"master mix protects against clipping")


func _voice_checks() -> void:
	Sfx.play3d("hit_flesh", Vector3.ZERO)
	Sfx.play3d("hit_flesh", Vector3.ZERO)
	_check(_playing() == 1, "duplicate contact reports produce one impact")
	for p in Sfx._pool:
		p.stream = Sfx._get_stream("parry_ring")
		p.set_meta("event", "parry_ring")
		p.set_meta("priority", 3)
		p.set_meta("started", Time.get_ticks_msec())
		p.play()
	Sfx.play3d("step_grass", Vector3(3, 0, 0))
	var protected := true
	for p in Sfx._pool:
		protected = protected and p.get_meta("event") == "parry_ring"
	_check(protected, "footsteps cannot steal critical combat voices")
	_stop_audio(Sfx)
	var owner := Node3D.new()
	add_child(owner)
	var loop: AudioStreamPlayer3D = Sfx.loop3d("fire_crackle_loop", owner)
	_check(loop.get_parent() == owner and loop.bus == &"Ambience",
			"environment loops follow their owner and ambience bus")
	owner.queue_free()


func _playing() -> int:
	var count := 0
	for p in Sfx._pool:
		count += int(p.playing)
	return count


func _spell_checks() -> void:
	for i in range(2):
		var actor = load("res://player/player.tscn").instantiate()
		actor.is_ai_companion = true
		actor.companion_class_override = i
		actor.enable_multiplayer = false
		add_child(actor)
		actor.position = Vector3(-3.2 + i * 6.4, .02, 0)
		actor.set_physics_process(false)
		actor._character_model.rotation.y = 0.0
		if i == 0:
			paladin = actor
		else:
			archer = actor
	camera.current = true
	_hide_ui(get_tree().root)
	await get_tree().process_frame
	for actor in [paladin, archer]:
		actor.is_casting = true
		actor._start_spell_effects()
		actor._current_anim_player.play(actor._get_current_mode_prefix() + "/SpellCast")
	_check(paladin._spell_audio.active and paladin._spell_audio.channel.playing,
			"paladin channels audible lightning")
	_check(archer._spell_audio.active and archer._spell_audio.channel.playing,
			"archer channels audible fire")
	var fire: GPUParticles3D = archer._fire_circle_particles[0]
	_check(fire.amount >= 40 and fire.lifetime >= 1.0
			and fire.process_material.initial_velocity_max >= 3.0,
			"fire ring has dense, rising flames")
	_check(paladin._rising_sparks.amount >= 90 and paladin._lightning_bolts_3d.size() >= 7,
			"lightning has a denser vertical spark and arc field")
	var tall := true
	for arc in paladin._lightning_bolts_3d:
		tall = tall and arc.end.y >= 2.4
	_check(tall, "lightning reaches above the caster")
	await get_tree().create_timer(1.1).timeout
	await _capture("spells")
	for actor in [paladin, archer]:
		actor._stop_spell_effects()
		actor.is_casting = false
	_check(not paladin._spell_audio.active and not archer._spell_audio.active,
			"spell release stops both channel sounds")
	await get_tree().create_timer(.5).timeout
	_check(paladin._spell_audio.get_child_count() == 0 and archer._spell_audio.get_child_count() == 0,
			"channel fade releases audio voices")
	var remote := preload("res://multiplayer/remote_player.gd").new()
	remote.character_class = 1
	add_child(remote)
	remote.set_physics_process(false)
	remote._start_spell_vfx()
	_check(remote._spell_audio.channel.playing
			and remote._fire_circle_particles[0].amount == fire.amount,
			"remote fire uses the same sound and flame density")
	remote._stop_spell_vfx()
	remote.queue_free()


func _record_demo() -> void:
	_stop_audio(Sfx)
	var record := AudioEffectRecord.new()
	AudioServer.add_bus_effect(0, record)
	record.set_recording_active(true)
	for i in range(4):
		Sfx.play3d("step_concrete", Vector3.ZERO, -4.0)
		Sfx.play3d("armor_step", Vector3.UP, -12.0)
		await get_tree().create_timer(.4).timeout
	for i in range(3):
		Sfx.play3d("sword_whoosh_%d" % (i + 1), Vector3.UP, -4.0)
		await get_tree().create_timer(.12).timeout
		Sfx.play3d("hit_metal" if i < 2 else "parry_ring", Vector3.UP, -3.0)
		await get_tree().create_timer(.55).timeout
	Sfx.play3d("bow_draw", Vector3.UP, -7.0)
	await get_tree().create_timer(.45).timeout
	Sfx.play3d("bow_release", Vector3.UP, -3.0)
	await get_tree().create_timer(.25).timeout
	Sfx.play3d("arrow_impact_wood", Vector3(1, 1, -2), -3.0)
	await get_tree().create_timer(.6).timeout
	for actor in [paladin, archer]:
		actor._spell_audio.start(actor == archer)
		await get_tree().create_timer(2.0).timeout
		actor._spell_audio.stop()
		await get_tree().create_timer(1.0).timeout
	record.set_recording_active(false)
	var wav := record.get_recording()
	_check(wav != null and wav.data.size() > 48000, "recorded the mixed sound demonstration")
	if wav:
		wav.save_to_wav("/tmp/lob-audio-demo.wav")
	AudioServer.remove_bus_effect(0, AudioServer.get_bus_effect_count(0) - 1)


func _environment() -> void:
	var world := WorldEnvironment.new()
	world.environment = Environment.new()
	world.environment.background_mode = Environment.BG_COLOR
	world.environment.background_color = Color(.035, .045, .06)
	world.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	world.environment.ambient_light_energy = .5
	world.environment.tonemap_mode = Environment.TONE_MAPPER_ACES
	world.environment.glow_enabled = true
	add_child(world)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-35, -25, 0)
	sun.light_energy = 1.0
	add_child(sun)
	var floor := CSGBox3D.new()
	floor.size = Vector3(40, .2, 40)
	floor.position.y = -.1
	floor.use_collision = true
	add_child(floor)
	camera = Camera3D.new()
	add_child(camera)
	camera.position = Vector3(7, 4.8, 12)
	camera.look_at(Vector3(0, 2, 0))
	camera.fov = 48
	camera.current = true
	var listener := AudioListener3D.new()
	add_child(listener)
	listener.position = Vector3(0, 1.6, 4)
	listener.make_current()


func _capture(label: String) -> void:
	if "--capture-presentation" not in OS.get_cmdline_user_args():
		return
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("/tmp/lob-presentation-%s.png" % label)


func _hide_ui(node: Node) -> void:
	if node is CanvasLayer:
		node.visible = false
	for child in node.get_children():
		_hide_ui(child)


func _stop_audio(node: Node) -> void:
	if node is AudioStreamPlayer or node is AudioStreamPlayer3D:
		node.stop()
		node.stream = null
	for child in node.get_children():
		_stop_audio(child)
