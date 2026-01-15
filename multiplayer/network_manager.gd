extends Node

## UDP Multiplayer Network Manager
## Structured like MPlayer - uses Protocol for messages, ClientState for local state, ServerState for host authority

# Preload protocol classes to ensure they're available
const ProtocolClass = preload("res://multiplayer/protocol.gd")
const ClientStateClass = preload("res://multiplayer/client_state.gd")
const ServerStateClass = preload("res://multiplayer/server_state.gd")

# =============================================================================
# SIGNALS
# =============================================================================

signal connected_to_server
signal disconnected_from_server
signal spectating_started  # Now spectating (receiving state but not joined)
signal joined_game  # Transitioned from spectator to active player
signal player_joined(player_id: int, player_data: Dictionary)
signal player_left(player_id: int)
signal world_state_received(players: Array)
signal entity_state_received(entities: Array)
signal arrow_spawned(arrow_data: Dictionary)
signal arrow_hit(arrow_id: int, hit_pos: Vector3, hit_entity_id: int)
signal host_status_changed(is_host: bool)
signal latency_updated(latency_ms: int)
signal player_damage_received(damage: float, knockback: Vector3, attacker_entity_id: int)
signal game_restart_received(reason: int)  # Server broadcast: all players should respawn

# =============================================================================
# STATE MANAGERS
# =============================================================================

var client_state  # Initialized in _init()
var server_state  # Initialized in _init()

func _init() -> void:
	client_state = ClientStateClass.new()
	server_state = ServerStateClass.new()

# =============================================================================
# NETWORK
# =============================================================================

var socket: PacketPeerUDP
var server_ip: String = ProtocolClass.DEFAULT_SERVER
var server_port: int = ProtocolClass.SERVER_PORT
var is_spectating: bool = false  # True when connected as spectator, not yet joined
var _spectate_seq: int = 0  # Sequence number for spectate message

# =============================================================================
# CONVENIENCE ACCESSORS (for backward compatibility)
# Properties that forward to client_state
# =============================================================================

## Whether we're the host (controls entities)
var is_host: bool:
	get: return client_state.is_host if client_state else false

## Our assigned player ID
var my_player_id: int:
	get: return client_state.my_player_id if client_state else 0

## Player name
var player_name: String:
	get: return client_state.player_name if client_state else "Player"
	set(value):
		if client_state:
			client_state.player_name = value

func is_network_connected() -> bool:
	return client_state.is_network_connected() if client_state else false

func get_my_player_id() -> int:
	return client_state.my_player_id if client_state else 0

func is_host_player() -> bool:
	return client_state.is_host if client_state else false

func get_player_name() -> String:
	return client_state.player_name if client_state else "Player"

func set_player_name(value: String) -> void:
	if client_state:
		client_state.player_name = value

# =============================================================================
# LOCAL REFERENCES
# =============================================================================

var remote_players: Dictionary = {}  # player_id -> RemotePlayer node
var local_player: Node3D = null

# Entity tracking
var tracked_entities: Dictionary = {}  # entity_id -> {type, node, id}
var network_arrows: Dictionary = {}    # arrow_id -> Arrow node
var _next_arrow_id: int = 1

# =============================================================================
# TIMERS
# =============================================================================

var _update_timer: float = 0.0
var _entity_update_timer: float = 0.0
var _ping_timer: float = 0.0
var _heartbeat_timer: float = 0.0
var _log_timer: float = 0.0

const UPDATE_INTERVAL: float = 0.0333       # 30 Hz player updates
const ENTITY_UPDATE_INTERVAL: float = 0.0333 # 30 Hz entity updates (host)
const PING_INTERVAL: float = 2.0            # Ping every 2 seconds
const HEARTBEAT_INTERVAL: float = 5.0       # Heartbeat every 5 seconds
const LOG_INTERVAL: float = 0.5             # Log every 0.5 seconds

# =============================================================================
# DESYNC DETECTION & RECOVERY
# =============================================================================

const DESYNC_WARNING_THRESHOLD_MS: int = 500  # Show warning after 500ms without state update
const DESYNC_SNAP_THRESHOLD: float = 3.0      # Snap to server if > 3m divergence

var _last_state_update_time: int = 0  # Time.get_ticks_msec() of last world state
var _desync_warning_visible: bool = false
var _needs_sync_recovery: bool = false  # True when we need to force-apply server state
var _desync_warning_label: Label = null
var _desync_warning_panel: ColorRect = null

# =============================================================================
# LOGGING
# =============================================================================

var _log_file: FileAccess
const STATE_NAMES = ["IDLE", "WALKING", "RUNNING", "ATTACKING", "BLOCKING", "JUMPING", "CASTING", "DRAWING_BOW", "HOLDING_BOW", "DEAD"]

# =============================================================================
# LIFECYCLE
# =============================================================================

