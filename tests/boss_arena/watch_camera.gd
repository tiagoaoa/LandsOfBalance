extends Node3D

#LOB_BOSS_CAMERA_CYCLE=<seconds>: archer, paladin, then the whole arena.
const VIEWS := ["Archer", "Paladin", "Overview"]

var arena: BossArena
var rig: SpectateCam
var _cam: Camera3D
var _label: Label
var _view := 0
var _left := 0.0
var _every := 18.0


func _ready() -> void:
	_every = maxf(3.0, float(OS.get_environment("LOB_BOSS_CAMERA_CYCLE")))
	_left = _every
	_cam = Camera3D.new()
	_cam.fov = 62.0
	add_child(_cam)
	rig.get_node("SpectateHUD").visible = false
	rig.set_process_input(false)
	var hud := CanvasLayer.new()
	hud.layer = 45
	add_child(hud)
	_label = Label.new()
	_label.position = Vector2(20, 86)
	_label.add_theme_font_size_override("font_size", 18)
	_label.add_theme_color_override("font_shadow_color", Color.BLACK)
	_label.add_theme_constant_override("shadow_offset_x", 2)
	_label.add_theme_constant_override("shadow_offset_y", 2)
	hud.add_child(_label)
	call_deferred("_start")


func _start() -> void:
	await get_tree().process_frame
	rig._arm.collision_mask = 3
	for p in arena.party():
		rig._arm.add_excluded_object(p.get_rid())
	var gs := get_node("/root/GameSettings")
	_set_view((gs.arena_round - 1) % VIEWS.size())


func _set_view(view: int) -> void:
	_view = view
	_left = _every
	if _view == 2:
		_overview(1.0)
		_cam.make_current()
	else:
		for p in arena.party():
			if p.is_paladin() == (_view == 1):
				rig.watch(p)
	_label.text = "%s camera  |  TAB next view  |  Q quit" % VIEWS[_view]
	print("[BossCamera] round=%d t=%.1f view=%s" % [
			get_node("/root/GameSettings").arena_round,
			arena._match_t, VIEWS[_view]])


func _physics_process(delta: float) -> void:
	_left -= delta
	if _left <= 0.0:
		_set_view((_view + 1) % VIEWS.size())
	if _view == 2:
		_overview(1.0 - exp(-1.5 * delta))


func _overview(weight: float) -> void:
	var away := arena.center - arena.boss.global_position
	away.y = 0.0
	away = away.normalized()
	var side := away.cross(Vector3.UP)
	var at := arena.center + (away + side * 0.35) * arena.radius * 1.9
	at.y = arena.floor_y + arena.radius * 1.4
	_cam.global_position = _cam.global_position.lerp(at, weight)
	var look := arena.center.lerp(arena.boss.head_pos(), 0.3)
	look.y = maxf(look.y, arena.floor_y + 2.0)
	_cam.look_at(look)


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_TAB:
			_set_view((_view + 1) % VIEWS.size())
			return
	if _view != 2:
		rig._input(event)
