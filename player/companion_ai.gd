class_name CompanionAI
extends Node

## Drives a co-op AI companion (a second player.tscn instance with
## `is_ai_companion = true`). It fights through the SAME control surface a human
## uses: it steers the character's camera pivot, writes `_ai_move_vec` /
## `_ai_run` / `_ai_block` (read where player.gd would poll Input), and calls
## the same action methods the combat harness does (_do_attack, _try_dodge,
## _try_parry, _try_estus, _do_spell_cast, _shoot_arrow).
##
## This file is now only the WIRING. The intelligence lives in two places:
##
##   combat/squad_brain.gd   — the party's shared tactical picture, built once
##                             at 10 Hz for every AI in the scene: who is out
##                             there, how sure we are, who is hunting whom,
##                             where the fires burn, and which patch of dark
##                             most needs an arrow. Nothing else in the co-op
##                             AI walks a scene group in a per-frame path.
##
##   player/ai/*_role.gd     — ONE BEHAVIOUR PER CLASS, as complements rather
##                             than duplicates:
##                               PaladinRole — the anchor: peels enemies off
##                                 the archer, drags fights into the light,
##                                 plans the heal rite, raises the fallen.
##                               ArcherRole  — the lantern: decides where the
##                                 party can SEE, aims the fire on or beside a
##                                 target by what the party needs, stands
##                                 outside his own light, and spends the ring
##                                 spell as a rescue.
##
## A role RE-DECIDES on a ~8 Hz beat and STEERS every frame with nothing but
## vector maths, so adding companions costs almost nothing per frame.

var body: Node3D = null           # the companion player instance

var _brain: SquadBrain = null
var _role: AIRole = null
var _role_class := -1


func _ready() -> void:
	if body == null:
		body = get_parent()


func _physics_process(delta: float) -> void:
	if body == null or not is_instance_valid(body):
		return
	if _brain == null or not is_instance_valid(_brain):
		_brain = SquadBrain.get_brain(self)
		if _brain == null:
			return
	if "is_dead" in body and body.is_dead:
		# Downed: no input at all until an ally raises us.
		body._ai_move_vec = Vector2.ZERO
		body._ai_run = false
		body._ai_block = false
		return
	_ensure_role()
	if _role != null:
		_role.update(delta)


## The class is applied after spawn (companion_class_override), and a scenario
## may switch it later — so the role is (re)built whenever the body's class
## stops matching the role driving it.
func _ensure_role() -> void:
	var cls: int = int(body.character_class)
	if _role != null and _role_class == cls:
		return
	_role_class = cls
	_role = _role_for(cls)
	_role.setup(body as Player, _brain)
	print("CompanionAI: %s behaviour online" % _role.role_name)


## THE ONLY PLACE A CLASS IS NAMED. One behaviour per class, one file each; a
## third class is a new file and one line here, and nothing else in the co-op
## AI has to be read or changed to add it.
func _role_for(cls: int) -> AIRole:
	match cls:
		Player.CharacterClass.PALADIN:
			return PaladinRole.new()
		Player.CharacterClass.ARCHER:
			return ArcherRole.new()
	push_warning("CompanionAI: no behaviour for character class %d" % cls)
	return ArcherRole.new()


## One line of "what is this AI doing and why", for playtest logs and the
## COOPSIM scenario.
func debug_line() -> String:
	if _role == null or _brain == null:
		return "companion: booting"
	return "%s tactic=%s hp=%.0f%% | %s" % [
			_role.role_name, _role.tactic, _role.hp_frac() * 100.0,
			_brain.status_line()]
