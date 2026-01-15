class_name Protocol
extends RefCounted

## Multiplayer Protocol Definitions
## Structured like MPlayer's common.h - defines message types, constants, and packet structures

# =============================================================================
# CONSTANTS
# =============================================================================

const MAX_PLAYERS: int = 64
const MAX_ENTITIES: int = 128
const MAX_ARROWS: int = 256
const SERVER_PORT: int = 7777
const DEFAULT_SERVER: String = "127.0.0.1"

# Timing constants (milliseconds)
const ACK_TIMEOUT_MS: int = 100
const MAX_RETRIES: int = 3
const UPDATE_INTERVAL_MS: int = 33  # 30 Hz
const ENTITY_UPDATE_INTERVAL_MS: int = 33  # 30 Hz
const STATE_BROADCAST_INTERVAL_MS: int = 50  # 20 Hz for full state

# FIFO-specific timing (slower for testing)
const FIFO_SERVER_BROADCAST_US: int = 200000  # 200ms = 5 Hz server broadcast
const FIFO_CLIENT_POLL_MS: int = 500  # 500ms = 2 Hz client poll

# FIFO paths
const FIFO_PATH_PREFIX: String = "/tmp/lob_"
const FIFO_MAX_PLAYERS: int = 4  # Max players for FIFO testing

# FIFO message types
const FIFO_MSG_PLAYER_UPDATE: int = 1
const FIFO_MSG_GLOBAL_STATE: int = 2
const FIFO_MSG_JOIN: int = 3
const FIFO_MSG_LEAVE: int = 4

# Packet size limits
const MAX_MSG_SIZE: int = 512
const MAX_PLAYER_NAME: int = 32
const MAX_ANIM_NAME: int = 32

# =============================================================================
# MESSAGE TYPES (like MSG_* in MPlayer)
# =============================================================================

enum MsgType {
	MSG_JOIN = 1,           # Client -> Server: Request to join game
	MSG_JOIN_ACK = 2,       # Server -> Client: Assigns player ID, initial state
	MSG_LEAVE = 3,          # Client -> Server: Graceful disconnect
	MSG_STATE = 4,          # Server -> Client: Full state broadcast (all players)
	MSG_MOVE = 5,           # Client -> Server: Position/state update
	MSG_ACK = 6,            # Bidirectional: Reliable delivery confirmation
	MSG_PING = 7,           # Client -> Server: Latency check
	MSG_PONG = 8,           # Server -> Client: Latency response
	MSG_ENTITY_STATE = 9,   # Server -> Client: NPC state broadcast (Bobba, Dragon)
	MSG_ENTITY_DAMAGE = 10, # Client -> Server: Report damage to entity
	MSG_ARROW_SPAWN = 11,   # Client -> Server -> Client: Arrow spawned
	MSG_ARROW_HIT = 12,     # Client -> Server -> Client: Arrow impact
	MSG_HOST_CHANGE = 13,   # Server -> Client: Host authority changed
	MSG_HEARTBEAT = 14,     # Client -> Server: Keep connection alive
	MSG_SPECTATE = 15,      # Client -> Server: Connect as spectator (receive state, don't join)
	MSG_SPECTATE_ACK = 16,  # Server -> Client: Acknowledge spectator connection
	MSG_PLAYER_DAMAGE = 17, # Server -> Client: Entity hit player (Bobba attack, etc.)
	MSG_GAME_RESTART = 18,  # Bidirectional: Request/broadcast game restart (respawn all)
}

# =============================================================================
# PLAYER STATE ENUM
# =============================================================================

enum PlayerState {
	STATE_IDLE = 0,
	STATE_WALKING = 1,
	STATE_RUNNING = 2,
	STATE_ATTACKING = 3,
	STATE_BLOCKING = 4,
	STATE_JUMPING = 5,
	STATE_CASTING = 6,
	STATE_DRAWING_BOW = 7,
	STATE_HOLDING_BOW = 8,
	STATE_DEAD = 9,
}

# =============================================================================
# COMBAT MODE ENUM
# =============================================================================

enum CombatMode {
	UNARMED = 0,
	ARMED = 1,
}

# =============================================================================
# CHARACTER CLASS ENUM
# =============================================================================

enum CharacterClass {
	PALADIN = 0,
	ARCHER = 1,
}

# =============================================================================
# ENTITY TYPE ENUM (must match server game_server.c)
# =============================================================================

