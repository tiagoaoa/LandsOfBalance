extends Node3D

## Test scene for dragon wing animation
## Dragon hovers 3 meters above ground, centered at spawn, just flapping wings

const DragonWingFlapClass := preload("res://enemies/dragon_wing_flap.gd")

var _dragon_model: Node3D
var _anim_player: AnimationPlayer
var _camera: Camera3D
var _skeleton: Skeleton3D
var _bone_markers: Dictionary = {}  # bone_name -> {sphere, label}

# Camera control
var _mouse_captured := false
var _camera_rotation := Vector2(-30, -45)  # pitch, yaw in degrees
var _camera_distance := 150.0
var _camera_target := Vector3(0, 50, 0)
const MOUSE_SENSITIVITY := 0.3
const MOVE_SPEED := 100.0
const ZOOM_SPEED := 10.0

# UI Controls
var _ui_panel: Control
var _bone_sliders: Dictionary = {}  # bone_key -> {x, y, z sliders}
var _manual_mode := false  # When true, manually control bones instead of animation

# Bone indices for head/neck
var _head_bone_idx := -1
var _neck_bone_indices: Array[int] = []

# Head/neck bone names from DragonWingFlap
const NECK_BONE_NAMES := {
	"Head": "NPC Head_046",
	"Neck5": "NPC Neck5_044",
	"Neck4": "NPC Neck4_043",
	"Neck3": "NPC Neck3_042",
	"Neck2": "NPC Neck2_041",
	"Neck1": "NPC Neck1_040",
}


func _ready() -> void:
	# Setup camera to view the dragon
	_setup_camera()

	# Setup lighting
	_setup_lighting()

	# Setup ground plane for reference
	_setup_ground()

	# Setup 3D axis at origin
	_setup_axis()

	# Load and position dragon
	_setup_dragon()

	# Setup UI controls for bone adjustment
	_setup_ui()

	print("=== Dragon Wing Test ===")
	print("Click - Capture mouse for camera control")
	print("ESC - Release mouse")
	print("WASD - Move camera")
	print("Q/E - Move up/down")
	print("Mouse - Rotate view (when captured)")
	print("Scroll wheel - Zoom in/out")
	print("R - Restart animation")
	print("SPACE - Pause/resume")
	print("M - Toggle manual bone control mode")
	print("P - Print current bone values")
	print("X - Quit")


func _setup_camera() -> void:
	_camera = Camera3D.new()
	_camera.name = "TestCamera"
	add_child(_camera)
	_camera.current = true
	_camera.far = 1000.0
	_update_camera_position()


func _setup_lighting() -> void:
	# Directional light (sun)
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-45, 45, 0)
	sun.light_energy = 1.0
	sun.shadow_enabled = true
	add_child(sun)

	# Environment for ambient light
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.4, 0.6, 0.8)  # Sky blue
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.3, 0.3, 0.4)
	env.ambient_light_energy = 0.5

	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)


func _setup_ground() -> void:
	# Simple ground plane for reference
	var ground := MeshInstance3D.new()
	ground.name = "Ground"

	var plane_mesh := PlaneMesh.new()
	plane_mesh.size = Vector2(50, 50)
	ground.mesh = plane_mesh

	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.3, 0.5, 0.2)  # Grass green
	ground.material_override = material

	ground.position = Vector3(0, 0, 0)
	add_child(ground)


