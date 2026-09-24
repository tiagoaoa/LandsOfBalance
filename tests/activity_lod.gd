extends Node3D

## ActivityLOD's promises, checked on a real skeleton:
##   awake while a camera is near, asleep when everything is far and it is
##   off screen, awake at once when hit or when it comes into view, and
##   never asleep while engaged.
##
##   godot --path . res://tests/activity_lod.tscn

const SkeletonScript := preload("res://enemies/skeleton.gd")

var failures := 0
var camera: Camera3D
var skeleton: CharacterBody3D


func _ready() -> void:
	Sfx.muted = true
	var floor_body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1000, 1, 1000)
	shape.shape = box
	shape.position.y = -0.5
	floor_body.add_child(shape)
	add_child(floor_body)
	camera = Camera3D.new()
	add_child(camera)
	camera.current = true
	camera.global_position = Vector3(0, 3, 8)
	camera.look_at(Vector3(0, 1, 0))
	skeleton = SkeletonScript.new()
	skeleton.home_post = Vector3.ZERO
	add_child(skeleton)
	skeleton.global_position = Vector3(0, 0.3, 0)
	var lod: ActivityLOD = skeleton.get_node("ActivityLOD")

	await _wait(0.8)
	_check(not lod.asleep and skeleton.can_process(), "awake with the camera near and looking")

	# Far away and looking elsewhere: nothing could perceive or see it.
	camera.global_position = Vector3(400, 3, 400)
	camera.look_at(Vector3(800, 3, 800))
	await _wait(0.8)
	_check(lod.asleep and not skeleton.can_process(), "asleep when far and off screen")
	var anim := skeleton.find_child("ProcAnim", true, false) as AnimationPlayer
	if anim:
		var pos := anim.current_animation_position
		await _wait(0.4)
		_check(is_equal_approx(pos, anim.current_animation_position), "a sleeper's animation holds still")

	skeleton.take_damage_flat(1.0)
	_check(not lod.asleep and skeleton.can_process(), "a hit wakes it the same frame")
	await _wait(0.8)
	_check(lod.asleep, "back asleep once nothing is near")

	# In view from far away: a frozen pose must never be what you look at.
	camera.look_at(skeleton.global_position + Vector3(0, 1, 0))
	await _wait(0.3)
	_check(not lod.asleep, "coming on screen wakes it, however far")

	camera.look_at(Vector3(800, 3, 800))
	await _wait(0.8)
	lod.engaged = func() -> bool: return true
	await _wait(0.5)
	_check(not lod.asleep, "never asleep while engaged")
	lod.engaged = func() -> bool: return false

	# Walking back into range: the camera within the wake radius.
	await _wait(0.8)
	camera.global_position = Vector3(ActivityLOD.DEFAULT_WAKE_RADIUS - 10.0, 3, 0)
	camera.look_at(Vector3(800, 3, 800))
	await _wait(0.5)
	_check(not lod.asleep, "awake once someone is inside the wake radius")

	print("[ActivityLOD] failures=%d" % failures)
	get_tree().quit(1 if failures else 0)


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _check(ok: bool, label: String) -> void:
	print("[ActivityLOD] %s %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		failures += 1
