extends Resource
class_name AttackData

## Data-driven attack definition — hit data moved off hardcoded player.gd
## constants and onto a Resource so designers can tune without code changes.
##
## Pattern adapted from bright-souls' `AttackData` ScriptableObject +
## `ICombatEffect` list. This first pass bakes the common fields into the
## resource directly; additional effects (DoT, knockback variants) can be
## added later via `extra_effects` once we have more than one attack that
## needs them.

@export var attack_name: String = ""
@export var damage: float = 0.0
@export_range(0.0, 300.0) var poise_damage: float = 0.0
@export_range(0.0, 200.0) var stamina_cost: float = 0.0
@export var knockback_magnitude: float = 0.0
@export var is_fully_blockable: bool = false
## Hit-window timing as a 0..1 ratio of the attack animation.
## Moving these off hardcoded player.gd constants lets each attack define
## its own active frames — replacement for bright-souls' AnimStateMessage.
@export_range(0.0, 1.0) var hit_window_start: float = 0.15
@export_range(0.0, 1.0) var hit_window_end: float = 0.95
## Optional follow-up effects applied on hit (CombatEffectResource subclasses).
## Each effect's `apply(target, attacker)` runs after the core damage/knockback.
@export var extra_effects: Array[Resource] = []


## Apply this attack against `target`. Returns the actual damage dealt.
## The caller should already have paid stamina cost via StaminaComponent.
func apply_to(target: Node, attacker: Node = null) -> float:
	if target == null or not is_instance_valid(target):
		return 0.0
	var knockback: Vector3 = Vector3.ZERO
	if attacker and attacker is Node3D and target is Node3D:
		var dir: Vector3 = (target.global_position - attacker.global_position).normalized()
		dir.y = 0.3
		knockback = dir * knockback_magnitude
	if target.has_method("take_hit"):
		target.take_hit(damage, knockback, false, attacker, is_fully_blockable)
	for effect in extra_effects:
		if effect and effect.has_method("apply"):
			effect.apply(target, attacker)
	return damage
