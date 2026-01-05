extends CanvasLayer

## Join Screen Overlay
## Auto-joins server if available, falls back to singleplayer mode

@onready var label: Label = $CenterContainer/VBoxContainer/JoinLabel
@onready var player_count_label: Label = $CenterContainer/VBoxContainer/PlayerCountLabel
@onready var container: CenterContainer = $CenterContainer

var network_manager: Node = null
var _connection_timer: float = 0.0
var _auto_join_timer: float = 0.0
var _received_state: bool = false
var _joined: bool = false

const CONNECTION_TIMEOUT: float = 2.0  # Wait 2 seconds for server
const AUTO_JOIN_DELAY: float = 0.5     # Auto-join 0.5 sec after receiving state

func _ready() -> void:
	print("JoinScreen: _ready()")
	visible = true
	container.visible = true

	if label:
		label.text = "Connecting to server..."
	if player_count_label:
		player_count_label.text = ""

	# Find the network manager
	network_manager = get_node_or_null("/root/NetworkManager")
	if network_manager == null:
		# Try to find it in the scene tree
		network_manager = get_tree().get_first_node_in_group("network_manager")

	if network_manager:
		print("JoinScreen: Found NetworkManager")
		network_manager.spectating_started.connect(_on_spectating_started)
		network_manager.joined_game.connect(_on_joined_game)
		network_manager.world_state_received.connect(_on_world_state_received)
		network_manager.connected_to_server.connect(_on_connected)
	else:
		print("JoinScreen: NetworkManager not found - singleplayer mode")
		_show_singleplayer_prompt()


func _process(delta: float) -> void:
	if _joined:
		return

	# Connection timeout - if no state received, offer singleplayer
	if not _received_state:
		_connection_timer += delta
		if _connection_timer >= CONNECTION_TIMEOUT:
			_show_singleplayer_prompt()
	else:
		# Auto-join after receiving state
		_auto_join_timer += delta
		if _auto_join_timer >= AUTO_JOIN_DELAY:
			_auto_join()


func _input(event: InputEvent) -> void:
	if _joined:
		return

	if event is InputEventKey:
		if event.pressed and event.keycode == KEY_ENTER:
			if _received_state:
				# Server available - join multiplayer
				_auto_join()
			else:
				# No server - start singleplayer
				_start_singleplayer()


func _on_spectating_started() -> void:
	print("JoinScreen: Spectating started")
	if label:
		label.text = "Connected! Joining..."


func _on_connected() -> void:
	print("JoinScreen: Connected to server")
	_received_state = true


func _on_joined_game() -> void:
	print("JoinScreen: Joined game!")
	_joined = true
	_hide_join_screen()


func _on_world_state_received(players: Array) -> void:
	if not _received_state:
		print("JoinScreen: First world state received (%d players)" % players.size())
		_received_state = true
		if label:
			label.text = "Joining game..."

	if visible and player_count_label:
		if players.size() == 0:
			player_count_label.text = "No players in game"
		elif players.size() == 1:
			player_count_label.text = "1 player in game"
		else:
			player_count_label.text = "%d players in game" % players.size()


func _show_singleplayer_prompt() -> void:
	print("JoinScreen: Server not available - showing singleplayer prompt")
	if label:
		label.text = "Server not available\nPress ENTER for Singleplayer"
	if player_count_label:
		player_count_label.text = ""


func _auto_join() -> void:
	if _joined:
		return

	print("JoinScreen: Auto-joining...")
	if network_manager and network_manager.is_spectating:
		network_manager.join_game()
	else:
		# Not spectating, just hide and continue
		_joined = true
		_hide_join_screen()


func _start_singleplayer() -> void:
	print("JoinScreen: Starting singleplayer mode")
	_joined = true

	# Disconnect from server attempts if any
	if network_manager:
		if network_manager.socket:
			network_manager.socket.close()
			network_manager.socket = null
		network_manager.is_spectating = false

	_hide_join_screen()


func _hide_join_screen() -> void:
	visible = false
	container.visible = false
