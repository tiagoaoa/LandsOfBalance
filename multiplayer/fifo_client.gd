extends Node
class_name FifoClient

## FIFO-based client for server-authoritative multiplayer.
## Communicates with fifo_server via named pipes.
## Player sends local state, receives global state every 5ms.

signal connected
signal disconnected
signal global_state_received(players: Array)
signal connection_failed(reason: String)

const FIFO_PATH_PREFIX := "/tmp/lob_"
const POLL_INTERVAL_MS := 500  # Read server updates every 500ms
const MAX_PLAYERS := 4

# Message types (match fifo_server.c)
const MSG_PLAYER_UPDATE := 1
const MSG_GLOBAL_STATE := 2
const MSG_JOIN := 3
const MSG_LEAVE := 4

# Player states (match protocol.gd)
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

var player_id: int = 0
var is_connected: bool = false

var _to_server_path: String
var _from_server_path: String
var _to_server_file: FileAccess
var _from_server_file: FileAccess

var _poll_thread: Thread
var _running: bool = false
var _mutex: Mutex

# Latest global state from server
var _server_players: Array = []
var _last_sequence: int = 0

# PlayerData structure size (must match C struct)
const PLAYER_DATA_SIZE := 60
const MSG_HEADER_SIZE := 8
const FIFO_MESSAGE_SIZE := MSG_HEADER_SIZE + (PLAYER_DATA_SIZE * MAX_PLAYERS)


func _init() -> void:
	_mutex = Mutex.new()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		disconnect_from_server()


## Connect to the FIFO server with the given player ID
func connect_to_server(id: int) -> bool:
	if is_connected:
		push_warning("Already connected as player %d" % player_id)
		return true

	player_id = id
	_to_server_path = FIFO_PATH_PREFIX + "player%d_to_server" % player_id
	_from_server_path = FIFO_PATH_PREFIX + "server_to_player%d" % player_id

	print("[FifoClient] Connecting as player %d..." % player_id)
	print("[FifoClient] Write to: %s" % _to_server_path)
	print("[FifoClient] Read from: %s" % _from_server_path)

	# Check if FIFOs exist
	if not FileAccess.file_exists(_to_server_path):
		var err := "FIFO not found: %s (is fifo_server running?)" % _to_server_path
		push_error(err)
		connection_failed.emit(err)
		return false

	if not FileAccess.file_exists(_from_server_path):
		var err := "FIFO not found: %s (is fifo_server running?)" % _from_server_path
		push_error(err)
		connection_failed.emit(err)
		return false

	# Open FIFOs
	# Note: Opening a FIFO blocks until the other end opens too
	# We open write first, then read
	_to_server_file = FileAccess.open(_to_server_path, FileAccess.WRITE)
	if not _to_server_file:
		var err := "Failed to open write FIFO: %s" % _to_server_path
		push_error(err)
		connection_failed.emit(err)
		return false

	_from_server_file = FileAccess.open(_from_server_path, FileAccess.READ)
	if not _from_server_file:
		var err := "Failed to open read FIFO: %s" % _from_server_path
		push_error(err)
		_to_server_file = null
		connection_failed.emit(err)
		return false

	is_connected = true
	_running = true

	# Start polling thread
	_poll_thread = Thread.new()
	_poll_thread.start(_poll_loop)

	print("[FifoClient] Connected as player %d" % player_id)
	connected.emit()
	return true


## Disconnect from the server
func disconnect_from_server() -> void:
	if not is_connected:
		return

	print("[FifoClient] Disconnecting player %d..." % player_id)

	_running = false

	# Wait for poll thread to finish
	if _poll_thread and _poll_thread.is_started():
		_poll_thread.wait_to_finish()
	_poll_thread = null

	# Close files
	_to_server_file = null
	_from_server_file = null

	is_connected = false
	disconnected.emit()
	print("[FifoClient] Disconnected")


## Send local player state to server
func send_local_state(data: Dictionary) -> void:
	if not is_connected or not _to_server_file:
		return

	var buffer := PackedByteArray()
	buffer.resize(FIFO_MESSAGE_SIZE)

	var offset := 0

	# Header
	buffer.encode_u8(offset, MSG_PLAYER_UPDATE)
	offset += 1
	buffer.encode_u8(offset, 1)  # player_count = 1
	offset += 1
	buffer.encode_u32(offset, 0)  # sequence (unused for client->server)
	offset += 4
	buffer.encode_u16(offset, 0)  # padding
	offset += 2

	# PlayerData
	_encode_player_data(buffer, offset, data)

	# Write to FIFO
	_to_server_file.store_buffer(buffer)
	_to_server_file.flush()


