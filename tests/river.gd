extends Node3D

var failures := 0
var river: Node3D
var camera: Camera3D
var sun: DirectionalLight3D
var world: WorldEnvironment


class Walker extends CharacterBody3D:
	func _physics_process(delta: float) -> void:
		velocity.x = 4
		velocity.z = 0
		velocity.y -= 9.8 * delta
		move_and_slide()


func _ready() -> void:
	Sfx.muted = true
	#Use the actual stage's dimensions, material and road transforms.
	var stage: Node3D = load("res://stage/lands_of_balance.tscn").instantiate()
	for label in ["Ground", "Roads", "River"]:
		var node: Node = stage.get_node(label)
		stage.remove_child(node)
		node.owner = null
		add_child(node)
	stage.free()
	river = $River
	_environment()
	for i in range(5):
		await get_tree().physics_frame
	_check(not $Ground/MainGround.use_collision, "original flat ground collision is removed")
	var depth_ok := true
	var land_ok := true
	var banks_ok := true
	var count := 0
	for i in range(65):
		var z: float = lerpf(river.bounds.position.y + .2, river.bounds.end.y - .2, i / 64.0)
		var x: float = river.center_x(z)
		var hit := _ray(x, z, river.water_y - .05)
		if hit.is_empty() or absf(hit.position.y - (river.water_y - 1.4)) >= .003:
			print("[River] depth probe z=", z, " hit=", hit)
		depth_ok = depth_ok and not hit.is_empty() and absf(hit.position.y - (river.water_y - 1.4)) < .003
		if not hit.is_empty():
			count += 1
		for side in [-1.0, 1.0]:
			hit = _ray(x + side * (river.half_width(z) + 5), z)
			land_ok = land_ok and not hit.is_empty() and absf(hit.position.y - river.ground_y) < .003
			hit = _ray(x + side * (river.half_width(z) - 1.25), z, river.water_y - .05)
			if hit.is_empty() or hit.normal.y <= .7 or hit.position.y >= river.water_y or hit.position.y <= river.water_y - 1.4:
				print("[River] bank probe z=", z, " side=", side, " hit=", hit)
			banks_ok = banks_ok and not hit.is_empty() and hit.normal.y > .7 \
					and hit.position.y < river.water_y and hit.position.y > river.water_y - 1.4
	_check(count == 65, "channel collision continues to both map edges")
	_check(depth_ok, "65 centerline probes find a 1.4m-deep riverbed")
	_check(land_ok, "terrain joins both banks with no gaps")
	_check(banks_ok, "both submerged slopes are walkable")
	var bridge_ok: bool = river.bridges.size() == 1
	for bridge in river.bridges:
		var hit := _ray(bridge.position.x, bridge.position.z)
		bridge_ok = bridge_ok and not hit.is_empty() and hit.position.y > river.water_y
	_check(bridge_ok, "road crossings have solid bridges above the water")
	var grass := preload("res://stage/realistic_grass_placer.gd").new()
	grass._river = river
	_check(grass._is_excluded(river.center_x(450), 450)
			and not grass._is_excluded(river.center_x(450) + 25, 450),
			"grass exclusion follows the extended river")
	grass.free()
	await _walk_bank()
	if "--capture-river" in OS.get_cmdline_user_args():
		await get_tree().create_timer(1.5).timeout
		await _capture("day")
		await get_tree().create_timer(1.0).timeout
		await _capture("flow")
		sun.light_color = Color(.55, .68, 1)
		sun.light_energy = .7
		world.environment.ambient_light_energy = .2
		world.environment.background_mode = Environment.BG_COLOR
		world.environment.background_color = Color(.015, .025, .055)
		await get_tree().create_timer(.4).timeout
		await _capture("night")
	print("[River] failures=%d" % failures)
	get_tree().quit(1 if failures else 0)


func _ray(x: float, z: float, from_y: float = 4.0) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(Vector3(x, from_y, z), Vector3(x, -5, z), 1)
	return get_world_3d().direct_space_state.intersect_ray(query)


func _walk_bank() -> void:
	var walker := Walker.new()
	var shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = .3
	capsule.height = 1.7
	shape.shape = capsule
	shape.position.y = .85
	walker.add_child(shape)
	add_child(walker)
	walker.position = Vector3(river.center_x(220), river.water_y - 1.35, 220)
	walker.floor_snap_length = .25
	var lowest := walker.position.y
	for i in range(300):
		await get_tree().physics_frame
		lowest = minf(lowest, walker.position.y)
	_check(lowest > river.water_y - 1.45 and walker.position.y >= river.ground_y - .03,
			"a character can walk out of the channel onto the bank")
	walker.queue_free()


func _check(ok: bool, label: String) -> void:
	print("[River] %s %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		failures += 1


func _capture(label: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("/tmp/lob-river-%s.png" % label)


func _environment() -> void:
	world = WorldEnvironment.new()
	world.environment = Environment.new()
	world.environment.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(.2, .4, .65)
	sky_mat.sky_horizon_color = Color(.7, .76, .8)
	sky.sky_material = sky_mat
	world.environment.sky = sky
	world.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	world.environment.ambient_light_color = Color(.72, .8, 1)
	world.environment.ambient_light_energy = .55
	world.environment.tonemap_mode = Environment.TONE_MAPPER_ACES
	add_child(world)
	sun = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-35, -30, 0)
	sun.light_color = Color(1, .9, .76)
	sun.light_energy = 1.7
	sun.shadow_enabled = true
	add_child(sun)
	camera = Camera3D.new()
	add_child(camera)
	camera.position = Vector3(river.center_x(150) + 10, 5.4, 160)
	camera.look_at(Vector3(river.center_x(135), river.water_y, 135))
	camera.fov = 64
	camera.current = true
