extends Node3D

var actor: CharacterBody3D
var cape: SkeletonModifier3D
var camera: Camera3D
var moving := Vector3.ZERO
var turn := 0.0
var failures := 0
var costs: Array[int] = []
var paladin := false
var anim_class := "archer"


func _ready() -> void:
	_environment()
	Sfx.muted = true
	paladin = "--paladin-cape" in OS.get_cmdline_user_args()
	anim_class = "paladin" if paladin else "archer"
	actor = load("res://player/player.tscn").instantiate()
	actor.is_ai_companion = true
	actor.companion_class_override = 0 if paladin else 1
	actor.enable_multiplayer = false
	add_child(actor)
	actor.set_physics_process(false)
	actor._character_model.rotation.y = 0
	actor._play_anim(anim_class + "/Idle")
	var model: Node3D = actor._armed_character if paladin else actor._archer_character
	cape = model.find_child("Cape", true, false)
	_hide_ui(get_tree().root)
	camera.current = true
	await get_tree().create_timer(2.0).timeout
	_check(cape != null and cape.points.size() > 0, anim_class + " has simulated cloth")
	_check(_old_mantle_replaced(model), "rigid mantle replaced while preserving armor")
	if paladin:
		_check(actor._unarmed_character.find_child("Cape", true, false) != null,
				"unarmed paladin also has cloth")
	_check(_anchors() < .002, "cape seam follows the animated shoulders")
	_check(_penetration() < .025, "resting cloth clears the body collision volumes")
	var idle := _hem()
	await _capture("idle")
	moving = Vector3(0, 0, 5)
	actor._play_anim(anim_class + "/Run")
	await get_tree().create_timer(1.4).timeout
	_check(_hem().distance_to(idle) > .08, "running changes the free hem through inertia and drag")
	await _capture("run")
	moving = Vector3(5, 0, 0)
	turn = PI * .5
	await get_tree().create_timer(.35).timeout
	await _capture("turn")
	await get_tree().create_timer(.65).timeout
	moving = Vector3.ZERO
	actor._play_anim(anim_class + "/Idle")
	await get_tree().create_timer(1.7).timeout
	await _capture("settled")
	_check(_bounded(), "cloth stays finite and within its tether lengths after turning")
	_check(_penetration() < .025, "cloth clears the torso and legs after turning")
	_check(_anchors() < .002, "turning preserves the shoulder attachment")
	actor.global_position += Vector3(80, 10, -50)
	await get_tree().create_timer(.1).timeout
	_check(_bounded(), "teleport resets the cloth without stretching")
	actor._character_model.rotation.x = -PI * .5
	actor._play_anim(anim_class + "/Roll")
	await get_tree().create_timer(.6).timeout
	_check(_bounded(), "cloth stays stable through a tumble")
	actor._character_model.rotation.x = 0
	actor._play_anim(anim_class + "/Idle")
	actor.global_position = Vector3.ZERO
	await get_tree().create_timer(.8).timeout
	actor.set_process(false)
	actor._character_model.position.y = .3
	actor._character_model.rotation.x = -PI * .5
	await get_tree().create_timer(.8).timeout
	var clear := true
	for p in cape.points:
		clear = clear and p.y >= -.02
	_check(clear, "low cloth stays above the floor")
	actor._character_model.rotation.x = 0
	actor._character_model.position.y = 0
	var remote := preload("res://multiplayer/remote_player.gd").new()
	remote.character_class = 0 if paladin else 1
	add_child(remote)
	await get_tree().create_timer(.2).timeout
	_check(remote.find_child("Cape", true, false) != null, "remote character uses the same cloth")
	_check(_old_mantle_replaced(remote), "remote appearance preserves the mantle replacement")
	remote.queue_free()
	costs.sort()
	print("[Cape] solver median=%dus p95=%dus" % [costs[costs.size() / 2], costs[int(costs.size() * .95)]])
	print("[Cape] failures=%d" % failures)
	get_tree().quit(1 if failures else 0)


