class_name Bobba
extends CharacterBody3D
## Bobba - A roaming creature that attacks when the player gets close.
## Roams around the map randomly, switches to attack mode within 10 meters of player.
## Network-synchronized across all players.

signal attack_landed(target: Node3D, knockback_direction: Vector3)

# Use Protocol.BobbaState for network sync compatibility
const Proto = preload("res://multiplayer/protocol.gd")
const State = Proto.BobbaState

# Network synchronization
var entity_id: int = 0  # Unique ID for network sync
var _is_network_controlled: bool = false  # True for non-host clients
var _target_position: Vector3 = Vector3.ZERO
var _target_rotation: float = 0.0

# Health system
const MAX_HEALTH: float = 500.0
var health: float = MAX_HEALTH

# Movement constants
const ROAM_SPEED: float = 2.0
const CHASE_SPEED: float = 5.0
const RETREAT_SPEED: float = 3.0  # Speed when retreating from arrows
const DETECTION_RADIUS: float = 10.0  # Start following within this radius
const LOSE_RADIUS: float = 20.0  # Stop following beyond this radius
const ATTACK_DISTANCE: float = 2.0  # Distance to start attack animation
const ROAM_CHANGE_TIME: float = 3.0  # Time between direction changes
const ROTATION_SPEED: float = 5.0

# Combat constants
const ATTACK_DAMAGE: float = 70.0  # Damage dealt to players
const ARROW_DAMAGE: float = 10.0  # Damage taken from arrows
const SWORD_DAMAGE: float = 50.0  # Damage taken from Paladin sword
const KNOCKBACK_FORCE: float = 12.0

# Arrow retreat behavior
var _is_retreating: bool = false
var _retreat_timer: float = 0.0
var _retreat_direction: Vector3 = Vector3.ZERO
const RETREAT_DURATION: float = 2.0  # Seconds to retreat after arrow hit

# Fire avoidance
var _ground_fires: Array = []  # Track active ground fire positions
const FIRE_AVOID_RADIUS: float = 3.0  # Distance to avoid from fire

signal health_changed(current: float, maximum: float)
signal died()

var state: int = State.ROAMING
var target: Node3D = null  # Current target player
var _all_players: Array[Node3D] = []  # All players in scene
var roam_direction: Vector3 = Vector3.ZERO
var roam_timer: float = 0.0
var attack_cooldown: float = 0.0

# Combat
var _left_hand_hitbox: Area3D
var _right_hand_hitbox: Area3D
var _left_hand_attachment: BoneAttachment3D
var _right_hand_attachment: BoneAttachment3D
var _has_hit_this_attack: bool = false
var _hit_flash_tween: Tween
var _stun_timer: float = 0.0
var _hit_label: Label3D
var _attack_anim_progress: float = 0.0
const HAND_HITBOX_START: float = 0.3  # Enable hitbox at 30% of attack animation
const HAND_HITBOX_END: float = 0.7    # Disable hitbox at 70% of attack animation

# Animation
var _anim_player: AnimationPlayer
var _model: Node3D
var _current_anim: StringName = &""

# Animation paths
const ANIM_PATHS: Dictionary = {
	"idle": "res://assets/bobba/mutant idle.fbx",
	"walk": "res://assets/bobba/mutant walking.fbx",
	"run": "res://assets/bobba/mutant run.fbx",
	"attack": "res://assets/bobba/mutant swiping.fbx",
	"roar": "res://assets/bobba/mutant roaring.fbx",
	"dying": "res://assets/bobba/mutant dying.fbx",
	"jump_attack": "res://assets/bobba/mutant jump attack.fbx",
}

@onready var gravity: Vector3 = ProjectSettings.get_setting("physics/3d/default_gravity") * \
		ProjectSettings.get_setting("physics/3d/default_gravity_vector")


func _ready() -> void:
	add_to_group("bobba")  # Add to group for easy finding
	_find_player()
	_setup_attack_hitbox()  # Must be before _setup_model which attaches hitboxes to bones
	_setup_model()
	_setup_hit_label()
	_pick_new_roam_direction()
	_setup_network()


func _setup_network() -> void:
	# Use fixed entity ID = 1 for scene Bobba (matches server's first spawned Bobba)
	# Server spawns Bobba with incrementing IDs starting from 1
	entity_id = 1

	# Register with NetworkManager if available
	var network_manager = get_node_or_null("/root/NetworkManager")
	if network_manager:
		network_manager.register_entity(self, Proto.EntityType.ENTITY_BOBBA, entity_id)

		# Connect to connection signals to update mode when connection state changes
		if not network_manager.connected_to_server.is_connected(_on_connected_to_server):
			network_manager.connected_to_server.connect(_on_connected_to_server)
		if not network_manager.joined_game.is_connected(_on_joined_game):
			network_manager.joined_game.connect(_on_joined_game)
		if not network_manager.spectating_started.is_connected(_on_spectating_started):
			network_manager.spectating_started.connect(_on_spectating_started)

		# Check connection status immediately
		_update_network_control_mode()
	else:
		# No NetworkManager - run locally
		_is_network_controlled = false
		print("Bobba [%d]: Locally-controlled (no NetworkManager)" % entity_id)


func _on_connected_to_server() -> void:
	_update_network_control_mode()


func _on_joined_game() -> void:
	_update_network_control_mode()


func _on_spectating_started() -> void:
	_update_network_control_mode()


