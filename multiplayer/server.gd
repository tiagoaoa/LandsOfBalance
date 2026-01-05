extends Node

## Standalone UDP Multiplayer Server
## Run with: godot --headless --script res://multiplayer/server.gd

const ProtocolClass = preload("res://multiplayer/protocol.gd")
const ServerStateClass = preload("res://multiplayer/server_state.gd")

var socket: UDPServer
var state: RefCounted  # ServerState
var client_endpoints: Dictionary = {}  # player_id -> {ip, port, peer}
var spectator_endpoints: Array = []  # Array of {ip, port, peer} for spectators

func _init() -> void:
	state = ServerStateClass.new()
	state.host_changed.connect(_on_host_changed)

func _ready() -> void:
	print("========================================")
	print("  MULTIPLAYER SERVER")
	print("  Port: %d" % ProtocolClass.SERVER_PORT)
	print("========================================")

	socket = UDPServer.new()
	var err = socket.listen(ProtocolClass.SERVER_PORT)
	if err != OK:
		push_error("Failed to start server on port %d: %s" % [ProtocolClass.SERVER_PORT, error_string(err)])
		get_tree().quit(1)
		return

	print("Server listening on port %d" % ProtocolClass.SERVER_PORT)
	print("Waiting for clients...")

var _broadcast_timer: float = 0.0
const BROADCAST_INTERVAL: float = 0.05  # 20 Hz state broadcast

func _process(delta: float) -> void:
	socket.poll()

	# Check for new connections or data
	while socket.is_connection_available():
		var peer: PacketPeerUDP = socket.take_connection()
		_handle_peer(peer)

	# Poll all existing player peers for data
	for pid in client_endpoints.keys():
		var endpoint = client_endpoints[pid]
		var peer: PacketPeerUDP = endpoint.peer
		while peer.get_available_packet_count() > 0:
			var packet = peer.get_packet()
			_handle_packet(packet, peer, endpoint.ip, endpoint.port)

	# Poll spectator peers for data (they might send JOIN)
	for i in range(spectator_endpoints.size() - 1, -1, -1):
		var endpoint = spectator_endpoints[i]
		var peer: PacketPeerUDP = endpoint.peer
		while peer.get_available_packet_count() > 0:
			var packet = peer.get_packet()
			_handle_packet(packet, peer, endpoint.ip, endpoint.port)

	# Broadcast state to all clients AND spectators periodically
	_broadcast_timer += delta
	if _broadcast_timer >= BROADCAST_INTERVAL:
		_broadcast_timer = 0.0
		_broadcast_state()

func _handle_peer(peer: PacketPeerUDP) -> void:
	var ip = peer.get_packet_ip()
	var port = peer.get_packet_port()

	while peer.get_available_packet_count() > 0:
		var packet = peer.get_packet()
		_handle_packet(packet, peer, ip, port)

func _handle_packet(packet: PackedByteArray, peer: PacketPeerUDP, ip: String, port: int) -> void:
	if packet.size() < ProtocolClass.MsgHeader.size():
		return

	var header = ProtocolClass.parse_header(packet)
	if header == null:
		return

	var msg_type = header.type
	var seq = header.seq
	var sender_id = header.sender_id

	match msg_type:
		ProtocolClass.MsgType.MSG_SPECTATE:
			_handle_spectate(peer, ip, port, seq)
		ProtocolClass.MsgType.MSG_JOIN:
			_handle_join(packet, peer, ip, port, seq)
		ProtocolClass.MsgType.MSG_LEAVE:
			_handle_leave(sender_id, seq)
		ProtocolClass.MsgType.MSG_MOVE:
			_handle_move(packet, sender_id)
		ProtocolClass.MsgType.MSG_PING:
			_handle_ping(packet, peer, sender_id, seq)
		ProtocolClass.MsgType.MSG_ARROW_SPAWN:
			_handle_arrow_spawn(packet, sender_id, seq)
		ProtocolClass.MsgType.MSG_ARROW_HIT:
			_handle_arrow_hit(packet, sender_id, seq)
		ProtocolClass.MsgType.MSG_ENTITY_DAMAGE:
			_handle_entity_damage(packet, sender_id)

func _handle_spectate(peer: PacketPeerUDP, ip: String, port: int, seq: int) -> void:
	# Check if already a spectator
	for endpoint in spectator_endpoints:
		if endpoint.ip == ip and endpoint.port == port:
			return  # Already spectating

	# Check if already a player
	for pid in client_endpoints.keys():
		var endpoint = client_endpoints[pid]
		if endpoint.ip == ip and endpoint.port == port:
			return  # Already a player

	# Add as spectator
	spectator_endpoints.append({"ip": ip, "port": port, "peer": peer})
	print("Server: Spectator connected from %s:%d" % [ip, port])

	# Send SPECTATE_ACK
	var ack = ProtocolClass.build_spectate_ack_msg(seq)
	peer.put_packet(ack)

	# Send current state immediately
	_broadcast_state()