enum EntityType {
	ENTITY_BOBBA = 0,
	ENTITY_DRAGON = 1,
	ENTITY_ARROW = 2,
}

# =============================================================================
# ENTITY STATE ENUMS
# =============================================================================

enum BobbaState {
	ROAMING = 0,
	CHASING = 1,
	ATTACKING = 2,
	IDLE = 3,
	STUNNED = 4,
	DEAD = 5,
}

enum DragonState {
	PATROL = 0,
	FLYING_TO_LAND = 1,
	LANDING = 2,
	WAIT = 3,
	TAKING_OFF = 4,
	ATTACKING = 5,
	DEAD = 6,
}

# =============================================================================
# MESSAGE HEADER (9 bytes)
# =============================================================================

class MsgHeader:
	var type: int = 0        # 1 byte - MsgType enum
	var seq: int = 0         # 4 bytes - Message sequence number
	var sender_id: int = 0   # 4 bytes - 0 = server, else player_id

	func encode() -> PackedByteArray:
		var buf := PackedByteArray()
		buf.resize(9)
		buf.encode_u8(0, type)
		buf.encode_u32(1, seq)
		buf.encode_u32(5, sender_id)
		return buf

	func decode(buf: PackedByteArray) -> bool:
		if buf.size() < 9:
			return false
		type = buf.decode_u8(0)
		seq = buf.decode_u32(1)
		sender_id = buf.decode_u32(5)
		return true

	static func size() -> int:
		return 9

# =============================================================================
# PLAYER DATA STRUCTURE (60 bytes)
# =============================================================================

class PlayerData:
	var player_id: int = 0       # 4 bytes
	var x: float = 0.0           # 4 bytes
	var y: float = 0.0           # 4 bytes
	var z: float = 0.0           # 4 bytes
	var rotation_y: float = 0.0  # 4 bytes - facing direction
	var state: int = 0           # 1 byte - PlayerState enum
	var combat_mode: int = 1     # 1 byte - CombatMode enum
	var character_class: int = 1 # 1 byte - CharacterClass enum
	var health: float = 100.0    # 4 bytes
	var anim_name: String = ""   # 32 bytes (null-padded)
	var active: bool = true      # 1 byte

	func get_position() -> Vector3:
		return Vector3(x, y, z)

	func set_position(pos: Vector3) -> void:
		x = pos.x
		y = pos.y
		z = pos.z

	func encode() -> PackedByteArray:
		var buf := PackedByteArray()
		buf.resize(60)  # 4+4+4+4+4+1+1+1+4+32+1 = 60 bytes
		var offset := 0
		buf.encode_u32(offset, player_id); offset += 4
		buf.encode_float(offset, x); offset += 4
		buf.encode_float(offset, y); offset += 4
		buf.encode_float(offset, z); offset += 4
		buf.encode_float(offset, rotation_y); offset += 4
		buf.encode_u8(offset, state); offset += 1
		buf.encode_u8(offset, combat_mode); offset += 1
		buf.encode_u8(offset, character_class); offset += 1
		buf.encode_float(offset, health); offset += 4

		# Encode animation name (32 bytes, null-padded)
		var anim_bytes := anim_name.to_utf8_buffer()
		for i in range(32):
			if i < anim_bytes.size():
				buf.encode_u8(offset + i, anim_bytes[i])
			else:
				buf.encode_u8(offset + i, 0)
		offset += 32

		buf.encode_u8(offset, 1 if active else 0)
		return buf

	func decode(buf: PackedByteArray, start_offset: int = 0) -> bool:
		if buf.size() < start_offset + 60:
			return false
		var offset := start_offset
		player_id = buf.decode_u32(offset); offset += 4
		x = buf.decode_float(offset); offset += 4
		y = buf.decode_float(offset); offset += 4
		z = buf.decode_float(offset); offset += 4
		rotation_y = buf.decode_float(offset); offset += 4
		state = buf.decode_u8(offset); offset += 1
		combat_mode = buf.decode_u8(offset); offset += 1
		character_class = buf.decode_u8(offset); offset += 1
		health = buf.decode_float(offset); offset += 4

		# Decode animation name
		var anim_bytes := buf.slice(offset, offset + 32)
		var null_pos := anim_bytes.find(0)
		if null_pos >= 0:
			anim_bytes = anim_bytes.slice(0, null_pos)
		anim_name = anim_bytes.get_string_from_utf8()
		offset += 32

		active = buf.decode_u8(offset) != 0
		return true

	static func size() -> int:
		return 60

