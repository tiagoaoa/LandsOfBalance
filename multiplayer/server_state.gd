class_name ServerState
extends RefCounted

## Server-side Global State Manager
## Structured like MPlayer's server.c - maintains authoritative game state

const Protocol = preload("res://multiplayer/protocol.gd")
## This runs on the relay server OR on the host client for entity authority

# =============================================================================
# SIGNALS
# =============================================================================

signal player_joined(player_id: int, player_data: Protocol.PlayerData)
signal player_left(player_id: int)
signal state_changed()
signal entity_state_changed()
signal host_changed(new_host_id: int)

# =============================================================================
# GLOBAL STATE
# =============================================================================

## All connected players indexed by slot (like players[] in MPlayer)
var players: Array[Protocol.PlayerData] = []

## Player ID to slot mapping
var player_slots: Dictionary = {}  # player_id -> slot_index

## Active player tracking
var active_players: Array[bool] = []

## All tracked entities (Bobba, Dragon, etc.)
var entities: Array[Protocol.EntityData] = []

## Entity ID to slot mapping
var entity_slots: Dictionary = {}  # entity_id -> slot_index

## Active arrows in flight
var arrows: Array[Protocol.ArrowData] = []

## Arrow ID to slot mapping
var arrow_slots: Dictionary = {}  # arrow_id -> slot_index

## ID generators (like next_id in MPlayer)
var next_player_id: int = 1
var next_entity_id: int = 1
var next_arrow_id: int = 1

## Sequence number generators
var next_seq: int = 1
var state_seq: int = 0  # Incremented on every state change

## Host player ID (lowest connected player ID, or 0 if server is host)
var host_player_id: int = 0

## Message queue (FIFO like MPlayer)
var message_queue: Array[Dictionary] = []
const QUEUE_SIZE: int = 256

# =============================================================================
# INITIALIZATION
# =============================================================================

func _init() -> void:
	# Pre-allocate arrays
	players.resize(Protocol.MAX_PLAYERS)
	active_players.resize(Protocol.MAX_PLAYERS)
	entities.resize(Protocol.MAX_ENTITIES)
	arrows.resize(Protocol.MAX_ARROWS)

	for i in range(Protocol.MAX_PLAYERS):
		players[i] = Protocol.PlayerData.new()
		active_players[i] = false

	for i in range(Protocol.MAX_ENTITIES):
		entities[i] = Protocol.EntityData.new()

	for i in range(Protocol.MAX_ARROWS):
		arrows[i] = Protocol.ArrowData.new()
		arrows[i].active = false

## Reset all state
func reset() -> void:
	player_slots.clear()
	entity_slots.clear()
	arrow_slots.clear()
	message_queue.clear()

	for i in range(Protocol.MAX_PLAYERS):
		players[i] = Protocol.PlayerData.new()
		active_players[i] = false

	for i in range(Protocol.MAX_ENTITIES):
		entities[i] = Protocol.EntityData.new()

	for i in range(Protocol.MAX_ARROWS):
		arrows[i] = Protocol.ArrowData.new()
		arrows[i].active = false

	next_player_id = 1
	next_entity_id = 1
	next_arrow_id = 1
	next_seq = 1
	state_seq = 0
	host_player_id = 0

# =============================================================================
# PLAYER MANAGEMENT (like handle_join/handle_move in MPlayer)
# =============================================================================

## Find a free player slot
func find_free_player_slot() -> int:
	for i in range(Protocol.MAX_PLAYERS):
		if not active_players[i]:
			return i
	return -1

## Find player by ID
func find_player(player_id: int) -> Protocol.PlayerData:
	if player_slots.has(player_id):
		var slot: int = player_slots[player_id]
		if active_players[slot]:
			return players[slot]
	return null

## Handle player join request
func handle_join(player_name: String, initial_position: Vector3 = Vector3.ZERO) -> Protocol.PlayerData:
	var slot := find_free_player_slot()
	if slot < 0:
		return null  # Server full

	var player_id := next_player_id
	next_player_id += 1

	var player := Protocol.PlayerData.new()
	player.player_id = player_id
	player.set_position(initial_position)
	player.rotation_y = 0.0
	player.state = Protocol.PlayerState.STATE_IDLE
	player.combat_mode = Protocol.CombatMode.ARMED
	player.character_class = Protocol.CharacterClass.ARCHER
	player.health = 100.0
	player.anim_name = "Idle"
	player.active = true

	players[slot] = player
	active_players[slot] = true
	player_slots[player_id] = slot

	_increment_state_seq()

	# If this is the first player, assign them as host
	if get_player_count() == 1:
		assign_host(player_id)

	player_joined.emit(player_id, player)
	return player

## Handle player leave
func handle_leave(player_id: int) -> void:
	if not player_slots.has(player_id):
		return

	var slot: int = player_slots[player_id]
	active_players[slot] = false
	players[slot].active = false
	player_slots.erase(player_id)

	_increment_state_seq()

	# If the leaving player was host, reassign to next player
	if player_id == host_player_id:
		reassign_host_if_needed()

	player_left.emit(player_id)

