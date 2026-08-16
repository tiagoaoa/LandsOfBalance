extends Node3D

## Bobba animation lab — a scrubber for his clips, including the composed ones.
##
## Built because the composed clips could not be inspected. The combat
## scenarios shoot at night from behind the player, the GEARSIM turntable can
## hold one clip but only from a frozen angle at a fixed rate, and neither
## shows you WHERE in a clip the damage window sits. Chasing the axe swing
## through those cost several rounds of guessing at signs and cadences.
##
## Here: pick any clip, scrub it, slow it down, orbit around it, and see the
## damage window drawn on the timeline so you can check the blade is actually
## travelling when the hitbox goes live.
##
## Launch with tools/run_anim_lab.sh

const BOBBA_SCENE: PackedScene = preload("res://enemies/bobba.tscn")

var _bobba: Node3D
var _anim: AnimationPlayer
var _skeleton: Skeleton3D

# Camera rig
var _pivot: Node3D
var _cam: Camera3D
var _yaw: float = 0.6
var _pitch: float = -0.12
var _dist: float = 6.5
var _height: float = 1.5
var _dragging: bool = false

# UI
var _clip_list: ItemList
var _time_slider: HSlider
var _speed_slider: HSlider
var _info: Label
var _timeline: Control
var _loop_check: CheckBox
var _axe_check: CheckBox
var _play_btn: Button
var _scrubbing: bool = false
var _current_clip: String = ""
## {clip_name: Vector2(window_start, window_end)} in clip fraction.
var _windows: Dictionary = {}


func _ready() -> void:
	_build_world()
	_build_ui()
	# _spawn_bobba awaits frames, so it MUST be awaited — calling it bare
	# made _ready run straight on and populate the clip list while the
	# AnimationPlayer was still null, which is why the lab came up empty.
	await _spawn_bobba()
	_populate_clips()


# --- scene ------------------------------------------------------------------

func _build_world() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var mat := ProceduralSkyMaterial.new()
	mat.sky_top_color = Color(0.35, 0.42, 0.55)
	mat.sky_horizon_color = Color(0.62, 0.66, 0.70)
	mat.ground_bottom_color = Color(0.22, 0.24, 0.26)
	mat.ground_horizon_color = Color(0.45, 0.46, 0.48)
	sky.sky_material = mat
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_energy = 1.1
	env.environment = e
	add_child(env)

	# Three-point-ish lighting: a key with shadows so the silhouette reads,
	# plus fill from the opposite side so the far arm never goes to black.
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-42, 38, 0)
	key.light_energy = 1.5
	key.shadow_enabled = true
	add_child(key)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-25, -130, 0)
	fill.light_energy = 0.55
	add_child(fill)

	# A plain grid floor — grass hid his feet in every previous capture.
	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(40, 40)
	floor_mesh.mesh = plane
	var fm := StandardMaterial3D.new()
	fm.albedo_color = Color(0.30, 0.32, 0.34)
	floor_mesh.material_override = fm
	add_child(floor_mesh)
	_add_reference_grid()

	_pivot = Node3D.new()
	add_child(_pivot)
	_cam = Camera3D.new()
	_cam.current = true
	_cam.fov = 50.0
	_pivot.add_child(_cam)
	_update_camera()


## One-metre grid with a taller marker every metre up to 3 m, so limb height
## and reach can be read off the image instead of guessed.
func _add_reference_grid() -> void:
	var im := ImmediateMesh.new()
	var mi := MeshInstance3D.new()
	mi.mesh = im
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.vertex_color_use_as_albedo = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mi.material_override = m
	add_child(mi)
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	var grid := Color(1, 1, 1, 0.13)
	for i in range(-6, 7):
		im.surface_set_color(grid)
		im.surface_add_vertex(Vector3(i, 0.01, -6))
		im.surface_set_color(grid)
		im.surface_add_vertex(Vector3(i, 0.01, 6))
		im.surface_set_color(grid)
		im.surface_add_vertex(Vector3(-6, 0.01, i))
		im.surface_set_color(grid)
		im.surface_add_vertex(Vector3(6, 0.01, i))
	# Height poles at 1, 2 and 3 m behind the subject.
	for h in [1.0, 2.0, 3.0]:
		var c := Color(0.4, 0.9, 1.0, 0.5)
		im.surface_set_color(c)
		im.surface_add_vertex(Vector3(-1.6, 0.0, -1.6))
		im.surface_set_color(c)
		im.surface_add_vertex(Vector3(-1.6, h, -1.6))
		im.surface_set_color(c)
		im.surface_add_vertex(Vector3(-1.75, h, -1.6))
		im.surface_set_color(c)
		im.surface_add_vertex(Vector3(-1.45, h, -1.6))
	im.surface_end()