# =============================================================================
# ENTITY DATA STRUCTURE (34 bytes)
# =============================================================================

class EntityData:
	var entity_type: int = 0     # 1 byte - EntityType enum
	var entity_id: int = 0       # 4 bytes
	var x: float = 0.0           # 4 bytes
	var y: float = 0.0           # 4 bytes
	var z: float = 0.0           # 4 bytes
	var rotation_y: float = 0.0  # 4 bytes
	var state: int = 0           # 1 byte - BobbaState or DragonState
	var health: float = 100.0    # 4 bytes
	var extra_data: PackedByteArray = PackedByteArray()  # 8 bytes (dragon: lap_count + patrol_angle)

	func get_position() -> Vector3:
		return Vector3(x, y, z)

	func set_position(pos: Vector3) -> void:
		x = pos.x
		y = pos.y
		z = pos.z

	func encode() -> PackedByteArray:
		var buf := PackedByteArray()
		buf.resize(34)
		var offset := 0
		buf.encode_u8(offset, entity_type); offset += 1
		buf.encode_u32(offset, entity_id); offset += 4
		buf.encode_float(offset, x); offset += 4
		buf.encode_float(offset, y); offset += 4
		buf.encode_float(offset, z); offset += 4
		buf.encode_float(offset, rotation_y); offset += 4
		buf.encode_u8(offset, state); offset += 1
		buf.encode_float(offset, health); offset += 4

		# Extra data (8 bytes)
		extra_data.resize(8)
		for i in range(8):
			buf.encode_u8(offset + i, extra_data[i] if i < extra_data.size() else 0)
		return buf

	func decode(buf: PackedByteArray, start_offset: int = 0) -> bool:
		if buf.size() < start_offset + 34:
			return false
		var offset := start_offset
		entity_type = buf.decode_u8(offset); offset += 1
		entity_id = buf.decode_u32(offset); offset += 4
		x = buf.decode_float(offset); offset += 4
		y = buf.decode_float(offset); offset += 4
		z = buf.decode_float(offset); offset += 4
		rotation_y = buf.decode_float(offset); offset += 4
		state = buf.decode_u8(offset); offset += 1
		health = buf.decode_float(offset); offset += 4
		extra_data = buf.slice(offset, offset + 8)
		return true

	static func size() -> int:
		return 34

# =============================================================================
# ARROW DATA STRUCTURE (33 bytes)
# =============================================================================

class ArrowData:
	var arrow_id: int = 0        # 4 bytes
	var shooter_id: int = 0      # 4 bytes
	var x: float = 0.0           # 4 bytes - spawn position
	var y: float = 0.0           # 4 bytes
	var z: float = 0.0           # 4 bytes
	var dir_x: float = 0.0       # 4 bytes - direction
	var dir_y: float = 0.0       # 4 bytes
	var dir_z: float = 0.0       # 4 bytes
	var active: bool = true      # 1 byte

	func get_position() -> Vector3:
		return Vector3(x, y, z)

	func set_position(pos: Vector3) -> void:
		x = pos.x
		y = pos.y
		z = pos.z

	func get_direction() -> Vector3:
		return Vector3(dir_x, dir_y, dir_z)

	func set_direction(dir: Vector3) -> void:
		dir_x = dir.x
		dir_y = dir.y
		dir_z = dir.z

	func encode() -> PackedByteArray:
		var buf := PackedByteArray()
		buf.resize(33)
		var offset := 0
		buf.encode_u32(offset, arrow_id); offset += 4
		buf.encode_u32(offset, shooter_id); offset += 4
		buf.encode_float(offset, x); offset += 4
		buf.encode_float(offset, y); offset += 4
		buf.encode_float(offset, z); offset += 4
		buf.encode_float(offset, dir_x); offset += 4
		buf.encode_float(offset, dir_y); offset += 4
		buf.encode_float(offset, dir_z); offset += 4
		buf.encode_u8(offset, 1 if active else 0)
		return buf

	func decode(buf: PackedByteArray, start_offset: int = 0) -> bool:
		if buf.size() < start_offset + 33:
			return false
		var offset := start_offset
		arrow_id = buf.decode_u32(offset); offset += 4
		shooter_id = buf.decode_u32(offset); offset += 4
		x = buf.decode_float(offset); offset += 4
		y = buf.decode_float(offset); offset += 4
		z = buf.decode_float(offset); offset += 4
		dir_x = buf.decode_float(offset); offset += 4
		dir_y = buf.decode_float(offset); offset += 4
		dir_z = buf.decode_float(offset); offset += 4
		active = buf.decode_u8(offset) != 0
		return true

	static func size() -> int:
		return 33