func _ready() -> void:
	# Generate random player name
	client_state.player_name = "Player_%d" % (randi() % 10000)
	print("NetworkManager: Ready, player name: ", client_state.player_name)

	# Connect client_state signals
	client_state.connected.connect(_on_client_connected)
	client_state.disconnected.connect(_on_client_disconnected)
	client_state.host_status_changed.connect(_on_host_status_changed)
	client_state.state_updated.connect(_on_state_updated)
	client_state.player_added.connect(_on_player_added)
	client_state.player_removed.connect(_on_player_removed)
	client_state.entity_updated.connect(_on_entity_updated)
	client_state.arrow_spawned.connect(_on_arrow_spawned)
	client_state.arrow_hit.connect(_on_arrow_hit)
	client_state.latency_updated.connect(_on_latency_updated)
	client_state.divergence_detected.connect(_on_divergence_detected)

	# Open log file
	var log_path = "user://multiplayer_%s.log" % client_state.player_name
	_log_file = FileAccess.open(log_path, FileAccess.WRITE)
	if _log_file:
		_log("=== Multiplayer Log Started for %s ===" % client_state.player_name)
		print("NetworkManager: Logging to %s" % ProjectSettings.globalize_path(log_path))

	# Create desync warning UI
	_create_desync_warning_ui()

	# Auto-connect to server on startup
	call_deferred("_auto_connect")


func _auto_connect() -> void:
	# Check for --server argument to skip auto-connect (for server process)
	for arg in OS.get_cmdline_args():
		if arg == "--server" or "server.tscn" in arg:
			return

	var server_host := ProtocolClass.DEFAULT_SERVER
	print("NetworkManager: Auto-connecting as spectator to %s:%d" % [server_host, server_port])
	spectate_server(server_host, server_port)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		if _log_file:
			_log("=== Game closing ===")
			_log_file.close()
			_log_file = null


func _process(delta: float) -> void:
	# Need socket to receive packets (for both spectating and playing)
	if socket == null:
		return

	# Always receive packets when connected (spectating or playing)
	_receive_packets()

	# If only spectating, don't send game updates
	if is_spectating:
		return

	if not client_state.is_network_connected():
		return

	# Check for message retries
	var retry_msg: PackedByteArray = client_state.check_retry()
	if not retry_msg.is_empty():
		socket.put_packet(retry_msg)

	# Send position updates
	_update_timer += delta
	if _update_timer >= UPDATE_INTERVAL:
		_update_timer = 0.0
		_send_update()

	# Note: Server is authoritative for entities - clients don't send entity updates

	# Send ping
	_ping_timer += delta
	if _ping_timer >= PING_INTERVAL:
		_ping_timer = 0.0
		_send_ping()

	# Send heartbeat
	_heartbeat_timer += delta
	if _heartbeat_timer >= HEARTBEAT_INTERVAL:
		_heartbeat_timer = 0.0
		_send_heartbeat()

	# Periodic logging
	_log_timer += delta
	if _log_timer >= LOG_INTERVAL:
		_log_timer = 0.0
		_log_positions()

	# Check for desync (no state update for too long)
	_check_desync_warning()

# =============================================================================
# LOGGING
# =============================================================================

func _log(message: String) -> void:
	if _log_file:
		var timestamp = Time.get_ticks_msec() / 1000.0
		_log_file.store_line("[%.3f] %s" % [timestamp, message])
		_log_file.flush()


func _get_state_name(state: int) -> String:
	if state >= 0 and state < STATE_NAMES.size():
		return STATE_NAMES[state]
	return "UNKNOWN(%d)" % state


func _log_positions() -> void:
	if client_state.my_player_id == 0:
		return

	# Log local player
	if local_player:
		var state = ProtocolClass.PlayerState.STATE_IDLE
		if local_player.has_method("get_network_state"):
			state = local_player.get_network_state()
		var pos = local_player.global_position
		_log("LOCAL  [ID:%d] pos=(%.2f, %.2f, %.2f) state=%s" % [
			client_state.my_player_id, pos.x, pos.y, pos.z, _get_state_name(state)
		])

	# Log remote players
	for player_id in remote_players.keys():
		var remote = remote_players[player_id]
		if is_instance_valid(remote):
			var pos = remote.global_position
			var state = remote.current_state if "current_state" in remote else 0
			_log("REMOTE [ID:%d] pos=(%.2f, %.2f, %.2f) state=%s" % [
				player_id, pos.x, pos.y, pos.z, _get_state_name(state)
			])

	# Log latency and divergence
	_log("STATS: latency=%dms divergences=%d host=%s" % [
		client_state.get_latency(),
		client_state.get_divergence_count(),
		"yes" if client_state.is_host else "no"
	])

# =============================================================================
# DESYNC WARNING UI
# =============================================================================

func _create_desync_warning_ui() -> void:
	# Create a CanvasLayer for the warning overlay
	var canvas = CanvasLayer.new()
	canvas.name = "DesyncWarningCanvas"
	canvas.layer = 90  # High layer but below restart overlay
	add_child(canvas)

	# Create warning panel (top-right corner)
	_desync_warning_panel = ColorRect.new()
	_desync_warning_panel.color = Color(0.8, 0.2, 0.2, 0.85)
	_desync_warning_panel.custom_minimum_size = Vector2(280, 60)
	_desync_warning_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_desync_warning_panel.position = Vector2(-290, 10)
	_desync_warning_panel.visible = false
	canvas.add_child(_desync_warning_panel)

	# Create warning label
	_desync_warning_label = Label.new()
	_desync_warning_label.text = "DESYNC WARNING\nNo server update"
	_desync_warning_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_desync_warning_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_desync_warning_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_desync_warning_label.add_theme_font_size_override("font_size", 16)
	_desync_warning_label.add_theme_color_override("font_color", Color(1, 1, 1))
	_desync_warning_panel.add_child(_desync_warning_label)