func _setup_axis() -> void:
	# Draw 3D axis at origin: X=Red, Y=Green, Z=Blue
	var axis_length := 30.0
	var axis_thickness := 0.5

	# X axis (Red) - points right
	var x_axis := MeshInstance3D.new()
	var x_mesh := CylinderMesh.new()
	x_mesh.top_radius = axis_thickness
	x_mesh.bottom_radius = axis_thickness
	x_mesh.height = axis_length
	x_axis.mesh = x_mesh
	var x_mat := StandardMaterial3D.new()
	x_mat.albedo_color = Color(1, 0, 0)  # Red
	x_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	x_axis.material_override = x_mat
	x_axis.position = Vector3(axis_length / 2, 0, 0)
	x_axis.rotation_degrees = Vector3(0, 0, 90)  # Rotate to point along X
	add_child(x_axis)

	# X label
	var x_label := Label3D.new()
	x_label.text = "X"
	x_label.font_size = 64
	x_label.pixel_size = 0.1
	x_label.modulate = Color(1, 0, 0)
	x_label.position = Vector3(axis_length + 3, 0, 0)
	x_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	add_child(x_label)

	# Y axis (Green) - points up
	var y_axis := MeshInstance3D.new()
	var y_mesh := CylinderMesh.new()
	y_mesh.top_radius = axis_thickness
	y_mesh.bottom_radius = axis_thickness
	y_mesh.height = axis_length
	y_axis.mesh = y_mesh
	var y_mat := StandardMaterial3D.new()
	y_mat.albedo_color = Color(0, 1, 0)  # Green
	y_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	y_axis.material_override = y_mat
	y_axis.position = Vector3(0, axis_length / 2, 0)
	# No rotation needed, cylinder points up by default
	add_child(y_axis)

	# Y label
	var y_label := Label3D.new()
	y_label.text = "Y (UP)"
	y_label.font_size = 64
	y_label.pixel_size = 0.1
	y_label.modulate = Color(0, 1, 0)
	y_label.position = Vector3(0, axis_length + 3, 0)
	y_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	add_child(y_label)

	# Z axis (Blue) - points forward
	var z_axis := MeshInstance3D.new()
	var z_mesh := CylinderMesh.new()
	z_mesh.top_radius = axis_thickness
	z_mesh.bottom_radius = axis_thickness
	z_mesh.height = axis_length
	z_axis.mesh = z_mesh
	var z_mat := StandardMaterial3D.new()
	z_mat.albedo_color = Color(0, 0, 1)  # Blue
	z_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	z_axis.material_override = z_mat
	z_axis.position = Vector3(0, 0, axis_length / 2)
	z_axis.rotation_degrees = Vector3(90, 0, 0)  # Rotate to point along Z
	add_child(z_axis)

	# Z label
	var z_label := Label3D.new()
	z_label.text = "Z"
	z_label.font_size = 64
	z_label.pixel_size = 0.1
	z_label.modulate = Color(0, 0, 1)
	z_label.position = Vector3(0, 0, axis_length + 3)
	z_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	add_child(z_label)


func _setup_dragon() -> void:
	# Load the dragon model
	var dragon_scene: PackedScene = load("res://assets/dragon.glb") as PackedScene
	if dragon_scene == null:
		push_error("Failed to load dragon.glb")
		return

	_dragon_model = dragon_scene.instantiate()
	_dragon_model.name = "DragonModel"
	add_child(_dragon_model)

	# Position: 3 meters above ground, centered at spawn (0, 0, 0)
	_dragon_model.position = Vector3(0, 3, 0)

	# Scale: same as in game (50x)
	_dragon_model.scale = Vector3(50, 50, 50)

	# Rotate to face camera (model faces -Z, rotate 180° to face +Z)
	_dragon_model.rotation_degrees = Vector3(0, 180, 0)

	# Find skeleton and create bone markers
	_skeleton = _find_skeleton(_dragon_model)
	if _skeleton:
		_create_bone_markers()

	# Find AnimationPlayer
	_anim_player = _find_animation_player(_dragon_model)
	if _anim_player:
		print("AnimationPlayer found with ", _anim_player.get_animation_list().size(), " animations")

		# Add our procedural wing flap animation
		DragonWingFlapClass.add_to_animation_player(_anim_player, &"WingFlap")

		# Play the wing flap animation
		_anim_player.play(&"WingFlap")
		print("Playing WingFlap animation")
	else:
		push_error("No AnimationPlayer found in dragon model")


func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node as Skeleton3D
	for child in node.get_children():
		var result := _find_skeleton(child)
		if result:
			return result
	return null


func _setup_ui() -> void:
	# Find bone indices
	if _skeleton:
		for bone_key in NECK_BONE_NAMES:
			var bone_name: String = NECK_BONE_NAMES[bone_key]
			var idx := _skeleton.find_bone(bone_name)
			if idx >= 0:
				if bone_key == "Head":
					_head_bone_idx = idx
				else:
					_neck_bone_indices.append(idx)

	# Create UI layer
	var canvas := CanvasLayer.new()
	canvas.name = "UILayer"
	add_child(canvas)

	# Main panel
	_ui_panel = PanelContainer.new()
	_ui_panel.name = "BoneControlPanel"
	_ui_panel.position = Vector2(10, 10)
	_ui_panel.size = Vector2(320, 500)
	canvas.add_child(_ui_panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 2)
	_ui_panel.add_child(vbox)

	# Title
	var title := Label.new()
	title.text = "Head/Neck Bone Controls"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	# Mode toggle
	var mode_btn := CheckButton.new()
	mode_btn.text = "Manual Mode (M)"
	mode_btn.button_pressed = _manual_mode
	mode_btn.toggled.connect(_on_manual_mode_toggled)
	vbox.add_child(mode_btn)

	# Print button
	var print_btn := Button.new()
	print_btn.text = "Print Values (P)"
	print_btn.pressed.connect(_print_bone_values)
	vbox.add_child(print_btn)

	# Separator
	vbox.add_child(HSeparator.new())

	# Create sliders for each bone (Head first, then Neck5 down to Neck1)
	var bone_order := ["Head", "Neck5", "Neck4", "Neck3", "Neck2", "Neck1"]
	for bone_key in bone_order:
		_create_bone_control(vbox, bone_key)


