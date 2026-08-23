class_name SpectateCam
extends Node3D

## The camera for a match nobody is playing.
##
## In spectate mode both classes are bots (GameSettings.spectate), and a bot
## uses its camera pivot the way a human uses the mouse: as an AIM, snapped
## instantly onto whatever it is shooting at or swinging at. Riding that pivot
## is unwatchable, so the view moves OUT of both heads into this rig — a
## chase camera that follows the watched bot's aim lazily, absorbs the snaps,
## and hands the mouse back to the person on the couch.
##
##   TAB          switch which bot the camera follows
##   mouse        free look (eases back onto the bot's own view after a pause)
##   wheel        pull in / push out
##   H            hide the tactic overlay
##
## Spawned by Player._spawn_companion_if_coop() when spectating.

const FOLLOW_YAW_SPEED := 3.2      ## rad/s the rig lags the bot's aim by
const FOLLOW_POS_SPEED := 9.0      ## how hard the rig chases the body
const MANUAL_HOLD := 3.0           ## seconds free look stays where you put it
const MANUAL_DECAY := 1.4          ## rad/s the free-look offset eases back
const MOUSE_SENS := 0.0035
const PITCH_MIN := deg_to_rad(-55.0)
const PITCH_MAX := deg_to_rad(35.0)
const REST_PITCH := deg_to_rad(-11.0)
const HEAD_HEIGHT := 1.65
const ZOOM_MIN := 2.5
const ZOOM_MAX := 16.0

var target: Node3D = null

var _arm: SpringArm3D = null
var _cam: Camera3D = null
var _yaw: float = 0.0
var _pitch: float = REST_PITCH
var _manual_yaw: float = 0.0
var _manual_pitch: float = 0.0
var _manual_left: float = 0.0
var _zoom: float = 6.5
var _hud: CanvasLayer = null
var _panel: PanelContainer = null
var _label: RichTextLabel = null
var _hint: Label = null
var _hud_timer: float = 0.0


func _ready() -> void:
	_arm = SpringArm3D.new()
	_arm.spring_length = _zoom
	_arm.collision_mask = 1
	_arm.margin = 0.3
	add_child(_arm)
	_cam = Camera3D.new()
	_cam.fov = 62.0
	_cam.near = 0.1
	_cam.transform.origin = Vector3(0.35, 0.25, 0.0)
	_arm.add_child(_cam)
	_cam.current = true
	_build_hud()
	set_process_input(true)


## Point the rig at a body and take the viewport from it.
func watch(body: Node3D) -> void:
	if body == null or not is_instance_valid(body):
		return
	target = body
	global_position = body.global_position + Vector3.UP * HEAD_HEIGHT
	_yaw = _body_yaw()
	_cam.current = true
	print("Spectate: watching %s (%s)" % [body.name, _class_label(body)])


## Driven on the PHYSICS tick, not the render tick: the bodies move in
## physics, and a camera moved outside it fights Godot's interpolation
## (and says so, loudly, in the log).
func _physics_process(delta: float) -> void:
	if target == null or not is_instance_valid(target):
		_next_target()
		return
	# The rig sits at the head and CHASES it — a hard parent would inherit
	# every one of the body's stagger/roll jitters.
	var want_pos: Vector3 = target.global_position + Vector3.UP * HEAD_HEIGHT
	global_position = global_position.lerp(want_pos, clampf(FOLLOW_POS_SPEED * delta, 0.0, 1.0))
	# Free look holds for a few seconds after the last mouse move, then the
	# offset bleeds off and the rig settles back behind the bot's own view.
	if _manual_left > 0.0:
		_manual_left -= delta
	else:
		_manual_yaw = move_toward(_manual_yaw, 0.0, MANUAL_DECAY * delta)
		_manual_pitch = move_toward(_manual_pitch, 0.0, MANUAL_DECAY * delta)
	_yaw = lerp_angle(_yaw, _body_yaw(), clampf(FOLLOW_YAW_SPEED * delta, 0.0, 1.0))
	rotation.y = _yaw + _manual_yaw
	rotation.x = clampf(REST_PITCH + _manual_pitch, PITCH_MIN, PITCH_MAX)
	_arm.spring_length = lerpf(_arm.spring_length, _zoom, 8.0 * delta)
	_hud_timer -= delta
	if _hud_timer <= 0.0:
		_hud_timer = 0.25
		_refresh_hud()


