extends CanvasLayer

## Join Screen Overlay
## Shows character selection then joins server, falls back to singleplayer mode

@onready var label: Label = $CenterContainer/VBoxContainer/JoinLabel
@onready var player_count_label: Label = $CenterContainer/VBoxContainer/PlayerCountLabel
@onready var container: CenterContainer = $CenterContainer

var network_manager: Node = null
var _connection_timer: float = 0.0
var _received_state: bool = false
var _joined: bool = false
var _awaiting_selection: bool = false  # Waiting for character selection

# Selected character class (0 = Paladin, 1 = Archer)
var selected_character_class: int = 1  # Default to Archer

const CONNECTION_TIMEOUT: float = 2.0  # Wait 2 seconds for server

func _ready() -> void:
	print("JoinScreen: _ready()")
	add_to_group("join_screen")
	visible = true
	container.visible = true

	if label:
		label.text = "Connecting to server..."
	if player_count_label:
		player_count_label.text = ""

	# Check if character was already selected from menu (mobile flow)
	if GameSettings and GameSettings.character_selected_from_menu:
		print("JoinScreen: Character already selected from menu, using class %d" % GameSettings.selected_character_class)
		selected_character_class = GameSettings.selected_character_class

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
		# If character already selected, go directly to game
		if GameSettings and GameSettings.character_selected_from_menu:
			_start_singleplayer()
		else:
			_show_singleplayer_prompt()


func _process(delta: float) -> void:
	if _joined:
		return

	# Connection timeout - if no state received, offer singleplayer
	if not _received_state and not _awaiting_selection:
		_connection_timer += delta
		if _connection_timer >= CONNECTION_TIMEOUT:
			# If character already selected, go directly to singleplayer
			if GameSettings and GameSettings.character_selected_from_menu:
				_start_singleplayer()
			else:
				_show_singleplayer_prompt()
	elif _received_state and not _awaiting_selection:
		# If character already selected from menu, auto-join
		if GameSettings and GameSettings.character_selected_from_menu:
			_join_with_class()
		else:
			# Show character selection after receiving state
			_show_character_selection()


func _input(event: InputEvent) -> void:
	if _joined:
		return

	if event is InputEventKey and event.pressed:
		if _awaiting_selection:
			# Character selection - 1 for Paladin, 2 for Archer
			if event.keycode == KEY_1:
				selected_character_class = 0  # Paladin
				# Update GameSettings autoload so player reads correct class
				if GameSettings:
					GameSettings.selected_character_class = 0
				print("JoinScreen: Selected Paladin")
				if _received_state:
					_join_with_class()
				else:
					_start_singleplayer()
			elif event.keycode == KEY_2:
				selected_character_class = 1  # Archer
				# Update GameSettings autoload so player reads correct class
				if GameSettings:
					GameSettings.selected_character_class = 1
				print("JoinScreen: Selected Archer")
				if _received_state:
					_join_with_class()
				else:
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
	_awaiting_selection = true
	if label:
		label.text = "Choose Your Class (Singleplayer)\n\n[1] Paladin\n[2] Archer"
	if player_count_label:
		player_count_label.text = "Press 1 or 2 to select"


func _show_character_selection() -> void:
	_awaiting_selection = true
	print("JoinScreen: Showing character selection")
	if label:
		label.text = "Choose Your Class\n\n[1] Paladin\n[2] Archer"
	if player_count_label:
		player_count_label.text = "Press 1 or 2 to select"


func _join_with_class() -> void:
	if _joined:
		return

	print("JoinScreen: Joining with class %d" % selected_character_class)
	if network_manager and network_manager.is_spectating:
		network_manager.join_game()
	else:
		# Not spectating (singleplayer), just hide and continue
		_joined = true
		_hide_join_screen()


func _start_singleplayer() -> void:
	print("JoinScreen: Starting singleplayer mode")
	_joined = true

	# Disconnect from server attempts if any
	if network_manager:
		# Use has_method/get for defensive access (handles script caching issues)
		if "socket" in network_manager and network_manager.socket:
			network_manager.socket.close()
			network_manager.socket = null
		if "is_spectating" in network_manager:
			network_manager.is_spectating = false

	_hide_join_screen()


func _hide_join_screen() -> void:
	visible = false
	container.visible = false
