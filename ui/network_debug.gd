extends CanvasLayer
class_name NetworkDebug

## Debug overlay showing network player info in upper right corner

var label: Label
var log_lines: Array = []
const MAX_LINES := 15

func _ready() -> void:
	print("NetworkDebug: _ready()")

	# Create label directly
	label = Label.new()
	label.anchor_left = 1.0
	label.anchor_right = 1.0
	label.anchor_top = 0.0
	label.offset_left = -450
	label.offset_right = -10
	label.offset_top = 10
	label.add_theme_font_size_override("font_size", 14)
	label.add_theme_color_override("font_color", Color.WHITE)
	label.add_theme_color_override("font_shadow_color", Color.BLACK)
	label.add_theme_constant_override("shadow_offset_x", 1)
	label.add_theme_constant_override("shadow_offset_y", 1)
	add_child(label)

	_log("Network Debug Started")

	# Connect to NetworkManager
	call_deferred("_connect_signals")


func _connect_signals() -> void:
	print("NetworkDebug: Looking for NetworkManager...")

	var nm = get_node_or_null("/root/NetworkManager")
	if nm:
		print("NetworkDebug: Found NetworkManager, connecting signals...")
		if nm.has_signal("player_joined"):
			nm.player_joined.connect(_on_player_joined)
		if nm.has_signal("player_left"):
			nm.player_left.connect(_on_player_left)
		if nm.has_signal("world_state_received"):
			nm.world_state_received.connect(_on_world_state)
		if nm.has_signal("connected_to_server"):
			nm.connected_to_server.connect(_on_connected)
		if nm.has_signal("spectating_started"):
			nm.spectating_started.connect(_on_spectating)
		if nm.has_signal("joined_game"):
			nm.joined_game.connect(_on_joined)
		_log("Connected to NetworkManager")
	else:
		print("NetworkDebug: NetworkManager NOT found!")
		_log("ERROR: NetworkManager not found")


func _on_connected() -> void:
	_log("CONNECTED to server")


func _on_spectating() -> void:
	_log("SPECTATING server")


func _on_joined() -> void:
	_log("JOINED game")


func _on_player_joined(player_id: int, data: Dictionary) -> void:
	var pos = data.get("position", Vector3.ZERO)
	_log("JOIN Player %d at (%.1f, %.1f, %.1f)" % [player_id, pos.x, pos.y, pos.z])


func _on_player_left(player_id: int) -> void:
	_log("LEFT Player %d" % player_id)


func _on_world_state(players: Array) -> void:
	# This is called frequently, don't log every time
	pass


func _log(msg: String) -> void:
	var time_str := "%.1f" % (Time.get_ticks_msec() / 1000.0)
	var line := "[%s] %s" % [time_str, msg]
	log_lines.append(line)
	print("NetworkDebug: " + line)

	while log_lines.size() > MAX_LINES:
		log_lines.pop_front()

	_update_display()


func _update_display() -> void:
	if not label:
		return

	var text := "=== NETWORK DEBUG ===\n"

	# Get NetworkManager info
	var nm = get_node_or_null("/root/NetworkManager")
	if nm:
		var connected := false
		if nm.has_method("is_network_connected"):
			connected = nm.is_network_connected()

		var spectating: bool = nm.is_spectating if "is_spectating" in nm else false
		var my_id: int = nm.my_player_id if "my_player_id" in nm else 0
		var remote_count: int = nm.remote_players.size() if "remote_players" in nm else 0

		# Status line
		var status := "DISCONNECTED"
		if spectating:
			status = "SPECTATING"
		elif connected:
			status = "CONNECTED"
		text += "Status: %s\n" % status

		text += "My ID: %d\n" % my_id
		text += "Remote Players: %d\n" % remote_count

		# List remote players
		if "remote_players" in nm:
			for pid in nm.remote_players:
				var remote = nm.remote_players[pid]
				if is_instance_valid(remote):
					var pos = remote.global_position
					text += "  #%d: (%.1f, %.1f, %.1f)\n" % [pid, pos.x, pos.y, pos.z]
				else:
					text += "  #%d: INVALID NODE\n" % pid

		# Show client_state info
		if "client_state" in nm and nm.client_state:
			var cs = nm.client_state
			if cs.has_method("get_all_remote_players"):
				var remote_data = cs.get_all_remote_players()
				if remote_data.size() > 0:
					text += "Server Players: %d\n" % remote_data.size()
					for pid in remote_data:
						var p = remote_data[pid]
						text += "  srv#%d: (%.1f, %.1f, %.1f)\n" % [pid, p.x, p.y, p.z]
	else:
		text += "NetworkManager: NOT FOUND\n"

	text += "\n--- Log ---\n"
	text += "\n".join(log_lines)

	label.text = text


func _process(_delta: float) -> void:
	# Update every 30 frames (~0.5 sec)
	if Engine.get_process_frames() % 30 == 0:
		_update_display()
