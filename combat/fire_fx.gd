class_name FireFX
extends RefCounted

## Shared procedural fire effects — one recipe for every flame in the game
## (arrow tip, arrow ground fire, network ground fires, future braziers).
##
## Design rules:
## - Flames are ADDITIVE billboards driven by a white→yellow→orange→red ramp
##   and a grow-shrink scale curve; alpha-blend quads read as fog, not fire.
## - Embers use GPU turbulence so they drift like real sparks.
## - Lights are single-digit energies with a proportional flicker. (The old
##   500-energy "fireplace" lights nuked the whole rainy-night grade.)


static func flame_gradient() -> GradientTexture1D:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.15, 0.35, 0.55, 0.75, 1.0])
	g.colors = PackedColorArray([
		Color(1.0, 1.0, 0.9, 0.9),    # white-hot core
		Color(1.0, 0.85, 0.3, 1.0),   # bright yellow
		Color(1.0, 0.5, 0.1, 1.0),    # orange
		Color(0.95, 0.25, 0.05, 0.9), # bright red
		Color(0.7, 0.1, 0.02, 0.6),   # deep red
		Color(0.3, 0.05, 0.01, 0.0),  # fade out
	])
	var tex := GradientTexture1D.new()
	tex.gradient = g
	tex.width = 256
	return tex


static func _flame_scale_curve() -> CurveTexture:
	var c := Curve.new()
	c.add_point(Vector2(0.0, 0.35))
	c.add_point(Vector2(0.25, 1.0))
	c.add_point(Vector2(0.65, 0.65))
	c.add_point(Vector2(1.0, 0.05))
	var tex := CurveTexture.new()
	tex.curve = c
	return tex


## Soft radial falloff sprite — without it every particle is a hard-edged
## rectangle and the fire reads as glowing confetti.
static func _soft_circle_tex() -> GradientTexture2D:
	var g := Gradient.new()
	g.interpolation_mode = Gradient.GRADIENT_INTERPOLATE_CUBIC
	g.offsets = PackedFloat32Array([0.0, 0.35, 1.0])
	g.colors = PackedColorArray([
		Color(1, 1, 1, 1),
		Color(1, 1, 1, 0.55),
		Color(1, 1, 1, 0.0),
	])
	var tex := GradientTexture2D.new()
	tex.gradient = g
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(0.5, 0.0)
	tex.width = 64
	tex.height = 64
	return tex


static func _additive_billboard(size: Vector2) -> QuadMesh:
	var mesh := QuadMesh.new()
	mesh.size = size
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = Color(1, 1, 1, 1)
	mat.albedo_texture = _soft_circle_tex()
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.45, 0.1)
	mat.emission_energy_multiplier = 2.5
	mesh.material = mat
	return mesh


## Licking flame tongues. `size` ~ flame height in metres.
static func add_flames(parent: Node, pos: Vector3, size: float, amount: int) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.name = "Flames"
	p.amount = amount
	p.lifetime = 0.55
	p.randomness = 0.5
	p.position = pos
	p.visibility_aabb = AABB(Vector3(-3, -1, -3), Vector3(6, 6, 6))

	var m := ParticleProcessMaterial.new()
	m.direction = Vector3(0, 1, 0)
	m.spread = 12.0
	m.initial_velocity_min = 0.8 * size
	m.initial_velocity_max = 2.2 * size
	m.gravity = Vector3(0, 1.5, 0)  # buoyant — flames accelerate upward
	m.scale_min = 0.55 * size
	m.scale_max = 1.0 * size
	m.scale_curve = _flame_scale_curve()
	m.color_ramp = flame_gradient()
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	m.emission_sphere_radius = 0.22 * size
	p.process_material = m

	p.draw_pass_1 = _additive_billboard(Vector2(0.4, 0.6) * size)
	parent.add_child(p)
	return p