func _create_bone_control(parent: Control, bone_key: String) -> void:
	var group := VBoxContainer.new()
	group.add_theme_constant_override("separation", 0)
	parent.add_child(group)

	# Bone label
	var label := Label.new()
	label.text = bone_key
	label.add_theme_font_size_override("font_size", 14)
	group.add_child(label)

	# Create X, Y, Z sliders
	var sliders := {}
	for axis in ["X", "Y", "Z"]:
		var hbox := HBoxContainer.new()
		group.add_child(hbox)

		var axis_label := Label.new()
		axis_label.text = axis + ":"
		axis_label.custom_minimum_size.x = 20
		hbox.add_child(axis_label)

		var slider := HSlider.new()
		slider.min_value = -180
		slider.max_value = 180
		slider.value = 0
		slider.step = 1
		slider.custom_minimum_size.x = 180
		slider.value_changed.connect(_on_bone_slider_changed.bind(bone_key, axis))
		hbox.add_child(slider)

		var value_label := Label.new()
		value_label.text = "0°"
		value_label.custom_minimum_size.x = 45
		value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		hbox.add_child(value_label)

		sliders[axis] = {"slider": slider, "label": value_label}

	_bone_sliders[bone_key] = sliders

	# Small separator
	var sep := HSeparator.new()
	sep.add_theme_constant_override("separation", 4)
	parent.add_child(sep)


func _on_manual_mode_toggled(pressed: bool) -> void:
	_manual_mode = pressed
	if _manual_mode:
		if _anim_player and _anim_player.is_playing():
			_anim_player.pause()
		print("Manual mode ON - animation paused")
	else:
		print("Manual mode OFF - use R to restart animation")


func _on_bone_slider_changed(value: float, bone_key: String, axis: String) -> void:
	# Update label
	if _bone_sliders.has(bone_key) and _bone_sliders[bone_key].has(axis):
		_bone_sliders[bone_key][axis]["label"].text = "%d°" % int(value)

	# Apply to bone if in manual mode
	if _manual_mode and _skeleton:
		_apply_bone_rotation(bone_key)


func _apply_bone_rotation(bone_key: String) -> void:
	if not _skeleton or not _bone_sliders.has(bone_key):
		return

	var bone_name: String = NECK_BONE_NAMES.get(bone_key, "")
	if bone_name.is_empty():
		return

	var bone_idx := _skeleton.find_bone(bone_name)
	if bone_idx < 0:
		return

	var sliders = _bone_sliders[bone_key]
	var x_deg: float = sliders["X"]["slider"].value
	var y_deg: float = sliders["Y"]["slider"].value
	var z_deg: float = sliders["Z"]["slider"].value

	var rotation := Quaternion.from_euler(Vector3(
		deg_to_rad(x_deg),
		deg_to_rad(y_deg),
		deg_to_rad(z_deg)
	))

	_skeleton.set_bone_pose_rotation(bone_idx, rotation)


func _print_bone_values() -> void:
	print("\n=== Current Bone Values ===")
	var bone_order := ["Head", "Neck5", "Neck4", "Neck3", "Neck2", "Neck1"]
	for bone_key in bone_order:
		if _bone_sliders.has(bone_key):
			var sliders = _bone_sliders[bone_key]
			var x_val: float = sliders["X"]["slider"].value
			var y_val: float = sliders["Y"]["slider"].value
			var z_val: float = sliders["Z"]["slider"].value
			print("%s: X=%d°, Y=%d°, Z=%d°" % [bone_key, int(x_val), int(y_val), int(z_val)])
	print("===========================\n")


