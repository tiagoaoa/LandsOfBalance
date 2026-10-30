class_name BossSpells
extends Node

## Candidate spells for the boss arena, one per class on the second spell
## key (Z / D-pad up), chosen per run so playtests can compare kits:
##   LOB_SPELL_PALADIN = leap          Skyward Leap: much higher jumps for a
##                                     while — onto arms, ledges, plunges.
##   LOB_SPELL_ARCHER  = incendiary    the next arrows set the hide alight
##                     | decoy         two spirit hounds draw the giant's eye
##                     | mark          glowing runes on its joints: critical,
##                                     poise-cracking shots
## The class's original spell (C) is untouched.

signal cast(kind: String)

const COOLDOWN := {"leap": 16.0, "incendiary": 18.0, "decoy": 22.0, "mark": 18.0}
const LEAP_TIME := 7.0
const LEAP_MULT := 2.3

var body: Player
var arena: Node
var kind := ""
var cd := 3.0
var _leap_left := 0.0
var _aura: OmniLight3D


static func kind_for(p: Player) -> String:
	if p.is_paladin():
		var k := OS.get_environment("LOB_SPELL_PALADIN")
		return k if k != "" else "leap"
	var a := OS.get_environment("LOB_SPELL_ARCHER")
	return a if a != "" else "incendiary"


func ready_now() -> bool:
	return cd <= 0.0 and kind != "none"


func _physics_process(delta: float) -> void:
	if body == null or not is_instance_valid(body):
		return
	cd -= delta
	if _leap_left > 0.0:
		_leap_left -= delta
		if _leap_left <= 0.0:
			body.jump_mult = 1.0
			if _aura:
				_aura.queue_free()
				_aura = null
	var pressed: bool = body._ai_spell2 if body.ai_driven else Input.is_action_just_pressed(&"spell_alt")
	body._ai_spell2 = false
	var seized: bool = arena != null and is_instance_valid(arena.get("boss")) \
			and arena.boss.grab_victim() == body
	if pressed and ready_now() and not body.is_dead and not seized:
		_cast()


func _cast() -> void:
	cd = COOLDOWN.get(kind, 18.0)
	match kind:
		"leap":
			_leap_left = LEAP_TIME
			body.jump_mult = LEAP_MULT
			_aura = OmniLight3D.new()
			_aura.light_color = Color(0.5, 0.75, 1.0)
			_aura.light_energy = 2.0
			_aura.omni_range = 3.5
			_aura.position = Vector3(0, 1.0, 0)
			body.add_child(_aura)
			Sfx.play3d("spell_lightning_start", body.global_position, -2.0)
		"incendiary":
			body.set_meta("incendiary", 6)
			Sfx.play3d("spell_fire_start", body.global_position, -2.0)
		"decoy":
			if arena and arena.has_method("spawn_decoys"):
				arena.spawn_decoys(body.global_position, 2)
			Sfx.play3d("spell_lightning_start", body.global_position, -4.0)
		"mark":
			if arena and arena.boss:
				arena.boss.add_marks(3, 9.0)
			Sfx.play3d("spell_fire_end", body.global_position, -2.0)
	cast.emit(kind)
