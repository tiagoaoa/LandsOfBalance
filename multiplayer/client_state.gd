class_name ClientState
extends RefCounted

## Client-side State Manager
## Structured like MPlayer's client.c - manages local state, optimistic updates, and reliable messaging

const Protocol = preload("res://multiplayer/protocol.gd")

# =============================================================================
# SIGNALS
# =============================================================================

signal connected(player_id: int)
signal disconnected()
signal host_status_changed(is_host: bool)
signal state_updated(state_seq: int)
signal player_added(player_id: int, player_data: Protocol.PlayerData)
signal player_removed(player_id: int)
signal entity_updated(entity_id: int, entity_data: Protocol.EntityData)
signal arrow_spawned(arrow_data: Protocol.ArrowData)
signal arrow_hit(hit_data: Protocol.ArrowHitData)
signal divergence_detected(local_data: Protocol.PlayerData, server_data: Protocol.PlayerData)
signal latency_updated(latency_ms: int)

# =============================================================================
# CONNECTION STATE
# =============================================================================

enum ConnectionState {
	DISCONNECTED,
	CONNECTING,
	CONNECTED,
}

var connection_state: ConnectionState = ConnectionState.DISCONNECTED

## My assigned player ID (0 = not assigned)
var my_player_id: int = 0

## Am I the host? (lowest player ID controls entities)
var is_host: bool = false

## Player name
var player_name: String = "Player"

# =============================================================================
# LOCAL STATE (Optimistic - Updated immediately on input)
# =============================================================================

## My local player data (optimistic state)
var my_local_data: Protocol.PlayerData = Protocol.PlayerData.new()

## Last server-confirmed position (for divergence checking)
var my_server_data: Protocol.PlayerData = Protocol.PlayerData.new()

# =============================================================================
# CACHED REMOTE STATE (from server broadcasts)
# =============================================================================

## All players from last state broadcast
var remote_players: Dictionary = {}  # player_id -> Protocol.PlayerData

## All entities from last state broadcast
var remote_entities: Dictionary = {}  # entity_id -> Protocol.EntityData

## All active arrows
var remote_arrows: Dictionary = {}  # arrow_id -> Protocol.ArrowData

## Last received state sequence
var last_state_seq: int = 0

# =============================================================================
# RELIABLE MESSAGING (like MPlayer's ACK system)
# =============================================================================

## Outgoing sequence number
var my_seq: int = 1

## Pending message awaiting ACK
var pending_msg: PackedByteArray = PackedByteArray()
var pending_ack_seq: int = 0
var pending_msg_type: int = 0

## Retry tracking
var last_send_time: int = 0
var retry_count: int = 0

## Messages that need reliable delivery
var reliable_queue: Array[Dictionary] = []

# =============================================================================
# LATENCY TRACKING
# =============================================================================

## Ping tracking
var pending_ping_time: int = 0
var last_ping_seq: int = 0
var current_latency_ms: int = 0
var latency_samples: Array[int] = []
const MAX_LATENCY_SAMPLES: int = 10

# =============================================================================
# DIVERGENCE CHECKING (like MPlayer's -c flag)
# =============================================================================

var divergence_check_enabled: bool = true
var divergence_count: int = 0
var divergence_threshold: float = 1.0  # Position difference threshold

# =============================================================================
# INITIALIZATION
# =============================================================================

func _init() -> void:
	reset()

## Reset all state
func reset() -> void:
	connection_state = ConnectionState.DISCONNECTED
	my_player_id = 0
	is_host = false

	my_local_data = Protocol.PlayerData.new()
	my_server_data = Protocol.PlayerData.new()

	remote_players.clear()
	remote_entities.clear()
	remote_arrows.clear()
	last_state_seq = 0

	my_seq = 1
	pending_msg.clear()
	pending_ack_seq = 0
	pending_msg_type = 0
	last_send_time = 0
	retry_count = 0
	reliable_queue.clear()

	pending_ping_time = 0
	last_ping_seq = 0
	current_latency_ms = 0
	latency_samples.clear()

	divergence_count = 0

