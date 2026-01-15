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
var _bone_ranges: Dictionary = {}  # bone_key -> {axis -> {min_slider, max_slider, min_label, max_label}}
var _manual_mode := false  # When true, manually control bones instead of animation
var _anim_time := 0.0  # Manual animation time

# Animation parameters (editable via UI)
var _anim_params := {
	# Wing bones - Y rotation amplitude
	"R_UpArm2": {"Y": {"min": -25.0, "max": 25.0}},
	"R_Forearm1": {"Y": {"min": -30.0, "max": 30.0}},
	"R_Finger1": {"Y": {"min": -35.0, "max": 35.0}},
	"R_Finger2": {"Y": {"min": -35.0, "max": 35.0}},
	"R_Finger3": {"Y": {"min": -35.0, "max": 35.0}},
	"R_Finger4": {"Y": {"min": -35.0, "max": 35.0}},
	"L_UpArm2": {"Y": {"min": -25.0, "max": 25.0}},
	"L_Forearm1": {"Y": {"min": -30.0, "max": 30.0}},
	"L_Finger1": {"Y": {"min": -35.0, "max": 35.0}},
	"L_Finger2": {"Y": {"min": -35.0, "max": 35.0}},
	"L_Finger3": {"Y": {"min": -35.0, "max": 35.0}},
	"L_Finger4": {"Y": {"min": -35.0, "max": 35.0}},
	# Neck bones - Z rotation (custom ranges from editor)
	"Neck1": {"Z": {"min": -10.0, "max": 10.0}},
	"Neck2": {"Z": {"min": -10.0, "max": 10.0}},
	"Neck3": {"Z": {"min": 68.0, "max": 80.0}},
	"Neck4": {"Z": {"min": 17.0, "max": 28.0}},
	"Neck5": {"Z": {"min": 60.0, "max": -21.0}},
	# Tail bones - Z rotation (custom values from editor)
	"Tail1": {"Z": {"min": -14.0, "max": -62.0}},
	"Tail2": {"Z": {"min": -65.0, "max": -33.0}},
	"Tail3": {"Z": {"min": 47.0, "max": -40.0}},
	"Tail4": {"Z": {"min": 56.0, "max": -29.0}},
	"Tail5": {"Z": {"min": -76.0, "max": -38.0}},
	"Tail6": {"Z": {"min": 14.0, "max": 61.0}},
	"Tail7": {"Z": {"min": 6.0, "max": 81.0}},
}

# Bone name mapping
const BONE_NAMES := {
	"R_UpArm2": "NPC RUpArm2_060",
	"R_Forearm1": "NPC RForearm1_062",
	"R_Finger1": "NPC RFinger11_065",
	"R_Finger2": "NPC RFinger21_067",
	"R_Finger3": "NPC RFinger31_069",
	"R_Finger4": "NPC RFinger41_071",
	"L_UpArm2": "NPC LUpArm2_026",
	"L_Forearm1": "NPC LForearm1_028",
	"L_Finger1": "NPC LFinger11_031",
	"L_Finger2": "NPC LFinger21_033",
	"L_Finger3": "NPC LFinger31_035",
	"L_Finger4": "NPC LFinger41_037",
	"Neck1": "NPC Neck1_040",
	"Neck2": "NPC Neck2_041",
	"Neck3": "NPC Neck3_042",
	"Neck4": "NPC Neck4_043",
	"Neck5": "NPC Neck5_044",
	"Tail1": "NPC Tail1_074",
	"Tail2": "NPC Tail2_075",
	"Tail3": "NPC Tail3_076",
	"Tail4": "NPC Tail4_077",
	"Tail5": "NPC Tail5_078",
	"Tail6": "NPC Tail6_079",
	"Tail7": "NPC Tail7_080",
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
	# Create UI layer
	var canvas := CanvasLayer.new()
	canvas.name = "UILayer"
	add_child(canvas)

	# Main panel with dark background
	_ui_panel = PanelContainer.new()
	_ui_panel.name = "BoneControlPanel"
	_ui_panel.position = Vector2(10, 10)
	_ui_panel.size = Vector2(340, 850)
	canvas.add_child(_ui_panel)

	var main_vbox := VBoxContainer.new()
	main_vbox.add_theme_constant_override("separation", 8)
	_ui_panel.add_child(main_vbox)

	# Title
	var title := Label.new()
	title.text = "Bone Range Editor"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 16)
	main_vbox.add_child(title)

	# Buttons row (Save / Reset)
	var btn_hbox := HBoxContainer.new()
	btn_hbox.add_theme_constant_override("separation", 10)
	main_vbox.add_child(btn_hbox)

	var save_btn := Button.new()
	save_btn.text = "Save to File"
	save_btn.pressed.connect(_save_to_file)
	btn_hbox.add_child(save_btn)

	var reset_btn := Button.new()
	reset_btn.text = "Reset to Default"
	reset_btn.pressed.connect(_reset_ranges)
	btn_hbox.add_child(reset_btn)

	main_vbox.add_child(HSeparator.new())

	# Scrollable bone list
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(320, 750)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_ALWAYS
	main_vbox.add_child(scroll)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 2)
	scroll.add_child(vbox)

	# === RIGHT WING SECTION ===
	_add_section_header(vbox, "RIGHT WING (Y)")
	for bone_key in ["R_UpArm2", "R_Forearm1", "R_Finger1", "R_Finger2", "R_Finger3", "R_Finger4"]:
		_create_range_control(vbox, bone_key, "Y")

	# === LEFT WING SECTION ===
	_add_section_header(vbox, "LEFT WING (Y)")
	for bone_key in ["L_UpArm2", "L_Forearm1", "L_Finger1", "L_Finger2", "L_Finger3", "L_Finger4"]:
		_create_range_control(vbox, bone_key, "Y")

	# === NECK SECTION ===
	_add_section_header(vbox, "NECK (Z)")
	for bone_key in ["Neck1", "Neck2", "Neck3", "Neck4", "Neck5"]:
		_create_range_control(vbox, bone_key, "Z")

	# === TAIL SECTION ===
	_add_section_header(vbox, "TAIL (Z)")
	for bone_key in ["Tail1", "Tail2", "Tail3", "Tail4", "Tail5", "Tail6", "Tail7"]:
		_create_range_control(vbox, bone_key, "Z")