## Drifting sparks — turbulence makes them wander like real embers.
static func add_embers(parent: Node, pos: Vector3, size: float, amount: int) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.name = "Embers"
	p.amount = amount
	p.lifetime = 1.6
	p.randomness = 0.8
	p.position = pos
	p.visibility_aabb = AABB(Vector3(-4, -1, -4), Vector3(8, 8, 8))

	var m := ParticleProcessMaterial.new()
	m.direction = Vector3(0, 1, 0)
	m.spread = 25.0
	m.initial_velocity_min = 1.2 * size
	m.initial_velocity_max = 3.0 * size
	m.gravity = Vector3(0, 0.6, 0)
	m.damping_min = 0.4
	m.damping_max = 1.2
	m.scale_min = 0.5
	m.scale_max = 1.0
	m.turbulence_enabled = true
	m.turbulence_noise_strength = 0.7
	m.turbulence_noise_scale = 2.5
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	m.emission_sphere_radius = 0.3 * size

	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.6, 1.0])
	g.colors = PackedColorArray([
		Color(1.0, 0.8, 0.35, 1.0),
		Color(1.0, 0.4, 0.08, 0.9),
		Color(0.5, 0.08, 0.01, 0.0),
	])
	var ramp := GradientTexture1D.new()
	ramp.gradient = g
	m.color_ramp = ramp
	p.process_material = m

	p.draw_pass_1 = _additive_billboard(Vector2(0.05, 0.05) * maxf(size, 0.6))
	parent.add_child(p)
	return p


## Slow dark smoke column above the flames (alpha blend, not additive).
static func add_smoke(parent: Node, pos: Vector3, size: float, amount: int) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.name = "Smoke"
	p.amount = amount
	p.lifetime = 2.6
	p.randomness = 0.6
	p.position = pos
	p.visibility_aabb = AABB(Vector3(-4, -1, -4), Vector3(8, 10, 8))

	var m := ParticleProcessMaterial.new()
	m.direction = Vector3(0, 1, 0)
	m.spread = 15.0
	m.initial_velocity_min = 0.5 * size
	m.initial_velocity_max = 1.2 * size
	m.gravity = Vector3(0, 0.4, 0)
	m.scale_min = 0.6 * size
	m.scale_max = 1.4 * size
	# Smoke expands as it rises.
	var c := Curve.new()
	c.add_point(Vector2(0.0, 0.4))
	c.add_point(Vector2(1.0, 1.6))
	var ctex := CurveTexture.new()
	ctex.curve = c
	m.scale_curve = ctex
	m.turbulence_enabled = true
	m.turbulence_noise_strength = 0.5
	m.turbulence_noise_scale = 1.8

	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.25, 1.0])
	g.colors = PackedColorArray([
		Color(0.12, 0.11, 0.10, 0.0),
		Color(0.14, 0.13, 0.12, 0.35),
		Color(0.10, 0.10, 0.10, 0.0),
	])
	var ramp := GradientTexture1D.new()
	ramp.gradient = g
	m.color_ramp = ramp
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	m.emission_sphere_radius = 0.25 * size
	p.process_material = m

	var mesh := QuadMesh.new()
	mesh.size = Vector2(0.8, 0.8) * size
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.vertex_color_use_as_albedo = true
	mat.albedo_texture = _soft_circle_tex()
	mesh.material = mat
	p.draw_pass_1 = mesh
	parent.add_child(p)
	return p


## Warm fire light with a proportional flicker loop.
static func add_fire_light(parent: Node, pos: Vector3, energy: float,
		radius: float, shadows: bool) -> OmniLight3D:
	var light := OmniLight3D.new()
	light.name = "FireLight"
	light.light_color = Color(1.0, 0.55, 0.18)
	light.light_energy = energy
	light.omni_range = radius
	light.omni_attenuation = 1.0  # linear falloff — a wide, useful throw
	light.shadow_enabled = shadows
	light.position = pos
	parent.add_child(light)
	start_flicker(light, energy)
	return light


## Looping flicker scaled to the light's base energy (±25%). The tween is
## stored on the light (meta "flicker_tween") so a burn-down can kill it —
## otherwise the loop keeps re-lighting a fire that's supposed to be dying.
static func start_flicker(light: OmniLight3D, base_energy: float) -> void:
	var tw := light.create_tween()
	tw.set_loops()
	tw.tween_property(light, "light_energy", base_energy * 1.25, 0.09)
	tw.tween_property(light, "light_energy", base_energy * 0.8, 0.14)
	tw.tween_property(light, "light_energy", base_energy * 1.1, 0.07)
	tw.tween_property(light, "light_energy", base_energy * 0.9, 0.12)
	light.set_meta("flicker_tween", tw)