# =============================================================================
# CONNECTION LIFECYCLE
# =============================================================================

## Start connection process
func start_connecting(name: String) -> void:
	player_name = name
	connection_state = ConnectionState.CONNECTING
	my_seq = 1

## Handle successful join
func handle_join_ack(assigned_id: int, initial_data: Protocol.PlayerData) -> void:
	my_player_id = assigned_id
	connection_state = ConnectionState.CONNECTED

	# Initialize local and server data
	my_local_data = initial_data
	my_server_data = initial_data

	# Clear pending ACK for join message
	pending_ack_seq = 0
	pending_msg.clear()
	retry_count = 0

	connected.emit(assigned_id)

## Handle disconnection
func handle_disconnect() -> void:
	var was_connected := connection_state == ConnectionState.CONNECTED
	reset()
	if was_connected:
		disconnected.emit()

## Check if connected
func is_network_connected() -> bool:
	return connection_state == ConnectionState.CONNECTED

# =============================================================================
# OPTIMISTIC UPDATES (Apply immediately, server confirms later)
# =============================================================================

## Update local position (called on player input)
func update_local_position(position: Vector3) -> void:
	my_local_data.set_position(position)

## Update local rotation
func update_local_rotation(rotation_y: float) -> void:
	my_local_data.rotation_y = rotation_y

## Update local state
func update_local_state(state: int) -> void:
	my_local_data.state = state

## Update local combat mode
func update_local_combat_mode(mode: int) -> void:
	my_local_data.combat_mode = mode

## Update local character class
func update_local_character_class(char_class: int) -> void:
	my_local_data.character_class = char_class

## Update local animation
func update_local_animation(anim_name: String) -> void:
	my_local_data.anim_name = anim_name

## Update local health
func update_local_health(health: float) -> void:
	my_local_data.health = health

## Get current local data for sending
func get_local_data() -> Protocol.PlayerData:
	my_local_data.player_id = my_player_id
	return my_local_data

# =============================================================================
# SERVER STATE HANDLING
# =============================================================================

## Handle full state broadcast from server
func handle_state_broadcast(state_seq: int, players: Array[Protocol.PlayerData]) -> void:
	if state_seq <= last_state_seq:
		return  # Old state, ignore

	last_state_seq = state_seq

	# Track which players we received
	var received_ids: Dictionary = {}

	# Update all players
	for player_data in players:
		received_ids[player_data.player_id] = true

		if player_data.player_id == my_player_id:
			# Update server-confirmed state for divergence checking
			my_server_data = player_data
			_check_divergence()
		else:
			# Update remote player
			var is_new := not remote_players.has(player_data.player_id)
			remote_players[player_data.player_id] = player_data

			if is_new:
				player_added.emit(player_data.player_id, player_data)

	# Remove players not in broadcast
	var to_remove: Array[int] = []
	for pid in remote_players.keys():
		if not received_ids.has(pid):
			to_remove.append(pid)

	for pid in to_remove:
		remote_players.erase(pid)
		player_removed.emit(pid)

	# Host status is assigned by server via MSG_HOST_CHANGE, not elected locally

	state_updated.emit(state_seq)

## Handle entity state broadcast
func handle_entity_broadcast(entities: Array[Protocol.EntityData]) -> void:
	for entity_data in entities:
		remote_entities[entity_data.entity_id] = entity_data
		entity_updated.emit(entity_data.entity_id, entity_data)

## Handle arrow spawn event
func handle_arrow_spawn(arrow_data: Protocol.ArrowData) -> void:
	# Don't spawn our own arrows (we already spawned locally)
	if arrow_data.shooter_id == my_player_id:
		return

	remote_arrows[arrow_data.arrow_id] = arrow_data
	arrow_spawned.emit(arrow_data)

