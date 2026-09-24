extends Node

## Frame-time probe. Idle unless the game is launched with --perf-probe.
##
## Smoothness is not average FPS: a run that averages 60 but drops one
## 50 ms frame a second FEELS worse than a steady 45. So every window
## reports the frame-time spread (p50 / p95 / p99 / worst) next to the
## CPU split and what the renderer was asked to draw, and at the end the
## census of every node that is still ticking — the list that says which
## systems are paying rent while nobody is looking at them.
##
##   godot --path . -- --singleplayer --combat-scenario=WATCH --perf-probe
##   LOB_PERF_SECONDS=60 tools/perf_probe.sh
##
## Lines are prefixed "PERF" so a log can be grepped straight into a table.

const WINDOW_SECONDS := 5.0

var _active := false
var _run_seconds := 0.0
var _warmup := 6.0
var _elapsed := 0.0
var _window_t := 0.0
var _frames: PackedFloat32Array = PackedFloat32Array()
var _all_frames: PackedFloat32Array = PackedFloat32Array()
var _proc_sum := 0.0
var _phys_sum := 0.0
var _draw_sum := 0.0
var _prim_sum := 0.0
var _obj_sum := 0.0
var _samples := 0
var _finishing := false
var _cape_sum := 0.0
var _gpu_sum := 0.0
var _rcpu_sum := 0.0


func _ready() -> void:
	var args := OS.get_cmdline_user_args() + OS.get_cmdline_args()
	if not "--perf-probe" in args:
		set_process(false)
		return
	_active = true
	process_mode = Node.PROCESS_MODE_ALWAYS
	_run_seconds = float(OS.get_environment("LOB_PERF_SECONDS")) \
			if OS.get_environment("LOB_PERF_SECONDS") != "" else 0.0
	# Uncapped, so the numbers say what the frame COSTS rather than what
	# the monitor's refresh rate allows.
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	# LOB_PERF_SCALE=0.25 renders 3D at a quarter resolution: if the frame
	# barely moves the game is CPU-bound, if it collapses the GPU was.
	if OS.get_environment("LOB_PERF_SCALE") != "":
		var scaler := get_node_or_null("/root/RenderScaler")
		if scaler:
			scaler.enabled = false
		get_viewport().scaling_3d_scale = float(OS.get_environment("LOB_PERF_SCALE"))
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	print("PERF probe armed (window %.0fs, run %s)" % [WINDOW_SECONDS,
			"%.0fs" % _run_seconds if _run_seconds > 0.0 else "until quit"])


func _process(delta: float) -> void:
	if not _active:
		return
	_elapsed += delta
	if _elapsed < _warmup:
		return   # loading hitches are a different problem
	var ms := delta * 1000.0
	_frames.append(ms)
	_all_frames.append(ms)
	_proc_sum += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	_phys_sum += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	_draw_sum += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	_prim_sum += Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
	_obj_sum += Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)
	_samples += 1
	_cape_sum += _cape_usec()
	_gpu_sum += RenderingServer.viewport_get_measured_render_time_gpu(get_viewport().get_viewport_rid())
	_rcpu_sum += RenderingServer.viewport_get_measured_render_time_cpu(get_viewport().get_viewport_rid()) \
			+ RenderingServer.get_frame_setup_time_cpu()
	_window_t += delta
	if _window_t >= WINDOW_SECONDS:
		_report_window()
	if _run_seconds > 0.0 and _elapsed >= _run_seconds + _warmup and not _finishing:
		_finishing = true
		if OS.get_environment("LOB_PERF_SHOT") != "":
			get_viewport().get_texture().get_image().save_png(OS.get_environment("LOB_PERF_SHOT"))
		_report_final()
		if "--perf-ablate" in OS.get_cmdline_user_args():
			await _ablate()
		if "--perf-gpu" in OS.get_cmdline_user_args():
			await _ablate_gpu()
		get_tree().quit()


func _notification(what: int) -> void:
	if _active and what == NOTIFICATION_WM_CLOSE_REQUEST:
		_report_final()