func _check_desync_warning() -> void:
	if _last_state_update_time == 0:
		return  # Haven't received any state yet

	var now := Time.get_ticks_msec()
	var elapsed := now - _last_state_update_time

	if elapsed > DESYNC_WARNING_THRESHOLD_MS:
		if not _desync_warning_visible:
			_show_desync_warning(elapsed)
		else:
			# Update the elapsed time display
			_update_desync_warning_text(elapsed)
	else:
		if _desync_warning_visible:
			_hide_desync_warning()


func _show_desync_warning(elapsed_ms: int) -> void:
	_desync_warning_visible = true
	_needs_sync_recovery = true  # Mark that we need to force-apply server state when it arrives
	if _desync_warning_panel:
		_desync_warning_panel.visible = true
	if _desync_warning_label:
		_desync_warning_label.text = "DESYNC WARNING\nNo update for %dms" % elapsed_ms
	_log("DESYNC WARNING: No state update for %dms - recovery needed" % elapsed_ms)
	print("NetworkManager: DESYNC detected - will force sync on next server update")


func _hide_desync_warning() -> void:
	_desync_warning_visible = false
	if _desync_warning_panel:
		_desync_warning_panel.visible = false


func _update_desync_warning_text(elapsed_ms: int) -> void:
	if _desync_warning_label and _desync_warning_visible:
		_desync_warning_label.text = "DESYNC WARNING\nNo update for %dms" % elapsed_ms


## Force-apply server state to all local objects after desync recovery
func _perform_sync_recovery(players: Array[ProtocolClass.PlayerData]) -> void:
	print("NetworkManager: === SYNC RECOVERY - Forcing server state ===")
	_log("SYNC RECOVERY: Forcing server state to all local objects")

	# Find our player data in the server state
	var my_id: int = client_state.my_player_id
	var my_server_data: ProtocolClass.PlayerData = null

	for player_data in players:
		if player_data.player_id == my_id:
			my_server_data = player_data
			break

	# Force-apply server state to local player
	if my_server_data and local_player and is_instance_valid(local_player):
		var server_pos := my_server_data.get_position()
		var old_pos := local_player.global_position

		# Force position
		local_player.global_position = server_pos
		client_state.update_local_position(server_pos)

		# Force health
		if "current_health" in local_player:
			local_player.current_health = my_server_data.health
			if local_player.has_signal("health_changed") and "max_health" in local_player:
				local_player.health_changed.emit(my_server_data.health, local_player.max_health)
		client_state.update_local_health(my_server_data.health)

		# Force rotation
		if "rotation" in local_player:
			local_player.rotation.y = my_server_data.rotation_y
		client_state.update_local_rotation(my_server_data.rotation_y)

		print("NetworkManager: SYNC RECOVERY - Player forced from (%.1f,%.1f,%.1f) to (%.1f,%.1f,%.1f)" % [
			old_pos.x, old_pos.y, old_pos.z,
			server_pos.x, server_pos.y, server_pos.z
		])
		_log("SYNC RECOVERY: Player pos corrected, health=%.1f" % my_server_data.health)

	# Force-apply server state to all tracked entities
	for entity_id in tracked_entities.keys():
		var entity_info = tracked_entities[entity_id]
		var node = entity_info["node"]
		var server_entity: ProtocolClass.EntityData = client_state.get_remote_entity(entity_id)

		if server_entity and is_instance_valid(node):
			var data = {
				"entity_id": server_entity.entity_id,
				"entity_type": server_entity.entity_type,
				"position": server_entity.get_position(),
				"rotation_y": server_entity.rotation_y,
				"state": server_entity.state,
				"health": server_entity.health,
				"extra_data": server_entity.extra_data
			}

			# Force position directly (bypass interpolation)
			node.global_position = server_entity.get_position()

			# Apply full network state
			if node.has_method("apply_network_state"):
				node.apply_network_state(data)

			print("NetworkManager: SYNC RECOVERY - Entity %d forced to (%.1f,%.1f,%.1f) health=%.1f" % [
				entity_id,
				server_entity.x, server_entity.y, server_entity.z,
				server_entity.health
			])

	# Clear the recovery flag
	_needs_sync_recovery = false
	print("NetworkManager: === SYNC RECOVERY COMPLETE ===")

# =============================================================================
# CONNECTION
# =============================================================================

## Connect to server as spectator (watch game without playing)
func spectate_server(ip: String = "", port: int = 0) -> bool:
	print("NetworkManager: spectate_server called")
	if ip.is_empty():
		ip = server_ip
	if port == 0:
		port = server_port

	server_ip = ip
	server_port = port

	print("NetworkManager: Creating UDP socket to %s:%d (spectator)" % [ip, port])
	socket = PacketPeerUDP.new()
	var err = socket.connect_to_host(ip, port)

	if err != OK:
		print("NetworkManager: Failed to connect to %s:%d - Error: %d" % [ip, port, err])
		return false

	print("NetworkManager: Socket connected to %s:%d (spectating)" % [ip, port])

	# Send spectate packet
	_spectate_seq += 1
	var msg = ProtocolClass.build_spectate_msg(_spectate_seq)
	socket.put_packet(msg)
	print("NetworkManager: Sent spectate packet (%d bytes)" % msg.size())

	return true

