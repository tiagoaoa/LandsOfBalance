class_name Dragon
extends CharacterBody3D

## Ancient Dragon that patrols the map flying, lands on hills, and attacks nearby players
## Network-synchronized across all players.
##
## Behavior:
## - Flies in oval patrol pattern around player start area
## - After 2 laps, flies to and lands on the main hill
## - Waits for 5 seconds (idle animation)
## - Takes off and resumes patrol
## - Attacks player if within range while landed

const DragonWingFlapClass := preload("res://enemies/dragon_wing_flap.gd")

# Use Protocol.DragonState for network sync compatibility
const Proto = preload("res://multiplayer/protocol.gd")
const DragonState = Proto.DragonState

signal lap_completed(lap_number: int)
signal state_changed(new_state: int)

# Network synchronization
var entity_id: int = 0
var health: float = 500.0  # Dragon has more health
var _is_network_controlled: bool = false
var _target_position: Vector3 = Vector3.ZERO
var _target_rotation: float = 0.0
var lap_count: int = 0  # For network sync

# Patrol settings
@export var patrol_radius: float = 15.0  # Radius of patrol circle
@export var patrol_height: float = 10.0  # Flying height (5-15 units above ground)
@export var patrol_speed: float = 5.0    # Flying speed
@export var laps_before_landing: int = 2 # Land after this many laps

# Landing settings
@export var landing_spot: Vector3 = Vector3(0, 1, 10)  # Where to land (top of hill)
@export var wait_time: float = 5.0  # Seconds to wait when landed

# Combat settings
@export var attack_range: float = 25.0   # Distance to trigger attack when landed
@export var detection_range: float = 50.0  # Distance to detect player

# State
var state: int = DragonState.PATROL:
	set(value):
		var old_state := state
		state = value
		if old_state != state:
			state_changed.emit(state)
			print("Dragon state: ", Proto.DragonState.keys()[state])

var patrol_angle: float = 0.0  # Current angle in circular patrol
var patrol_center: Vector3 = Vector3.ZERO
var laps_completed: int = 0
var wait_timer: float = 0.0
var target_player: Node3D = null

# Orientation tracking for smooth banking
var _last_direction: Vector3 = Vector3.FORWARD
var _current_bank_angle: float = 0.0
var _target_basis: Basis = Basis.IDENTITY

# Components
var _model: Node3D
var _anim_player: AnimationPlayer
var _anim_tree: AnimationTree

# Animation names (Elder Scrolls Blades dragon)
var anim_fly: StringName = &""
var anim_idle: StringName = &""
var anim_attack: StringName = &""
var anim_land: StringName = &""
var anim_takeoff: StringName = &""

@onready var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")


func _ready() -> void:
	# Load and setup dragon model
	_setup_dragon_model()

	# Add collision shape
	_setup_collision()

	# Set initial position - center patrol on player start position
	patrol_center = Vector3(0, 0, 10)  # Player starts at (0, 1, 10)
	patrol_angle = 0.0
	position = _get_patrol_position()

	# Find player
	await get_tree().process_frame
	_find_player()

	# Setup network
	_setup_network()

	print("Dragon ready! Animations found: ", _get_animation_list())


func _setup_network() -> void:
	# Generate unique entity ID
	entity_id = get_instance_id() % 1000000 + 100000  # Offset to avoid collision with Bobba IDs

	# Register with NetworkManager if available
	if has_node("/root/NetworkManager"):
		var network_manager = get_node("/root/NetworkManager")
		network_manager.register_entity(self, Proto.EntityType.ENTITY_DRAGON, entity_id)

		# Wait for network manager to determine host status
		await get_tree().process_frame
		await get_tree().process_frame
		_is_network_controlled = not network_manager.is_host
		if _is_network_controlled:
			print("Dragon [%d]: Network-controlled (client mode)" % entity_id)
		else:
			print("Dragon [%d]: Locally-controlled (host mode)" % entity_id)


func _exit_tree() -> void:
	# Unregister from NetworkManager
	if has_node("/root/NetworkManager"):
		var network_manager = get_node("/root/NetworkManager")
		network_manager.unregister_entity(entity_id)