## Dark scorched-earth patch under the fire.
static func add_scorch_decal(parent: Node, radius: float) -> Decal:
	var g := Gradient.new()
	g.interpolation_mode = Gradient.GRADIENT_INTERPOLATE_CUBIC
	g.offsets = PackedFloat32Array([0.0, 0.55, 1.0])
	g.colors = PackedColorArray([
		Color(0.05, 0.04, 0.03, 0.85),
		Color(0.07, 0.05, 0.04, 0.5),
		Color(0.0, 0.0, 0.0, 0.0),
	])
	var tex := GradientTexture2D.new()
	tex.gradient = g
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(0.5, 0.0)
	tex.width = 128
	tex.height = 128

	var decal := Decal.new()
	decal.name = "ScorchDecal"
	decal.texture_albedo = tex
	decal.size = Vector3(radius * 2.0, 2.0, radius * 2.0)
	decal.albedo_mix = 0.9
	decal.cull_mask = 1  # ground only — don't paint characters standing in it
	parent.add_child(decal)
	return decal


## Full ground-fire composition: lights, layered flames, embers, smoke and
## scorch, with a soft burn-down in the last few seconds and auto-free at
## `lifetime`. Returns the container (caller adds gameplay bits like the
## damage aura). `node_name` must keep "GroundFire" in it — Bobba's fire
## avoidance scans node names for that substring.
static func create_ground_fire(scene_root: Node, world_pos: Vector3,
		node_name: String, lifetime: float, shadows: bool) -> Node3D:
	var fire := Node3D.new()
	fire.name = node_name
	fire.add_to_group("ground_fire")  # AI perception + Bobba's fire avoidance
	scene_root.add_child(fire)
	fire.global_position = world_pos

	# The fire is a TACTICAL BEACON, not just a hazard: the archer drops
	# these to light paths and reveal enemies for the paladin, and to wall
	# off pursuers during a retreat. Big bright pool, well beyond the 5m
	# damage aura — raised off the ground so the knee-high grass doesn't
	# swallow the throw.
	var light := add_fire_light(fire, Vector3(0, 1.4, 0), 30.0, 18.0, shadows)
	var core := add_flames(fire, Vector3(0, 0.15, 0), 1.0, 40)
	var outer := add_flames(fire, Vector3(0, 0.1, 0), 1.6, 24)
	var embers := add_embers(fire, Vector3(0, 0.3, 0), 1.0, 30)
	var smoke := add_smoke(fire, Vector3(0, 0.9, 0), 1.0, 16)
	add_scorch_decal(fire, 1.8)

	# Ignite whump + crackle loop for the fire's lifetime.
	var sfx := fire.get_node_or_null("/root/Sfx")
	var crackle: AudioStreamPlayer3D = null
	if sfx:
		sfx.play3d("fire_ignite", world_pos, -3.0)
		crackle = sfx.loop3d("fire_crackle_loop", fire, Vector3(0, 0.5, 0), -6.0, 24.0)

	# Burn-down: stop feeding the fire 3s before the end and dim the light,
	# so it dies like a fire instead of blinking out.
	var burn_down := func() -> void:
		# The scene can reload (death/restart) while this timer is pending —
		# every captured node may already be freed.
		if not is_instance_valid(fire) or not is_instance_valid(light):
			return
		if is_instance_valid(core):
			core.emitting = false
		if is_instance_valid(outer):
			outer.emitting = false
		if is_instance_valid(embers):
			embers.emitting = false
		if is_instance_valid(smoke):
			smoke.emitting = false
		if light.has_meta("flicker_tween"):
			var flicker: Tween = light.get_meta("flicker_tween")
			if flicker:
				flicker.kill()
		var tw := fire.create_tween()
		tw.tween_property(light, "light_energy", 0.0, 2.5)
		if crackle != null and is_instance_valid(crackle):
			tw.parallel().tween_property(crackle, "volume_db", -40.0, 2.5)
	fire.get_tree().create_timer(maxf(lifetime - 3.0, 0.1)).timeout.connect(burn_down)
	fire.get_tree().create_timer(lifetime).timeout.connect(fire.queue_free)
	return fire
