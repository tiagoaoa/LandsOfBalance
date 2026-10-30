class_name ColossusPart
extends StaticBody3D

## A solid body part, following the animated rig. Head hits take health;
## recovering hands take less damage but build poise. ColossusBoss.on_part_hit
## owns the damage rules.
##
## Swords find this through the sweep query on layer 2 (take_hit), arrows by
## colliding with it (take_arrow_hit — deliberately NO take_damage_flat, so
## the arrow reports itself and the boss can see who shot it and from where).
## The part only forwards; ColossusBoss.on_part_hit owns every rule.

enum Kind { ARMOR, HAND_L, HAND_R, CORE, HEAD, EYE, MARK, MOUTH }

var boss: Node = null
var kind: int = Kind.ARMOR


func _ready() -> void:
	collision_layer = 2     # enemies: the sword sweep and arrows both scan it
	collision_mask = 0      # it is moved by script, never by contact
	# Motion comes from the rig; impact sweeps supply damage and knockback.
	# Estimated platform velocity would drag players away with a retreating arm.
	set_meta(&"no_body_fire", true)   # arrow.gd: stone takes no burning aura
	add_to_group("colossus_parts")


## Sword (and any other melee) contact. Returns whether it landed, like
## every other take_hit in the game.
func take_hit(damage: float, _knockback: Vector3, _blocked: bool = false,
		attacker: Node3D = null, _fully_blockable: bool = false) -> bool:
	if boss == null:
		return false
	return boss.on_part_hit(self, damage, attacker, false, global_position)


## Arrow contact (arrow.gd calls this on anything that has it).
func take_arrow_hit(hit_pos: Vector3, arrow: Node) -> void:
	if boss == null:
		return
	var shooter: Node3D = arrow.shooter if "shooter" in arrow else null
	var damage: float = 35.0
	if arrow.has_method("_compute_flat_arrow_damage"):
		damage = arrow._compute_flat_arrow_damage(self)
	boss.on_part_hit(self, damage, shooter, true, hit_pos)


## A paladin's timed shield flick against a fist that is coming down.
func on_parried(parrier: Node3D) -> void:
	if boss and boss.has_method("on_parried"):
		boss.on_parried(self, parrier)