func _report_window() -> void:
	var n := maxf(_samples, 1)
	var cam := get_viewport().get_camera_3d()
	print("PERF t=%5.1f fps=%5.1f frame p50=%5.2f p95=%5.2f p99=%5.2f max=%6.2f | gpu=%5.2f rcpu=%5.2f scale=%.2f | cpu proc=%5.2f phys=%5.2f | draws=%5.0f prims=%7.0fk objs=%4.0f | cape=%4.2fms nodes=%d cam=%s" % [
			_elapsed - _warmup, _frames.size() / _window_t,
			_pct(_frames, .50), _pct(_frames, .95), _pct(_frames, .99), _pct(_frames, 1.0),
			_gpu_sum / n, _rcpu_sum / n, get_viewport().scaling_3d_scale, _proc_sum / n, _phys_sum / n,
			_draw_sum / n, _prim_sum / n / 1000.0, _obj_sum / n, _cape_sum / n / 1000.0,
			int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
			str(cam.global_position.snapped(Vector3.ONE)) if cam else "-"])
	_frames.clear()
	_window_t = 0.0
	_proc_sum = 0.0
	_phys_sum = 0.0
	_draw_sum = 0.0
	_prim_sum = 0.0
	_obj_sum = 0.0
	_samples = 0
	_cape_sum = 0.0
	_gpu_sum = 0.0
	_rcpu_sum = 0.0


func _report_final() -> void:
	if _all_frames.is_empty():
		return
	var total := 0.0
	for f in _all_frames:
		total += f
	var hitches := 0
	for f in _all_frames:
		if f > 33.3:
			hitches += 1
	print("PERF VIEW %s scale3d=%.2f window=%s driver=%s gpu=%s (%s)" % [
			str(get_viewport().get_visible_rect().size), get_viewport().scaling_3d_scale,
			str(DisplayServer.window_get_size()), DisplayServer.get_name(),
			RenderingServer.get_video_adapter_name(), RenderingServer.get_video_adapter_type()])
	print("PERF SUMMARY frames=%d avg_fps=%.1f p50=%.2f p95=%.2f p99=%.2f max=%.2f hitches>33ms=%d" % [
			_all_frames.size(), _all_frames.size() / (total / 1000.0),
			_pct(_all_frames, .50), _pct(_all_frames, .95), _pct(_all_frames, .99),
			_pct(_all_frames, 1.0), hitches])
	_census()


## Who is ticking: every node with _process or _physics_process switched on,
## grouped by script (or class when it has none).
func _census() -> void:
	var proc := {}
	var phys := {}
	var stack: Array[Node] = [get_tree().root]
	var meshes := 0
	var lights := 0
	var particles := 0
	var tris := {}
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		var key := node.get_class()
		var script: Script = node.get_script()
		if script:
			key = script.resource_path.get_file()
		if node.is_processing_internal() and not script:
			key = "[int]" + key
		if node.is_processing() or node.is_processing_internal():
			proc[key] = int(proc.get(key, 0)) + 1
		if node.is_physics_processing() or node.is_physics_processing_internal():
			phys[key] = int(phys.get(key, 0)) + 1
		if node is MeshInstance3D or node is MultiMeshInstance3D:
			meshes += 1
		elif node is Light3D:
			lights += 1
		elif node is GPUParticles3D or node is CPUParticles3D:
			particles += 1
		if node is GeometryInstance3D and node.is_visible_in_tree():
			_count_tris(node, tris)
		for child in node.get_children():
			stack.append(child)
	var heavy := tris.keys()
	heavy.sort_custom(func(a, b) -> bool: return tris[a] > tris[b])
	for i in mini(heavy.size(), 18):
		print("PERF TRIS %8.0fk  %s" % [tris[heavy[i]] / 1000.0, heavy[i]])
	for kind in ["AnimationMixer", "Skeleton3D"]:
		for m in get_tree().root.find_children("*", kind, true, false):
			var n3 := m as Node
			var vis := true
			var p := n3.get_parent()
			while p:
				if p is Node3D and not (p as Node3D).visible:
					vis = false
					break
				p = p.get_parent()
			var active: bool = m.active if "active" in m else true
			print("PERF RIG %-14s visible=%-5s active=%-5s proc=%s  %s" % [m.get_class(), vis, active,
					m.can_process(), str(n3.get_path()).trim_prefix("/root/Game/")])
	for sv in get_tree().root.find_children("*", "SubViewport", true, false):
		var v := sv as SubViewport
		print("PERF VIEWPORT %s size=%s update=%d 3d=%s own_world=%s in_visible=%s" % [
				str(v.get_path()).trim_prefix("/root/"), str(v.size), v.render_target_update_mode,
				not v.disable_3d, v.own_world_3d,
				v.get_parent() is CanvasItem and (v.get_parent() as CanvasItem).is_visible_in_tree()])
	print("PERF CENSUS meshes=%d lights=%d particles=%d" % [meshes, lights, particles])
	for label in ["process", "physics"]:
		var table: Dictionary = proc if label == "process" else phys
		var keys := table.keys()
		keys.sort_custom(func(a, b) -> bool: return table[a] > table[b])
		var parts: PackedStringArray = []
		for k in keys:
			parts.append("%s×%d" % [k, table[k]])
		print("PERF CENSUS %s: %s" % [label, ", ".join(parts)])


