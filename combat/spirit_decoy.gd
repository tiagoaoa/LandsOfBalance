class_name SpiritDecoy
extends CharacterBody3D

## A spectral hound the archer conjures to draw a giant's eye: it darts about
## the platform, and the boss's fists and spit go after it like after a
## player. One blow dispels it. Duck-types the handful of Player fields the
## boss touches (health, guard, roll, knockback).

const SPEED := 6.5
const LIFE := 10.0

var arena: Node = null
var is_dead := false
var current_health := 1.0
var max_health := 1.0
var is_blocking := false
var is_crouching := false
var is_rolling := false
var _is_stunned := false
var _stun_timer := 0.0
var _knockback_velocity := Vector3.ZERO
var _life := LIFE
var _goal := Vector3.ZERO
var _goal_t := 0.0


func _ready() -> void:
	add_to_group("lures")
	collision_layer = 0
	collision_mask = 1
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = 1.2
	cs.shape = cap
	cs.position = Vector3(0, 0.6, 0)
	add_child(cs)
	var mi := MeshInstance3D.new()
	var m := CapsuleMesh.new()
	m.radius = 0.35
	m.height = 1.1
	mi.mesh = m
	mi.rotation_degrees = Vector3(90, 0, 0)
	mi.position = Vector3(0, 0.6, 0)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.45, 0.8, 1.0, 0.55)
	mi.material_override = mat
	add_child(mi)
	var l := OmniLight3D.new()
	l.light_color = Color(0.45, 0.8, 1.0)
	l.light_energy = 1.2
	l.omni_range = 4.0
	l.position = Vector3(0, 0.8, 0)
	add_child(l)


func _physics_process(delta: float) -> void:
	_life -= delta
	if _life <= 0.0 or is_dead:
		queue_free()
		return
	_goal_t -= delta
	if _goal_t <= 0.0 and arena:
		_goal_t = randf_range(0.8, 1.6)
		var a := randf() * TAU
		_goal = arena.center + Vector3(cos(a), 0, sin(a)) * arena.radius * randf_range(0.2, 0.75)
	var to := _goal - global_position
	to.y = 0.0
	var v := to.normalized() * SPEED if to.length() > 0.5 else Vector3.ZERO
	velocity.x = v.x
	velocity.z = v.z
	velocity.y -= 20.0 * delta
	move_and_slide()


func take_hit(_d: float, _kb: Vector3, _b: bool = false, _a: Node3D = null, _f: bool = false) -> bool:
	is_dead = true
	current_health = 0.0
	SlashTrail.spawn_hit_spark(self, global_position + Vector3(0, 0.8, 0), Color(0.5, 0.85, 1.0))
	return true


func take_damage_flat(_d: float) -> void:
	pass


func is_paladin() -> bool:
	return false