func _create_bone_markers() -> void:
	var bone_count := _skeleton.get_bone_count()
	print("Skeleton has ", bone_count, " bones")

	for bone_idx in bone_count:
		var bone_name := _skeleton.get_bone_name(bone_idx)

		# Create shorter label by removing "NPC " prefix
		var label_text := bone_name.replace("NPC ", "")

		# Create sphere marker
		var sphere := MeshInstance3D.new()
		var sphere_mesh := SphereMesh.new()
		sphere_mesh.radius = 1.0
		sphere_mesh.height = 2.0
		sphere.mesh = sphere_mesh

		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(1, 0, 0)  # Red
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		sphere.material_override = mat
		add_child(sphere)

		# Create label
		var label := Label3D.new()
		label.text = label_text
		label.font_size = 32
		label.pixel_size = 0.05
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.no_depth_test = true
		label.modulate = Color(1, 1, 0)  # Yellow text
		add_child(label)

		_bone_markers[bone_idx] = {"sphere": sphere, "label": label, "name": bone_name}

	print("Created markers for ", _bone_markers.size(), " bones")


func _process(delta: float) -> void:
	# Update marker positions to follow bones
	if _skeleton:
		for bone_idx in _bone_markers:
			var marker = _bone_markers[bone_idx]
			var bone_global := _skeleton.global_transform * _skeleton.get_bone_global_pose(bone_idx)
			var pos: Vector3 = bone_global.origin

			marker["sphere"].global_position = pos
			marker["label"].global_position = pos + Vector3(0, 3, 0)

	# Camera movement with WASD
	var move_dir := Vector3.ZERO
	if Input.is_key_pressed(KEY_W):
		move_dir.z -= 1
	if Input.is_key_pressed(KEY_S):
		move_dir.z += 1
	if Input.is_key_pressed(KEY_A):
		move_dir.x -= 1
	if Input.is_key_pressed(KEY_D):
		move_dir.x += 1
	if Input.is_key_pressed(KEY_Q):
		move_dir.y -= 1
	if Input.is_key_pressed(KEY_E):
		move_dir.y += 1

	if move_dir != Vector3.ZERO:
		# Transform movement to camera space
		var yaw_rad := deg_to_rad(_camera_rotation.y)
		var forward := Vector3(sin(yaw_rad), 0, cos(yaw_rad))
		var right := Vector3(cos(yaw_rad), 0, -sin(yaw_rad))
		_camera_target += forward * move_dir.z * MOVE_SPEED * delta
		_camera_target += right * move_dir.x * MOVE_SPEED * delta
		_camera_target.y += move_dir.y * MOVE_SPEED * delta
		_update_camera_position()


func _update_camera_position() -> void:
	var pitch_rad := deg_to_rad(_camera_rotation.x)
	var yaw_rad := deg_to_rad(_camera_rotation.y)

	var offset := Vector3(
		_camera_distance * cos(pitch_rad) * sin(yaw_rad),
		_camera_distance * sin(-pitch_rad),
		_camera_distance * cos(pitch_rad) * cos(yaw_rad)
	)

	_camera.position = _camera_target + offset
	_camera.look_at(_camera_target)


func _find_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node as AnimationPlayer
	for child in node.get_children():
		var result := _find_animation_player(child)
		if result:
			return result
	return null


func _input(event: InputEvent) -> void:
	# Left click captures mouse (only if not clicking on UI)
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			# Check if mouse is over UI panel
			var mouse_pos := get_viewport().get_mouse_position()
			var panel_rect := Rect2(_ui_panel.global_position, _ui_panel.size)
			if not panel_rect.has_point(mouse_pos):
				_mouse_captured = true
				Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_camera_distance = max(0.1, _camera_distance - ZOOM_SPEED)  # tiny min to avoid look_at error
			_update_camera_position()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_camera_distance += ZOOM_SPEED
			_update_camera_position()

	# Mouse motion for camera rotation when captured
	if event is InputEventMouseMotion and _mouse_captured:
		_camera_rotation.y -= event.relative.x * MOUSE_SENSITIVITY
		_camera_rotation.x -= event.relative.y * MOUSE_SENSITIVITY
		_camera_rotation.x = clamp(_camera_rotation.x, -89, 89)
		_update_camera_position()

	# Keyboard
	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_ESCAPE:
				# Release mouse
				_mouse_captured = false
				Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
			KEY_R:
				if _anim_player:
					_anim_player.stop()
					_anim_player.play(&"WingFlap")
					print("Animation restarted")
			KEY_SPACE:
				if _anim_player:
					if _anim_player.is_playing():
						_anim_player.pause()
						print("Animation paused")
					else:
						_anim_player.play()
						print("Animation resumed")
			KEY_M:
				# Toggle manual mode
				_manual_mode = not _manual_mode
				_on_manual_mode_toggled(_manual_mode)
			KEY_P:
				# Print bone values
				_print_bone_values()
			KEY_X:
				# Quit
				get_tree().quit()