func _spawn_bobba() -> void:
	_bobba = BOBBA_SCENE.instantiate() as Node3D
	add_child(_bobba)
	_bobba.global_position = Vector3.ZERO
	# Inert: the lab drives the AnimationPlayer directly, so his AI, physics
	# and hitboxes must not fight it.
	_bobba.set_physics_process(false)
	# His clips are loaded and composed during his own setup, which takes a
	# few frames — wait for them rather than assuming one frame is enough.
	for i in 60:
		await get_tree().process_frame
		_anim = _find_anim_player(_bobba)
		if _anim != null and not _anim.get_animation_library_list().is_empty():
			break
	_bobba.set_process(false)
	_skeleton = _find_skeleton(_bobba)
	_read_attack_windows()
	var n := 0
	if _anim:
		for lib in _anim.get_animation_library_list():
			n += _anim.get_animation_library(lib).get_animation_list().size()
	print("AnimLab: found AnimationPlayer=%s with %d clips" % [str(_anim != null), n])


func _read_attack_windows() -> void:
	# Pull the real windows off the enemy so the timeline can never drift
	# from what the game actually uses.
	if "COMBO_ATTACKS" in _bobba:
		for a in _bobba.COMBO_ATTACKS:
			_windows[String(a["anim"]).get_slice("/", 1)] = a["window"]
	if "AXE_ATTACK" in _bobba:
		var ax: Dictionary = _bobba.AXE_ATTACK
		_windows[String(ax["anim"]).get_slice("/", 1)] = ax["window"]


