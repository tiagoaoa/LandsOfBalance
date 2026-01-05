extends Node
class_name FifoMultiplayerManager

## Central manager for FIFO-based multiplayer.
## Add as autoload singleton for easy access.
## Handles connection, player state sync, and remote player visuals.

signal connected
signal disconnected
signal player_joined(player_id: int)
signal player_left(player_id: int)
signal state_updated

const RemotePlayerScene = preload("res://multiplayer/remote_player.tscn")

@export var auto_connect: bool = false
@export var player_id: int = 1

var fifo_client: FifoClient
var fifo_controller: FifoPlayerController
var local_player: CharacterBody3D
var remote_players: Dictionary = {}  # player_id -> RemotePlayer node
var is_fifo_mode: bool = false


func _ready() -> void:
	# Parse command line for player ID
	_parse_command_line()

	# Create FIFO client
	fifo_client = FifoClient.new()
	fifo_client.name = "FifoClient"
	add_child(fifo_client)

	# Connect signals
	fifo_client.connected.connect(_on_connected)
	fifo_client.disconnected.connect(_on_disconnected)
	fifo_client.global_state_received.connect(_on_global_state_received)
	fifo_client.connection_failed.connect(_on_connection_failed)

	if auto_connect:
		call_deferred("connect_to_server")


func _parse_command_line() -> void:
	var args := OS.get_cmdline_args()
	for arg in args:
		if arg.begins_with("--player-id="):
			var id_str := arg.substr(12)
			player_id = int(id_str)
			print("[FifoManager] Player ID from command line: %d" % player_id)
			break


## Set the local player node and enable FIFO control
func set_local_player(player: CharacterBody3D) -> void:
	local_player = player

	# Create controller
	fifo_controller = FifoPlayerController.new()
	fifo_controller.name = "FifoController"
	add_child(fifo_controller)

	fifo_controller.setup(player, player_id)
	fifo_controller.fifo_client = fifo_client
	fifo_controller.other_player_updated.connect(_on_other_player_updated)

	print("[FifoManager] Local player set: %s" % player.name)


## Connect to the FIFO server
func connect_to_server() -> bool:
	if fifo_client == null:
		push_error("FifoClient not initialized")
		return false

	print("[FifoManager] Connecting as player %d..." % player_id)
	var success := fifo_client.connect_to_server(player_id)

	if success and fifo_controller:
		fifo_controller.enabled = true
		is_fifo_mode = true

	return success


## Disconnect from the server
func disconnect_from_server() -> void:
	if fifo_client:
		fifo_client.disconnect_from_server()

	if fifo_controller:
		fifo_controller.enabled = false

	is_fifo_mode = false

	# Remove all remote players
	for pid in remote_players.keys():
		_remove_remote_player(pid)


func _on_connected() -> void:
	print("[FifoManager] Connected to server!")
	is_fifo_mode = true
	connected.emit()


func _on_disconnected() -> void:
	print("[FifoManager] Disconnected from server")
	is_fifo_mode = false
	disconnected.emit()


func _on_connection_failed(reason: String) -> void:
	push_error("[FifoManager] Connection failed: %s" % reason)
	is_fifo_mode = false


func _on_global_state_received(players: Array) -> void:
	var active_ids := []

	for p in players:
		var pid: int = p.get("player_id", 0)
		if pid == 0:
			continue

		active_ids.append(pid)

		# Skip local player (handled by controller)
		if pid == player_id:
			continue

		# Update or create remote player
		if remote_players.has(pid):
			_update_remote_player(pid, p)
		else:
			_spawn_remote_player(pid, p)

	# Remove disconnected players
	for pid in remote_players.keys():
		if pid not in active_ids:
			_remove_remote_player(pid)

	state_updated.emit()


func _on_other_player_updated(pid: int, data: Dictionary) -> void:
	if remote_players.has(pid):
		_update_remote_player(pid, data)
	else:
		_spawn_remote_player(pid, data)


func _spawn_remote_player(pid: int, data: Dictionary) -> void:
	if local_player == null:
		return

	print("[FifoManager] Spawning remote player %d" % pid)

	var remote: Node3D
	if RemotePlayerScene:
		remote = RemotePlayerScene.instantiate()
	else:
		# Fallback: simple visual
		remote = _create_fallback_remote_player()

	remote.name = "RemotePlayer_%d" % pid
	remote_players[pid] = remote

	# Add to same parent as local player
	local_player.get_parent().add_child(remote)

	# Set initial state
	_update_remote_player(pid, data)

	player_joined.emit(pid)


func _update_remote_player(pid: int, data: Dictionary) -> void:
	var remote = remote_players.get(pid)
	if remote == null:
		return

	# Update position
	var pos := Vector3(
		data.get("x", 0.0),
		data.get("y", 0.0),
		data.get("z", 0.0)
	)

	# Apply directly for server-authoritative display
	remote.global_position = pos

	# Update rotation
	if remote.has_node("CharacterModel"):
		remote.get_node("CharacterModel").rotation.y = data.get("rotation_y", 0.0)
	else:
		remote.rotation.y = data.get("rotation_y", 0.0)

	# Update state if the remote player has the method
	if remote.has_method("update_from_network"):
		remote.update_from_network({
			"position": pos,
			"rotation_y": data.get("rotation_y", 0.0),
			"state": data.get("state", 0),
			"combat_mode": data.get("combat_mode", 1),
			"health": data.get("health", 100.0),
			"anim_name": data.get("anim_name", "Idle"),
		})


func _remove_remote_player(pid: int) -> void:
	var remote = remote_players.get(pid)
	if remote:
		print("[FifoManager] Removing remote player %d" % pid)
		remote.queue_free()
		remote_players.erase(pid)
		player_left.emit(pid)


func _create_fallback_remote_player() -> Node3D:
	var node := CharacterBody3D.new()

	# Simple capsule mesh
	var mesh := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.3
	capsule.height = 1.8
	mesh.mesh = capsule
	mesh.position.y = 0.9

	# Material
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.2, 0.6, 0.9)
	mesh.material_override = mat

	node.add_child(mesh)

	# Label
	var label := Label3D.new()
	label.text = "Player"
	label.position.y = 2.2
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	node.add_child(label)

	return node


## Get all remote player positions (for minimap, etc.)
func get_all_player_positions() -> Dictionary:
	var positions := {}

	if local_player:
		positions[player_id] = local_player.global_position

	for pid in remote_players:
		var remote = remote_players[pid]
		if remote:
			positions[pid] = remote.global_position

	return positions