# =============================================================================
# ARROW HIT DATA STRUCTURE (20 bytes)
# =============================================================================

class ArrowHitData:
	var arrow_id: int = 0        # 4 bytes
	var hit_x: float = 0.0       # 4 bytes
	var hit_y: float = 0.0       # 4 bytes
	var hit_z: float = 0.0       # 4 bytes
	var hit_entity_id: int = 0   # 4 bytes (0 = ground/world)

	func get_hit_position() -> Vector3:
		return Vector3(hit_x, hit_y, hit_z)

	func set_hit_position(pos: Vector3) -> void:
		hit_x = pos.x
		hit_y = pos.y
		hit_z = pos.z

	func encode() -> PackedByteArray:
		var buf := PackedByteArray()
		buf.resize(20)
		buf.encode_u32(0, arrow_id)
		buf.encode_float(4, hit_x)
		buf.encode_float(8, hit_y)
		buf.encode_float(12, hit_z)
		buf.encode_u32(16, hit_entity_id)
		return buf

	func decode(buf: PackedByteArray, start_offset: int = 0) -> bool:
		if buf.size() < start_offset + 20:
			return false
		arrow_id = buf.decode_u32(start_offset)
		hit_x = buf.decode_float(start_offset + 4)
		hit_y = buf.decode_float(start_offset + 8)
		hit_z = buf.decode_float(start_offset + 12)
		hit_entity_id = buf.decode_u32(start_offset + 16)
		return true

	static func size() -> int:
		return 20

# =============================================================================
# PLAYER DAMAGE DATA STRUCTURE (28 bytes)
# =============================================================================

class PlayerDamageData:
	var target_player_id: int = 0    # 4 bytes
	var damage: float = 0.0          # 4 bytes
	var attacker_entity_id: int = 0  # 4 bytes
	var knockback_x: float = 0.0     # 4 bytes
	var knockback_y: float = 0.0     # 4 bytes
	var knockback_z: float = 0.0     # 4 bytes

	func get_knockback() -> Vector3:
		return Vector3(knockback_x, knockback_y, knockback_z)

	func set_knockback(kb: Vector3) -> void:
		knockback_x = kb.x
		knockback_y = kb.y
		knockback_z = kb.z

	func encode() -> PackedByteArray:
		var buf := PackedByteArray()
		buf.resize(24)
		buf.encode_u32(0, target_player_id)
		buf.encode_float(4, damage)
		buf.encode_u32(8, attacker_entity_id)
		buf.encode_float(12, knockback_x)
		buf.encode_float(16, knockback_y)
		buf.encode_float(20, knockback_z)
		return buf

	func decode(buf: PackedByteArray, start_offset: int = 0) -> bool:
		if buf.size() < start_offset + 24:
			return false
		target_player_id = buf.decode_u32(start_offset)
		damage = buf.decode_float(start_offset + 4)
		attacker_entity_id = buf.decode_u32(start_offset + 8)
		knockback_x = buf.decode_float(start_offset + 12)
		knockback_y = buf.decode_float(start_offset + 16)
		knockback_z = buf.decode_float(start_offset + 20)
		return true

	static func size() -> int:
		return 24

# =============================================================================
# GAME RESTART REASON ENUM
# =============================================================================

enum RestartReason {
	PLAYER_DIED = 0,
	BOBBA_DIED = 1,
	MANUAL_RESTART = 2,
}

# =============================================================================
# MESSAGE BUILDERS
# =============================================================================

## Build MSG_JOIN packet
static func build_join_msg(seq: int, player_name: String) -> PackedByteArray:
	var header := MsgHeader.new()
	header.type = MsgType.MSG_JOIN
	header.seq = seq
	header.sender_id = 0  # Not assigned yet

	var buf := header.encode()

	# Add player name (32 bytes, null-padded)
	var name_bytes := player_name.to_utf8_buffer()
	name_bytes.resize(MAX_PLAYER_NAME)
	buf.append_array(name_bytes)

	return buf