## Join the game from spectator mode
func join_game() -> bool:
	if socket == null:
		print("NetworkManager: Cannot join - not connected to server")
		return false

	if not is_spectating:
		print("NetworkManager: Already joined or not spectating")
		return false

	print("NetworkManager: Joining game from spectator mode")

	# Stop spectating
	is_spectating = false

	# Start connection process
	client_state.start_connecting(client_state.player_name)

	# Send join packet
	_send_join()
	return true

## Connect to server and join immediately (legacy behavior)
func connect_to_server(ip: String = "", port: int = 0) -> bool:
	print("NetworkManager: connect_to_server called")
	if ip.is_empty():
		ip = server_ip
	if port == 0:
		port = server_port

	server_ip = ip
	server_port = port

	print("NetworkManager: Creating UDP socket to %s:%d" % [ip, port])
	socket = PacketPeerUDP.new()
	var err = socket.connect_to_host(ip, port)

	if err != OK:
		print("NetworkManager: Failed to connect to %s:%d - Error: %d" % [ip, port, err])
		return false

	print("NetworkManager: Socket connected to %s:%d" % [ip, port])

	# Start connection process
	client_state.start_connecting(client_state.player_name)

	# Send join packet
	_send_join()
	return true


func disconnect_from_server() -> void:
	if not client_state.is_network_connected():
		return

	_log("=== Disconnecting from server ===")
	_send_leave()
	socket.close()

	# Clear remote players
	for player_id in remote_players.keys():
		var remote = remote_players[player_id]
		if is_instance_valid(remote):
			remote.queue_free()
	remote_players.clear()

	# Reset client state
	client_state.handle_disconnect()

	# Close log file
	if _log_file:
		_log_file.close()
		_log_file = null

	disconnected_from_server.emit()
	print("NetworkManager: Disconnected from server")


func set_local_player(player: Node3D) -> void:
	local_player = player

# =============================================================================
# SENDING MESSAGES
# =============================================================================

func _send_join() -> void:
	print("NetworkManager: _send_join called")
	var msg: PackedByteArray = client_state.build_join_msg()
	socket.put_packet(msg)
	client_state.send_reliable(msg, ProtocolClass.MsgType.MSG_JOIN)
	print("NetworkManager: Sent join packet (%d bytes)" % msg.size())


func _send_leave() -> void:
	var msg: PackedByteArray = client_state.build_leave_msg()
	socket.put_packet(msg)


func _send_update() -> void:
	if local_player == null or client_state.my_player_id == 0:
		return

	# Update client state with local player data
	client_state.update_local_position(local_player.global_position)

	var facing_rot: float = 0.0
	if local_player.has_method("get_facing_rotation"):
		facing_rot = local_player.get_facing_rotation()
	else:
		facing_rot = local_player.rotation.y
	client_state.update_local_rotation(facing_rot)

	var state = ProtocolClass.PlayerState.STATE_IDLE
	if local_player.has_method("get_network_state"):
		state = local_player.get_network_state()
	client_state.update_local_state(state)

	var combat_mode_val = ProtocolClass.CombatMode.ARMED
	if "combat_mode" in local_player:
		combat_mode_val = local_player.combat_mode
	client_state.update_local_combat_mode(combat_mode_val)

	var char_class = ProtocolClass.CharacterClass.ARCHER
	if "character_class" in local_player:
		char_class = local_player.character_class
	client_state.update_local_character_class(char_class)

	var health = 100.0
	if "health" in local_player:
		health = local_player.health
	client_state.update_local_health(health)

	var anim_name = "Idle"
	if local_player.has_method("get_current_animation"):
		anim_name = local_player.get_current_animation()
	client_state.update_local_animation(anim_name)

	# Build and send move message
	var msg: PackedByteArray = client_state.build_move_msg()
	socket.put_packet(msg)


func _send_ping() -> void:
	var msg: PackedByteArray = client_state.build_ping_msg()
	socket.put_packet(msg)


func _send_heartbeat() -> void:
	var header := ProtocolClass.MsgHeader.new()
	header.type = ProtocolClass.MsgType.MSG_HEARTBEAT
	header.seq = client_state.get_next_seq()
	header.sender_id = client_state.my_player_id
	socket.put_packet(header.encode())

# =============================================================================
# RECEIVING MESSAGES
# =============================================================================

func _receive_packets() -> void:
	while socket.get_available_packet_count() > 0:
		var packet = socket.get_packet()
		if packet.size() < ProtocolClass.MsgHeader.size():
			continue

		var header := ProtocolClass.parse_header(packet)
		if header == null:
			continue

		match header.type:
			ProtocolClass.MsgType.MSG_SPECTATE_ACK:
				_handle_spectate_ack(packet)
			ProtocolClass.MsgType.MSG_JOIN_ACK:
				_handle_join_ack(packet)
			ProtocolClass.MsgType.MSG_STATE:
				_handle_world_state(packet)
			ProtocolClass.MsgType.MSG_ACK:
				_handle_ack(packet)
			ProtocolClass.MsgType.MSG_PONG:
				_handle_pong(packet)
			ProtocolClass.MsgType.MSG_ENTITY_STATE:
				_handle_entity_state(packet)
			ProtocolClass.MsgType.MSG_ARROW_SPAWN:
				_handle_arrow_spawn(packet)
			ProtocolClass.MsgType.MSG_ARROW_HIT:
				_handle_arrow_hit(packet)
			ProtocolClass.MsgType.MSG_HOST_CHANGE:
				_handle_host_change(packet)
			ProtocolClass.MsgType.MSG_PLAYER_DAMAGE:
				_handle_player_damage(packet)
			ProtocolClass.MsgType.MSG_GAME_RESTART:
				_handle_game_restart(packet)