func _pct(values: PackedFloat32Array, q: float) -> float:
	if values.is_empty():
		return 0.0
	var sorted := values.duplicate()
	sorted.sort()
	return sorted[clampi(int(round(q * (sorted.size() - 1))), 0, sorted.size() - 1)]


## Triangles a visible geometry node submits (mesh tris x instances),
## keyed by where it lives so the heavy hitters can be found in the tree.
func _count_tris(node: GeometryInstance3D, tris: Dictionary) -> void:
	var mesh: Mesh = null
	var instances := 1
	if node is MeshInstance3D:
		mesh = node.mesh
	elif node is MultiMeshInstance3D and node.multimesh:
		mesh = node.multimesh.mesh
		instances = node.multimesh.visible_instance_count
		if instances < 0:
			instances = node.multimesh.instance_count
	if mesh == null:
		return
	var n := 0
	for s in mesh.get_surface_count():
		var arr := mesh.surface_get_arrays(s) if not mesh is ArrayMesh \
				else []
		if mesh is ArrayMesh:
			var am := mesh as ArrayMesh
			var idx := am.surface_get_array_index_len(s)
			n += (idx if idx > 0 else am.surface_get_array_len(s)) / 3
		elif not arr.is_empty():
			var ia = arr[Mesh.ARRAY_INDEX]
			n += (ia.size() if ia != null else arr[Mesh.ARRAY_VERTEX].size()) / 3
	var key := "%s  (%s, x%d, range_end=%.0f)" % [
			str(node.get_path()).trim_prefix("/root/"), mesh.resource_path.get_file(),
			instances, node.visibility_range_end]
	tris[key] = int(tris.get(key, 0)) + n * instances


## Ablation: switch off one ticking system at a time and see what the frame
## gives back. The fight never holds still, so each system is toggled
## off/on in alternating short windows and the paired differences averaged —
## drift in the load cancels instead of landing on whoever is measured last.
## Crude (a disabled boss also stops casting spells), but it names the
## culprit in minutes instead of guessing from source.
func _ablate() -> void:
	var groups := {}
	var stack: Array[Node] = [get_tree().root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node != self and node != get_tree().current_scene and not node is SpringArm3D \
				and (node.is_processing() or node.is_physics_processing()
				or node.is_processing_internal() or node.is_physics_processing_internal()):
			var script: Script = node.get_script()
			var key := script.resource_path.get_file() if script else node.get_class()
			if not groups.has(key):
				groups[key] = []
			groups[key].append(node)
		for child in node.get_children():
			stack.append(child)
	for key in groups:
		var nodes: Array = groups[key]
		var gain := Vector2.ZERO
		for cycle in 3:
			var on := await _measure(1.0)
			var saved := []
			for n in nodes:
				if is_instance_valid(n):
					saved.append([n, n.process_mode])
					n.process_mode = Node.PROCESS_MODE_DISABLED
			var off := await _measure(1.0)
			for pair in saved:
				if is_instance_valid(pair[0]):
					pair[0].process_mode = pair[1]
			gain += on - off
		gain /= 3.0
		print("PERF ABLATE %-28s x%-3d saves cpu=%6.2fms frame=%6.2fms" % [
				key, nodes.size(), gain.x, gain.y])


func _measure(seconds: float) -> Vector2:
	await get_tree().process_frame
	var t := 0.0
	var cpu := 0.0
	var frames := 0
	while t < seconds:
		await get_tree().process_frame
		var d := get_process_delta_time()
		t += d
		cpu += (Performance.get_monitor(Performance.TIME_PROCESS)
				+ Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)) * 1000.0
		frames += 1
	return Vector2(cpu / frames, t * 1000.0 / frames)