func _find_anim_player(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n
	for c in n.get_children():
		var r := _find_anim_player(c)
		if r:
			return r
	return null


func _find_skeleton(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n
	for c in n.get_children():
		var r := _find_skeleton(c)
		if r:
			return r
	return null


# --- ui ---------------------------------------------------------------------

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)

	var left := PanelContainer.new()
	left.set_anchors_preset(Control.PRESET_TOP_LEFT)
	left.position = Vector2(12, 12)
	left.custom_minimum_size = Vector2(250, 460)
	layer.add_child(left)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	left.add_child(vb)

	var title := Label.new()
	title.text = "BOBBA CLIPS"
	title.add_theme_font_size_override("font_size", 16)
	vb.add_child(title)

	_clip_list = ItemList.new()
	_clip_list.custom_minimum_size = Vector2(230, 330)
	_clip_list.item_selected.connect(_on_clip_selected)
	vb.add_child(_clip_list)

	_loop_check = CheckBox.new()
	_loop_check.text = "Loop"
	_loop_check.button_pressed = true
	vb.add_child(_loop_check)

	_axe_check = CheckBox.new()
	_axe_check.text = "Show axe"
	_axe_check.button_pressed = true
	_axe_check.toggled.connect(_on_axe_toggled)
	vb.add_child(_axe_check)

	# Bottom transport bar
	var bottom := PanelContainer.new()
	bottom.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	bottom.offset_top = -108
	bottom.offset_left = 12
	bottom.offset_right = -12
	bottom.offset_bottom = -12
	layer.add_child(bottom)
	var bar := VBoxContainer.new()
	bottom.add_child(bar)

	_info = Label.new()
	_info.text = "pick a clip"
	bar.add_child(_info)

	# The timeline draws the damage window over the scrubber, which is the
	# whole point: you can see whether the blade is mid-arc when it goes live.
	_timeline = Control.new()
	_timeline.custom_minimum_size = Vector2(0, 16)
	_timeline.draw.connect(_draw_timeline)
	bar.add_child(_timeline)

	_time_slider = HSlider.new()
	_time_slider.min_value = 0.0
	_time_slider.max_value = 1.0
	_time_slider.step = 0.001
	_time_slider.drag_started.connect(func() -> void: _scrubbing = true)
	_time_slider.drag_ended.connect(func(_c: bool) -> void: _scrubbing = false)
	_time_slider.value_changed.connect(_on_scrub)
	bar.add_child(_time_slider)

	var row := HBoxContainer.new()
	bar.add_child(row)
	_play_btn = Button.new()
	_play_btn.text = "Pause"
	_play_btn.pressed.connect(_toggle_play)
	row.add_child(_play_btn)
	var step_back := Button.new()
	step_back.text = "< frame"
	step_back.pressed.connect(func() -> void: _step(-1.0 / 30.0))
	row.add_child(step_back)
	var step_fwd := Button.new()
	step_fwd.text = "frame >"
	step_fwd.pressed.connect(func() -> void: _step(1.0 / 30.0))
	row.add_child(step_fwd)
	var sl := Label.new()
	sl.text = "  speed"
	row.add_child(sl)
	_speed_slider = HSlider.new()
	_speed_slider.min_value = 0.05
	_speed_slider.max_value = 2.0
	_speed_slider.step = 0.05
	_speed_slider.value = 1.0
	_speed_slider.custom_minimum_size = Vector2(180, 0)
	_speed_slider.value_changed.connect(_on_speed)
	row.add_child(_speed_slider)
	var hint := Label.new()
	hint.text = "   drag = orbit · wheel = zoom · W/S = raise/lower · Esc = quit"
	row.add_child(hint)


func _populate_clips() -> void:
	if _anim == null:
		_info.text = "no AnimationPlayer found on Bobba"
		return
	var names: Array[String] = []
	for lib_name in _anim.get_animation_library_list():
		var lib := _anim.get_animation_library(lib_name)
		for a in lib.get_animation_list():
			names.append("%s/%s" % [lib_name, a] if String(lib_name) != "" else String(a))
	names.sort()
	for n in names:
		_clip_list.add_item(n)
	if not names.is_empty():
		_clip_list.select(0)
		_on_clip_selected(0)


# --- playback ---------------------------------------------------------------

func _on_clip_selected(idx: int) -> void:
	_current_clip = _clip_list.get_item_text(idx)
	_anim.play(_current_clip)
	_anim.speed_scale = _speed_slider.value
	_play_btn.text = "Pause"
	_timeline.queue_redraw()


func _toggle_play() -> void:
	if _anim == null:
		return
	if _anim.is_playing():
		_anim.pause()
		_play_btn.text = "Play"
	else:
		_anim.play()
		_play_btn.text = "Pause"


func _step(seconds: float) -> void:
	if _anim == null or _current_clip == "":
		return
	_anim.pause()
	_play_btn.text = "Play"
	var len_s: float = _anim.current_animation_length
	_anim.seek(clampf(_anim.current_animation_position + seconds, 0.0, len_s), true)


func _on_scrub(v: float) -> void:
	if _anim == null or not _scrubbing or _current_clip == "":
		return
	_anim.pause()
	_play_btn.text = "Play"
	_anim.seek(v * _anim.current_animation_length, true)


func _on_speed(v: float) -> void:
	if _anim:
		_anim.speed_scale = v


func _on_axe_toggled(on: bool) -> void:
	var axe: Node = _bobba.get("_axe")
	if axe is Node3D:
		(axe as Node3D).visible = on


# --- per-frame --------------------------------------------------------------

func _process(_delta: float) -> void:
	if _anim == null or _current_clip == "":
		return
	var len_s: float = _anim.current_animation_length
	var pos: float = _anim.current_animation_position
	var frac: float = pos / len_s if len_s > 0.0 else 0.0
	if not _scrubbing:
		_time_slider.set_value_no_signal(frac)
	# Looping is the lab's business, not the clip's — restarting by hand
	# leaves the clip's own loop_mode untouched, so nothing the game relies
	# on is mutated by having looked at it here.
	if _loop_check.button_pressed and not _anim.is_playing() \
			and _play_btn.text == "Pause":
		_anim.play(_current_clip)
	var win: Vector2 = _windows.get(_current_clip.get_slice("/", 1), Vector2.ZERO)
	var win_txt := ""
	if win != Vector2.ZERO:
		win_txt = "   window %.2f-%.2f%s" % [win.x, win.y,
				"   <<< LIVE" if frac >= win.x and frac <= win.y else ""]
	_info.text = "%s    %.2f / %.2f s   (%.0f%%)   speed %.2fx%s" % [
			_current_clip, pos, len_s, frac * 100.0, _speed_slider.value, win_txt]
	_timeline.queue_redraw()


func _draw_timeline() -> void:
	var w: float = _timeline.size.x
	var h: float = _timeline.size.y
	_timeline.draw_rect(Rect2(0, 0, w, h), Color(0.16, 0.17, 0.20))
	var win: Vector2 = _windows.get(_current_clip.get_slice("/", 1), Vector2.ZERO)
	if win != Vector2.ZERO:
		_timeline.draw_rect(Rect2(win.x * w, 0, (win.y - win.x) * w, h),
				Color(0.95, 0.35, 0.25, 0.65))
	if _anim and _anim.current_animation_length > 0.0:
		var f: float = _anim.current_animation_position / _anim.current_animation_length
		_timeline.draw_rect(Rect2(f * w - 1.0, 0, 2.0, h), Color(1, 1, 1, 0.9))


# --- camera -----------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_dragging = mb.pressed
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_dist = maxf(1.5, _dist - 0.4)
			_update_camera()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_dist = minf(18.0, _dist + 0.4)
			_update_camera()
	elif event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		_yaw -= mm.relative.x * 0.008
		_pitch = clampf(_pitch - mm.relative.y * 0.006, -1.2, 1.2)
		_update_camera()
	elif event is InputEventKey and (event as InputEventKey).pressed:
		match (event as InputEventKey).keycode:
			KEY_ESCAPE:
				get_tree().quit()
			KEY_W:
				_height = minf(3.5, _height + 0.15)
				_update_camera()
			KEY_S:
				_height = maxf(0.1, _height - 0.15)
				_update_camera()
			KEY_SPACE:
				_toggle_play()


func _update_camera() -> void:
	if _pivot == null:
		return
	_pivot.position = Vector3(0, _height, 0)
	var offset := Vector3(
		sin(_yaw) * cos(_pitch), sin(_pitch), cos(_yaw) * cos(_pitch)) * _dist
	_cam.position = offset
	_cam.look_at_from_position(_pivot.position + offset, _pivot.position, Vector3.UP)
	_cam.position = _cam.position - _pivot.position