func _add_section_header(parent: Control, text: String) -> void:
	var label := Label.new()
	label.text = "── " + text + " ──"
	label.add_theme_font_size_override("font_size", 13)
	label.add_theme_color_override("font_color", Color(0.7, 0.9, 1.0))
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	parent.add_child(label)


func _create_range_control(parent: Control, bone_key: String, axis: String) -> void:
	var group := VBoxContainer.new()
	group.add_theme_constant_override("separation", 0)
	parent.add_child(group)

	# Get current min/max values
	var params = _anim_params.get(bone_key, {}).get(axis, {"min": -45.0, "max": 45.0})

	# Header row: bone name and current values
	var header := HBoxContainer.new()
	group.add_child(header)

	var label := Label.new()
	label.text = bone_key
	label.custom_minimum_size.x = 90
	label.add_theme_font_size_override("font_size", 12)
	header.add_child(label)

	var range_label := Label.new()
	range_label.name = "RangeLabel"
	range_label.text = "[%d° to %d°]" % [int(params["min"]), int(params["max"])]
	range_label.add_theme_font_size_override("font_size", 11)
	range_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.5))
	header.add_child(range_label)

	# Range slider row
	var slider_row := HBoxContainer.new()
	slider_row.add_theme_constant_override("separation", 4)
	group.add_child(slider_row)

	# Min value
	var min_val := Label.new()
	min_val.text = "%d" % int(params["min"])
	min_val.custom_minimum_size.x = 30
	min_val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	min_val.add_theme_font_size_override("font_size", 11)
	slider_row.add_child(min_val)

	# Combined range slider using HSlider for min
	var min_slider := HSlider.new()
	min_slider.min_value = -90
	min_slider.max_value = 90
	min_slider.value = params["min"]
	min_slider.step = 1
	min_slider.custom_minimum_size.x = 90
	min_slider.value_changed.connect(_on_range_changed.bind(bone_key, axis, "min"))
	slider_row.add_child(min_slider)

	# Separator
	var sep := Label.new()
	sep.text = "─"
	sep.add_theme_font_size_override("font_size", 10)
	slider_row.add_child(sep)

	# Max slider
	var max_slider := HSlider.new()
	max_slider.min_value = -90
	max_slider.max_value = 90
	max_slider.value = params["max"]
	max_slider.step = 1
	max_slider.custom_minimum_size.x = 90
	max_slider.value_changed.connect(_on_range_changed.bind(bone_key, axis, "max"))
	slider_row.add_child(max_slider)

	# Max value
	var max_val := Label.new()
	max_val.text = "%d" % int(params["max"])
	max_val.custom_minimum_size.x = 30
	max_val.add_theme_font_size_override("font_size", 11)
	slider_row.add_child(max_val)

	# Store references
	if not _bone_ranges.has(bone_key):
		_bone_ranges[bone_key] = {}
	_bone_ranges[bone_key][axis] = {
		"min_slider": min_slider,
		"max_slider": max_slider,
		"min_label": min_val,
		"max_label": max_val,
		"range_label": range_label,
	}