## Handle player position/state update
func handle_move(player_id: int, player_data: Protocol.PlayerData) -> bool:
	var existing := find_player(player_id)
	if not existing:
		return false

	# Update player state (server validates/accepts move)
	existing.x = player_data.x
	existing.y = player_data.y
	existing.z = player_data.z
	existing.rotation_y = player_data.rotation_y
	existing.state = player_data.state
	existing.combat_mode = player_data.combat_mode
	existing.character_class = player_data.character_class
	existing.health = player_data.health
	existing.anim_name = player_data.anim_name

	_increment_state_seq()
	return true

## Get all active players
func get_active_players() -> Array[Protocol.PlayerData]:
	var result: Array[Protocol.PlayerData] = []
	for i in range(Protocol.MAX_PLAYERS):
		if active_players[i]:
			result.append(players[i])
	return result

## Get player count
func get_player_count() -> int:
	var count := 0
	for active in active_players:
		if active:
			count += 1
	return count

# =============================================================================
# ENTITY MANAGEMENT (Bobba, Dragon)
# =============================================================================

## Find a free entity slot (empty slots have entity_id == 0)
func find_free_entity_slot() -> int:
	for i in range(Protocol.MAX_ENTITIES):
		if entities[i].entity_id == 0:
			return i
	return -1

## Find entity by ID
func find_entity(entity_id: int) -> Protocol.EntityData:
	if entity_slots.has(entity_id):
		var slot: int = entity_slots[entity_id]
		return entities[slot]
	return null

## Register a new entity (called by host when entity spawns)
func register_entity(entity_type: int, initial_position: Vector3 = Vector3.ZERO) -> Protocol.EntityData:
	var slot := find_free_entity_slot()
	if slot < 0:
		return null

	var entity_id := next_entity_id
	next_entity_id += 1

	var entity := Protocol.EntityData.new()
	entity.entity_type = entity_type
	entity.entity_id = entity_id
	entity.set_position(initial_position)
	entity.rotation_y = 0.0
	entity.state = 0
	entity.health = 100.0 if entity_type == Protocol.EntityType.ENTITY_BOBBA else 500.0
	entity.extra_data.resize(8)

	entities[slot] = entity
	entity_slots[entity_id] = slot

	return entity

## Update entity state (called by host)
func update_entity(entity_id: int, entity_data: Protocol.EntityData) -> bool:
	var existing := find_entity(entity_id)
	if not existing:
		return false

	existing.x = entity_data.x
	existing.y = entity_data.y
	existing.z = entity_data.z
	existing.rotation_y = entity_data.rotation_y
	existing.state = entity_data.state
	existing.health = entity_data.health
	existing.extra_data = entity_data.extra_data.duplicate()

	return true

## Handle entity damage
func handle_entity_damage(entity_id: int, damage: float, attacker_id: int) -> float:
	var entity := find_entity(entity_id)
	if not entity:
		return 0.0

	entity.health = maxf(0.0, entity.health - damage)
	entity_state_changed.emit()

	return entity.health

## Remove entity
func remove_entity(entity_id: int) -> void:
	if not entity_slots.has(entity_id):
		return

	var slot: int = entity_slots[entity_id]
	entities[slot] = Protocol.EntityData.new()
	entity_slots.erase(entity_id)

## Get all active entities (active entities have entity_id > 0)
func get_active_entities() -> Array[Protocol.EntityData]:
	var result: Array[Protocol.EntityData] = []
	for i in range(Protocol.MAX_ENTITIES):
		if entities[i].entity_id > 0:
			result.append(entities[i])
	return result

# =============================================================================
# ARROW MANAGEMENT
# =============================================================================

## Find a free arrow slot
func find_free_arrow_slot() -> int:
	for i in range(Protocol.MAX_ARROWS):
		if not arrows[i].active:
			return i
	return -1

## Find arrow by ID
func find_arrow(arrow_id: int) -> Protocol.ArrowData:
	if arrow_slots.has(arrow_id):
		var slot: int = arrow_slots[arrow_id]
		if arrows[slot].active:
			return arrows[slot]
	return null

## Register arrow spawn
func register_arrow(shooter_id: int, position: Vector3, direction: Vector3) -> Protocol.ArrowData:
	var slot := find_free_arrow_slot()
	if slot < 0:
		return null

	var arrow_id := next_arrow_id
	next_arrow_id += 1

	var arrow := Protocol.ArrowData.new()
	arrow.arrow_id = arrow_id
	arrow.shooter_id = shooter_id
	arrow.set_position(position)
	arrow.set_direction(direction)
	arrow.active = true

	arrows[slot] = arrow
	arrow_slots[arrow_id] = slot

	return arrow