## The bot's own view direction, i.e. what it is aiming at this instant.
func _body_yaw() -> float:
	if target == null or not is_instance_valid(target):
		return _yaw
	var pivot := target.get_node_or_null("CameraPivot") as Node3D
	return pivot.rotation.y if pivot != null else target.rotation.y


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and CloudInput.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		_manual_yaw = wrapf(_manual_yaw - event.relative.x * MOUSE_SENS, -PI, PI)
		_manual_pitch = clampf(_manual_pitch - event.relative.y * MOUSE_SENS, PITCH_MIN, PITCH_MAX)
		_manual_left = MANUAL_HOLD
		return
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom = clampf(_zoom - 0.8, ZOOM_MIN, ZOOM_MAX)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom = clampf(_zoom + 0.8, ZOOM_MIN, ZOOM_MAX)
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_TAB:
			_next_target()
		elif event.keycode == KEY_H and _panel != null:
			_panel.visible = not _panel.visible


## Hand the view to the other half of the party.
func _next_target() -> void:
	var party: Array[Node3D] = _party()
	if party.is_empty():
		return
	var idx := party.find(target)
	watch(party[(idx + 1) % party.size()])


func _party() -> Array[Node3D]:
	var out: Array[Node3D] = []
	for gname in ["player", "companion"]:
		var n := get_tree().get_first_node_in_group(gname)
		if n is Node3D and is_instance_valid(n):
			out.append(n as Node3D)
	return out


func _class_label(body: Node3D) -> String:
	if not ("character_class" in body):
		return "?"
	return "Paladin" if int(body.character_class) == 0 else "Archer"


# ------------------------------------------------------------------- overlay --

func _build_hud() -> void:
	_hud = CanvasLayer.new()
	_hud.name = "SpectateHUD"
	_hud.layer = 20
	add_child(_hud)
	var panel := PanelContainer.new()
	_panel = panel
	panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	panel.position = Vector2(18, 18)
	panel.custom_minimum_size = Vector2(560, 0)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.02, 0.03, 0.05, 0.55)
	style.corner_radius_top_left = 6
	style.corner_radius_top_right = 6
	style.corner_radius_bottom_left = 6
	style.corner_radius_bottom_right = 6
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	panel.add_theme_stylebox_override("panel", style)
	_hud.add_child(panel)
	_label = RichTextLabel.new()
	_label.bbcode_enabled = true
	_label.fit_content = true
	_label.scroll_active = false
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.add_theme_font_size_override("normal_font_size", 15)
	panel.add_child(_label)
	_hint = Label.new()
	_hint.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_hint.position = Vector2(20, -34)
	_hint.text = "TAB switch bot   ·   mouse look   ·   wheel zoom   ·   H hide   ·   Q quit"
	_hint.add_theme_font_size_override("font_size", 13)
	_hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.55))
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud.add_child(_hint)


## What each bot is doing and why — the whole point of watching.
func _refresh_hud() -> void:
	if _label == null or _panel == null or not _panel.visible:
		return
	var lines: Array[String] = []
	for body in _party():
		var ai := body.get_node_or_null("CompanionAI")
		var line: String = ai.debug_line() if ai != null and ai.has_method("debug_line") \
				else "%s: no brain" % _class_label(body)
		var hp: float = 0.0
		if "current_health" in body and "max_health" in body:
			hp = 100.0 * float(body.current_health) / maxf(float(body.max_health), 1.0)
		var down: bool = "is_dead" in body and body.is_dead
		var colour := "ff5a5a" if down else ("ffd479" if hp < 45.0 else "b9f0c4")
		var eye := "[color=8fd3ff]►[/color] " if body == target else "   "
		lines.append("%s[color=%s]%s %.0f%%%s[/color]  [color=cfd6e2]%s[/color]" % [
				eye, colour, _class_label(body), hp, " DOWN" if down else "", line])
	_label.text = "\n".join(lines)