func _on_range_changed(value: float, bone_key: String, axis: String, minmax: String) -> void:
	# Update parameter
	if not _anim_params.has(bone_key):
		_anim_params[bone_key] = {}
	if not _anim_params[bone_key].has(axis):
		_anim_params[bone_key][axis] = {"min": -45.0, "max": 45.0}
	_anim_params[bone_key][axis][minmax] = value

	# Update labels
	if _bone_ranges.has(bone_key) and _bone_ranges[bone_key].has(axis):
		var refs = _bone_ranges[bone_key][axis]
		refs[minmax + "_label"].text = "%d" % int(value)
		var min_v: float = _anim_params[bone_key][axis]["min"]
		var max_v: float = _anim_params[bone_key][axis]["max"]
		refs["range_label"].text = "[%d° to %d°]" % [int(min_v), int(max_v)]

	# Regenerate animation immediately
	_regenerate_animation()


func _regenerate_animation() -> void:
	# Regenerate the animation - start from default, then apply modifications
	if not _anim_player:
		return

	# Start with the original animation from DragonWingFlap
	var anim := DragonWingFlapClass.create_wing_flap_animation(1.2, 1.0)

	var t0 := 0.0
	var t1 := 0.48  # 40% downstroke
	var t2 := 1.2

	# Now modify only the tracks that differ from defaults
	for bone_key in _anim_params:
		var bone_name: String = BONE_NAMES.get(bone_key, "")
		if bone_name.is_empty():
			continue

		for axis in _anim_params[bone_key]:
			var params: Dictionary = _anim_params[bone_key][axis]
			var min_val: float = params["min"]
			var max_val: float = params["max"]

			# Left wing bones need inverted Y rotation (mirroring)
			var is_left_wing: bool = bone_key.begins_with("L_")
			if is_left_wing and axis == "Y":
				min_val = -min_val
				max_val = -max_val

			# Find the track for this bone
			var track_path := DragonWingFlapClass.SKELETON_PATH + ":" + bone_name
			var track_idx := anim.find_track(track_path, Animation.TYPE_ROTATION_3D)

			if track_idx < 0:
				# Track doesn't exist, create it
				track_idx = anim.add_track(Animation.TYPE_ROTATION_3D)
				anim.track_set_path(track_idx, track_path)
				anim.track_set_interpolation_type(track_idx, Animation.INTERPOLATION_CUBIC)
			else:
				# Clear existing keys
				while anim.track_get_key_count(track_idx) > 0:
					anim.track_remove_key(track_idx, 0)

			# Create rotation keyframes based on axis
			var rot_min := Vector3.ZERO
			var rot_max := Vector3.ZERO
			match axis:
				"X":
					rot_min.x = deg_to_rad(min_val)
					rot_max.x = deg_to_rad(max_val)
				"Y":
					rot_min.y = deg_to_rad(min_val)
					rot_max.y = deg_to_rad(max_val)
				"Z":
					rot_min.z = deg_to_rad(min_val)
					rot_max.z = deg_to_rad(max_val)

			var q_min := Quaternion.from_euler(rot_min)
			var q_max := Quaternion.from_euler(rot_max)

			# Keyframes: max -> min -> max (for wing flap cycle)
			anim.rotation_track_insert_key(track_idx, t0, q_max)
			anim.rotation_track_insert_key(track_idx, t1, q_min)
			anim.rotation_track_insert_key(track_idx, t2, q_max)

	# Replace animation in player
	var lib: AnimationLibrary
	if _anim_player.has_animation_library(&""):
		lib = _anim_player.get_animation_library(&"")
	else:
		lib = AnimationLibrary.new()
		_anim_player.add_animation_library(&"", lib)

	if lib.has_animation(&"WingFlap"):
		lib.remove_animation(&"WingFlap")
	lib.add_animation(&"WingFlap", anim)

	# Restart if playing
	if _anim_player.current_animation == "WingFlap":
		var pos := _anim_player.current_animation_position
		_anim_player.play(&"WingFlap")
		_anim_player.seek(pos)