## Handle arrow hit event
func handle_arrow_hit(hit_data: Protocol.ArrowHitData) -> void:
	# Remove arrow from tracking
	remote_arrows.erase(hit_data.arrow_id)
	arrow_hit.emit(hit_data)

## Handle host change notification from server
## Server assigns entity authority - clients don't elect among themselves
func handle_host_change(new_host_id: int) -> void:
	var was_host := is_host
	is_host = (new_host_id == my_player_id)

	if was_host != is_host:
		host_status_changed.emit(is_host)

# =============================================================================
# DIVERGENCE CHECKING
# =============================================================================

## Check for state divergence between local and server
func _check_divergence() -> void:
	if not divergence_check_enabled:
		return

	var local_pos := my_local_data.get_position()
	var server_pos := my_server_data.get_position()
	var distance := local_pos.distance_to(server_pos)

	if distance > divergence_threshold:
		divergence_count += 1
		divergence_detected.emit(my_local_data, my_server_data)

		# Optionally snap to server position
		# my_local_data.set_position(server_pos)

## Get divergence stats
func get_divergence_count() -> int:
	return divergence_count

## Reset divergence counter
func reset_divergence_count() -> void:
	divergence_count = 0

# =============================================================================
# RELIABLE MESSAGING
# =============================================================================

## Get next sequence number
func get_next_seq() -> int:
	var seq := my_seq
	my_seq += 1
	return seq

## Send reliable message (waits for ACK)
func send_reliable(msg: PackedByteArray, msg_type: int) -> void:
	if pending_ack_seq > 0:
		# Queue message if we're waiting for ACK
		reliable_queue.append({
			"msg": msg,
			"type": msg_type
		})
		return

	_send_pending(msg, msg_type)

func _send_pending(msg: PackedByteArray, msg_type: int) -> void:
	pending_msg = msg
	pending_msg_type = msg_type
	pending_ack_seq = _extract_seq_from_msg(msg)
	last_send_time = Time.get_ticks_msec()
	retry_count = 0

## Extract sequence number from message
func _extract_seq_from_msg(msg: PackedByteArray) -> int:
	if msg.size() < Protocol.MsgHeader.size():
		return 0
	return msg.decode_u32(1)

## Handle ACK received
func handle_ack(acked_seq: int) -> void:
	if acked_seq == pending_ack_seq:
		pending_ack_seq = 0
		pending_msg.clear()
		retry_count = 0

		# Send next queued message
		if not reliable_queue.is_empty():
			var next: Dictionary = reliable_queue.pop_front()
			_send_pending(next["msg"], next["type"])

## Check if retry needed (call every frame)
func check_retry() -> PackedByteArray:
	if pending_ack_seq == 0:
		return PackedByteArray()

	var elapsed := Time.get_ticks_msec() - last_send_time

	if elapsed > Protocol.ACK_TIMEOUT_MS:
		if retry_count < Protocol.MAX_RETRIES:
			retry_count += 1
			last_send_time = Time.get_ticks_msec()
			return pending_msg  # Return message to retry
		else:
			# Give up
			pending_ack_seq = 0
			pending_msg.clear()
			retry_count = 0

	return PackedByteArray()

## Check if we're waiting for ACK
func is_waiting_for_ack() -> bool:
	return pending_ack_seq > 0

# =============================================================================
# LATENCY TRACKING
# =============================================================================

## Record ping sent
func start_ping(seq: int) -> void:
	pending_ping_time = Time.get_ticks_msec()
	last_ping_seq = seq

## Handle pong received
func handle_pong(original_timestamp: int) -> void:
	var now := Time.get_ticks_msec()
	var latency := now - original_timestamp

	latency_samples.append(latency)
	if latency_samples.size() > MAX_LATENCY_SAMPLES:
		latency_samples.pop_front()

	# Calculate average
	var total := 0
	for sample in latency_samples:
		total += sample
	current_latency_ms = total / latency_samples.size()

	latency_updated.emit(current_latency_ms)

