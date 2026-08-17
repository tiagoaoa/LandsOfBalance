class_name FireGlow
extends RefCounted
## Makes firelight VISIBLY land on a body, so "the archer revealed it" is
## something you can see rather than something the AI merely knows.
##
## The night is genuinely black — measured, the middle of a combat frame has a
## median luma of 0 — and the field is waist-high grass. Between the two, an
## enemy standing 13 m away inside a burning pool is still only a dark shape
## behind blades: the ground lights up beautifully and the thing you needed to
## find does not. On a phone, held in daylight, it is nothing at all.
##
## So a lit body warms and brightens from its own surface. This is not a HUD
## marker or an outline drawn through the world — it is bounded by the same
## fire radius the AI uses, it fades with distance from the flames, and it
## cannot show you anything a hill or a wall is hiding. The archer lighting
## the dark is the only thing that switches it on.

## Warm enough to read as firelight rather than as a highlight effect.
const GLOW_COLOR := Color(1.0, 0.52, 0.20)
## Peak emission for a body standing in the flames. Tuned against the night
## grade (tonemap ACES, exposure 1.0, white 6.0) — high enough to separate a
## body from black grass, low enough that it never reads as self-lit.
const GLOW_ENERGY := 1.5
## Seconds-ish to ramp. Firelight arriving on a body over a beat looks like
## light; arriving on a frame looks like a toggle.
const GLOW_RATE := 4.0

var _materials: Array[StandardMaterial3D] = []
var _amount: float = 0.0


## Collect the surface overrides already installed on `root`. Overrides only:
## a material shared with another instance would light every skeleton at once.
func collect(root: Node) -> void:
	_materials.clear()
	if root == null:
		return
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		for si in mi.mesh.get_surface_count():
			var m := mi.get_surface_override_material(si) as StandardMaterial3D
			if m != null and not _materials.has(m):
				_materials.append(m)


func has_materials() -> bool:
	return not _materials.is_empty()


## Ease toward `target` (0..1, from Perception.fire_lit_amount) and write it.
func update(target: float, delta: float) -> void:
	if _materials.is_empty():
		return
	var next: float = move_toward(_amount, clampf(target, 0.0, 1.0), GLOW_RATE * delta)
	if is_equal_approx(next, _amount):
		return
	_amount = next
	for m in _materials:
		if m == null:
			continue
		# Emission is switched OFF rather than left on at zero energy: an
		# enabled emission channel is not free on the mobile renderer, and
		# most of these bodies are in the dark most of the time.
		if _amount <= 0.001:
			m.emission_enabled = false
			continue
		m.emission_enabled = true
		m.emission = GLOW_COLOR
		m.emission_energy_multiplier = GLOW_ENERGY * _amount
