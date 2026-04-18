extends Node3D


func _ready() -> void:
	if RenderingServer.get_current_rendering_method() == "gl_compatibility":
		# Use PCF13 shadow filtering to improve quality (Medium maps to PCF5 instead).
		RenderingServer.directional_soft_shadow_filter_set_quality(RenderingServer.SHADOW_QUALITY_SOFT_HIGH)

		# Darken the light's energy to compensate for sRGB blending (without affecting sky rendering).
		$DirectionalLight3D.sky_mode = DirectionalLight3D.SKY_MODE_SKY_ONLY
		var new_light: DirectionalLight3D = $DirectionalLight3D.duplicate()
		new_light.light_energy = 0.25
		new_light.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY
		add_child(new_light)

	if _is_performance_mode():
		_apply_performance_mode()


func _is_performance_mode() -> bool:
	if OS.has_feature("mobile"):
		return true
	return GameSettings != null and GameSettings.performance_mode


func _apply_performance_mode() -> void:
	print("Stage: Applying performance mode")

	# Keep SimpleGrassTextured on — the RealisticGrassPlacer populates it
	# with the tall-blade field that defines the game's look. We reduce
	# density instead of killing it so perf mode still *has* grass.
	var simple_grass := get_node_or_null("SimpleGrassTextured")
	if simple_grass:
		simple_grass.visible = true
		simple_grass.process_mode = Node.PROCESS_MODE_INHERIT

	for node_path in ["Grass/GrassMultiMesh_0", "Grass/GrassMultiMesh_1", "Grass/GrassMultiMesh_2"]:
		var grass_patch := get_node_or_null(node_path)
		if grass_patch:
			grass_patch.visible = false

	# RealisticGrassPlacer reads GameSettings.performance_mode itself at
	# _ready() time and scales its own blade density — nothing to do here.
	var realistic_grass := get_node_or_null("Grass/RealisticGrass")
	if realistic_grass:
		realistic_grass.visible = true
		if "grass_count" in realistic_grass:
			realistic_grass.grass_count = min(realistic_grass.grass_count, 200)

	var moon_light := get_node_or_null("Moon/MoonLight")
	if moon_light and moon_light is DirectionalLight3D:
		moon_light.shadow_enabled = false