## Build MSG_JOIN_ACK packet
static func build_join_ack_msg(seq: int, assigned_id: int, player_data: PlayerData) -> PackedByteArray:
	var header := MsgHeader.new()
	header.type = MsgType.MSG_JOIN_ACK
	header.seq = seq
	header.sender_id = 0  # From server

	var buf := header.encode()
	buf.encode_u32(buf.size(), assigned_id)
	buf.resize(buf.size() + 4)
	buf.append_array(player_data.encode())

	return buf

## Build MSG_LEAVE packet
static func build_leave_msg(seq: int, player_id: int) -> PackedByteArray:
	var header := MsgHeader.new()
	header.type = MsgType.MSG_LEAVE
	header.seq = seq
	header.sender_id = player_id

	return header.encode()

## Build MSG_MOVE packet (player position/state update)
static func build_move_msg(seq: int, player_data: PlayerData) -> PackedByteArray:
	var header := MsgHeader.new()
	header.type = MsgType.MSG_MOVE
	header.seq = seq
	header.sender_id = player_data.player_id

	var buf := header.encode()
	buf.append_array(player_data.encode())

	return buf

## Build MSG_STATE packet (full state broadcast)
static func build_state_msg(seq: int, state_seq: int, players: Array[PlayerData]) -> PackedByteArray:
	var header := MsgHeader.new()
	header.type = MsgType.MSG_STATE
	header.seq = seq
	header.sender_id = 0  # From server

	var buf := header.encode()

	# State sequence number (4 bytes)
	var state_seq_bytes := PackedByteArray()
	state_seq_bytes.resize(4)
	state_seq_bytes.encode_u32(0, state_seq)
	buf.append_array(state_seq_bytes)

	# Player count (1 byte)
	buf.append(players.size())

	# All player data
	for player in players:
		buf.append_array(player.encode())

	return buf

## Build MSG_ACK packet
static func build_ack_msg(seq: int, sender_id: int, acked_seq: int) -> PackedByteArray:
	var header := MsgHeader.new()
	header.type = MsgType.MSG_ACK
	header.seq = seq
	header.sender_id = sender_id

	var buf := header.encode()
	var acked_bytes := PackedByteArray()
	acked_bytes.resize(4)
	acked_bytes.encode_u32(0, acked_seq)
	buf.append_array(acked_bytes)

	return buf

## Build MSG_PING packet
static func build_ping_msg(seq: int, sender_id: int, timestamp: int) -> PackedByteArray:
	var header := MsgHeader.new()
	header.type = MsgType.MSG_PING
	header.seq = seq
	header.sender_id = sender_id

	var buf := header.encode()
	var ts_bytes := PackedByteArray()
	ts_bytes.resize(8)
	ts_bytes.encode_u64(0, timestamp)
	buf.append_array(ts_bytes)

	return buf

## Build MSG_PONG packet
static func build_pong_msg(seq: int, original_timestamp: int) -> PackedByteArray:
	var header := MsgHeader.new()
	header.type = MsgType.MSG_PONG
	header.seq = seq
	header.sender_id = 0  # From server

	var buf := header.encode()
	var ts_bytes := PackedByteArray()
	ts_bytes.resize(8)
	ts_bytes.encode_u64(0, original_timestamp)
	buf.append_array(ts_bytes)

	return buf

## Build MSG_ENTITY_STATE packet
static func build_entity_state_msg(seq: int, entities: Array[EntityData]) -> PackedByteArray:
	var header := MsgHeader.new()
	header.type = MsgType.MSG_ENTITY_STATE
	header.seq = seq
	header.sender_id = 0  # From server/host

	var buf := header.encode()

	# Entity count (1 byte)
	buf.append(entities.size())

	# All entity data
	for entity in entities:
		buf.append_array(entity.encode())

	return buf

## Build MSG_ENTITY_DAMAGE packet
static func build_entity_damage_msg(seq: int, sender_id: int, entity_id: int, damage: float, attacker_id: int) -> PackedByteArray:
	var header := MsgHeader.new()
	header.type = MsgType.MSG_ENTITY_DAMAGE
	header.seq = seq
	header.sender_id = sender_id

	var buf := header.encode()
	var damage_bytes := PackedByteArray()
	damage_bytes.resize(12)
	damage_bytes.encode_u32(0, entity_id)
	damage_bytes.encode_float(4, damage)
	damage_bytes.encode_u32(8, attacker_id)
	buf.append_array(damage_bytes)

	return buf