## Cloth capes time their own solve (cape.gd step_usec); sum this frame's.
func _cape_usec() -> float:
	var total := 0.0
	for cape in get_tree().get_nodes_in_group(&"perf_cape"):
		total += float(cape.step_usec)
	return total


## GPU twin of _ablate: each look feature toggled off/on in alternating
## windows. Only the frame-time column means anything here.
func _ablate_gpu() -> void:
	var vp := get_viewport()
	var env: Environment = vp.world_3d.environment if vp.world_3d else null
	var we := get_tree().root.find_child("WorldEnvironment", true, false) as WorldEnvironment
	if we:
		env = we.environment
	var lights: Array[Light3D] = []
	for n in get_tree().root.find_children("*", "Light3D", true, false):
		lights.append(n)
	var features := {
		"msaa": func(on: bool) -> void: vp.msaa_3d = Viewport.MSAA_2X if on else Viewport.MSAA_DISABLED,
		"volumetric_fog": func(on: bool) -> void: env.volumetric_fog_enabled = on,
		"ssao": func(on: bool) -> void: env.ssao_enabled = on,
		"glow": func(on: bool) -> void: env.glow_enabled = on,
		"fog": func(on: bool) -> void: env.fog_enabled = on,
		"dir_shadows": func(on: bool) -> void:
			for l in lights:
				if is_instance_valid(l) and l is DirectionalLight3D:
					l.set_meta("_pp", l.get_meta("_pp", l.shadow_enabled))
					l.shadow_enabled = on and l.get_meta("_pp"),
		"omni_shadows": func(on: bool) -> void:
			for l in get_tree().root.find_children("*", "OmniLight3D", true, false):
				l.set_meta("_pp", l.get_meta("_pp", l.shadow_enabled))
				l.shadow_enabled = on and l.get_meta("_pp"),
		"soft_shadow_q": func(on: bool) -> void:
			RenderingServer.directional_soft_shadow_filter_set_quality(
					RenderingServer.SHADOW_QUALITY_SOFT_HIGH if on else RenderingServer.SHADOW_QUALITY_SOFT_LOW),
		"soft_shadow_high_vs_med": func(on: bool) -> void:
			RenderingServer.directional_soft_shadow_filter_set_quality(
					RenderingServer.SHADOW_QUALITY_SOFT_HIGH if on else RenderingServer.SHADOW_QUALITY_SOFT_MEDIUM),
		"ssao_med_vs_low": func(on: bool) -> void:
			RenderingServer.environment_set_ssao_quality(
					RenderingServer.ENV_SSAO_QUALITY_MEDIUM if on else RenderingServer.ENV_SSAO_QUALITY_LOW,
					true, 0.5, 2, 50.0, 300.0),
		"aniso": func(on: bool) -> void:
			vp.anisotropic_filtering_level = Viewport.ANISOTROPY_4X if on else Viewport.ANISOTROPY_DISABLED,
		"grass_interactive": func(on: bool) -> void:
			var sg := get_node_or_null("/root/SimpleGrass")
			if sg:
				sg.set_interactive(on),
		"grass": func(on: bool) -> void:
			var g := get_tree().root.find_child("GrassTiles", true, false) as Node3D
			if g:
				g.visible = on,
	}
	print("PERF GPU state msaa=%d vfog=%s ssao=%s glow=%s omni_lights=%d" % [vp.msaa_3d,
			env.volumetric_fog_enabled, env.ssao_enabled, env.glow_enabled,
			get_tree().root.find_children("*", "OmniLight3D", true, false).size()])
	var only := OS.get_environment("LOB_PERF_GPU_ONLY").split(",", false)
	for key in features:
		if not only.is_empty() and not key in only:
			continue
		var toggle: Callable = features[key]
		var gain := 0.0
		for cycle in 3:
			var on := await _measure(1.0)
			toggle.call(false)
			var off := await _measure(1.0)
			toggle.call(true)
			gain += on.y - off.y
		print("PERF GPU %-16s costs frame=%6.2fms" % [key, gain / 3.0])