func _handle_join(packet: PackedByteArray, peer: PacketPeerUDP, ip: String, port: int, seq: int) -> void:
	# Remove from spectators if was spectating
	for i in range(spectator_endpoints.size() - 1, -1, -1):
		var endpoint = spectator_endpoints[i]
		if endpoint.ip == ip and endpoint.port == port:
			spectator_endpoints.remove_at(i)
			print("Server: Spectator %s:%d is now joining as player" % [ip, port])
			break

	# Parse name from packet
	var offset = ProtocolClass.MsgHeader.size()
	var name_len = packet.decode_u8(offset) if packet.size() > offset else 0
	offset += 1
	var player_name = packet.slice(offset, offset + name_len).get_string_from_utf8() if name_len > 0 else "Player"

	# Add player to server state
	var player_data = state.handle_join(player_name)
	if player_data == null:
		print("Server: Player rejected (server full)")
		return

	var player_id = player_data.player_id

	# Store endpoint
	client_endpoints[player_id] = {"ip": ip, "port": port, "peer": peer}

	print("Server: Player '%s' joined as ID %d from %s:%d" % [player_name, player_id, ip, port])

	# Build and send JOIN_ACK
	var ack = _build_join_ack(seq, player_id, player_data)
	peer.put_packet(ack)

	# Broadcast state to all
	_broadcast_state()

func _handle_leave(player_id: int, _seq: int) -> void:
	if player_id == 0:
		return

	print("Server: Player ID %d left" % player_id)

	state.handle_leave(player_id)
	client_endpoints.erase(player_id)

	# Reassign host if needed
	state.reassign_host_if_needed()

	# Broadcast updated state
	_broadcast_state()

func _handle_move(packet: PackedByteArray, player_id: int) -> void:
	if player_id == 0:
		return

	var offset = ProtocolClass.MsgHeader.size()
	var player_data = ProtocolClass.PlayerData.new()
	if not player_data.decode(packet, offset):
		return

	# Update server state
	state.handle_move(player_id, player_data)

func _handle_ping(packet: PackedByteArray, peer: PacketPeerUDP, player_id: int, seq: int) -> void:
	# Extract timestamp from ping
	var offset = ProtocolClass.MsgHeader.size()
	var timestamp = packet.decode_s64(offset) if packet.size() > offset + 8 else 0

	# Send pong with same timestamp
	var pong = _build_pong(seq, player_id, timestamp)
	peer.put_packet(pong)

func _handle_arrow_spawn(packet: PackedByteArray, sender_id: int, seq: int) -> void:
	# Broadcast arrow spawn to all OTHER clients
	for pid in client_endpoints.keys():
		if pid != sender_id:
			var endpoint = client_endpoints[pid]
			endpoint.peer.put_packet(packet)

func _handle_arrow_hit(packet: PackedByteArray, sender_id: int, seq: int) -> void:
	# Broadcast arrow hit to all clients
	for pid in client_endpoints.keys():
		var endpoint = client_endpoints[pid]
		endpoint.peer.put_packet(packet)

func _handle_entity_damage(packet: PackedByteArray, sender_id: int) -> void:
	var offset = ProtocolClass.MsgHeader.size()
	var entity_id = packet.decode_s32(offset) if packet.size() > offset + 4 else 0
	offset += 4
	var damage = packet.decode_float(offset) if packet.size() > offset + 4 else 0.0

	print("Server: Entity %d damaged for %.1f by player %d" % [entity_id, damage, sender_id])
	# TODO: Track entity health if needed

func _on_host_changed(new_host_id: int) -> void:
	print("Server: Host changed to player %d" % new_host_id)
	# Broadcast host change to all clients
	var msg = _build_host_change(new_host_id)
	for pid in client_endpoints.keys():
		var endpoint = client_endpoints[pid]
		endpoint.peer.put_packet(msg)

var _msg_seq: int = 1

func _broadcast_state() -> void:
	var players: Array[ProtocolClass.PlayerData] = state.get_active_players()

	_msg_seq += 1
	var state_msg = ProtocolClass.build_state_msg(_msg_seq, state.get_state_seq(), players)

	# Send to all players
	for pid in client_endpoints.keys():
		var endpoint = client_endpoints[pid]
		endpoint.peer.put_packet(state_msg)

	# Send to all spectators
	for endpoint in spectator_endpoints:
		endpoint.peer.put_packet(state_msg)

# Message builders
func _build_join_ack(seq: int, player_id: int, player_data: ProtocolClass.PlayerData) -> PackedByteArray:
	var header := ProtocolClass.MsgHeader.new()
	header.type = ProtocolClass.MsgType.MSG_JOIN_ACK
	header.seq = seq
	header.sender_id = 0

	var buf := header.encode()

	# Player ID (4 bytes)
	var id_bytes := PackedByteArray()
	id_bytes.resize(4)
	id_bytes.encode_u32(0, player_id)
	buf.append_array(id_bytes)

	# Initial player data
	if player_data:
		buf.append_array(player_data.encode())

	return buf

func _build_pong(seq: int, player_id: int, timestamp: int) -> PackedByteArray:
	var buf = PackedByteArray()
	buf.resize(ProtocolClass.MsgHeader.size() + 8)

	buf.encode_u8(0, ProtocolClass.MsgType.MSG_PONG)
	buf.encode_u32(1, seq)
	buf.encode_u32(5, 0)
	buf.encode_s64(ProtocolClass.MsgHeader.size(), timestamp)

	return buf

func _build_host_change(new_host_id: int) -> PackedByteArray:
	var buf = PackedByteArray()
	buf.resize(ProtocolClass.MsgHeader.size() + 4)

	buf.encode_u8(0, ProtocolClass.MsgType.MSG_HOST_CHANGE)
	buf.encode_u32(1, 0)
	buf.encode_u32(5, 0)
	buf.encode_u32(ProtocolClass.MsgHeader.size(), new_host_id)

	return buf