func _update_network_control_mode() -> void:
	var network_manager = get_node_or_null("/root/NetworkManager")
	if not network_manager:
		return

	# Server is ALWAYS authoritative for entities - all clients receive state from server
	var is_connected = network_manager.client_state and network_manager.client_state.is_network_connected()
	# Also check if we're spectating (receiving state but not joined yet)
	var is_spectating = network_manager.is_spectating

	if is_connected or is_spectating:
		if not _is_network_controlled:
			_is_network_controlled = true
			print("Bobba [%d]: Network-controlled (server authoritative)" % entity_id)
	else:
		if _is_network_controlled:
			_is_network_controlled = false
			print("Bobba [%d]: Locally-controlled (single player)" % entity_id)


func _exit_tree() -> void:
	# Unregister from NetworkManager
	if has_node("/root/NetworkManager"):
		var network_manager = get_node("/root/NetworkManager")
		if network_manager.has_method("unregister_entity"):
			network_manager.unregister_entity(entity_id)


func _find_player() -> void:
	# Find all players in the scene (local + remote)
	await get_tree().process_frame
	_update_player_list()


func _update_player_list() -> void:
	# Refresh list of all players (local and remote)
	_all_players.clear()

	# Find local player by name (most reliable)
	var local_player = _find_node_by_name(get_tree().root, "Player")
	if local_player and is_instance_valid(local_player):
		_all_players.append(local_player)

	# Also check for group membership as fallback
	var group_player = get_tree().get_first_node_in_group("player")
	if group_player and is_instance_valid(group_player) and group_player not in _all_players:
		_all_players.append(group_player)

	# Find remote players - search for RemotePlayer nodes
	_find_remote_players(get_tree().root)


func _find_remote_players(node: Node) -> void:
	# Recursively find all RemotePlayer instances
	if node.get_class() == "CharacterBody3D" and "RemotePlayer" in node.name:
		if is_instance_valid(node) and node not in _all_players:
			_all_players.append(node)
	# Also check by script class name
	if node is CharacterBody3D and node.has_method("update_from_network"):
		if is_instance_valid(node) and node not in _all_players:
			_all_players.append(node)
	for child in node.get_children():
		_find_remote_players(child)


func _select_target() -> void:
	# Select which player to follow based on rules:
	# 1. Keep current target if still valid and within LOSE_RADIUS
	# 2. Otherwise, pick first player within DETECTION_RADIUS

	# Always update player list to catch new players
	_update_player_list()

	# Check if current target is still valid
	if target and is_instance_valid(target):
		var dist = global_position.distance_to(target.global_position)
		if dist <= LOSE_RADIUS:
			return  # Keep current target
		else:
			# Target escaped, clear it
			target = null
			state = State.ROAMING
			_pick_new_roam_direction()
			print("Bobba: Target escaped beyond %dm, returning to roaming" % int(LOSE_RADIUS))

	# No valid target, look for a new one within detection radius
	if target == null:
		for p in _all_players:
			if is_instance_valid(p):
				var dist = global_position.distance_to(p.global_position)
				if dist <= DETECTION_RADIUS:
					target = p
					state = State.CHASING
					print("Bobba: New target acquired at %.1fm - %s" % [dist, p.name])
					break


func _set_attacker_as_target(attacker: Node3D) -> void:
	# When attacked, prioritize the attacker as target
	if attacker and is_instance_valid(attacker):
		target = attacker
		if state == State.ROAMING or state == State.IDLE:
			state = State.CHASING
		print("Bobba: Switching target to attacker")


func _find_node_by_name(node: Node, target_name: String) -> Node:
	if node.name == target_name:
		return node
	for child in node.get_children():
		var result = _find_node_by_name(child, target_name)
		if result:
			return result
	return null


func _setup_model() -> void:
	# Find the model and animation player
	for child in get_children():
		if child is Node3D and child.name != "CollisionShape3D":
			_model = child
			print("Bobba: Found model: ", child.name)
			break

	if _model:
		# Always force-apply our material to ensure visibility
		print("Bobba: Force-applying material to model")
		_apply_textures(_model)

		_anim_player = _find_animation_player(_model)
		if _anim_player:
			print("Bobba: Found AnimationPlayer: ", _anim_player.name)
			print("Bobba: AnimationPlayer root node: ", _anim_player.root_node)
			_anim_player.animation_finished.connect(_on_animation_finished)
			_load_animations()
			print("Bobba: Available animations after load: ", _anim_player.get_animation_list())
			_play_anim(&"bobba/Idle")
		else:
			print("Bobba: ERROR - No AnimationPlayer found in model!")
			_print_node_tree(_model, 0)

		# Setup hand bone attachments after model and animations are ready
		_setup_hand_bone_attachments()
	else:
		print("Bobba: ERROR - No model found!")


func _print_node_tree(node: Node, depth: int) -> void:
	var indent = ""
	for i in range(depth):
		indent += "  "
	print(indent, node.name, " [", node.get_class(), "]")
	for child in node.get_children():
		_print_node_tree(child, depth + 1)


func _setup_attack_hitbox() -> void:
	# Create hand hitboxes - will be attached to bones after model is set up
	_left_hand_hitbox = _create_hand_hitbox("LeftHandHitbox")
	_right_hand_hitbox = _create_hand_hitbox("RightHandHitbox")

	# Connect signals
	_left_hand_hitbox.body_entered.connect(_on_attack_hitbox_body_entered)
	_right_hand_hitbox.body_entered.connect(_on_attack_hitbox_body_entered)