func _handle_spectate_ack(_packet: PackedByteArray) -> void:
	print("NetworkManager: Received SPECTATE_ACK - now spectating")
	is_spectating = true
	spectating_started.emit()
	_log("SPECTATING: Now watching game")


func _handle_join_ack(packet: PackedByteArray) -> void:
	if packet.size() < ProtocolClass.MsgHeader.size() + 4 + ProtocolClass.PlayerData.size():
		return

	var offset := ProtocolClass.MsgHeader.size()
	var assigned_id := packet.decode_u32(offset)
	offset += 4

	var player_data := ProtocolClass.PlayerData.new()
	player_data.decode(packet, offset)

	client_state.handle_join_ack(assigned_id, player_data)
	print("NetworkManager: Assigned player ID: %d" % assigned_id)
	_log("JOINED: id=%d" % assigned_id)

	# Emit joined_game signal (after transitioning from spectator)
	joined_game.emit()


func _handle_ack(packet: PackedByteArray) -> void:
	if packet.size() < ProtocolClass.MsgHeader.size() + 4:
		return

	var acked_seq := packet.decode_u32(ProtocolClass.MsgHeader.size())
	client_state.handle_ack(acked_seq)


func _handle_pong(packet: PackedByteArray) -> void:
	if packet.size() < ProtocolClass.MsgHeader.size() + 8:
		return

	var original_timestamp := packet.decode_u64(ProtocolClass.MsgHeader.size())
	client_state.handle_pong(original_timestamp)


func _handle_world_state(packet: PackedByteArray) -> void:
	# Record the time of this state update for desync detection
	_last_state_update_time = Time.get_ticks_msec()

	var offset := ProtocolClass.MsgHeader.size()
	if packet.size() < offset + 5:  # state_seq(4) + player_count(1)
		return

	var state_seq := packet.decode_u32(offset)
	offset += 4
	var player_count := packet.decode_u8(offset)
	offset += 1

	_log("PACKET: size=%d state_seq=%d player_count=%d" % [packet.size(), state_seq, player_count])

	var players: Array[ProtocolClass.PlayerData] = []
	var players_array: Array = []  # For backward compatibility signal

	for i in range(player_count):
		if offset + ProtocolClass.PlayerData.size() > packet.size():
			break

		var player_data := ProtocolClass.PlayerData.new()
		if not player_data.decode(packet, offset):
			break
		offset += ProtocolClass.PlayerData.size()

		players.append(player_data)

		# Build legacy dictionary for signals
		var data = {
			"player_id": player_data.player_id,
			"position": player_data.get_position(),
			"rotation_y": player_data.rotation_y,
			"state": player_data.state,
			"combat_mode": player_data.combat_mode,
			"character_class": player_data.character_class,
			"health": player_data.health,
			"anim_name": player_data.anim_name
		}
		players_array.append(data)

		_log("PARSED [%d]: id=%d pos=(%.2f,%.2f,%.2f) rot=%.2f state=%d" % [
			i, player_data.player_id, player_data.x, player_data.y, player_data.z,
			player_data.rotation_y, player_data.state
		])

	# Handle first-time ID assignment (legacy support) - skip if spectating
	if not is_spectating and client_state.my_player_id == 0 and not players.is_empty():
		# Last player in list is us (server behavior)
		var our_data := players[players.size() - 1]
		var initial_data := ProtocolClass.PlayerData.new()
		initial_data.player_id = our_data.player_id
		initial_data.set_position(local_player.global_position if local_player else our_data.get_position())
		client_state.handle_join_ack(our_data.player_id, initial_data)
		print("NetworkManager: Assigned player ID: %d" % our_data.player_id)

		# Don't overwrite local player position
		if local_player:
			var current_pos = local_player.global_position
			print("NetworkManager: Keeping local spawn at (%.1f, %.1f, %.1f)" % [current_pos.x, current_pos.y, current_pos.z])

	# Update client state
	client_state.handle_state_broadcast(state_seq, players)

	# SYNC RECOVERY: If we were desynced, force-apply server state to local player
	if _needs_sync_recovery:
		_perform_sync_recovery(players)

	# Update visual representations
	_update_remote_player_visuals()

	world_state_received.emit(players_array)


func _update_remote_player_visuals() -> void:
	var current_ids: Dictionary = {}

	for player_id in client_state.get_all_remote_players().keys():
		current_ids[player_id] = true
		var player_data: ProtocolClass.PlayerData = client_state.get_remote_player(player_id)

		if player_id in remote_players:
			_update_remote_player(player_id, player_data)
		else:
			_create_remote_player(player_id, player_data)

	# Remove players that left
	var to_remove: Array[int] = []
	for existing_id in remote_players.keys():
		if not current_ids.has(existing_id):
			to_remove.append(existing_id)

	for pid in to_remove:
		_remove_remote_player(pid)