func _setup_dragon_model() -> void:
	# Load the dragon GLB
	var dragon_scene: PackedScene = load("res://assets/dragon.glb") as PackedScene
	if dragon_scene == null:
		push_error("Dragon: Failed to load dragon.glb")
		return

	_model = dragon_scene.instantiate()
	_model.name = "DragonModel"
	add_child(_model)

	# Scale dragon appropriately (adjust based on model size)
	# Elder Scrolls Blades dragon models are large, so scale down
	_model.scale = Vector3(0.5, 0.5, 0.5)  # Larger scale for visibility

	# Find AnimationPlayer
	_anim_player = _find_animation_player(_model)
	if _anim_player:
		_anim_player.animation_finished.connect(_on_animation_finished)
		# Create procedural wing flap animation for flying
		DragonWingFlapClass.add_to_animation_player(_anim_player, &"WingFlap")
		_detect_animations()
		print("Dragon AnimationPlayer found with ", _anim_player.get_animation_list().size(), " animations")
	else:
		push_warning("Dragon: No AnimationPlayer found")


func _setup_collision() -> void:
	# Check if collision shape already exists (added in scene file)
	var existing_collision := get_node_or_null("CollisionShape3D")
	if existing_collision:
		print("Dragon: Using existing collision shape from scene")
	else:
		# Create collision shape for the dragon body using ConvexPolygonShape3D
		var collision := CollisionShape3D.new()
		collision.name = "CollisionShape3D"

		# Create a convex polygon shape that roughly matches dragon silhouette
		var shape := ConvexPolygonShape3D.new()

		# Define vertices for a dragon-shaped convex hull (scaled for 0.5 model scale)
		# Body is roughly 4m long, 1.5m wide, 2m tall
		var points := PackedVector3Array([
			# Body front (head area)
			Vector3(0.0, 1.0, 2.5),      # Nose tip
			Vector3(-0.4, 0.8, 2.0),     # Head left
			Vector3(0.4, 0.8, 2.0),      # Head right
			Vector3(0.0, 1.5, 1.5),      # Head top

			# Body middle (torso)
			Vector3(-1.0, 0.5, 0.0),     # Body left bottom
			Vector3(1.0, 0.5, 0.0),      # Body right bottom
			Vector3(-1.2, 1.5, 0.0),     # Body left top
			Vector3(1.2, 1.5, 0.0),      # Body right top
			Vector3(0.0, 2.0, 0.0),      # Back ridge

			# Wing attachment points (widest part)
			Vector3(-2.5, 1.0, -0.5),    # Left wing root
			Vector3(2.5, 1.0, -0.5),     # Right wing root

			# Body rear (hip area)
			Vector3(-0.8, 0.5, -1.5),    # Rear left bottom
			Vector3(0.8, 0.5, -1.5),     # Rear right bottom
			Vector3(-0.6, 1.2, -1.5),    # Rear left top
			Vector3(0.6, 1.2, -1.5),     # Rear right top

			# Tail base
			Vector3(0.0, 0.8, -2.5),     # Tail tip
		])

		shape.points = points
		collision.shape = shape
		collision.position = Vector3(0, 0.5, 0)  # Offset up slightly

		add_child(collision)

	# Set collision layers - dragon is on layer 2 (enemies)
	collision_layer = 2
	collision_mask = 1  # Collides with layer 1 (player/world)


func _find_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node as AnimationPlayer
	for child in node.get_children():
		var result := _find_animation_player(child)
		if result:
			return result
	return null