## Get current latency
func get_latency() -> int:
	return current_latency_ms

# =============================================================================
# REMOTE DATA ACCESS
# =============================================================================

## Get remote player data
func get_remote_player(player_id: int) -> Protocol.PlayerData:
	return remote_players.get(player_id)

## Get all remote players
func get_all_remote_players() -> Dictionary:
	return remote_players

## Get remote entity data
func get_remote_entity(entity_id: int) -> Protocol.EntityData:
	return remote_entities.get(entity_id)

## Get all remote entities
func get_all_remote_entities() -> Dictionary:
	return remote_entities

## Get active arrow
func get_remote_arrow(arrow_id: int) -> Protocol.ArrowData:
	return remote_arrows.get(arrow_id)

# =============================================================================
# MESSAGE BUILDING HELPERS
# =============================================================================

## Build join message
func build_join_msg() -> PackedByteArray:
	return Protocol.build_join_msg(get_next_seq(), player_name)

## Build move message with current local state
func build_move_msg() -> PackedByteArray:
	return Protocol.build_move_msg(get_next_seq(), get_local_data())

## Build leave message
func build_leave_msg() -> PackedByteArray:
	return Protocol.build_leave_msg(get_next_seq(), my_player_id)

## Build ping message
func build_ping_msg() -> PackedByteArray:
	var seq := get_next_seq()
	start_ping(seq)
	return Protocol.build_ping_msg(seq, my_player_id, Time.get_ticks_msec())

## Build arrow spawn message
func build_arrow_spawn_msg(arrow_id: int, position: Vector3, direction: Vector3) -> PackedByteArray:
	var arrow_data := Protocol.ArrowData.new()
	arrow_data.arrow_id = arrow_id
	arrow_data.shooter_id = my_player_id
	arrow_data.set_position(position)
	arrow_data.set_direction(direction)
	arrow_data.active = true

	return Protocol.build_arrow_spawn_msg(get_next_seq(), my_player_id, arrow_data)

## Build arrow hit message
func build_arrow_hit_msg(arrow_id: int, hit_position: Vector3, hit_entity_id: int) -> PackedByteArray:
	var hit_data := Protocol.ArrowHitData.new()
	hit_data.arrow_id = arrow_id
	hit_data.set_hit_position(hit_position)
	hit_data.hit_entity_id = hit_entity_id

	return Protocol.build_arrow_hit_msg(get_next_seq(), my_player_id, hit_data)

## Build entity damage message
func build_entity_damage_msg(entity_id: int, damage: float) -> PackedByteArray:
	return Protocol.build_entity_damage_msg(get_next_seq(), my_player_id, entity_id, damage, my_player_id)

## Build entity state message (for host)
func build_entity_state_msg(entities: Array[Protocol.EntityData]) -> PackedByteArray:
	return Protocol.build_entity_state_msg(get_next_seq(), entities)

# =============================================================================
# DEBUG/LOGGING
# =============================================================================

## Get state summary for logging
func get_state_summary() -> String:
	var lines: Array[String] = []
	lines.append("=== CLIENT STATE ===")
	lines.append("ID: %d | Host: %s | State: %s" % [
		my_player_id,
		"Yes" if is_host else "No",
		ConnectionState.keys()[connection_state]
	])
	lines.append("Local: pos=(%.1f,%.1f,%.1f) state=%d" % [
		my_local_data.x, my_local_data.y, my_local_data.z, my_local_data.state
	])
	lines.append("Server: pos=(%.1f,%.1f,%.1f) state=%d" % [
		my_server_data.x, my_server_data.y, my_server_data.z, my_server_data.state
	])
	lines.append("Remote players: %d | Entities: %d | Arrows: %d" % [
		remote_players.size(), remote_entities.size(), remote_arrows.size()
	])
	lines.append("Latency: %dms | Divergences: %d" % [current_latency_ms, divergence_count])

	return "\n".join(lines)