func _handle_host_change(packet: PackedByteArray) -> void:
	if packet.size() < ProtocolClass.MsgHeader.size() + 4:
		return

	var new_host_id := packet.decode_u32(ProtocolClass.MsgHeader.size())
	client_state.handle_host_change(new_host_id)
	_log("HOST CHANGE: new_host=%d is_us=%s" % [new_host_id, "yes" if new_host_id == client_state.my_player_id else "no"])


func _handle_player_damage(packet: PackedByteArray) -> void:
	# Parse player damage packet from server (entity hit us)
	var offset := ProtocolClass.MsgHeader.size()
	var damage_data := ProtocolClass.PlayerDamageData.new()
	if not damage_data.decode(packet, offset):
		print("NetworkManager: Failed to decode player damage packet")
		return

	# Verify this damage is for us
	if damage_data.target_player_id != client_state.my_player_id:
		print("NetworkManager: Player damage for different player %d (we are %d)" % [damage_data.target_player_id, client_state.my_player_id])
		return

	print("NetworkManager: Received player damage: %.1f from entity %d" % [damage_data.damage, damage_data.attacker_entity_id])
	_log("PLAYER DAMAGE: damage=%.1f from_entity=%d knockback=(%.2f,%.2f,%.2f)" % [
		damage_data.damage, damage_data.attacker_entity_id,
		damage_data.knockback_x, damage_data.knockback_y, damage_data.knockback_z
	])

	# Apply damage to local player
	if local_player and is_instance_valid(local_player):
		var knockback = damage_data.get_knockback()
		if local_player.has_method("take_hit"):
			# Use take_hit which handles damage, knockback, stun, and visuals
			local_player.take_hit(damage_data.damage, knockback, false)
		elif local_player.has_method("take_damage"):
			# Fallback: just apply damage
			local_player.take_damage(damage_data.damage)

	# Emit signal for any listeners
	player_damage_received.emit(damage_data.damage, damage_data.get_knockback(), damage_data.attacker_entity_id)


func _handle_game_restart(packet: PackedByteArray) -> void:
	# Parse restart reason from packet
	var offset := ProtocolClass.MsgHeader.size()
	if packet.size() < offset + 4:
		print("NetworkManager: Game restart packet too small")
		return

	var reason := packet.decode_u32(offset)
	print("NetworkManager: Received game restart (reason: %d)" % reason)
	_log("GAME RESTART: reason=%d" % reason)

	# Emit signal for listeners (player will handle respawn)
	game_restart_received.emit(reason)


## Send game restart request to server
func send_game_restart(reason: int) -> void:
	if socket == null or not client_state.is_network_connected():
		print("NetworkManager: Cannot send restart - not connected")
		return

	var msg := ProtocolClass.build_game_restart_msg(
		client_state.get_next_seq(),
		client_state.my_player_id,
		reason
	)
	socket.put_packet(msg)
	print("NetworkManager: Sent game restart request (reason: %d)" % reason)
	_log("RESTART REQUEST: reason=%d" % reason)

# =============================================================================
# REMOTE PLAYER MANAGEMENT
# =============================================================================

func _create_remote_player(player_id: int, player_data: ProtocolClass.PlayerData) -> void:
	var remote_scene = load("res://multiplayer/remote_player.tscn")
	if remote_scene == null:
		print("NetworkManager: Failed to load remote_player.tscn")
		return

	var remote = remote_scene.instantiate()
	remote.player_id = player_id
	remote.name = "RemotePlayer_%d" % player_id
	# Set character class BEFORE adding to scene so correct model loads
	remote.character_class = player_data.character_class

	get_tree().current_scene.add_child(remote)
	remote_players[player_id] = remote

	_update_remote_player(player_id, player_data)

	_log("JOINED [ID:%d] pos=(%.2f, %.2f, %.2f) state=%s" % [
		player_id, player_data.x, player_data.y, player_data.z, _get_state_name(player_data.state)
	])
	print("NetworkManager: Created remote player %d" % player_id)

	# Emit legacy signal
	var data = {
		"player_id": player_data.player_id,
		"position": player_data.get_position(),
		"rotation_y": player_data.rotation_y,
		"state": player_data.state,
		"combat_mode": player_data.combat_mode,
		"health": player_data.health,
		"anim_name": player_data.anim_name
	}
	player_joined.emit(player_id, data)


func _update_remote_player(player_id: int, player_data: ProtocolClass.PlayerData) -> void:
	if player_id not in remote_players:
		return

	var remote = remote_players[player_id]
	if not is_instance_valid(remote):
		return

	# Convert to legacy dictionary format
	var data = {
		"position": player_data.get_position(),
		"rotation_y": player_data.rotation_y,
		"state": player_data.state,
		"combat_mode": player_data.combat_mode,
		"character_class": player_data.character_class,
		"health": player_data.health,
		"anim_name": player_data.anim_name
	}
	remote.update_from_network(data)


func _remove_remote_player(player_id: int) -> void:
	if player_id not in remote_players:
		return

	var remote = remote_players[player_id]
	if is_instance_valid(remote):
		remote.queue_free()

	remote_players.erase(player_id)
	print("NetworkManager: Removed remote player %d" % player_id)
	player_left.emit(player_id)

