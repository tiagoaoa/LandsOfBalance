extends Area3D

## A time-ticking healing area for spell circles.
##
## Heals any Player inside the radius at a class-specific percent-of-max-HP
## rate per second. Used by the Paladin's (knight's) heal spell: Paladin in
## range recovers `knight_heal_pct_per_sec`, Archer in range recovers
## `archer_heal_pct_per_sec`.
##
## The target must expose:
##   - `heal_pct(pct: float)`
##   - `is_paladin() -> bool` and/or `is_archer() -> bool`
## Any other body is ignored.

signal ticked(healed_bodies: Array)
signal expired()

@export var radius: float = 5.0
@export var knight_heal_pct_per_sec: float = 0.05
@export var archer_heal_pct_per_sec: float = 0.10
@export var tick_interval: float = 1.0
@export var lifetime: float = 0.0  # 0 = persists until manually destroyed

var _age: float = 0.0
var _tick_timer: float = 0.0
var _bodies_inside: Array[Node3D] = []


func _ready() -> void:
	var shape_node := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = radius
	shape_node.shape = sphere
	add_child(shape_node)

	collision_layer = 0
	collision_mask = 1 | 8  # Local player (1) + remote players (8)
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
	var healed: Array = []
	for body in _bodies_inside:
		if not is_instance_valid(body):
			continue
		if not body.has_method("heal_pct"):
			continue
		var rate: float = _get_heal_rate_for(body)
		if rate <= 0.0:
			continue
		body.heal_pct(rate * tick_interval)
		healed.append(body)
	if not healed.is_empty():
		ticked.emit(healed)


func _get_heal_rate_for(body: Node3D) -> float:
	if body.has_method("is_paladin") and body.is_paladin():
		return knight_heal_pct_per_sec
	if body.has_method("is_archer") and body.is_archer():
		return archer_heal_pct_per_sec
	return 0.0


func _on_body_entered(body: Node3D) -> void:
	if not body.has_method("heal_pct"):
		return
	if not _bodies_inside.has(body):
		_bodies_inside.append(body)


func _on_body_exited(body: Node3D) -> void:
	_bodies_inside.erase(body)
