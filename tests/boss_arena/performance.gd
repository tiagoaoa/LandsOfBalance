#Fixed view, fixed simulation seed, wall-clock timings even under physics overload.
extends Node3D

var arena: BossArena
var frames := PackedFloat32Array()
var start := 0
var previous := 0
var gpu := 0.0
var physics := 0.0
var draws := 0.0
var triangles := 0.0
var cape := 0.0


func _ready() -> void:
	seed(301)
	var win := get_window()
	#Match the baseline's actual viewport, independent of desktop tiling.
	win.content_scale_size = Vector2i(1382, 720)
	win.content_scale_mode = Window.CONTENT_SCALE_MODE_VIEWPORT
	win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	get_node("/root/RenderScaler").enabled = false
	win.scaling_3d_scale = 1.0
	arena = load("res://tests/boss_arena/boss_arena.tscn").instantiate()
	add_child(arena)
	await get_tree().process_frame
	arena.set_process(false)
	arena.set_physics_process(false)
	for p in arena.party():
		p.set_physics_process(false)
		for ai in p.find_children("CompanionAI", "Node", true, false):
			ai.process_mode = Node.PROCESS_MODE_DISABLED
		p.position = Vector3(-2 if p.is_paladin() else 2, 0, 3)
	arena.boss._start(arena.boss.Act.IDLE, 10000.0)
	var cam := Camera3D.new()
	cam.far = 600.0
	cam.fov = 65.0
	add_child(cam)
	cam.look_at_from_position(Vector3(16, 12, 24), Vector3(0, 6, -10))
	cam.make_current()
	RenderingServer.viewport_set_measure_render_time(win.get_viewport_rid(), true)
	if OS.get_environment("LOB_GPU_REVIEW") == "1":
		await _gpu_review()
		get_tree().quit()
		return
	start = Time.get_ticks_usec()
	previous = start


func _process(_delta: float) -> void:
	if start == 0:
		return
	var now := Time.get_ticks_usec()
	var elapsed := (now - start) / 1000000.0
	var ms := (now - previous) / 1000.0
	previous = now
	if elapsed < 6.0:
		return
	frames.append(ms)
	gpu += RenderingServer.viewport_get_measured_render_time_gpu(get_viewport().get_viewport_rid())
	physics += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	draws += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	triangles += Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
	for node in get_tree().get_nodes_in_group("perf_cape"):
		cape += node.step_usec / 1000.0
	if elapsed >= 26.0:
		set_process(false)
		await _finish()


func _finish() -> void:
	var count := frames.size()
	var total := 0.0
	for ms in frames:
		total += ms
	frames.sort()
	print("ARENA PERF viewport=%s scale=1.0 hz=%d frames=%d fps=%.2f median=%.2f p95=%.2f gpu=%.2f physics=%.2f cape=%.2f draws=%.0f triangles=%.0f" % [
			get_viewport().get_visible_rect().size, Engine.physics_ticks_per_second, count, count * 1000.0 / total,
			frames[count / 2], frames[int(count * 0.95)], gpu / count,
			physics / count, cape / count, draws / count, triangles / count])
	var out := OS.get_environment("LOB_PERF_SHOT")
	if out != "" and DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(out)
	get_tree().quit()


func _gpu_review() -> void:
	arena.boss.set_physics_process(false)
	for p in arena.party():
		p.process_mode = Node.PROCESS_MODE_DISABLED
	var env: Environment = arena.get_node("WorldEnvironment").environment
	var vp := get_viewport()
	var features := {
		"fog_resolution": func(on: bool) -> void:
			RenderingServer.environment_set_volumetric_fog_volume_size(128 if on else 64, 64),
		"volumetric_fog": func(on: bool) -> void: env.volumetric_fog_enabled = on,
		"msaa": func(on: bool) -> void: vp.msaa_3d = Viewport.MSAA_2X if on else Viewport.MSAA_DISABLED,
		"glow": func(on: bool) -> void: env.glow_enabled = on,
		"shadow_filter": func(on: bool) -> void:
			RenderingServer.directional_soft_shadow_filter_set_quality(
				RenderingServer.SHADOW_QUALITY_SOFT_MEDIUM if on else RenderingServer.SHADOW_QUALITY_SOFT_LOW),
	}
	for key: String in features:
		var samples := []
		for on: bool in [true, false, true]:
			features[key].call(on)
			for k in 30:
				await RenderingServer.frame_post_draw
			var total := 0.0
			for k in 90:
				await RenderingServer.frame_post_draw
				total += RenderingServer.viewport_get_measured_render_time_gpu(vp.get_viewport_rid())
			samples.append(total / 90)
		print("ARENA GPU ", key, " on/off/on ms=", samples)