# =============================================================================
# ENTITY SYNCHRONIZATION
# =============================================================================

func register_entity(entity: Node3D, entity_type: int, entity_id: int) -> void:
	tracked_entities[entity_id] = {
		"type": entity_type,
		"node": entity,
		"id": entity_id
	}

	# Also register in server_state if we're host
	if client_state.is_host:
		server_state.register_entity(entity_type, entity.global_position)

	_log("ENTITY REGISTERED: type=%d id=%d" % [entity_type, entity_id])
	print("NetworkManager: Registered entity type=%d id=%d" % [entity_type, entity_id])


func unregister_entity(entity_id: int) -> void:
	if entity_id in tracked_entities:
		tracked_entities.erase(entity_id)
		server_state.remove_entity(entity_id)
		_log("ENTITY UNREGISTERED: id=%d" % entity_id)


func _send_entity_updates() -> void:
	if tracked_entities.is_empty():
		return

	var entities: Array[ProtocolClass.EntityData] = []

	for entity_id in tracked_entities:
		var entity_info = tracked_entities[entity_id]
		var node = entity_info["node"]
		if not is_instance_valid(node):
			continue

		var entity_data := ProtocolClass.EntityData.new()
		entity_data.entity_type = entity_info["type"]
		entity_data.entity_id = entity_id
		entity_data.set_position(node.global_position)

		# Get facing rotation (model rotation for entities with separate model)
		if node.has_method("get_facing_rotation"):
			entity_data.rotation_y = node.get_facing_rotation()
		else:
			entity_data.rotation_y = node.rotation.y

		# Get state and health from entity
		if node.has_method("get_network_state"):
			entity_data.state = node.get_network_state()
		elif "state" in node:
			entity_data.state = node.state

		if "health" in node:
			entity_data.health = node.health

		# Extra data for Dragon
		entity_data.extra_data.resize(8)
		if entity_info["type"] == ProtocolClass.EntityType.ENTITY_DRAGON:
			if "lap_count" in node:
				entity_data.extra_data.encode_u32(0, node.lap_count)
			if "patrol_angle" in node:
				entity_data.extra_data.encode_float(4, node.patrol_angle)

		entities.append(entity_data)

	var msg: PackedByteArray = ProtocolClass.build_entity_state_msg(client_state.get_next_seq(), entities)
	socket.put_packet(msg)


func _handle_entity_state(packet: PackedByteArray) -> void:
	# Server is authoritative for entities - all clients receive state
	var offset := ProtocolClass.MsgHeader.size()
	if packet.size() < offset + 1:
		return

	var entity_count := packet.decode_u8(offset)
	offset += 1

	var entities: Array[ProtocolClass.EntityData] = []
	var entities_array: Array = []  # Legacy format

	for i in range(entity_count):
		if offset + ProtocolClass.EntityData.size() > packet.size():
			break

		var entity_data := ProtocolClass.EntityData.new()
		if not entity_data.decode(packet, offset):
			break
		offset += ProtocolClass.EntityData.size()

		entities.append(entity_data)

		# Legacy format
		var data = {
			"entity_id": entity_data.entity_id,
			"entity_type": entity_data.entity_type,
			"position": entity_data.get_position(),
			"rotation_y": entity_data.rotation_y,
			"state": entity_data.state,
			"health": entity_data.health,
			"extra1": entity_data.extra_data.decode_u32(0) if entity_data.extra_data.size() >= 4 else 0,
			"extra2": entity_data.extra_data.decode_float(4) if entity_data.extra_data.size() >= 8 else 0.0
		}
		entities_array.append(data)

		# Update local entity if it exists
		if entity_data.entity_id in tracked_entities:
			var entity_info = tracked_entities[entity_data.entity_id]
			var node = entity_info["node"]
			if is_instance_valid(node) and node.has_method("apply_network_state"):
				node.apply_network_state(data)

	client_state.handle_entity_broadcast(entities)
	entity_state_received.emit(entities_array)

# =============================================================================
# ARROW SYNCHRONIZATION
# =============================================================================

func send_arrow_spawn(spawn_pos: Vector3, direction: Vector3, shooter_id: int) -> int:
	var arrow_id = _next_arrow_id
	_next_arrow_id += 1

	if not socket or not is_network_connected():
		return arrow_id  # Not connected, just return local arrow ID

	var msg: PackedByteArray = client_state.build_arrow_spawn_msg(arrow_id, spawn_pos, direction)
	socket.put_packet(msg)

	print("NetworkManager: SENT arrow spawn id=%d to server" % arrow_id)
	_log("ARROW SPAWN: id=%d pos=(%.2f,%.2f,%.2f)" % [arrow_id, spawn_pos.x, spawn_pos.y, spawn_pos.z])

	return arrow_id