func _detect_animations() -> void:
	if not _anim_player:
		return

	var anims := _get_animation_list()
	print("Dragon animations: ", anims)

	# Use our procedural WingFlap animation for flying
	if _anim_player.has_animation(&"WingFlap"):
		anim_fly = &"WingFlap"
		print("Dragon: Using procedural WingFlap animation for flying")

	# Try to match animations by common naming patterns
	for anim_name in anims:
		var lower := anim_name.to_lower()

		if anim_fly == &"" and ("fly" in lower or "glide" in lower or "hover" in lower):
			anim_fly = anim_name
		elif lower.ends_with("patrol_idle"):  # Prefer base patrol_idle (not random variants)
			anim_idle = anim_name
		elif "idle" in lower and "fly" not in lower and "recoil" not in lower:
			if anim_idle == &"":  # Only if not already set
				anim_idle = anim_name
		elif "powerattack" in lower or "power_attack" in lower:
			anim_attack = anim_name  # Prioritize power attack
		elif ("attack" in lower or "bite" in lower) and anim_attack == &"":
			anim_attack = anim_name
		elif "land" in lower and "take" not in lower:
			anim_land = anim_name
		elif "take" in lower and "off" in lower:
			anim_takeoff = anim_name

	# Fallbacks - use first animation containing keywords
	if anim_fly == &"":
		for anim_name in anims:
			if "fly" in anim_name.to_lower():
				anim_fly = anim_name
				break

	if anim_idle == &"":
		for anim_name in anims:
			if "idle" in anim_name.to_lower():
				anim_idle = anim_name
				break

	# If still no fly animation, use idle as fallback
	if anim_fly == &"" and anim_idle != &"":
		anim_fly = anim_idle

	print("Detected - Fly: ", anim_fly, ", Idle: ", anim_idle, ", Attack: ", anim_attack)


func _get_animation_list() -> PackedStringArray:
	var result := PackedStringArray()
	if not _anim_player:
		return result

	for lib_name in _anim_player.get_animation_library_list():
		var lib := _anim_player.get_animation_library(lib_name)
		for anim_name in lib.get_animation_list():
			if lib_name == &"":
				result.append(anim_name)
			else:
				result.append(str(lib_name) + "/" + str(anim_name))

	return result


func _find_player() -> void:
	# Find player in the scene
	var players := get_tree().get_nodes_in_group("player")
	if players.size() > 0:
		target_player = players[0]
	else:
		# Try to find by class name
		for node in get_tree().get_nodes_in_group(""):
			if node is CharacterBody3D and node.name == "Player":
				target_player = node
				break

		# Last resort - find any Player node
		if target_player == null:
			target_player = get_tree().root.find_child("Player", true, false)


func _get_patrol_position() -> Vector3:
	# Oval patrol path with slight height variation for realism
	var x := patrol_center.x + cos(patrol_angle) * patrol_radius
	var z := patrol_center.z + sin(patrol_angle) * patrol_radius * 0.7  # Oval shape
	var y := patrol_height + sin(patrol_angle * 2) * 1.5  # Gentle undulation
	return Vector3(x, y, z)


func _physics_process(delta: float) -> void:
	# Network-controlled mode: interpolate to received position
	if _is_network_controlled:
		_handle_network_interpolation(delta)
		return

	# Host controls the dragon AI
	match state:
		DragonState.PATROL:
			_process_patrol(delta)
		DragonState.FLYING_TO_LAND:
			_process_flying_to_land(delta)
		DragonState.LANDING:
			_process_landing(delta)
		DragonState.WAIT:
			_process_wait(delta)
		DragonState.TAKING_OFF:
			_process_takeoff(delta)
		DragonState.ATTACKING:
			_process_attacking(delta)

	# Update lap_count for network sync
	lap_count = laps_completed

	move_and_slide()


## Handle interpolation for network-controlled entities
func _handle_network_interpolation(delta: float) -> void:
	const INTERP_SPEED = 8.0

	# Smoothly interpolate to target position
	global_position = global_position.lerp(_target_position, INTERP_SPEED * delta)

	# Interpolate rotation
	if _model:
		_model.rotation.y = lerp_angle(_model.rotation.y, _target_rotation, INTERP_SPEED * delta)

	move_and_slide()


## Get network state for synchronization
func get_network_state() -> int:
	return state


## Apply network state received from host
func apply_network_state(data: Dictionary) -> void:
	if not _is_network_controlled:
		return

	_target_position = data.get("position", global_position)
	_target_rotation = data.get("rotation_y", _target_rotation)

	var new_state = data.get("state", state)
	if new_state != state:
		state = new_state
		_update_animation_for_state()

	health = data.get("health", health)

	# Extra data for dragon
	lap_count = data.get("extra1", lap_count)
	patrol_angle = data.get("extra2", patrol_angle)


