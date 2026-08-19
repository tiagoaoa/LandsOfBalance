class_name Factions
extends RefCounted
## Who is on whose side. One answer, asked everywhere damage is applied.
##
## THERE IS NO FRIENDLY FIRE. A character's attacks cannot hurt another
## character, full stop — not the archer's ground fire, not a stray arrow,
## not a sword swing that clips an ally mid-brawl. The party fights shoulder
## to shoulder in the dark and is meant to bunch up around firelight; a game
## that punishes that is fighting its own design.
##
## Every damage source used to make this decision for itself, and each made a
## different one: the sword hitbox hit anything exposing take_hit, the arrow
## and its ground fire excluded exactly one node (the shooter), and nothing
## excluded a teammate at all. Hence this file — a source that forgets to ask
## is a bug you find by being set on fire by your own archer.

## The party. Anything in one of these groups is friendly to anything else in
## one of these groups.
const PARTY_GROUPS: Array[String] = ["player", "companion", "remote_players"]


## Is `node` a member of the party (local player, AI companion, or a
## networked ally)?
static func is_party(node: Node) -> bool:
	if node == null or not is_instance_valid(node):
		return false
	for g in PARTY_GROUPS:
		if node.is_in_group(g):
			return true
	return false


## Would damage from `attacker` to `target` be friendly fire?
##
## True when both are party members — INCLUDING when they are the same node,
## so a source cannot cook its own caster either. An unknown or freed
## attacker (a scripted test hit, a fire whose owner has died) is treated as
## hostile, so this can only ever suppress damage it is certain about.
static func is_ally(attacker: Node, target: Node) -> bool:
	if attacker == null or target == null:
		return false
	if not is_instance_valid(attacker) or not is_instance_valid(target):
		return false
	return is_party(attacker) and is_party(target)