func _handle_arrow_spawn(packet: PackedByteArray) -> void:
	var header := ProtocolClass.parse_header(packet)
	if header == null:
		return

	if header.sender_id == client_state.my_player_id:
		return  # Ignore own arrows

	var offset := ProtocolClass.MsgHeader.size()
	var arrow_data := ProtocolClass.ArrowData.new()
	if not arrow_data.decode(packet, offset):
		return

	var data = {
		"arrow_id": arrow_data.arrow_id,
		"position": arrow_data.get_position(),
		"direction": arrow_data.get_direction(),
		"shooter_id": arrow_data.shooter_id
	}

	_log("ARROW RECEIVED: id=%d pos=(%.2f,%.2f,%.2f)" % [
		arrow_data.arrow_id, arrow_data.x, arrow_data.y, arrow_data.z
	])

	client_state.handle_arrow_spawn(arrow_data)
	arrow_spawned.emit(data)


func send_arrow_hit(arrow_id: int, hit_pos: Vector3, hit_entity_id: int) -> void:
	if not socket or not is_network_connected():
		return  # Not connected

	var msg: PackedByteArray = client_state.build_arrow_hit_msg(arrow_id, hit_pos, hit_entity_id)
	socket.put_packet(msg)
	_log("ARROW HIT: id=%d entity=%d" % [arrow_id, hit_entity_id])


func _handle_arrow_hit(packet: PackedByteArray) -> void:
	var offset := ProtocolClass.MsgHeader.size()
	var hit_data := ProtocolClass.ArrowHitData.new()
	if not hit_data.decode(packet, offset):
		return

	client_state.handle_arrow_hit(hit_data)
	arrow_hit.emit(hit_data.arrow_id, hit_data.get_hit_position(), hit_data.hit_entity_id)

# =============================================================================
# ENTITY DAMAGE
# =============================================================================

func send_entity_damage(entity_id: int, damage: float, attacker_id: int) -> void:
	var msg: PackedByteArray = client_state.build_entity_damage_msg(entity_id, damage)
	socket.put_packet(msg)
	_log("ENTITY DAMAGE: entity=%d damage=%.1f attacker=%d" % [entity_id, damage, attacker_id])

# =============================================================================
# CLIENT STATE SIGNAL HANDLERS
# =============================================================================

func _on_client_connected(player_id: int) -> void:
	print("NetworkManager: Connected with ID %d" % player_id)
	connected_to_server.emit()


func _on_client_disconnected() -> void:
	print("NetworkManager: Disconnected")


func _on_host_status_changed(new_is_host: bool) -> void:
	if new_is_host:
		print("NetworkManager: We are now the HOST")
		_log("HOST: We are now authoritative for entities")
	else:
		print("NetworkManager: We are no longer host")
		_log("CLIENT: No longer host")
	host_status_changed.emit(new_is_host)


func _on_state_updated(state_seq: int) -> void:
	pass  # Could log state sequence updates


func _on_player_added(player_id: int, player_data: ProtocolClass.PlayerData) -> void:
	print("NetworkManager: Player %d added" % player_id)
	if player_id not in remote_players:
		_create_remote_player(player_id, player_data)


func _on_player_removed(player_id: int) -> void:
	print("NetworkManager: Player %d removed" % player_id)
	if player_id in remote_players:
		var remote = remote_players[player_id]
		if is_instance_valid(remote):
			remote.queue_free()
		remote_players.erase(player_id)
		player_left.emit(player_id)


func _on_entity_updated(entity_id: int, entity_data: ProtocolClass.EntityData) -> void:
	pass  # Handled in _handle_entity_state


func _on_arrow_spawned(arrow_data: ProtocolClass.ArrowData) -> void:
	pass  # Handled in _handle_arrow_spawn


func _on_arrow_hit(hit_data: ProtocolClass.ArrowHitData) -> void:
	pass  # Handled in _handle_arrow_hit


func _on_latency_updated(latency_ms: int) -> void:
	pass  # Could display latency in UI


func _on_divergence_detected(local_data: ProtocolClass.PlayerData, server_data: ProtocolClass.PlayerData) -> void:
	var local_pos := local_data.get_position()
	var server_pos := server_data.get_position()
	var distance := local_pos.distance_to(server_pos)

	_log("DIVERGENCE: local=(%.2f,%.2f,%.2f) server=(%.2f,%.2f,%.2f) dist=%.2f" % [
		local_data.x, local_data.y, local_data.z,
		server_data.x, server_data.y, server_data.z,
		distance
	])

	# If divergence exceeds threshold, snap local player to server position
	# Server state is authoritative
	if distance > DESYNC_SNAP_THRESHOLD:
		print("NetworkManager: DESYNC - Snapping to server position (%.1fm divergence)" % distance)
		_log("DESYNC SNAP: Correcting position to server state")

		# Update local player position
		if local_player and is_instance_valid(local_player):
			local_player.global_position = server_pos
			# Also update client_state local data to match
			client_state.update_local_position(server_pos)

			# Update health if significantly different
			if abs(local_data.health - server_data.health) > 1.0:
				if local_player.has_method("set_health"):
					local_player.set_health(server_data.health)
				elif "current_health" in local_player:
					local_player.current_health = server_data.health
					if local_player.has_signal("health_changed"):
						local_player.health_changed.emit(server_data.health, local_player.max_health)
				client_state.update_local_health(server_data.health)

			print("NetworkManager: Corrected to server pos (%.1f, %.1f, %.1f)" % [server_pos.x, server_pos.y, server_pos.z])

# =============================================================================
# DEBUG
# =============================================================================

func get_debug_info() -> String:
	return client_state.get_state_summary()
