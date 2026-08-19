extends Area3D

## A time-ticking damage-over-time aura.
##
## Any CharacterBody3D inside this area that exposes a `take_damage_pct(pct)`
## method takes a percent-HP hit every `tick_interval` seconds, equal to
## `damage_pct_per_sec * tick_interval`. The area despawns after `lifetime`
## seconds (or lives forever if `lifetime == 0`).
##
## Used by the archer's landed-arrow ground fire (step 3) and can be reused
## for any area DoT effect later.
##
## Set `source_node` to whoever created the aura: it and everyone on its side
## are immune (Factions.is_ally). `exclude_node` remains for a one-off
## exemption that has nothing to do with sides.
##
## Excluding only the caster was not enough. The archer's ground fire is the
## party's light source — the whole night design pushes the paladin toward
## standing in it — and it was burning him 5% of max HP a second for doing
## exactly what the fire is for.

signal ticked(damaged_bodies: Array)
signal expired()

@export var radius: float = 5.0
@export var damage_pct_per_sec: float = 0.05
@export var tick_interval: float = 1.0
@export var lifetime: float = 30.0
@export var exclude_node: Node3D = null
## Whoever this aura belongs to. Anyone allied with it takes no damage.
@export var source_node: Node3D = null

var _age: float = 0.0
var _tick_timer: float = 0.0
var _bodies_inside: Array[Node3D] = []


func _ready() -> void:
	var shape_node := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = radius
	shape_node.shape = sphere
	add_child(shape_node)

	# Detect any character body — player (layer 1), bobba/dragon (layer 2),
	# remote players (layer 8). Don't collide with anything ourselves.
	collision_layer = 0
	collision_mask = 1 | 2 | 8
	monitoring = true
	monitorable = false

	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)


func _physics_process(delta: float) -> void:
	_age += delta
	if lifetime > 0.0 and _age >= lifetime:
		expired.emit()
		queue_free()
		return

	_tick_timer += delta
	if _tick_timer >= tick_interval:
		_tick_timer -= tick_interval
		_apply_tick()


func _apply_tick() -> void:
	if damage_pct_per_sec <= 0.0:
		return
	var damage_this_tick: float = damage_pct_per_sec * tick_interval
	var damaged: Array = []
	for body in _bodies_inside:
		if not is_instance_valid(body):
			continue
		if body == exclude_node or body == source_node:
			continue
		if Factions.is_ally(source_node, body):
			continue
		if body.has_method("take_damage_pct"):
			body.take_damage_pct(damage_this_tick)
			damaged.append(body)
	if not damaged.is_empty():
		ticked.emit(damaged)


func _on_body_entered(body: Node3D) -> void:
	# Only track bodies that can actually receive percent-HP damage.
	if not body.has_method("take_damage_pct"):
		return
	if not _bodies_inside.has(body):
		_bodies_inside.append(body)


func _on_body_exited(body: Node3D) -> void:
	_bodies_inside.erase(body)
