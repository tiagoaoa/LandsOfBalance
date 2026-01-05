extends Node3D

## FIFO Multiplayer Test Scene
## Demonstrates server-authoritative multiplayer with FIFO communication.

@onready var fifo_manager: FifoMultiplayerManager
@onready var player: CharacterBody3D
@onready var status_label: Label
@onready var connect_button: Button

var player_scene := preload("res://player/player_animtree.tscn")


func _ready() -> void:
	# Create UI
	_create_ui()

	# Create FIFO manager
	fifo_manager = FifoMultiplayerManager.new()
	fifo_manager.name = "FifoManager"
	add_child(fifo_manager)

	# Connect signals
	fifo_manager.connected.connect(_on_connected)
	fifo_manager.disconnected.connect(_on_disconnected)
	fifo_manager.player_joined.connect(_on_player_joined)
	fifo_manager.player_left.connect(_on_player_left)

	# Create floor
	_create_floor()

	# Create player
	_spawn_player()

	# Update status
	_update_status("Ready. Player ID: %d" % fifo_manager.player_id)


func _create_ui() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)

	var vbox := VBoxContainer.new()
	vbox.position = Vector2(20, 20)
	canvas.add_child(vbox)

	status_label = Label.new()
	status_label.text = "Initializing..."
	status_label.add_theme_font_size_override("font_size", 18)
	vbox.add_child(status_label)

	connect_button = Button.new()
	connect_button.text = "Connect to Server"
	connect_button.pressed.connect(_on_connect_pressed)
	vbox.add_child(connect_button)

	var disconnect_button := Button.new()
	disconnect_button.text = "Disconnect"
	disconnect_button.pressed.connect(_on_disconnect_pressed)
	vbox.add_child(disconnect_button)

	var help_label := Label.new()
	help_label.text = "\nControls:\nWASD - Move\nShift - Run\nSpace - Jump\nMouse - Look\nESC - Release mouse"
	vbox.add_child(help_label)


func _create_floor() -> void:
	var floor_mesh := MeshInstance3D.new()
	floor_mesh.name = "Floor"
	var plane := PlaneMesh.new()
	plane.size = Vector2(50, 50)
	floor_mesh.mesh = plane

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.3, 0.5, 0.3)
	floor_mesh.material_override = mat

	add_child(floor_mesh)

	# Static body for collision
	var static_body := StaticBody3D.new()
	static_body.name = "FloorCollision"

	var collision := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(50, 0.1, 50)
	collision.shape = box
	collision.position.y = -0.05

	static_body.add_child(collision)
	add_child(static_body)

	# Light
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45, 45, 0)
	add_child(light)

	# Environment
	var env := WorldEnvironment.new()
	var sky_env := Environment.new()
	sky_env.background_mode = Environment.BG_COLOR
	sky_env.background_color = Color(0.5, 0.7, 0.9)
	sky_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	sky_env.ambient_light_color = Color(0.4, 0.4, 0.5)
	env.environment = sky_env
	add_child(env)


func _spawn_player() -> void:
	if player_scene:
		player = player_scene.instantiate()
	else:
		player = _create_simple_player()

	player.name = "LocalPlayer"
	player.position = Vector3(fifo_manager.player_id * 3.0, 1.0, 0.0)
	add_child(player)

	# Register with FIFO manager
	fifo_manager.set_local_player(player)


func _create_simple_player() -> CharacterBody3D:
	var body := CharacterBody3D.new()

	var mesh := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.3
	capsule.height = 1.8
	mesh.mesh = capsule
	mesh.position.y = 0.9

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.2, 0.8, 0.3)
	mesh.material_override = mat

	body.add_child(mesh)

	var collision := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.radius = 0.3
	shape.height = 1.8
	collision.shape = shape
	collision.position.y = 0.9
	body.add_child(collision)

	var camera_pivot := Node3D.new()
	camera_pivot.name = "CameraPivot"
	camera_pivot.position.y = 1.6
	body.add_child(camera_pivot)

	var camera := Camera3D.new()
	camera.position.z = 3.0
	camera.position.y = 0.4
	camera_pivot.add_child(camera)

	return body


func _on_connect_pressed() -> void:
	_update_status("Connecting...")
	if fifo_manager.connect_to_server():
		connect_button.disabled = true
	else:
		_update_status("Connection failed! Is fifo_server running?")


func _on_disconnect_pressed() -> void:
	fifo_manager.disconnect_from_server()
	connect_button.disabled = false
	_update_status("Disconnected. Player ID: %d" % fifo_manager.player_id)


func _on_connected() -> void:
	_update_status("Connected! Player ID: %d" % fifo_manager.player_id)
	connect_button.disabled = true


func _on_disconnected() -> void:
	_update_status("Disconnected. Player ID: %d" % fifo_manager.player_id)
	connect_button.disabled = false


func _on_player_joined(pid: int) -> void:
	print("Player %d joined!" % pid)
	_update_status("Connected! Player ID: %d (Player %d joined)" % [fifo_manager.player_id, pid])


func _on_player_left(pid: int) -> void:
	print("Player %d left!" % pid)


func _update_status(text: String) -> void:
	if status_label:
		status_label.text = text


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
