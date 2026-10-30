class_name ArenaBrazier
extends StaticBody3D
## A fire on the dark platform: most of the light the fight has. The boss's
## blows knock it out (slam and head shockwaves, a claw raked through the
## bowl, the gust of a roar); a burning arrow in the bowl lights it again.
## Left alone, the embers catch by themselves after EMBER_RELIGHT seconds,
## so a fight without an archer does not stay blind for good.

## Physics layer only arrows look at (player/arrow.gd): players, the boss and
## the terrain guard all ignore it, so the bowl blocks nothing but a shot.
const ARROW_LAYER := 32
const EMBER_RELIGHT := 30.0

signal changed(lit: bool)

var lit := true
var energy := 6.0
var reach := 14.0
var _light: OmniLight3D
var _flames: GPUParticles3D
var _embers: GPUParticles3D
var _out_t := 0.0
var _fade: Tween


func build(at: Vector3, light_energy: float, light_range: float, stone: Material) -> void:
	name = "Brazier"
	position = at
	energy = light_energy
	reach = light_range
	# Catches arrows only while it is out; a lit bowl lets shots pass.
	collision_layer = 0
	collision_mask = 0
	add_to_group("braziers")
	add_to_group("brazier_light")
	var cs := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = 0.8
	shape.height = 1.4
	cs.shape = shape
	cs.position = Vector3(0, 1.45, 0)
	add_child(cs)
	# A carved stone pedestal and a wide iron bowl with a real fire in it.
	var ped := MeshInstance3D.new()
	var pm := CylinderMesh.new()
	pm.top_radius = 0.28
	pm.bottom_radius = 0.42
	pm.height = 1.0
	pm.radial_segments = 8
	ped.mesh = pm
	ped.material_override = stone
	ped.position = Vector3(0, 0.5, 0)
	add_child(ped)
	var bowl := MeshInstance3D.new()
	var bm := CylinderMesh.new()
	bm.top_radius = 0.62
	bm.bottom_radius = 0.3
	bm.height = 0.32
	bm.radial_segments = 12
	bowl.mesh = bm
	var iron := StandardMaterial3D.new()
	iron.albedo_color = Color(0.08, 0.07, 0.065)
	iron.metallic = 0.85
	iron.roughness = 0.45
	bowl.material_override = iron
	bowl.position = Vector3(0, 1.16, 0)
	add_child(bowl)
	_light = FireFX.add_fire_light(self, Vector3(0, 1.8, 0), energy, reach, false)
	# The fog scatters the fire: a warm halo that says "light here" from afar.
	_light.light_volumetric_fog_energy = 2.5
	_flames = FireFX.add_flames(self, Vector3(0, 1.3, 0), 1.3, 40)
	_embers = FireFX.add_embers(self, Vector3(0, 1.5, 0), 0.8, 16)


## Where an archer aims to light it.
func aim_point() -> Vector3:
	return global_position + Vector3(0, 1.35, 0)


func douse() -> void:
	if not lit:
		return
	lit = false
	_out_t = 0.0
	collision_layer = ARROW_LAYER
	remove_from_group("brazier_light")
	_flames.emitting = false
	_embers.emitting = false
	var tw: Tween = _light.get_meta("flicker_tween") if _light.has_meta("flicker_tween") else null
	if tw != null:
		tw.kill()
	_fade = _light.create_tween()
	_fade.tween_property(_light, "light_energy", 0.0, 0.35)
	var smoke := FireFX.add_smoke(self, Vector3(0, 1.4, 0), 1.2, 30)
	smoke.one_shot = true
	smoke.emitting = true
	get_tree().create_timer(4.0).timeout.connect(smoke.queue_free)
	Sfx.play3d("spell_fire_end", aim_point(), 4.0)
	changed.emit(false)


func kindle() -> bool:
	if lit:
		return false
	lit = true
	collision_layer = 0
	if _fade != null:
		_fade.kill()
	add_to_group("brazier_light")
	_flames.emitting = true
	_embers.emitting = true
	_light.light_energy = energy
	FireFX.start_flicker(_light, energy)
	Sfx.play3d("fire_ignite", aim_point(), 4.0)
	changed.emit(true)
	return true


func _physics_process(delta: float) -> void:
	if lit:
		return
	_out_t += delta
	if _out_t >= EMBER_RELIGHT:
		kindle()