## Get the latest server state for all players
func get_server_players() -> Array:
	_mutex.lock()
	var players := _server_players.duplicate(true)
	_mutex.unlock()
	return players


## Get server state for a specific player ID
func get_player_state(id: int) -> Dictionary:
	_mutex.lock()
	for p in _server_players:
		if p.get("player_id", 0) == id:
			_mutex.unlock()
			return p.duplicate()
	_mutex.unlock()
	return {}


## Get our own server-confirmed state
func get_my_server_state() -> Dictionary:
	return get_player_state(player_id)


# Encode player data into buffer at offset
func _encode_player_data(buffer: PackedByteArray, offset: int, data: Dictionary) -> void:
	buffer.encode_u32(offset, data.get("player_id", player_id))
	offset += 4
	buffer.encode_float(offset, data.get("x", 0.0))
	offset += 4
	buffer.encode_float(offset, data.get("y", 0.0))
	offset += 4
	buffer.encode_float(offset, data.get("z", 0.0))
	offset += 4
	buffer.encode_float(offset, data.get("rotation_y", 0.0))
	offset += 4
	buffer.encode_u8(offset, data.get("state", STATE_IDLE))
	offset += 1
	buffer.encode_u8(offset, data.get("combat_mode", 1))
	offset += 1
	buffer.encode_float(offset, data.get("health", 100.0))
	offset += 4

	# Animation name (32 bytes, null-padded)
	var anim_name: String = data.get("anim_name", "Idle")
	var anim_bytes := anim_name.to_utf8_buffer()
	for i in range(32):
		if i < anim_bytes.size():
			buffer.encode_u8(offset + i, anim_bytes[i])
		else:
			buffer.encode_u8(offset + i, 0)
	offset += 32

	buffer.encode_u8(offset, 1 if data.get("active", true) else 0)
	offset += 1
	buffer.encode_u8(offset, data.get("character_class", 1))


# Decode player data from buffer at offset
func _decode_player_data(buffer: PackedByteArray, offset: int) -> Dictionary:
	var data := {}

	data["player_id"] = buffer.decode_u32(offset)
	offset += 4
	data["x"] = buffer.decode_float(offset)
	offset += 4
	data["y"] = buffer.decode_float(offset)
	offset += 4
	data["z"] = buffer.decode_float(offset)
	offset += 4
	data["rotation_y"] = buffer.decode_float(offset)
	offset += 4
	data["state"] = buffer.decode_u8(offset)
	offset += 1
	data["combat_mode"] = buffer.decode_u8(offset)
	offset += 1
	data["health"] = buffer.decode_float(offset)
	offset += 4

	# Animation name (32 bytes)
	var anim_bytes := buffer.slice(offset, offset + 32)
	var null_idx := anim_bytes.find(0)
	if null_idx > 0:
		anim_bytes = anim_bytes.slice(0, null_idx)
	data["anim_name"] = anim_bytes.get_string_from_utf8()
	offset += 32

	data["active"] = buffer.decode_u8(offset) != 0
	offset += 1
	data["character_class"] = buffer.decode_u8(offset)

	return data


# Polling loop running in separate thread
func _poll_loop() -> void:
	print("[FifoClient] Poll thread started (interval: %d ms)" % POLL_INTERVAL_MS)

	while _running:
		_read_server_state()
		OS.delay_msec(POLL_INTERVAL_MS)

	print("[FifoClient] Poll thread stopped")


# Read and parse server state from FIFO
func _read_server_state() -> void:
	if not _from_server_file:
		return

	# Try to read a full message
	var buffer := _from_server_file.get_buffer(FIFO_MESSAGE_SIZE)
	if buffer.size() < MSG_HEADER_SIZE:
		return

	# Parse header
	var msg_type := buffer.decode_u8(0)
	var player_count := buffer.decode_u8(1)
	var sequence := buffer.decode_u32(2)

	if msg_type != MSG_GLOBAL_STATE:
		return

	# Skip old messages
	if sequence <= _last_sequence:
		return
	_last_sequence = sequence

	# Parse player data
	var players: Array = []
	var offset := MSG_HEADER_SIZE

	for i in range(player_count):
		if offset + PLAYER_DATA_SIZE > buffer.size():
			break
		var data := _decode_player_data(buffer, offset)
		if data.get("active", false):
			players.append(data)
		offset += PLAYER_DATA_SIZE

	# Update state (thread-safe)
	_mutex.lock()
	_server_players = players
	_mutex.unlock()

	# Emit signal on main thread
	call_deferred("_emit_state_received", players)


func _emit_state_received(players: Array) -> void:
	global_state_received.emit(players)