## Update animation to match current state
func _update_animation_for_state() -> void:
	match state:
		DragonState.PATROL, DragonState.FLYING_TO_LAND, DragonState.TAKING_OFF:
			_play_animation(anim_fly, true)
		DragonState.LANDING:
			_play_animation(anim_land, false)
		DragonState.WAIT:
			_play_animation(anim_idle, true)
		DragonState.ATTACKING:
			_play_animation(anim_attack, false)


func _process_patrol(delta: float) -> void:
	# Play fly animation
	_play_animation(anim_fly, true)

	# Move along circular patrol path
	patrol_angle += (patrol_speed / patrol_radius) * delta

	# Check for lap completion
	if patrol_angle >= TAU:
		patrol_angle -= TAU
		laps_completed += 1
		lap_completed.emit(laps_completed)
		print("Dragon completed lap ", laps_completed)

		# Land after specified number of laps
		if laps_completed >= laps_before_landing:
			laps_completed = 0
			state = DragonState.FLYING_TO_LAND
			return

	# Move towards patrol position
	var target_pos := _get_patrol_position()
	var direction := (target_pos - position).normalized()
	velocity = direction * patrol_speed

	# Rotate dragon to face movement direction
	_face_direction(direction, delta)


func _process_flying_to_land(delta: float) -> void:
	_play_animation(anim_fly, true)

	# Fly towards landing spot (approach from above)
	var approach_point := landing_spot + Vector3(0, 5, 0)
	var direction := (approach_point - position).normalized()
	var dist := position.distance_to(approach_point)

	velocity = direction * patrol_speed
	_face_direction(direction, delta)

	# Start landing descent when close
	if dist < 3.0:
		state = DragonState.LANDING
		print("Dragon starting landing descent")
		if anim_land != &"":
			_play_animation(anim_land, false)


func _process_landing(delta: float) -> void:
	# Descend towards landing spot
	var target := landing_spot
	var direction := (target - position).normalized()
	var dist := position.distance_to(target)

	# Slow down as we approach
	var speed: float = clampf(dist * 0.5, 1.0, patrol_speed)
	velocity = direction * speed

	# Rotate to face landing direction
	_face_direction(direction, delta)

	# Check if landed
	if dist < 1.5:
		position = target
		velocity = Vector3.ZERO
		state = DragonState.WAIT
		wait_timer = 0.0
		print("Dragon landed! Waiting for ", wait_time, " seconds")
		_play_animation(anim_idle, true)


func _process_wait(delta: float) -> void:
	# Apply gravity when landed
	if not is_on_floor():
		velocity.y -= gravity * delta
	else:
		velocity.y = 0
		velocity.x = 0
		velocity.z = 0

	# Increment wait timer
	wait_timer += delta

	# Check for nearby player to attack
	if target_player and is_instance_valid(target_player):
		var dist := position.distance_to(target_player.global_position)

		# Face the player
		var dir_to_player := (target_player.global_position - position).normalized()
		_face_direction(dir_to_player, delta)

		if dist < attack_range:
			# Attack!
			_start_attack()
			return

	# Check if wait time complete
	if wait_timer >= wait_time:
		_start_takeoff()


func _start_attack() -> void:
	if state == DragonState.ATTACKING:
		return

	state = DragonState.ATTACKING
	print("Dragon attacking!")

	if anim_attack != &"":
		_play_animation(anim_attack, false)
	else:
		# No attack animation, just roar (return to wait after delay)
		await get_tree().create_timer(2.0).timeout
		state = DragonState.WAIT


func _process_attacking(delta: float) -> void:
	# Stay in place while attacking
	velocity = Vector3.ZERO

	# Keep facing player
	if target_player and is_instance_valid(target_player):
		var dir_to_player := (target_player.global_position - position).normalized()
		_face_direction(dir_to_player, delta)