func _create_hand_hitbox(hitbox_name: String) -> Area3D:
	var hitbox = Area3D.new()
	hitbox.name = hitbox_name
	hitbox.collision_layer = 0  # Doesn't collide with anything
	hitbox.collision_mask = 1   # Detects player (layer 1)
	hitbox.monitoring = true    # Always monitoring - damage gated by _hitbox_active_window

	# Create collision shape - large sphere for reliable hit detection
	var collision_shape = CollisionShape3D.new()
	var sphere = SphereShape3D.new()
	sphere.radius = 1.2  # Large radius for reliable hit detection
	collision_shape.shape = sphere
	collision_shape.position = Vector3(0, 0, 0.5)  # Offset forward from hand

	hitbox.add_child(collision_shape)
	return hitbox


func _setup_hand_bone_attachments() -> void:
	# Attach hand hitboxes to the hand bones
	if _model == null:
		print("Bobba: No model, adding hitboxes to self")
		add_child(_left_hand_hitbox)
		add_child(_right_hand_hitbox)
		_left_hand_hitbox.position = Vector3(-0.75, 1.5, 0.75)
		_right_hand_hitbox.position = Vector3(0.75, 1.5, 0.75)
		return

	var skeleton: Skeleton3D = _find_skeleton(_model)
	if skeleton == null:
		print("Bobba: No skeleton found for hand attachments, using fallback on model")
		# Add to _model so hitboxes rotate with Bobba's facing direction
		_model.add_child(_left_hand_hitbox)
		_model.add_child(_right_hand_hitbox)
		# Position in model's local space (forward = +Z in model space)
		_left_hand_hitbox.position = Vector3(-0.5, 1.0, 0.5)
		_right_hand_hitbox.position = Vector3(0.5, 1.0, 0.5)
		return

	# Debug: print all bone names
	print("Bobba: Skeleton has ", skeleton.get_bone_count(), " bones:")
	for i in range(skeleton.get_bone_count()):
		print("  Bone ", i, ": ", skeleton.get_bone_name(i))

	# Find left hand bone
	var left_hand_idx: int = _find_hand_bone(skeleton, "Left")
	if left_hand_idx != -1:
		_left_hand_attachment = BoneAttachment3D.new()
		_left_hand_attachment.name = "LeftHandAttachment"
		_left_hand_attachment.bone_name = skeleton.get_bone_name(left_hand_idx)
		skeleton.add_child(_left_hand_attachment)
		_left_hand_attachment.add_child(_left_hand_hitbox)
		print("Bobba: Attached left hand hitbox to bone: ", skeleton.get_bone_name(left_hand_idx))
	else:
		print("Bobba: Left hand bone not found, using fallback position on model")
		_model.add_child(_left_hand_hitbox)
		_left_hand_hitbox.position = Vector3(-0.5, 1.0, 0.5)

	# Find right hand bone
	var right_hand_idx: int = _find_hand_bone(skeleton, "Right")
	if right_hand_idx != -1:
		_right_hand_attachment = BoneAttachment3D.new()
		_right_hand_attachment.name = "RightHandAttachment"
		_right_hand_attachment.bone_name = skeleton.get_bone_name(right_hand_idx)
		skeleton.add_child(_right_hand_attachment)
		_right_hand_attachment.add_child(_right_hand_hitbox)
		print("Bobba: Attached right hand hitbox to bone: ", skeleton.get_bone_name(right_hand_idx))
	else:
		print("Bobba: Right hand bone not found, using fallback position on model")
		_model.add_child(_right_hand_hitbox)
		_right_hand_hitbox.position = Vector3(0.5, 1.0, 0.5)


func _find_hand_bone(skeleton: Skeleton3D, side: String) -> int:
	# Try various naming conventions for hand bones
	var possible_names: Array = [
		"mixamorig_" + side + "Hand",
		"mixamorig:" + side + "Hand",
		side + "Hand",
		side + "_Hand",
		"mixamorig_" + side + "HandIndex1",  # Some rigs use finger as hand
	]

	for bone_name in possible_names:
		var idx = skeleton.find_bone(bone_name)
		if idx != -1:
			return idx

	# Fallback: search for any bone containing the side and "hand"
	for i in range(skeleton.get_bone_count()):
		var name = skeleton.get_bone_name(i).to_lower()
		if side.to_lower() in name and "hand" in name:
			return i

	return -1


func _setup_hit_label() -> void:
	# Create floating "Hit!" label above character
	_hit_label = Label3D.new()
	_hit_label.name = "HitLabel"
	_hit_label.text = "Hit!"
	_hit_label.font_size = 64
	_hit_label.modulate = Color(1.0, 0.2, 0.2)  # Red for enemy
	_hit_label.outline_modulate = Color(0.3, 0.0, 0.0)
	_hit_label.outline_size = 8
	_hit_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_hit_label.no_depth_test = true  # Always visible
	_hit_label.position = Vector3(0, 3.0, 0)  # Above head
	_hit_label.visible = false
	add_child(_hit_label)

	# Create health bar label above Bobba
	var health_label = Label3D.new()
	health_label.name = "HealthLabel"
	health_label.text = "%.0f / %.0f" % [health, MAX_HEALTH]
	health_label.font_size = 32
	health_label.modulate = Color(1.0, 0.3, 0.3)
	health_label.outline_modulate = Color(0.2, 0.0, 0.0)
	health_label.outline_size = 6
	health_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	health_label.no_depth_test = true
	health_label.position = Vector3(0, 4.0, 0)  # Above name label
	add_child(health_label)

	# Connect health signal to update label
	health_changed.connect(_on_health_label_update)