## Handle arrow hit
func handle_arrow_hit(arrow_id: int, hit_position: Vector3, hit_entity_id: int) -> Protocol.ArrowHitData:
	var arrow := find_arrow(arrow_id)
	if not arrow:
		return null

	# Deactivate arrow
	arrow.active = false
	arrow_slots.erase(arrow_id)

	# Create hit data
	var hit_data := Protocol.ArrowHitData.new()
	hit_data.arrow_id = arrow_id
	hit_data.set_hit_position(hit_position)
	hit_data.hit_entity_id = hit_entity_id

	return hit_data

## Remove arrow
func remove_arrow(arrow_id: int) -> void:
	if not arrow_slots.has(arrow_id):
		return

	var slot: int = arrow_slots[arrow_id]
	arrows[slot].active = false
	arrow_slots.erase(arrow_id)

## Get all active arrows
func get_active_arrows() -> Array[Protocol.ArrowData]:
	var result: Array[Protocol.ArrowData] = []
	for i in range(Protocol.MAX_ARROWS):
		if arrows[i].active:
			result.append(arrows[i])
	return result

# =============================================================================
# MESSAGE QUEUE (like MPlayer's queue_push/queue_pop)
# =============================================================================

## Push message to queue
func queue_push(msg_type: int, sender_id: int, data: PackedByteArray, sender_addr: String = "") -> bool:
	if message_queue.size() >= QUEUE_SIZE:
		return false  # Queue full

	message_queue.append({
		"type": msg_type,
		"sender_id": sender_id,
		"data": data,
		"sender_addr": sender_addr,
		"timestamp": Time.get_ticks_msec()
	})
	return true

## Pop message from queue
func queue_pop() -> Dictionary:
	if message_queue.is_empty():
		return {}
	return message_queue.pop_front()

## Get queue size
func queue_size() -> int:
	return message_queue.size()

## Check if queue is empty
func queue_empty() -> bool:
	return message_queue.is_empty()

# =============================================================================
# HOST MANAGEMENT (Server-assigned, not client-elected)
# =============================================================================

## Assign a new host for entity authority
## Called by server when current host leaves or on first player join
func assign_host(player_id: int) -> void:
	if player_id != host_player_id:
		host_player_id = player_id
		host_changed.emit(player_id)

## Reassign host when current host leaves
## Server picks the next available player (lowest ID as fallback)
func reassign_host_if_needed() -> void:
	# If current host is still connected, do nothing
	if host_player_id > 0 and player_slots.has(host_player_id):
		return

	# Find next available player (lowest ID)
	var new_host_id := 0
	for pid in player_slots.keys():
		if new_host_id == 0 or pid < new_host_id:
			new_host_id = pid

	if new_host_id != host_player_id:
		host_player_id = new_host_id
		host_changed.emit(new_host_id)

## Check if player is host
func is_host(player_id: int) -> bool:
	return player_id == host_player_id

## Get current host ID
func get_host_id() -> int:
	return host_player_id

# =============================================================================
# STATE SEQUENCING
# =============================================================================

## Increment state sequence (called on any state change)
func _increment_state_seq() -> void:
	state_seq += 1
	state_changed.emit()

## Get next message sequence number
func get_next_seq() -> int:
	var seq := next_seq
	next_seq += 1
	return seq

## Get current state sequence
func get_state_seq() -> int:
	return state_seq

# =============================================================================
# STATE BROADCAST BUILDING
# =============================================================================

## Build full state broadcast message
func build_state_broadcast() -> PackedByteArray:
	var active := get_active_players()
	return Protocol.build_state_msg(get_next_seq(), state_seq, active)

## Build entity state broadcast message
func build_entity_broadcast() -> PackedByteArray:
	var active := get_active_entities()
	return Protocol.build_entity_state_msg(get_next_seq(), active)

# =============================================================================
# DEBUG/LOGGING
# =============================================================================

## Get state summary for logging
func get_state_summary() -> String:
	var lines: Array[String] = []
	lines.append("=== SERVER STATE (seq=%d) ===" % state_seq)
	lines.append("Host: %d" % host_player_id)
	lines.append("Players (%d):" % get_player_count())

	for player in get_active_players():
		lines.append("  [%d] pos=(%.1f,%.1f,%.1f) state=%d hp=%.0f" % [
			player.player_id, player.x, player.y, player.z, player.state, player.health
		])

	var entity_count := get_active_entities().size()
	if entity_count > 0:
		lines.append("Entities (%d):" % entity_count)
		for entity in get_active_entities():
			var type_name := "Unknown"
			match entity.entity_type:
				Protocol.EntityType.ENTITY_BOBBA: type_name = "Bobba"
				Protocol.EntityType.ENTITY_DRAGON: type_name = "Dragon"
			lines.append("  [%d] %s pos=(%.1f,%.1f,%.1f) state=%d hp=%.0f" % [
				entity.entity_id, type_name, entity.x, entity.y, entity.z, entity.state, entity.health
			])

	var arrow_count := get_active_arrows().size()
	if arrow_count > 0:
		lines.append("Arrows (%d):" % arrow_count)

	return "\n".join(lines)
