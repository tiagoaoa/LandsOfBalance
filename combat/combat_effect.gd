extends Resource
class_name CombatEffect

## Base class for post-hit effects chained off an AttackData. Concrete
## subclasses override `apply(target, attacker)` — e.g. a DoT, a heal
## leech, a stamina drain.
##
## Kept minimal because at the time of writing, only one attack (the
## Paladin sword) uses it. Expand when a second attack needs different
## follow-up behavior.

func apply(_target: Node, _attacker: Node) -> void:
	pass