func _on_attack_hitbox_body_entered(body: Node3D) -> void:
	# Only process hits during the active damage window
	if not _hitbox_active_window:
		return

	if _has_hit_this_attack:
		return

	# Only process CharacterBody3D (ignore ground, walls, etc.)
	if not body is CharacterBody3D:
		return

	# Check if this is any player (local or remote)
	var is_player = body == target or body.is_in_group("player") or body.is_in_group("remote_players")
	if is_player and is_instance_valid(body):
		print("Bobba: Hit player: ", body.name)
		_has_hit_this_attack = true

		# Calculate knockback direction (from Bobba to hit body)
		var knockback_dir = (body.global_position - global_position).normalized()
		knockback_dir.y = 0.3  # Add slight upward component

		# Check if player is blocking (is_blocking is a variable, not a method)
		var player_is_blocking: bool = false
		if "is_blocking" in body:
			player_is_blocking = body.is_blocking

		if player_is_blocking:
			# Blocked - reduced knockback, no damage
			if body.has_method("take_hit"):
				body.take_hit(0, knockback_dir * KNOCKBACK_FORCE * 0.3, true)
			print("Bobba: HIT BLOCKED by player")
		else:
			# Not blocked - full damage and knockback
			if body.has_method("take_hit"):
				body.take_hit(ATTACK_DAMAGE, knockback_dir * KNOCKBACK_FORCE, false)
			print("Bobba: HIT LANDED on player")

		attack_landed.emit(body, knockback_dir)


var _hitbox_active_window: bool = false  # Whether we're in the damage-dealing portion of attack

func enable_attack_hitbox() -> void:
	# Reset attack hit tracking - called when attack starts
	print("Bobba: enable_attack_hitbox() - resetting _has_hit_this_attack to false")
	_has_hit_this_attack = false
	_attack_anim_progress = 0.0
	_hitbox_active_window = false
	# Keep hitboxes monitoring always - we control damage via _hitbox_active_window
	_left_hand_hitbox.monitoring = true
	_right_hand_hitbox.monitoring = true


func disable_attack_hitbox() -> void:
	_hitbox_active_window = false
	_attack_anim_progress = 0.0
	# Keep monitoring on - avoids state confusion when toggling


func _update_attack_hitbox_timing() -> void:
	# Track attack animation progress and set active window for damage dealing
	if state != State.ATTACKING or _anim_player == null:
		_hitbox_active_window = false
		return

	# Calculate animation progress (0.0 to 1.0)
	var anim_length: float = _anim_player.current_animation_length
	var anim_position: float = _anim_player.current_animation_position
	if anim_length > 0:
		_attack_anim_progress = anim_position / anim_length
	else:
		_attack_anim_progress = 0.0

	# Active window is when hands are swinging (30% to 70% of animation)
	var should_be_active: bool = _attack_anim_progress >= HAND_HITBOX_START and _attack_anim_progress <= HAND_HITBOX_END

	if should_be_active and not _hitbox_active_window:
		_hitbox_active_window = true
		print("Bobba: Attack window ACTIVE at progress ", _attack_anim_progress)
	elif not should_be_active and _hitbox_active_window:
		_hitbox_active_window = false
		print("Bobba: Attack window ENDED at progress ", _attack_anim_progress)

	# Check for hits during active window
	if _hitbox_active_window and not _has_hit_this_attack:
		var left_bodies = _left_hand_hitbox.get_overlapping_bodies()
		var right_bodies = _right_hand_hitbox.get_overlapping_bodies()
		if left_bodies.size() > 0 or right_bodies.size() > 0:
			print("Bobba: Overlapping bodies - Left: ", left_bodies.size(), ", Right: ", right_bodies.size())
		for body in left_bodies:
			_on_attack_hitbox_body_entered(body)
			if _has_hit_this_attack:
				return
		for body in right_bodies:
			_on_attack_hitbox_body_entered(body)
			if _has_hit_this_attack:
				return


func take_hit(damage: float, knockback: Vector3, _blocked: bool = false, attacker: Node3D = null) -> void:
	# Flash red when hit
	_flash_hit(Color(1.0, 0.2, 0.2))

	# Show floating "Hit!" label
	_show_hit_label()

	# Switch target to attacker (prioritize who is attacking)
	if attacker:
		_set_attacker_as_target(attacker)

	# Apply knockback (visual feedback is ok locally even in multiplayer)
	if knockback.length() > 0:
		state = State.STUNNED
		_stun_timer = 0.5
		velocity = knockback
		# Force current animation to clear so it can transition properly after stun
		_current_anim = &""

	# In multiplayer, don't apply damage locally - server is authoritative
	# The player will send MSG_ENTITY_DAMAGE to server which updates our health
	if not _is_network_controlled:
		take_damage(damage)
	print("Bobba took hit! Damage: %.1f HP: %.1f/%.1f" % [damage, health, MAX_HEALTH])


## Take damage from any source (arrows, sword, etc.)
func take_damage(amount: float) -> void:
	var old_health = health
	health = maxf(0.0, health - amount)
	print("Bobba: take_damage(%.1f) - HP: %.1f -> %.1f" % [amount, old_health, health])
	health_changed.emit(health, MAX_HEALTH)

	if health <= 0:
		_on_death()


## Called when Bobba dies
func _on_death() -> void:
	print("Bobba died!")
	died.emit()
	state = State.DEAD
	# Play death animation if available
	if _anim_player and _anim_player.has_animation(&"bobba/Dying"):
		_play_anim(&"bobba/Dying")
	# Disable collision and hitboxes
	if _left_hand_hitbox:
		_left_hand_hitbox.monitoring = false
	if _right_hand_hitbox:
		_right_hand_hitbox.monitoring = false


