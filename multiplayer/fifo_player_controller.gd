extends Node
class_name FifoPlayerController

## Server-authoritative player controller for FIFO-based multiplayer.
## Captures input and sends desired state to server.
## Only applies server-confirmed state to the player.
## No local prediction - pure server authority.

signal state_applied(data: Dictionary)
signal other_player_updated(player_id: int, data: Dictionary)

const WALK_SPEED: float = 3.5
const RUN_SPEED: float = 7.0
const JUMP_VELOCITY: float = 6.0
const MOUSE_SENSITIVITY: float = 0.002
const GAMEPAD_SENSITIVITY: float = 2.5
const CAMERA_VERTICAL_LIMIT: float = 85.0
const RUN_THRESHOLD: float = 0.6

# Player states (match FifoClient/protocol)
const STATE_IDLE := 0
const STATE_WALKING := 1
const STATE_RUNNING := 2
const STATE_ATTACKING := 3
const STATE_BLOCKING := 4
const STATE_JUMPING := 5
const STATE_CASTING := 6
const STATE_DRAWING_BOW := 7
const STATE_HOLDING_BOW := 8
const STATE_DEAD := 9

@export var player_id: int = 1
@export var enabled: bool = false

var fifo_client: FifoClient
var player_node: CharacterBody3D
var camera_pivot: Node3D
var character_model: Node3D

# Input state (sent to server)
var input_direction: Vector2 = Vector2.ZERO
var is_running: bool = false
var is_jumping: bool = false
var is_attacking: bool = false
var is_blocking: bool = false
var camera_rotation: Vector2 = Vector2.ZERO

# Desired state calculated from input
var desired_position: Vector3 = Vector3.ZERO
var desired_velocity: Vector3 = Vector3.ZERO
var desired_rotation_y: float = 0.0
var desired_state: int = STATE_IDLE
var desired_anim_name: String = "Idle"

# Server-confirmed state (what we display)
var server_position: Vector3 = Vector3.ZERO
var server_rotation_y: float = 0.0
var server_state: int = STATE_IDLE
var server_anim_name: String = "Idle"
var server_health: float = 100.0

# Other players (for remote display)
var other_players: Dictionary = {}

# Gravity
var gravity: Vector3


func _ready() -> void:
	gravity = ProjectSettings.get_setting("physics/3d/default_gravity") * \
			ProjectSettings.get_setting("physics/3d/default_gravity_vector")

	# Find or create FIFO client
	fifo_client = get_node_or_null("/root/FifoClient")
	if fifo_client == null:
		fifo_client = FifoClient.new()
		fifo_client.name = "FifoClient"
		get_tree().root.add_child(fifo_client)

	fifo_client.global_state_received.connect(_on_global_state_received)
	fifo_client.connected.connect(_on_connected)
	fifo_client.disconnected.connect(_on_disconnected)


func _exit_tree() -> void:
	if fifo_client and fifo_client.is_connected:
		fifo_client.disconnect_from_server()


## Initialize the controller with a player node
func setup(player: CharacterBody3D, id: int) -> void:
	player_node = player
	player_id = id

	# Find camera pivot and character model
	camera_pivot = player.get_node_or_null("CameraPivot")
	character_model = player.get_node_or_null("CharacterModel")

	# Initialize positions
	server_position = player.global_position
	desired_position = player.global_position
	if character_model:
		server_rotation_y = character_model.rotation.y
		desired_rotation_y = character_model.rotation.y

	print("[FifoController] Setup for player %d" % player_id)


## Connect to the FIFO server
func connect_to_server() -> bool:
	if fifo_client == null:
		push_error("FifoClient not found")
		return false

	var success := fifo_client.connect_to_server(player_id)
	if success:
		enabled = true
	return success


## Disconnect from server
func disconnect_from_server() -> void:
	enabled = false
	if fifo_client:
		fifo_client.disconnect_from_server()


func _on_connected() -> void:
	print("[FifoController] Connected to server as player %d" % player_id)
	enabled = true


func _on_disconnected() -> void:
	print("[FifoController] Disconnected from server")
	enabled = false


func _input(event: InputEvent) -> void:
	if not enabled or player_node == null:
		return

	# Mouse look (still handled locally for camera)
	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		camera_rotation.x -= event.relative.x * MOUSE_SENSITIVITY
		camera_rotation.y -= event.relative.y * MOUSE_SENSITIVITY
		camera_rotation.y = clamp(camera_rotation.y, deg_to_rad(-CAMERA_VERTICAL_LIMIT), deg_to_rad(CAMERA_VERTICAL_LIMIT))
		if camera_pivot:
			camera_pivot.rotation.y = camera_rotation.x
			camera_pivot.rotation.x = camera_rotation.y

	# Attack input
	if event.is_action_pressed(&"attack") or \
			(event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED):
		is_attacking = true

	# Block
	if event.is_action_pressed(&"block") or \
			(event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed):
		is_blocking = true
	elif event.is_action_released(&"block") or \
			(event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and not event.pressed):
		is_blocking = false


func _physics_process(delta: float) -> void:
	if not enabled or player_node == null:
		return

	# Capture input
	_capture_input(delta)

	# Calculate desired state from input
	_calculate_desired_state(delta)

	# Send state to server
	_send_state_to_server()

	# Apply server-confirmed state to player
	_apply_server_state(delta)


