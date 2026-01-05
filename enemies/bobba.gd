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
var health: float = 100.0
var _is_network_controlled: bool = false  # True for non-host clients
var _target_position: Vector3 = Vector3.ZERO
var _target_rotation: float = 0.0

const ROAM_SPEED: float = 2.0
const CHASE_SPEED: float = 5.0
const ATTACK_RANGE: float = 10.0  # Detection radius in meters
const ATTACK_DISTANCE: float = 2.0  # Distance to start attack animation
const ROAM_CHANGE_TIME: float = 3.0  # Time between direction changes
const ROTATION_SPEED: float = 5.0
const ATTACK_DAMAGE: float = 10.0
const KNOCKBACK_FORCE: float = 12.0

var state: int = State.ROAMING
var player: Node3D = null
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
	_find_player()
	_setup_attack_hitbox()  # Must be before _setup_model which attaches hitboxes to bones
	_setup_model()
	_setup_hit_label()
	_pick_new_roam_direction()
	_setup_network()


func _setup_network() -> void:
	# Generate unique entity ID from instance ID
	entity_id = get_instance_id() % 1000000  # Keep it reasonable size

	# Register with NetworkManager if available
	if has_node("/root/NetworkManager"):
		var network_manager = get_node("/root/NetworkManager")
		network_manager.register_entity(self, Proto.EntityType.ENTITY_BOBBA, entity_id)

		# Check if we're the host - if not, we're network-controlled
		# Wait a frame for the network manager to determine host status
		await get_tree().process_frame
		await get_tree().process_frame
		_is_network_controlled = not network_manager.is_host
		if _is_network_controlled:
			print("Bobba [%d]: Network-controlled (client mode)" % entity_id)
		else:
			print("Bobba [%d]: Locally-controlled (host mode)" % entity_id)


func _exit_tree() -> void:
	# Unregister from NetworkManager
	if has_node("/root/NetworkManager"):
		var network_manager = get_node("/root/NetworkManager")
		network_manager.unregister_entity(entity_id)


func _find_player() -> void:
	# Find the player in the scene
	await get_tree().process_frame
	player = get_tree().get_first_node_in_group("player")
	if player == null:
		# Try to find by class name
		for node in get_tree().get_nodes_in_group(""):
			if node is CharacterBody3D and node.name == "Player":
				player = node
				break
	if player == null:
		# Search entire tree
		player = _find_node_by_name(get_tree().root, "Player")


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
	hitbox.monitoring = false   # Start disabled

	# Create collision shape - sphere for hand/fist
	var collision_shape = CollisionShape3D.new()
	var sphere = SphereShape3D.new()
	sphere.radius = 0.4  # Fist-sized hitbox
	collision_shape.shape = sphere
	collision_shape.position = Vector3.ZERO

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
		print("Bobba: No skeleton found for hand attachments, using fallback")
		add_child(_left_hand_hitbox)
		add_child(_right_hand_hitbox)
		_left_hand_hitbox.position = Vector3(-0.75, 1.5, 0.75)
		_right_hand_hitbox.position = Vector3(0.75, 1.5, 0.75)
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
		print("Bobba: Left hand bone not found, using fallback position")
		add_child(_left_hand_hitbox)
		_left_hand_hitbox.position = Vector3(-0.75, 1.5, 0.75)

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
		print("Bobba: Right hand bone not found, using fallback position")
		add_child(_right_hand_hitbox)
		_right_hand_hitbox.position = Vector3(0.75, 1.5, 0.75)


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


func _on_attack_hitbox_body_entered(body: Node3D) -> void:
	print("Bobba: Hand hitbox detected body: ", body.name, " (class: ", body.get_class(), ")")

	if _has_hit_this_attack:
		print("Bobba: Already hit this attack, ignoring")
		return

	if body == player and player and is_instance_valid(player):
		_has_hit_this_attack = true

		# Calculate knockback direction (from Bobba to player)
		var knockback_dir = (player.global_position - global_position).normalized()
		knockback_dir.y = 0.3  # Add slight upward component

		# Check if player is blocking (is_blocking is a variable, not a method)
		var player_is_blocking: bool = false
		if "is_blocking" in player:
			player_is_blocking = player.is_blocking

		if player_is_blocking:
			# Blocked - reduced knockback, no damage
			if player.has_method("take_hit"):
				player.take_hit(0, knockback_dir * KNOCKBACK_FORCE * 0.3, true)
			print("Bobba: HIT BLOCKED by player")
		else:
			# Not blocked - full damage and knockback
			if player.has_method("take_hit"):
				player.take_hit(ATTACK_DAMAGE, knockback_dir * KNOCKBACK_FORCE, false)
			print("Bobba: HIT LANDED on player")

		attack_landed.emit(player, knockback_dir)
	else:
		print("Bobba: Body is not the player")


func enable_attack_hitbox() -> void:
	# Don't immediately enable - will be enabled based on animation progress
	_has_hit_this_attack = false
	_attack_anim_progress = 0.0


func disable_attack_hitbox() -> void:
	_left_hand_hitbox.monitoring = false
	_right_hand_hitbox.monitoring = false
	_attack_anim_progress = 0.0