## Update health label when health changes
func _on_health_label_update(current: float, _maximum: float) -> void:
	print("Bobba: _on_health_label_update called with HP=%.1f" % current)
	var health_label = get_node_or_null("HealthLabel")
	if health_label == null:
		print("Bobba: WARNING - HealthLabel not found!")
		return
	health_label.text = "%.0f / %.0f" % [current, MAX_HEALTH]
	print("Bobba: Updated health label to: ", health_label.text)
	# Change color based on health
	var health_pct = current / MAX_HEALTH
	if health_pct > 0.5:
		health_label.modulate = Color(0.3, 1.0, 0.3)  # Green
	elif health_pct > 0.25:
		health_label.modulate = Color(1.0, 0.8, 0.2)  # Yellow
	else:
		health_label.modulate = Color(1.0, 0.3, 0.3)  # Red


## Take damage from arrow (causes retreat behavior)
func take_arrow_hit(arrow_position: Vector3, arrow_node: Node3D = null) -> void:
	# Flash orange for arrow hit
	_flash_hit(Color(1.0, 0.6, 0.2))
	_show_hit_label()

	# In multiplayer, don't apply damage locally - server is authoritative
	# The arrow will send MSG_ENTITY_DAMAGE to server which updates our health
	if not _is_network_controlled:
		take_damage(ARROW_DAMAGE)

	# Start retreat behavior - walk away from arrow (visual feedback is ok locally)
	_is_retreating = true
	_retreat_timer = RETREAT_DURATION
	_retreat_direction = (global_position - arrow_position).normalized()
	_retreat_direction.y = 0  # Keep on ground plane

	# Track the ground fire position for avoidance
	if arrow_node:
		_register_ground_fire(arrow_position)

	print("Bobba hit by arrow! Retreating. HP: %.1f/%.1f" % [health, MAX_HEALTH])


## Register a ground fire position to avoid
func _register_ground_fire(pos: Vector3) -> void:
	_ground_fires.append({"position": pos, "time": Time.get_ticks_msec()})
	# Clean up old fires (older than 30 seconds)
	var current_time := Time.get_ticks_msec()
	_ground_fires = _ground_fires.filter(func(fire): return current_time - fire.time < 30000)


## Check if a position is too close to any ground fire
func _is_near_fire(pos: Vector3) -> bool:
	for fire in _ground_fires:
		var fire_pos: Vector3 = fire.position
		fire_pos.y = pos.y  # Compare on same Y level
		if pos.distance_to(fire_pos) < FIRE_AVOID_RADIUS:
			return true
	return false


## Get direction to avoid nearby fires
func _get_fire_avoidance_direction() -> Vector3:
	var avoidance := Vector3.ZERO
	for fire in _ground_fires:
		var fire_pos: Vector3 = fire.position
		fire_pos.y = global_position.y
		var dist := global_position.distance_to(fire_pos)
		if dist < FIRE_AVOID_RADIUS * 2:
			# Push away from fire, stronger when closer
			var away := (global_position - fire_pos).normalized()
			avoidance += away * (1.0 - dist / (FIRE_AVOID_RADIUS * 2))
	return avoidance.normalized() if avoidance.length() > 0.1 else Vector3.ZERO


func _show_hit_label() -> void:
	if _hit_label == null:
		return

	# Reset and show the label
	_hit_label.visible = true
	_hit_label.position = Vector3(0, 3.0, 0)
	_hit_label.modulate.a = 1.0
	_hit_label.scale = Vector3(0.5, 0.5, 0.5)

	# Animate: scale up, float up, fade out
	var tween = create_tween()
	tween.set_parallel(true)
	tween.tween_property(_hit_label, "scale", Vector3(1.0, 1.0, 1.0), 0.15).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
	tween.tween_property(_hit_label, "position", Vector3(0, 4.0, 0), 0.6).set_ease(Tween.EASE_OUT)
	tween.tween_property(_hit_label, "modulate:a", 0.0, 0.4).set_delay(0.2)
	tween.chain().tween_callback(func(): _hit_label.visible = false)


func _flash_hit(color: Color) -> void:
	if _hit_flash_tween:
		_hit_flash_tween.kill()

	# Apply color tint to model
	if _model:
		_apply_hit_flash_recursive(_model, color)

		# Reset after short delay
		_hit_flash_tween = create_tween()
		_hit_flash_tween.tween_callback(func(): _clear_hit_flash_recursive(_model)).set_delay(0.15)


func _apply_hit_flash_recursive(node: Node, color: Color) -> void:
	if node is MeshInstance3D:
		var mesh_inst := node as MeshInstance3D
		if mesh_inst.material_override:
			var mat = mesh_inst.material_override
			if mat is StandardMaterial3D:
				mat.emission_enabled = true
				mat.emission = color
				mat.emission_energy_multiplier = 3.0

	for child in node.get_children():
		_apply_hit_flash_recursive(child, color)


func _clear_hit_flash_recursive(node: Node) -> void:
	if node is MeshInstance3D:
		var mesh_inst := node as MeshInstance3D
		if mesh_inst.material_override:
			var mat = mesh_inst.material_override
			if mat is StandardMaterial3D:
				mat.emission_enabled = false

	for child in node.get_children():
		_clear_hit_flash_recursive(child)