## Build MSG_ARROW_SPAWN packet
static func build_arrow_spawn_msg(seq: int, sender_id: int, arrow_data: ArrowData) -> PackedByteArray:
	var header := MsgHeader.new()
	header.type = MsgType.MSG_ARROW_SPAWN
	header.seq = seq
	header.sender_id = sender_id

	var buf := header.encode()
	buf.append_array(arrow_data.encode())

	return buf

## Build MSG_ARROW_HIT packet
static func build_arrow_hit_msg(seq: int, sender_id: int, hit_data: ArrowHitData) -> PackedByteArray:
	var header := MsgHeader.new()
	header.type = MsgType.MSG_ARROW_HIT
	header.seq = seq
	header.sender_id = sender_id

	var buf := header.encode()
	buf.append_array(hit_data.encode())

	return buf

## Build MSG_HOST_CHANGE packet
static func build_host_change_msg(seq: int, new_host_id: int) -> PackedByteArray:
	var header := MsgHeader.new()
	header.type = MsgType.MSG_HOST_CHANGE
	header.seq = seq
	header.sender_id = 0  # From server

	var buf := header.encode()
	var host_bytes := PackedByteArray()
	host_bytes.resize(4)
	host_bytes.encode_u32(0, new_host_id)
	buf.append_array(host_bytes)

	return buf

## Build MSG_HEARTBEAT packet
static func build_heartbeat_msg(seq: int, sender_id: int) -> PackedByteArray:
	var header := MsgHeader.new()
	header.type = MsgType.MSG_HEARTBEAT
	header.seq = seq
	header.sender_id = sender_id

	return header.encode()

## Build MSG_SPECTATE packet (connect as spectator)
static func build_spectate_msg(seq: int) -> PackedByteArray:
	var header := MsgHeader.new()
	header.type = MsgType.MSG_SPECTATE
	header.seq = seq
	header.sender_id = 0  # Not a player yet

	return header.encode()

## Build MSG_SPECTATE_ACK packet
static func build_spectate_ack_msg(seq: int) -> PackedByteArray:
	var header := MsgHeader.new()
	header.type = MsgType.MSG_SPECTATE_ACK
	header.seq = seq
	header.sender_id = 0  # From server

	return header.encode()

## Build MSG_GAME_RESTART packet (client -> server to request restart)
static func build_game_restart_msg(seq: int, sender_id: int, reason: int) -> PackedByteArray:
	var header := MsgHeader.new()
	header.type = MsgType.MSG_GAME_RESTART
	header.seq = seq
	header.sender_id = sender_id

	var buf := header.encode()
	var reason_bytes := PackedByteArray()
	reason_bytes.resize(4)
	reason_bytes.encode_u32(0, reason)
	buf.append_array(reason_bytes)

	return buf

# =============================================================================
# MESSAGE PARSER
# =============================================================================

## Parse incoming message header
static func parse_header(buf: PackedByteArray) -> MsgHeader:
	var header := MsgHeader.new()
	if header.decode(buf):
		return header
	return null

## Get message type name for logging
static func get_msg_type_name(msg_type: int) -> String:
	match msg_type:
		MsgType.MSG_JOIN: return "JOIN"
		MsgType.MSG_JOIN_ACK: return "JOIN_ACK"
		MsgType.MSG_LEAVE: return "LEAVE"
		MsgType.MSG_STATE: return "STATE"
		MsgType.MSG_MOVE: return "MOVE"
		MsgType.MSG_ACK: return "ACK"
		MsgType.MSG_PING: return "PING"
		MsgType.MSG_PONG: return "PONG"
		MsgType.MSG_ENTITY_STATE: return "ENTITY_STATE"
		MsgType.MSG_ENTITY_DAMAGE: return "ENTITY_DAMAGE"
		MsgType.MSG_ARROW_SPAWN: return "ARROW_SPAWN"
		MsgType.MSG_ARROW_HIT: return "ARROW_HIT"
		MsgType.MSG_HOST_CHANGE: return "HOST_CHANGE"
		MsgType.MSG_HEARTBEAT: return "HEARTBEAT"
		MsgType.MSG_SPECTATE: return "SPECTATE"
		MsgType.MSG_SPECTATE_ACK: return "SPECTATE_ACK"
		MsgType.MSG_PLAYER_DAMAGE: return "PLAYER_DAMAGE"
		MsgType.MSG_GAME_RESTART: return "GAME_RESTART"
		_: return "UNKNOWN(%d)" % msg_type