func _update_attack_hitbox_timing() -> void:
	# Track attack animation progress and enable hitboxes only during active portion
	if state != State.ATTACKING or _anim_player == null:
		return

	# Calculate animation progress (0.0 to 1.0)
	var anim_length: float = _anim_player.current_animation_length
	var anim_position: float = _anim_player.current_animation_position
	if anim_length > 0:
		_attack_anim_progress = anim_position / anim_length
	else:
		_attack_anim_progress = 0.0

	# Enable hitboxes during the active swipe portion (when hands are swinging)
	var should_be_active: bool = _attack_anim_progress >= HAND_HITBOX_START and _attack_anim_progress <= HAND_HITBOX_END

	if should_be_active and not _left_hand_hitbox.monitoring:
		_left_hand_hitbox.monitoring = true
		_right_hand_hitbox.monitoring = true
		print("Bobba: Hand hitboxes ENABLED at progress ", _attack_anim_progress)
	elif not should_be_active and _left_hand_hitbox.monitoring:
		_left_hand_hitbox.monitoring = false
		_right_hand_hitbox.monitoring = false
		print("Bobba: Hand hitboxes DISABLED at progress ", _attack_anim_progress)


func take_hit(damage: float, knockback: Vector3, _blocked: bool = false) -> void:
	# Flash red when hit
	_flash_hit(Color(1.0, 0.2, 0.2))

	# Show floating "Hit!" label
	_show_hit_label()

	# Apply knockback
	if knockback.length() > 0:
		state = State.STUNNED
		_stun_timer = 0.5
		velocity = knockback
		# Force current animation to clear so it can transition properly after stun
		_current_anim = &""

	print("Bobba took hit! Damage: ", damage, " State: ", state)
	# TODO: Track health when implementing health system


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
		return
	if _anim_player.has_animation(anim_name):
		_anim_player.play(anim_name)
		_current_anim = anim_name


func _on_animation_finished(anim_name: StringName) -> void:
	if anim_name == &"bobba/Attack" or anim_name == &"bobba/JumpAttack":
		disable_attack_hitbox()
		attack_cooldown = 0.5
		state = State.CHASING
	elif anim_name == &"bobba/Roar":
		# After roar finishes, start chasing
		state = State.CHASING
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

	# Apply gravity
	velocity += gravity * delta

	# Check distance to player
	var distance_to_player: float = INF
	if player and is_instance_valid(player):
		distance_to_player = global_position.distance_to(player.global_position)

	# State machine (host only)
	match state:
		State.ROAMING:
			_handle_roaming(delta, distance_to_player)
		State.CHASING:
			_handle_chasing(delta, distance_to_player)
		State.ATTACKING:
			_handle_attacking(delta)
		State.IDLE:
			_handle_idle(delta, distance_to_player)
		State.STUNNED:
			_handle_stunned(delta)

	move_and_slide()


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

	health = data.get("health", health)


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


func _handle_roaming(delta: float, distance_to_player: float) -> void:
	# Check if player is within attack range
	if distance_to_player <= ATTACK_RANGE:
		state = State.CHASING
		_play_anim(&"bobba/Roar")
		return

	# Update roam timer
	roam_timer -= delta
	if roam_timer <= 0:
		_pick_new_roam_direction()

	# Move in roam direction
	var horizontal_velocity = roam_direction * ROAM_SPEED
	velocity.x = horizontal_velocity.x
	velocity.z = horizontal_velocity.z

	# Rotate to face movement direction
	if _model and roam_direction.length() > 0.1:
		var target_rotation = atan2(roam_direction.x, roam_direction.z)
		_model.rotation.y = lerp_angle(_model.rotation.y, target_rotation, ROTATION_SPEED * delta)

	_play_anim(&"bobba/Walk")


func _handle_chasing(delta: float, distance_to_player: float) -> void:
	# If player escapes attack range, go back to roaming
	if distance_to_player > ATTACK_RANGE * 1.5:
		state = State.ROAMING
		_pick_new_roam_direction()
		return

	# If close enough, attack
	if distance_to_player <= ATTACK_DISTANCE and attack_cooldown <= 0:
		state = State.ATTACKING
		_play_anim(&"bobba/Attack")
		enable_attack_hitbox()  # Enable hitbox when attack starts
		velocity.x = 0
		velocity.z = 0
		return

	# Chase the player
	if player and is_instance_valid(player):
		var direction = (player.global_position - global_position).normalized()
		direction.y = 0

		var horizontal_velocity = direction * CHASE_SPEED
		velocity.x = horizontal_velocity.x
		velocity.z = horizontal_velocity.z

		# Rotate to face player
		if _model and direction.length() > 0.1:
			var target_rotation = atan2(direction.x, direction.z)
			_model.rotation.y = lerp_angle(_model.rotation.y, target_rotation, ROTATION_SPEED * delta)

		_play_anim(&"bobba/Run")


func _handle_attacking(_delta: float) -> void:
	# Stay in attacking state until animation finishes
	velocity.x = 0
	velocity.z = 0


func _handle_stunned(delta: float) -> void:
	# Decelerate knockback velocity
	velocity.x = move_toward(velocity.x, 0, 20.0 * delta)
	velocity.z = move_toward(velocity.z, 0, 20.0 * delta)

	# Play idle during stun (no special stun animation available)
	_play_anim(&"bobba/Idle")

	_stun_timer -= delta
	if _stun_timer <= 0:
		state = State.CHASING
		_current_anim = &""  # Clear to allow new animation


func _handle_idle(delta: float, distance_to_player: float) -> void:
	if distance_to_player <= ATTACK_RANGE:
		state = State.CHASING
	else:
		# Randomly start roaming
		if randf() < 0.01:
			state = State.ROAMING
			_pick_new_roam_direction()

	_play_anim(&"bobba/Idle")
