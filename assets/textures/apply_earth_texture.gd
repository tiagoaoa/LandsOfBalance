extends SceneTree
## Run with: godot --headless --script res://assets/textures/apply_earth_texture.gd

func _init() -> void:
	print("Applying earth texture to terrain...")

	var scene_path := "res://stage/lands_of_balance.tscn"
	var packed: PackedScene = load(scene_path)
	if packed == null:
		push_error("Failed to load scene")
		quit()
		return

	var scene: Node3D = packed.instantiate()

	# Find MainGround
	var main_ground: CSGBox3D = scene.get_node_or_null("Ground/MainGround")
	if main_ground == null:
		push_error("Could not find Ground/MainGround")
		quit()
		return

	# Create earth material with Ground037 textures
	var material := StandardMaterial3D.new()

	# Load textures
	var color_tex: Texture2D = load("res://assets/textures/Ground037_1K-JPG_Color.jpg")
	var normal_tex: Texture2D = load("res://assets/textures/Ground037_1K-JPG_NormalGL.jpg")
	var roughness_tex: Texture2D = load("res://assets/textures/Ground037_1K-JPG_Roughness.jpg")
	var ao_tex: Texture2D = load("res://assets/textures/Ground037_1K-JPG_AmbientOcclusion.jpg")

	if color_tex:
		material.albedo_texture = color_tex
	if normal_tex:
		material.normal_enabled = true
		material.normal_texture = normal_tex
	if roughness_tex:
		material.roughness_texture = roughness_tex
	if ao_tex:
		material.ao_enabled = true
		material.ao_texture = ao_tex

	# Scale UV for large terrain (300x300)
	material.uv1_scale = Vector3(30, 30, 30)

	# Apply material
	main_ground.material = material

	# Save the modified scene
	var new_packed := PackedScene.new()
	new_packed.pack(scene)
	var err := ResourceSaver.save(new_packed, scene_path)
	if err == OK:
		print("Done! Applied earth texture to MainGround")
	else:
		push_error("Failed to save: " + str(err))

	scene.queue_free()
	quit()
