extends RefCounted

static var grain: NoiseTexture2D


static func apply(node: Node) -> void:
	if node is MeshInstance3D and node.mesh:
		for i in range(node.mesh.get_surface_count()):
			var mat := node.mesh.surface_get_material(i) as StandardMaterial3D
			if mat and mat.resource_name in ["Tempered steel", "Weathered wool", "Aged brass"]:
				node.set_surface_override_material(i, _finish(mat))
			elif mat and mat.resource_name in ["model.021", "model.022"]:
				var worn := mat.duplicate() as StandardMaterial3D
				var cloth := mat.resource_name == "model.021"
				worn.roughness_texture = null
				worn.roughness = 0.88 if cloth else 0.52
				worn.metallic = 0.0 if cloth else minf(worn.metallic, 0.65)
				worn.albedo_color = Color(0.78, 0.72, 0.60)
				node.set_surface_override_material(i, worn)
	for child in node.get_children():
		apply(child)


static func _finish(src: StandardMaterial3D) -> StandardMaterial3D:
	if not grain:
		var noise := FastNoiseLite.new()
		noise.seed = 73
		noise.frequency = 0.055
		noise.fractal_octaves = 3
		grain = NoiseTexture2D.new()
		grain.width = 256
		grain.height = 256
		grain.seamless = true
		grain.noise = noise
		grain.as_normal_map = true
		grain.bump_strength = 0.35
	var mat := src.duplicate() as StandardMaterial3D
	mat.normal_enabled = true
	mat.normal_texture = grain
	mat.normal_scale = 0.32 if src.metallic > 0.5 else 0.6
	mat.uv1_triplanar = true
	mat.uv1_scale = Vector3.ONE * (8.0 if src.metallic > 0.5 else 18.0)
	return mat
