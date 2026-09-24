extends RefCounted


static func sigil(color: Color, diameter: float) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2.ONE * diameter
	node.mesh = plane
	var mat := ShaderMaterial.new()
	mat.shader = preload("res://combat/ritual_sigil.gdshader")
	mat.set_shader_parameter("glow_color", color)
	node.material_override = mat
	node.position.y = 0.045
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return node


static func flame_mesh() -> QuadMesh:
	var mesh := QuadMesh.new()
	mesh.size = Vector2(0.45, 0.85)
	var mat := ShaderMaterial.new()
	mat.shader = preload("res://combat/flame_sprite.gdshader")
	mesh.material = mat
	return mesh


static func ring_flame(pos: Vector3) -> GPUParticles3D:
	var fire := GPUParticles3D.new()
	fire.emitting = false
	fire.amount = 44
	fire.lifetime = 1.15
	fire.randomness = .35
	fire.position = pos
	fire.visibility_aabb = AABB(Vector3(-2, -1, -2), Vector3(4, 7, 4))
	var mat := ParticleProcessMaterial.new()
	mat.direction = Vector3.UP
	mat.spread = 14.0
	mat.initial_velocity_min = 1.6
	mat.initial_velocity_max = 3.0
	mat.gravity = Vector3(0, 1.2, 0)
	mat.damping_min = .15
	mat.damping_max = .5
	mat.scale_min = .75
	mat.scale_max = 1.25
	mat.scale_curve = FireFX._flame_scale_curve()
	mat.color_ramp = FireFX.flame_gradient()
	mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	mat.emission_sphere_radius = .32
	fire.process_material = mat
	fire.draw_pass_1 = flame_mesh()
	return fire


static func sparks(rising: bool, color: Color = Color(.35, .65, 1.0)) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.emitting = false
	p.amount = 96 if rising else 80
	p.lifetime = 1.65 if rising else .8
	p.randomness = .5
	p.visibility_aabb = AABB(Vector3(-4, -1, -4), Vector3(8, 12, 8))
	var mat := ParticleProcessMaterial.new()
	mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
	mat.emission_ring_axis = Vector3.UP
	mat.emission_ring_height = .15 if rising else 1.8
	mat.emission_ring_radius = 1.8 if rising else .85
	mat.emission_ring_inner_radius = 1.5 if rising else .45
	mat.direction = Vector3.UP
	mat.spread = 12.0 if rising else 45.0
	mat.initial_velocity_min = 2.2
	mat.initial_velocity_max = 4.0
	mat.gravity = Vector3(0, .6, 0)
	mat.scale_min = .5
	mat.scale_max = 1.0
	var ramp := Gradient.new()
	ramp.offsets = PackedFloat32Array([0, .15, .7, 1])
	ramp.colors = PackedColorArray([Color(color, 0), color, Color(color, .8), Color(color, 0)])
	var tex := GradientTexture1D.new()
	tex.gradient = ramp
	mat.color_ramp = tex
	p.process_material = mat
	var mesh := FireFX._additive_billboard(Vector2(.04, .16))
	mesh.material.emission = color
	mesh.material.emission_energy_multiplier = 1.5
	p.draw_pass_1 = mesh
	p.position.y = .1 if rising else 1.0
	return p


static func place_arcs(arcs: Array) -> void:
	for i in range(arcs.size()):
		var angle := TAU * i / arcs.size() + randf_range(-.2, .2)
		var radial := Vector3(cos(angle), 0, sin(angle))
		arcs[i].set_origin(radial * .4 + Vector3.UP * randf_range(.4, 1.1))
		arcs[i].set_end(radial * randf_range(.8, 1.6)
				+ Vector3.UP * randf_range(2.4, 4.6))