func _check_needs_material(node: Node) -> bool:
	# Check if any mesh has a valid albedo texture
	if node is MeshInstance3D:
		var mesh_inst := node as MeshInstance3D
		if mesh_inst.mesh:
			for i in range(mesh_inst.mesh.get_surface_count()):
				var mat = mesh_inst.get_surface_override_material(i)
				if mat == null:
					mat = mesh_inst.mesh.surface_get_material(i)
				if mat is StandardMaterial3D:
					var std_mat = mat as StandardMaterial3D
					if std_mat.albedo_texture != null:
						print("Bobba: Found existing texture on ", mesh_inst.name)
						return false
	for child in node.get_children():
		if not _check_needs_material(child):
			return false
	return true


func _apply_textures(node: Node) -> void:
	# Load the pre-made material with textures
	var bobba_mat = load("res://assets/bobba/bobba_material.tres") as StandardMaterial3D
	if bobba_mat == null:
		print("Bobba: Failed to load material!")
		return

	_apply_material_recursive(node, bobba_mat)


func _apply_material_recursive(node: Node, mat: Material) -> void:
	print("Bobba: Checking node ", node.name, " [", node.get_class(), "]")

	if node is MeshInstance3D:
		var mesh_inst := node as MeshInstance3D
		print("Bobba: Found MeshInstance3D: ", mesh_inst.name)

		# Apply material override to the entire mesh
		mesh_inst.material_override = mat
		print("Bobba: Applied material_override")

		# Also try applying to individual surfaces
		if mesh_inst.mesh:
			var surface_count = mesh_inst.mesh.get_surface_count()
			print("Bobba: Mesh has ", surface_count, " surfaces")
			for i in range(surface_count):
				mesh_inst.set_surface_override_material(i, mat)
				print("Bobba: Applied to surface ", i)

	for child in node.get_children():
		_apply_material_recursive(child, mat)


func _find_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node as AnimationPlayer
	for child in node.get_children():
		var result = _find_animation_player(child)
		if result:
			return result
	return null


func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node as Skeleton3D
	for child in node.get_children():
		var result = _find_skeleton(child)
		if result:
			return result
	return null


func _load_animations() -> void:
	if _anim_player == null or _model == null:
		return

	var skeleton: Skeleton3D = _find_skeleton(_model)
	if skeleton == null:
		print("Bobba: No skeleton found")
		return

	var anim_root: Node = _anim_player.get_node(_anim_player.root_node)
	var skel_path: String = str(anim_root.get_path_to(skeleton))

	var anim_config: Dictionary = {
		"idle": ["Idle", true],
		"walk": ["Walk", true],
		"run": ["Run", true],
		"attack": ["Attack", false],
		"roar": ["Roar", false],
		"dying": ["Dying", false],
		"jump_attack": ["JumpAttack", false],
	}

	for anim_key in ANIM_PATHS:
		var fbx_path: String = ANIM_PATHS[anim_key]
		var scene: PackedScene = load(fbx_path) as PackedScene
		if scene == null:
			print("Bobba: Failed to load animation: ", fbx_path)
			continue

		var instance: Node3D = scene.instantiate()
		var anim_player_src: AnimationPlayer = _find_animation_player(instance)
		if anim_player_src == null:
			instance.queue_free()
			continue

		# Find best animation
		var best_anim: Animation = null
		var best_key_count: int = 0

		for src_lib_name in anim_player_src.get_animation_library_list():
			var src_lib: AnimationLibrary = anim_player_src.get_animation_library(src_lib_name)
			for src_anim_name in src_lib.get_animation_list():
				var anim: Animation = src_lib.get_animation(src_anim_name)
				var total_keys: int = 0
				for t in range(anim.get_track_count()):
					total_keys += anim.track_get_key_count(t)
				if total_keys > best_key_count:
					best_anim = anim
					best_key_count = total_keys

		if best_anim != null:
			var new_anim: Animation = best_anim.duplicate()
			var config: Array = anim_config.get(anim_key, [anim_key, false])
			new_anim.loop_mode = Animation.LOOP_LINEAR if config[1] else Animation.LOOP_NONE

			# Retarget animation
			_retarget_animation(new_anim, skel_path, skeleton)

			var lib_name: StringName = &"bobba"
			if not _anim_player.has_animation_library(lib_name):
				_anim_player.add_animation_library(lib_name, AnimationLibrary.new())
			_anim_player.get_animation_library(lib_name).add_animation(StringName(config[0]), new_anim)
			print("Bobba: Loaded animation bobba/", config[0])

		instance.queue_free()


func _retarget_animation(anim: Animation, target_skeleton_path: String, skeleton: Skeleton3D) -> void:
	var tracks_to_remove: Array[int] = []

	# Debug: print skeleton bone names once
	if skeleton.get_bone_count() > 0:
		print("Bobba: Skeleton has ", skeleton.get_bone_count(), " bones")
		print("Bobba: First few bones: ", skeleton.get_bone_name(0), ", ", skeleton.get_bone_name(1) if skeleton.get_bone_count() > 1 else "")

	for i in range(anim.get_track_count()):
		var track_path: NodePath = anim.track_get_path(i)
		var path_str: String = str(track_path)

		# Find the bone name part (after the last colon for skeleton tracks)
		var colon_pos: int = path_str.rfind(":")
		if colon_pos == -1:
			continue

		var bone_name: String = path_str.substr(colon_pos + 1)

		# Convert animation bone names (mixamorig:BoneName) to Godot format (mixamorig_BoneName)
		var godot_bone_name: String = bone_name.replace(":", "_")

		# Remove root motion from Hips
		if godot_bone_name == "mixamorig_Hips" and anim.track_get_type(i) == Animation.TYPE_POSITION_3D:
			tracks_to_remove.append(i)
			continue

		# Verify bone exists in skeleton
		if skeleton.find_bone(godot_bone_name) == -1:
			# Try original name as fallback
			if skeleton.find_bone(bone_name) != -1:
				godot_bone_name = bone_name
			else:
				print("Bobba: Bone not found: ", bone_name, " / ", godot_bone_name)
				continue

		var new_path: String = target_skeleton_path + ":" + godot_bone_name
		anim.track_set_path(i, NodePath(new_path))

	tracks_to_remove.reverse()
	for track_idx in tracks_to_remove:
		anim.remove_track(track_idx)


