extends Node

## Global combat-feel helper. Registered as an autoload so any damage source
## can call CombatFX.hitstop() / CombatFX.shake_camera() without plumbing a
## reference through 6 nodes.
##
## All methods are best-effort — if no viewport/camera is available, they
## silently no-op.

## Briefly drop Engine.time_scale to simulate "impact freeze" used in
## souls-likes and character-action games. Default values match a medium
## weapon hit: 60ms of frozen-feel time at 5% speed.
##
## Nested calls extend the remaining duration but don't stack deeper than
## the minimum scale already in effect.
var _hitstop_timer: float = 0.0
var _hitstop_original_scale: float = 1.0


## Camera shake state (applies to whichever camera is current()).
var _shake_timer: float = 0.0
var _shake_duration: float = 0.0
var _shake_intensity: float = 0.0
var _shake_origin_offset: Vector3 = Vector3.ZERO
var _shake_camera: Camera3D = null


func _process(delta: float) -> void:
	if _hitstop_timer > 0.0:
		# time_scale does NOT scale the main loop's delta, so use the real
		# frame time from get_process_delta_time on an Idle process node.
		_hitstop_timer -= get_process_delta_time()
		if _hitstop_timer <= 0.0:
			Engine.time_scale = _hitstop_original_scale

	if _shake_timer > 0.0:
		_shake_timer -= delta
		if _shake_camera != null and is_instance_valid(_shake_camera):
			if _shake_timer <= 0.0:
				# Restore
				_shake_camera.h_offset = _shake_origin_offset.x
				_shake_camera.v_offset = _shake_origin_offset.y
				_shake_camera = null
			else:
				# Fall-off: intensity decays linearly across duration
				var remaining: float = _shake_timer / _shake_duration
				var mag: float = _shake_intensity * remaining
				_shake_camera.h_offset = _shake_origin_offset.x + randf_range(-mag, mag)
				_shake_camera.v_offset = _shake_origin_offset.y + randf_range(-mag, mag)


## Apply a brief time-scale drop to "sell" an impact. Defaults are tuned for
## a medium sword hit.
## scale: time scale during hitstop (0.05 = 5% speed; 0.0 is allowed but
##   suspends physics, which can confuse character controllers).
## duration: how long to hold (real seconds, ignores current time_scale).
func hitstop(duration: float = 0.06, scale: float = 0.05) -> void:
	if _hitstop_timer <= 0.0:
		_hitstop_original_scale = Engine.time_scale
	Engine.time_scale = scale
	# Extend if we're already stopping.
	if duration > _hitstop_timer:
		_hitstop_timer = duration


## Shake the current viewport camera for a short burst.
## intensity: max offset in world units.
## duration: seconds.
func shake_camera(intensity: float = 0.15, duration: float = 0.18) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	var vp: Viewport = tree.root.get_viewport()
	if vp == null:
		return
	var cam: Camera3D = vp.get_camera_3d()
	if cam == null:
		return
	# If we're already shaking the same camera, extend/boost.
	if _shake_camera != cam:
		_shake_origin_offset = Vector3(cam.h_offset, cam.v_offset, 0.0)
		_shake_camera = cam
	_shake_duration = duration
	_shake_timer = duration
	_shake_intensity = intensity


## Convenience hook that USED to trigger hitstop + camera shake. Per
## 2026-04-18 playtest feedback ("shaking animation and long stall" was
## rated not fun), the juice path is now a no-op. Callers still invoke
## CombatFX.on_hit(weight) at hit time — we keep the method so enabling
## it again is a one-line revert, but the *positional* knockback is the
## only hit-feedback channel the game uses today. `hitstop()` and
## `shake_camera()` above remain callable directly for cases where a
## deliberate stall is wanted (e.g. cinematic moments), but they're not
## driven from the combat loop.
func on_hit(_weight: float = 0.7) -> void:
	pass