func _capture_input(delta: float) -> void:
	# Gamepad camera
	var look_x: float = Input.get_action_strength(&"camera_look_right") - Input.get_action_strength(&"camera_look_left")
	var look_y: float = Input.get_action_strength(&"camera_look_down") - Input.get_action_strength(&"camera_look_up")
	if abs(look_x) > 0.01 or abs(look_y) > 0.01:
		camera_rotation.x -= look_x * GAMEPAD_SENSITIVITY * delta
		camera_rotation.y -= look_y * GAMEPAD_SENSITIVITY * delta
		camera_rotation.y = clamp(camera_rotation.y, deg_to_rad(-CAMERA_VERTICAL_LIMIT), deg_to_rad(CAMERA_VERTICAL_LIMIT))
		if camera_pivot:
			camera_pivot.rotation.y = camera_rotation.x
			camera_pivot.rotation.x = camera_rotation.y

	# Movement input
	input_direction = Input.get_vector(&"move_left", &"move_right", &"move_forward", &"move_back", 0.15)

	# Run
	var keyboard_run := Input.is_action_pressed(&"run") if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED else false
	is_running = keyboard_run or input_direction.length() > RUN_THRESHOLD

	# Jump
	if Input.is_action_just_pressed(&"jump"):
		is_jumping = true


func _calculate_desired_state(delta: float) -> void:
	# Calculate desired velocity from input
	var current_max_speed: float = RUN_SPEED if is_running else WALK_SPEED

	var cam_yaw: float = camera_pivot.rotation.y if camera_pivot else 0.0
	var forward := Vector3.FORWARD.rotated(Vector3.UP, cam_yaw)
	var right := Vector3.RIGHT.rotated(Vector3.UP, cam_yaw)

	var input_dir := input_direction.normalized() if input_direction.length() > 0.1 else Vector2.ZERO
	var movement_direction := (forward * -input_dir.y + right * input_dir.x).normalized()

	if movement_direction.length() > 0.1:
		desired_velocity.x = movement_direction.x * current_max_speed
		desired_velocity.z = movement_direction.z * current_max_speed
	else:
		desired_velocity.x = 0.0
		desired_velocity.z = 0.0

	# Apply gravity
	desired_velocity += gravity * delta

	# Jump
	if is_jumping and player_node.is_on_floor():
		desired_velocity.y = JUMP_VELOCITY
		is_jumping = false

	# Calculate desired position
	desired_position = server_position + desired_velocity * delta

	# Calculate facing direction (toward camera)
	if camera_pivot:
		desired_rotation_y = camera_pivot.rotation.y + PI

	# Calculate state enum
	if is_attacking:
		desired_state = STATE_ATTACKING
		desired_anim_name = "Attack"
		is_attacking = false  # One-shot
	elif is_blocking:
		desired_state = STATE_BLOCKING
		desired_anim_name = "Block"
	elif not player_node.is_on_floor():
		desired_state = STATE_JUMPING
		desired_anim_name = "Jump"
	elif desired_velocity.length() > 0.5:
		if is_running:
			desired_state = STATE_RUNNING
			desired_anim_name = "Run"
		else:
			desired_state = STATE_WALKING
			desired_anim_name = "Walk"
	else:
		desired_state = STATE_IDLE
		desired_anim_name = "Idle"


func _send_state_to_server() -> void:
	if fifo_client == null or not fifo_client.is_connected:
		return

	var data := {
		"player_id": player_id,
		"x": desired_position.x,
		"y": desired_position.y,
		"z": desired_position.z,
		"rotation_y": desired_rotation_y,
		"state": desired_state,
		"combat_mode": 1,  # Armed
		"health": server_health,
		"anim_name": desired_anim_name,
		"active": true,
		"character_class": 1,  # Archer
	}

	fifo_client.send_local_state(data)


func _apply_server_state(_delta: float) -> void:
	if player_node == null:
		return

	# Apply server-confirmed position directly (no interpolation for pure authority)
	player_node.global_position = server_position

	# Apply rotation to character model
	if character_model:
		character_model.rotation.y = server_rotation_y

	# Emit signal for animation updates
	state_applied.emit({
		"position": server_position,
		"rotation_y": server_rotation_y,
		"state": server_state,
		"anim_name": server_anim_name,
		"health": server_health,
	})


func _on_global_state_received(players: Array) -> void:
	for p in players:
		var pid: int = p.get("player_id", 0)
		if pid == player_id:
			# This is our own state - apply it
			server_position = Vector3(p.get("x", 0.0), p.get("y", 0.0), p.get("z", 0.0))
			server_rotation_y = p.get("rotation_y", 0.0)
			server_state = p.get("state", STATE_IDLE)
			server_anim_name = p.get("anim_name", "Idle")
			server_health = p.get("health", 100.0)
		else:
			# This is another player
			other_players[pid] = p
			other_player_updated.emit(pid, p)


## Get state for a remote player
func get_other_player(pid: int) -> Dictionary:
	return other_players.get(pid, {})


## Get all other players
func get_all_other_players() -> Dictionary:
	return other_players.duplicate()
