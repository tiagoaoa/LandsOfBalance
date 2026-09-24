extends Node3D

var actors: Array[Node3D] = []
var camera: Camera3D


func _ready() -> void:
	_environment()
	_ground()
	for i in range(2):
		var actor = load("res://player/player.tscn").instantiate()
		actor.is_ai_companion = true
		actor.companion_class_override = i
		actor.enable_multiplayer = false
		add_child(actor)
		actor.position = Vector3(-1.15 + i * 2.3, 0.02, 0)
		actors.append(actor)
	await get_tree().process_frame
	for actor in actors:
		actor.set_physics_process(false)
		actor.set_process(false)
		actor._character_model.rotation.y = 0.0
		actor._play_anim(StringName(actor._get_current_mode_prefix() + "/Idle"))
	camera = Camera3D.new()
	add_child(camera)
	camera.position = Vector3(3.1, 2.0, 6.2)
	camera.look_at(Vector3(0, 0.95, 0))
	camera.fov = 38
	camera.current = true
	_hide_ui(get_tree().root)
	await get_tree().create_timer(1.5).timeout
	await _capture("characters")
	for actor in actors:
		actor.is_casting = true
		actor._current_anim_player.play(actor._get_current_mode_prefix() + "/SpellCast")
		actor._start_spell_effects()
	await get_tree().create_timer(0.8).timeout
	await _capture("spells")
	for actor in actors:
		actor._stop_spell_effects()
		actor.is_casting = false
		actor._play_anim(StringName(actor._get_current_mode_prefix() + "/Idle"))
	camera.position = Vector3(-3.0, 2.0, -5.8)
	camera.look_at(Vector3(0, 1.0, 0))
	await get_tree().create_timer(1.6).timeout
	await _capture("mantles")
	await _world_review()
	_stop_audio(get_tree().root)
	await get_tree().create_timer(0.1).timeout
	get_tree().quit()


func _environment() -> void:
	var world := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.065, 0.08, 0.10)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.6, 0.69, 0.8)
	env.ambient_light_energy = 0.55
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.ssao_enabled = true
	env.ssao_intensity = 1.3
	env.glow_enabled = true
	env.glow_bloom = 0.02
	world.environment = env
	add_child(world)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-35, -25, 0)
	sun.light_color = Color(1.0, 0.88, 0.70)
	sun.light_energy = 1.8
	sun.shadow_enabled = true
	add_child(sun)
	var rim := OmniLight3D.new()
	rim.position = Vector3(0, 2.5, -2)
	rim.light_color = Color(0.45, 0.65, 1.0)
	rim.light_energy = 2.5
	rim.omni_range = 6
	add_child(rim)


func _ground() -> void:
	var mesh := CSGBox3D.new()
	mesh.size = Vector3(80, 0.2, 80)
	mesh.position.y = -0.1
	mesh.use_collision = true
	var mat := ShaderMaterial.new()
	mat.shader = load("res://stage/terrain_surface.gdshader")
	var textures := {"soil_color": "Color", "soil_normal": "NormalGL",
		"soil_roughness": "Roughness", "soil_ao": "AmbientOcclusion"}
	for key in textures:
		var file: String = "res://assets/textures/Ground037_1K-JPG_%s.jpg" % textures[key]
		mat.set_shader_parameter(key, load(file))
	mesh.material = mat
	add_child(mesh)


func _capture(label: String) -> void:
	await RenderingServer.frame_post_draw
	var file := "/tmp/lob-souls-%s.png" % label
	get_viewport().get_texture().get_image().save_png(file)
	print("[SoulsShowcase] saved ", file)


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


func _world_review() -> void:
	for child in get_children():
		child.queue_free()
	actors.clear()
	await get_tree().process_frame
	var game = load("res://game.tscn").instantiate()
	add_child(game)
	await get_tree().process_frame
	var player = game.get_node("Player")
	player.set_physics_process(false)
	player.global_position = Vector3(0, 0.55, 8)
	player._character_model.rotation.y = 0.0
	var bobba = game.get_node("Bobba")
	bobba.set_physics_process(false)
	bobba.position = Vector3(5, 0.55, -2)
	camera = Camera3D.new()
	add_child(camera)
	camera.position = Vector3(4, 2.6, 14)
	camera.look_at(Vector3(0, 1.0, 8))
	camera.current = true
	_hide_ui(get_tree().root)
	var light = game.find_child("LightingManager", true, false)
	light.set_time(0, true)
	await get_tree().create_timer(1.5).timeout
	await _capture("world-day")
	light.set_time(1, true)
	await get_tree().create_timer(1.5).timeout
	await _capture("world-night")