func _process(delta: float) -> void:
	if actor:
		actor.global_position += moving * delta
		actor._character_model.rotation.y = lerp_angle(actor._character_model.rotation.y, turn, minf(12.0 * delta, 1.0))
		var basis: Basis = actor._character_model.global_basis
		camera.global_position = actor.global_position + basis * Vector3(1.5, 1.65, -3.2)
		camera.look_at(actor.global_position + Vector3(0, 1.05, 0))
	if cape and cape.step_usec > 0:
		costs.append(cape.step_usec)


func _hem() -> Vector3:
	return actor._character_model.to_local(cape.points[cape.points.size() - 7])


func _old_mantle_replaced(model: Node3D) -> bool:
	var old := model.find_child("Armor and mantle", true, false) as MeshInstance3D
	if not paladin:
		return not old.visible
	if not old.visible:
		return false
	var wool := false
	var steel := false
	for i in range(old.mesh.get_surface_count()):
		var mat := old.mesh.surface_get_material(i)
		if mat.resource_name == "Weathered wool":
			wool = old.get_surface_override_material(i) is ShaderMaterial
		if mat.resource_name == "Tempered steel":
			steel = old.get_active_material(i) is StandardMaterial3D
	return wool and steel


func _anchors() -> float:
	var error := 0.0
	for i in range(cape.COLS):
		error = maxf(error, cape.points[i].distance_to(cape.anchors[i]))
	return error


func _bounded() -> bool:
	for i in range(cape.points.size()):
		if not cape.points[i].is_finite():
			return false
		if cape.points[i].distance_to(cape.points[i % cape.COLS]) > 1.3:
			return false
	return true


func _penetration() -> float:
	var depth := 0.0
	for i in range(cape.COLS, cape.points.size()):
		for k in range(cape.starts.size()):
			var span: Vector3 = cape.ends[k] - cape.starts[k]
			var t: float = clampf((cape.points[i] - cape.starts[k]).dot(span) / maxf(span.length_squared(), .0001), 0, 1)
			var center: Vector3 = cape.starts[k] + span * t
			depth = maxf(depth, cape.radii[k] - cape.points[i].distance_to(center))
	return depth


func _check(ok: bool, label: String) -> void:
	print("[Cape] %s %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		failures += 1


func _capture(label: String) -> void:
	if "--capture-cape" not in OS.get_cmdline_user_args():
		return
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("/tmp/lob-%s-cape-%s.png" % [anim_class, label])


func _environment() -> void:
	get_window().mode = Window.MODE_WINDOWED
	get_window().size = Vector2i(1280, 900)
	var world := WorldEnvironment.new()
	world.environment = Environment.new()
	world.environment.background_mode = Environment.BG_COLOR
	world.environment.background_color = Color(.065, .08, .095)
	world.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	world.environment.ambient_light_color = Color(.72, .79, .9)
	world.environment.ambient_light_energy = .55
	world.environment.tonemap_mode = Environment.TONE_MAPPER_ACES
	world.environment.ssao_enabled = true
	add_child(world)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-40, -30, 0)
	sun.light_color = Color(1, .9, .78)
	sun.light_energy = 1.8
	sun.shadow_enabled = true
	add_child(sun)
	var rim := DirectionalLight3D.new()
	rim.rotation_degrees = Vector3(-25, 140, 0)
	rim.light_color = Color(.7, .8, 1)
	rim.light_energy = 1.1
	add_child(rim)
	var floor := CSGBox3D.new()
	floor.size = Vector3(200, .1, 200)
	floor.position.y = -.05
	floor.use_collision = true
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(.13, .15, .13)
	mat.roughness = 1.0
	floor.material = mat
	add_child(floor)
	camera = Camera3D.new()
	camera.fov = 38
	add_child(camera)


func _hide_ui(node: Node) -> void:
	if node is CanvasLayer:
		node.visible = false
	for child in node.get_children():
		_hide_ui(child)