func _start_takeoff() -> void:
	state = DragonState.TAKING_OFF
	print("Dragon taking off!")

	if anim_takeoff != &"":
		_play_animation(anim_takeoff, false)
	else:
		# No takeoff animation, use fly animation
		_play_animation(anim_fly, true)


func _process_takeoff(delta: float) -> void:
	# Rise up
	velocity = Vector3(0, 8.0, 0)

	# Check if high enough to resume patrol
	if position.y >= patrol_height * 0.8:
		state = DragonState.PATROL
		patrol_angle = 0.0  # Reset patrol angle
		print("Dragon resuming patrol")


func _face_direction(direction: Vector3, delta: float, enable_banking: bool = true) -> void:
	## Orient dragon to face direction with optional banking on turns
	## Banking creates natural flight appearance during circular patrol
	if not _model or direction.length_squared() < 0.01:
		return

	var dir_normalized := direction.normalized()

	# Calculate yaw (Y-axis rotation) to face movement direction
	var target_yaw := atan2(dir_normalized.x, dir_normalized.z)

	# Calculate banking based on turn rate (change in direction)
	var bank_angle := 0.0
	if enable_banking and state == DragonState.PATROL:
		# Compute angular velocity (how fast we're turning)
		var cross := _last_direction.cross(dir_normalized)
		var turn_rate := cross.y  # Positive = turning right, Negative = turning left

		# Bank into the turn (negative roll for right turn, positive for left)
		var max_bank := deg_to_rad(25.0)  # Maximum bank angle
		bank_angle = clampf(-turn_rate * 15.0, -max_bank, max_bank)

		# Smooth the bank angle
		_current_bank_angle = lerp(_current_bank_angle, bank_angle, 3.0 * delta)
	else:
		# No banking when not in patrol (landing, taking off, etc.)
		_current_bank_angle = lerp(_current_bank_angle, 0.0, 5.0 * delta)

	# Calculate slight pitch based on vertical movement
	var pitch := 0.0
	if state == DragonState.PATROL or state == DragonState.FLYING_TO_LAND:
		# Pitch down slightly when descending, up when ascending
		pitch = clampf(-dir_normalized.y * 0.3, deg_to_rad(-15.0), deg_to_rad(15.0))

	# Build target rotation using euler angles (simpler and avoids basis normalization issues)
	# Euler order: YXZ (yaw, pitch, roll)
	# Add 90° Z-axis rotation and 180° Y-axis rotation to correct model orientation
	var z_offset := deg_to_rad(90.0)
	var y_offset := deg_to_rad(180.0)  # Flip to face forward (model faces opposite direction)
	var target_euler := Vector3(pitch, target_yaw + y_offset, _current_bank_angle + z_offset)

	# Smoothly interpolate rotation
	_model.rotation.x = lerp_angle(_model.rotation.x, target_euler.x, 5.0 * delta)
	_model.rotation.y = lerp_angle(_model.rotation.y, target_euler.y, 5.0 * delta)
	_model.rotation.z = lerp_angle(_model.rotation.z, target_euler.z, 5.0 * delta)

	# Store direction for next frame's turn rate calculation
	_last_direction = dir_normalized


func _play_animation(anim_name: StringName, loop: bool = false) -> void:
	if not _anim_player or anim_name == &"":
		return

	if _anim_player.current_animation == anim_name:
		return

	if _anim_player.has_animation(anim_name):
		_anim_player.play(anim_name)


func _on_animation_finished(anim_name: StringName) -> void:
	match state:
		DragonState.ATTACKING:
			# Attack finished, check if player still in range
			if target_player and is_instance_valid(target_player):
				var dist := position.distance_to(target_player.global_position)
				if dist < attack_range:
					# Attack again
					_play_animation(anim_attack, false)
				else:
					state = DragonState.WAIT
					wait_timer = 0.0  # Reset wait timer after attack
			else:
				state = DragonState.WAIT
				wait_timer = 0.0

		DragonState.LANDING:
			state = DragonState.WAIT
			wait_timer = 0.0
			_play_animation(anim_idle, true)

		DragonState.TAKING_OFF:
			state = DragonState.PATROL
			patrol_angle = 0.0