func _play_anim(anim_name: StringName) -> void:
	if _anim_player == null:
		return
	if _current_anim == anim_name:
		return  # Already playing this animation
	if _anim_player.has_animation(anim_name):
		_anim_player.play(anim_name)
		_current_anim = anim_name


func _on_animation_finished(anim_name: StringName) -> void:
	print("Bobba: Animation finished: ", anim_name)
	if anim_name == &"bobba/Attack" or anim_name == &"bobba/JumpAttack":
		print("Bobba: Attack animation finished, setting cooldown and state=CHASING")
		disable_attack_hitbox()
		attack_cooldown = 0.5
		state = State.CHASING
		_current_anim = &""  # Clear so attack can replay
		_attack_state_time = 0.0  # Reset attack timer
	elif anim_name == &"bobba/Roar":
		# After roar finishes, start chasing
		state = State.CHASING
		_current_anim = &""  # Clear so next animation can play
	# Note: Dying animation should not auto-recover - handled separately when health system is added


func _pick_new_roam_direction() -> void:
	var angle = randf() * TAU
	roam_direction = Vector3(cos(angle), 0, sin(angle))
	roam_timer = ROAM_CHANGE_TIME


func _physics_process(delta: float) -> void:
	if attack_cooldown > 0:
		attack_cooldown -= delta

	# Update hand hitbox timing based on attack animation progress
	_update_attack_hitbox_timing()

	# Network-controlled mode: interpolate to received position
	if _is_network_controlled:
		_handle_network_interpolation(delta)
		return

	# TEST_MULTIPLAYER mode: disable AI, just idle in place
	if GameSettings and GameSettings.test_multiplayer:
		_play_anim(&"bobba/Idle")
		velocity += gravity * delta
		move_and_slide()
		return

	# Dead - don't process further
	if health <= 0:
		return

	# Apply gravity
	velocity += gravity * delta

	# Handle retreat behavior (from arrow hits)
	if _is_retreating:
		_handle_retreat(delta)
		move_and_slide()
		return

	# Update target selection (handles detection/lose radius logic)
	_select_target()

	# Check distance to target
	var distance_to_target: float = INF
	if target and is_instance_valid(target):
		distance_to_target = global_position.distance_to(target.global_position)

	# State machine (host only)
	match state:
		State.ROAMING:
			_handle_roaming(delta, distance_to_target)
		State.CHASING:
			_handle_chasing(delta, distance_to_target)
		State.ATTACKING:
			_handle_attacking(delta)
		State.IDLE:
			_handle_idle(delta, distance_to_target)
		State.STUNNED:
			_handle_stunned(delta)
		State.DEAD:
			pass  # Don't move when dead

	move_and_slide()


## Handle retreat behavior after being hit by arrow
func _handle_retreat(delta: float) -> void:
	_retreat_timer -= delta

	if _retreat_timer <= 0:
		_is_retreating = false
		state = State.ROAMING
		_pick_new_roam_direction()
		return

	# Move away from the arrow hit location
	var move_dir := _retreat_direction

	# Also avoid fire while retreating
	var fire_avoid := _get_fire_avoidance_direction()
	if fire_avoid.length() > 0.1:
		move_dir = (move_dir + fire_avoid).normalized()

	velocity.x = move_dir.x * RETREAT_SPEED
	velocity.z = move_dir.z * RETREAT_SPEED

	# Face retreat direction
	if move_dir.length() > 0.1:
		var target_angle := atan2(move_dir.x, move_dir.z)
		_model.rotation.y = lerp_angle(_model.rotation.y, target_angle, ROTATION_SPEED * delta)

	# Play walk animation while retreating
	_play_anim(&"bobba/Walk")


## Handle interpolation for network-controlled entities
func _handle_network_interpolation(delta: float) -> void:
	# Smoothly interpolate to target position
	const INTERP_SPEED = 10.0
	global_position = global_position.lerp(_target_position, INTERP_SPEED * delta)

	# Interpolate rotation
	if _model:
		_model.rotation.y = lerp_angle(_model.rotation.y, _target_rotation, INTERP_SPEED * delta)

	# Apply gravity (still needed even in network mode)
	if not is_on_floor():
		velocity.y -= 22.0 * delta
	else:
		velocity.y = 0
	move_and_slide()


## Get network state for synchronization (called by NetworkManager)
func get_network_state() -> int:
	return state


## Get facing rotation (model rotation for network sync)
func get_facing_rotation() -> float:
	if _model:
		return _model.rotation.y
	return rotation.y