func _save_to_file() -> void:
	var path := "user://dragon_wing_ranges.txt"
	var file := FileAccess.open(path, FileAccess.WRITE)
	if not file:
		print("ERROR: Could not save to ", path)
		return

	file.store_line("# Dragon Wing Animation Ranges")
	file.store_line("# Generated: " + Time.get_datetime_string_from_system())
	file.store_line("")

	# Group by section
	file.store_line("## RIGHT WING (Y rotation)")
	for bone_key in ["R_UpArm2", "R_Forearm1", "R_Finger1", "R_Finger2", "R_Finger3", "R_Finger4"]:
		if _anim_params.has(bone_key):
			var p: Dictionary = _anim_params[bone_key].get("Y", {"min": 0, "max": 0})
			file.store_line("%s: min=%d, max=%d" % [bone_key, int(p["min"]), int(p["max"])])

	file.store_line("")
	file.store_line("## LEFT WING (Y rotation)")
	for bone_key in ["L_UpArm2", "L_Forearm1", "L_Finger1", "L_Finger2", "L_Finger3", "L_Finger4"]:
		if _anim_params.has(bone_key):
			var p: Dictionary = _anim_params[bone_key].get("Y", {"min": 0, "max": 0})
			file.store_line("%s: min=%d, max=%d" % [bone_key, int(p["min"]), int(p["max"])])

	file.store_line("")
	file.store_line("## NECK (Z rotation)")
	for bone_key in ["Neck1", "Neck2", "Neck3", "Neck4", "Neck5"]:
		if _anim_params.has(bone_key):
			var p: Dictionary = _anim_params[bone_key].get("Z", {"min": 0, "max": 0})
			file.store_line("%s: min=%d, max=%d" % [bone_key, int(p["min"]), int(p["max"])])

	file.store_line("")
	file.store_line("## TAIL (Z rotation)")
	for bone_key in ["Tail1", "Tail2", "Tail3", "Tail4", "Tail5", "Tail6", "Tail7"]:
		if _anim_params.has(bone_key):
			var p: Dictionary = _anim_params[bone_key].get("Z", {"min": 0, "max": 0})
			file.store_line("%s: min=%d, max=%d" % [bone_key, int(p["min"]), int(p["max"])])

	file.close()

	var full_path := ProjectSettings.globalize_path(path)
	print("Saved to: ", full_path)
	OS.shell_open(full_path.get_base_dir())


func _reset_ranges() -> void:
	# Reset to default values (includes custom neck values from editor)
	_anim_params = {
		"R_UpArm2": {"Y": {"min": -25.0, "max": 25.0}},
		"R_Forearm1": {"Y": {"min": -30.0, "max": 30.0}},
		"R_Finger1": {"Y": {"min": -35.0, "max": 35.0}},
		"R_Finger2": {"Y": {"min": -35.0, "max": 35.0}},
		"R_Finger3": {"Y": {"min": -35.0, "max": 35.0}},
		"R_Finger4": {"Y": {"min": -35.0, "max": 35.0}},
		"L_UpArm2": {"Y": {"min": -25.0, "max": 25.0}},
		"L_Forearm1": {"Y": {"min": -30.0, "max": 30.0}},
		"L_Finger1": {"Y": {"min": -35.0, "max": 35.0}},
		"L_Finger2": {"Y": {"min": -35.0, "max": 35.0}},
		"L_Finger3": {"Y": {"min": -35.0, "max": 35.0}},
		"L_Finger4": {"Y": {"min": -35.0, "max": 35.0}},
		# Neck - custom values from editor
		"Neck1": {"Z": {"min": -10.0, "max": 10.0}},
		"Neck2": {"Z": {"min": -10.0, "max": 10.0}},
		"Neck3": {"Z": {"min": 68.0, "max": 80.0}},
		"Neck4": {"Z": {"min": 17.0, "max": 28.0}},
		"Neck5": {"Z": {"min": 60.0, "max": -21.0}},
		# Tail - Z rotation (custom values from editor)
		"Tail1": {"Z": {"min": -14.0, "max": -62.0}},
		"Tail2": {"Z": {"min": -65.0, "max": -33.0}},
		"Tail3": {"Z": {"min": 47.0, "max": -40.0}},
		"Tail4": {"Z": {"min": 56.0, "max": -29.0}},
		"Tail5": {"Z": {"min": -76.0, "max": -38.0}},
		"Tail6": {"Z": {"min": 14.0, "max": 61.0}},
		"Tail7": {"Z": {"min": 6.0, "max": 81.0}},
	}

	# Update UI sliders
	for bone_key in _bone_ranges:
		for axis in _bone_ranges[bone_key]:
			var refs = _bone_ranges[bone_key][axis]
			var params = _anim_params.get(bone_key, {}).get(axis, {"min": -45.0, "max": 45.0})
			refs["min_slider"].value = params["min"]
			refs["max_slider"].value = params["max"]
			refs["min_label"].text = "%d" % int(params["min"])
			refs["max_label"].text = "%d" % int(params["max"])
			refs["range_label"].text = "[%d° to %d°]" % [int(params["min"]), int(params["max"])]

	# Regenerate animation with defaults
	_regenerate_animation()
	print("Ranges reset to defaults")


func _print_bone_values() -> void:
	print("\n=== Current Bone Ranges ===")
	for bone_key in _anim_params:
		var parts := []
		for axis in _anim_params[bone_key]:
			var p = _anim_params[bone_key][axis]
			parts.append("%s:[%d°,%d°]" % [axis, int(p["min"]), int(p["max"])])
		print("%s: %s" % [bone_key, ", ".join(parts)])
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
			KEY_P:
				# Print bone values
				_print_bone_values()
			KEY_X:
				# Quit
				get_tree().quit()
