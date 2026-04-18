extends Area3D

## Damage-buff aura for the archer's buff spell.
##
## Doesn't apply any effect directly. Instead, it pings each eligible body
## entering and exiting via `add_buff_source()` / `remove_buff_source()`.
## The body is responsible for accumulating (+5%/sec while at least one
## buff source is touching) and decaying (-5%/sec while zero sources) its
## own `damage_buff_pct`. This cleanly handles multiple overlapping auras,
## aura despawn, target entering/leaving, and matches the souls-like spec:
##   "damage increases by +5%/sec inside, decreases by -5%/sec outside".
##
## Only bodies that are a Knight (Paladin) receive the source — archers and
## NPCs get no buff. The `exclude_node` field prevents the caster from
## buffing themselves (mostly irrelevant here since the caster is an archer
## and therefore already ineligible, but kept for symmetry).

signal expired()

@export var radius: float = 6.0
@export var lifetime: float = 0.0  # 0 = persists until manually destroyed
@export var exclude_node: Node3D = null

var _age: float = 0.0
var _bodies_inside: Array[Node3D] = []


func _ready() -> void:
	var shape_node := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = radius
	shape_node.shape = sphere
	add_child(shape_node)

	collision_layer = 0
	collision_mask = 1 | 8
	monitoring = true
	monitorable = false

	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	tree_exiting.connect(_on_tree_exiting)


func _physics_process(delta: float) -> void:
	if lifetime <= 0.0:
		return
	_age += delta
	if _age >= lifetime:
		expired.emit()
		queue_free()


func _on_body_entered(body: Node3D) -> void:
	if body == exclude_node:
		return
	if not _is_valid_target(body):
		return
	if _bodies_inside.has(body):
		return
	_bodies_inside.append(body)
	body.add_buff_source()


func _on_body_exited(body: Node3D) -> void:
	if not _bodies_inside.has(body):
		return
	_bodies_inside.erase(body)
	if is_instance_valid(body) and body.has_method("remove_buff_source"):
		body.remove_buff_source()


func _on_tree_exiting() -> void:
	# Make sure every body currently inside gets its source cleared so the
	# buff decays properly after this aura despawns.
	for body in _bodies_inside:
		if is_instance_valid(body) and body.has_method("remove_buff_source"):
			body.remove_buff_source()
	_bodies_inside.clear()


func _is_valid_target(body: Node3D) -> bool:
	if not body.has_method("add_buff_source"):
		return false
	if not body.has_method("remove_buff_source"):
		return false
	# Only Knights (Paladins) receive the buff — archers and others ignored.
	if body.has_method("is_paladin"):
		return body.is_paladin()
	return false