## Apply network state received from host (called by NetworkManager on clients)
func apply_network_state(data: Dictionary) -> void:
	if not _is_network_controlled:
		return  # Host doesn't apply network state

	_target_position = data.get("position", global_position)
	_target_rotation = data.get("rotation_y", _target_rotation)

	var new_state = data.get("state", state)
	if new_state != state:
		state = new_state
		# Update animation based on new state
		_update_animation_for_state()

	var old_health = health
	var new_health = data.get("health", health)
	if new_health != old_health:
		health = new_health
		health_changed.emit(health, MAX_HEALTH)

		# Handle respawn: if health went from 0 to positive, re-enable hitboxes
		if old_health <= 0 and new_health > 0:
			print("Bobba: Respawned via network state")
			if _left_hand_hitbox:
				_left_hand_hitbox.monitoring = true
			if _right_hand_hitbox:
				_right_hand_hitbox.monitoring = true


## Update animation to match current state
func _update_animation_for_state() -> void:
	match state:
		State.ROAMING:
			_play_anim(&"bobba/Walk")
		State.CHASING:
			_play_anim(&"bobba/Run")
		State.ATTACKING:
			_play_anim(&"bobba/Attack")
		State.IDLE:
			_play_anim(&"bobba/Idle")
		State.STUNNED:
			_play_anim(&"bobba/Idle")
		State.DEAD:
			_play_anim(&"bobba/Dying")


func _handle_roaming(delta: float, distance_to_target: float) -> void:
	# Target selection already switched state to CHASING if target found
	# Just check if we somehow have a target while roaming
	if target and is_instance_valid(target):
		state = State.CHASING
		_play_anim(&"bobba/Roar")
		return

	# Update roam timer
	roam_timer -= delta
	if roam_timer <= 0:
		_pick_new_roam_direction()

	# Calculate movement direction with fire avoidance
	var move_dir := roam_direction
	var fire_avoid := _get_fire_avoidance_direction()
	if fire_avoid.length() > 0.1:
		# Blend avoidance with roam direction, prioritizing fire avoidance
		move_dir = (move_dir + fire_avoid * 2.0).normalized()

	# Move in adjusted direction
	var horizontal_velocity = move_dir * ROAM_SPEED
	velocity.x = horizontal_velocity.x
	velocity.z = horizontal_velocity.z

	# Rotate to face movement direction
	if _model and move_dir.length() > 0.1:
		var target_rot = atan2(move_dir.x, move_dir.z)
		_model.rotation.y = lerp_angle(_model.rotation.y, target_rot, ROTATION_SPEED * delta)

	_play_anim(&"bobba/Walk")


func _handle_chasing(delta: float, distance_to_target: float) -> void:
	# If target escapes beyond LOSE_RADIUS, _select_target will clear it
	# Here we just check if we lost target
	if target == null or not is_instance_valid(target):
		state = State.ROAMING
		_pick_new_roam_direction()
		return

	# If close enough, attack
	if distance_to_target <= ATTACK_DISTANCE and attack_cooldown <= 0:
		print("Bobba: Starting new attack (distance=%.1f, cooldown=%.2f)" % [distance_to_target, attack_cooldown])
		state = State.ATTACKING
		_play_anim(&"bobba/Attack")
		enable_attack_hitbox()  # Enable hitbox when attack starts
		velocity.x = 0
		velocity.z = 0
		return

	# Chase the target with fire avoidance
	var direction: Vector3 = (target.global_position - global_position).normalized()
	direction.y = 0

	# Check for fire in the path and avoid it
	var fire_avoid: Vector3 = _get_fire_avoidance_direction()
	var move_dir: Vector3 = direction
	if fire_avoid.length() > 0.1:
		# Blend chase direction with fire avoidance
		# Use less avoidance weight when chasing to still pursue target
		move_dir = (direction + fire_avoid * 1.5).normalized()

	var horizontal_velocity = move_dir * CHASE_SPEED
	velocity.x = horizontal_velocity.x
	velocity.z = horizontal_velocity.z

	# Rotate to face movement direction (not target, since we might be dodging fire)
	if _model and move_dir.length() > 0.1:
		var target_rot = atan2(move_dir.x, move_dir.z)
		_model.rotation.y = lerp_angle(_model.rotation.y, target_rot, ROTATION_SPEED * delta)

	_play_anim(&"bobba/Run")


var _attack_state_time: float = 0.0

func _handle_attacking(delta: float) -> void:
	# Stay in attacking state until animation finishes
	velocity.x = 0
	velocity.z = 0
	_attack_state_time += delta
	# Debug: warn if stuck in attacking state too long
	if _attack_state_time > 3.0:
		print("Bobba: WARNING - Stuck in ATTACKING state for %.1f seconds! Animation: %s" % [_attack_state_time, _current_anim])
		_attack_state_time = 0.0  # Reset to avoid spam


func _handle_stunned(delta: float) -> void:
	# Decelerate knockback velocity
	velocity.x = move_toward(velocity.x, 0, 20.0 * delta)
	velocity.z = move_toward(velocity.z, 0, 20.0 * delta)

	# Play idle during stun (no special stun animation available)
	_play_anim(&"bobba/Idle")

	_stun_timer -= delta
	if _stun_timer <= 0:
		# Return to chasing if we have a target, otherwise roam
		if target and is_instance_valid(target):
			state = State.CHASING
		else:
			state = State.ROAMING
			_pick_new_roam_direction()
		_current_anim = &""  # Clear to allow new animation


func _handle_idle(delta: float, distance_to_target: float) -> void:
	# Target selection handles detection, just check if we have a target
	if target and is_instance_valid(target):
		state = State.CHASING
	else:
		# Randomly start roaming
		if randf() < 0.01:
			state = State.ROAMING
			_pick_new_roam_direction()

	_play_anim(&"bobba/Idle")
