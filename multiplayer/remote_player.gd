extends CharacterBody3D
class_name RemotePlayer

## Represents another player in the multiplayer game
## Receives position updates from the server and interpolates movement
## Supports Archer and Paladin character classes with proper animations

@export var player_id: int = 0
@export var interpolation_speed: float = 20.0

var target_position: Vector3 = Vector3.ZERO
var target_rotation_y: float = 0.0
var current_state: int = 0
var combat_mode: int = 1
var health: float = 100.0
var current_anim_name: String = "Idle"

var _character_model: Node3D
var _anim_player: AnimationPlayer
var _name_label: Label3D
var _current_playing_anim: StringName = &""
var _setup_complete: bool = false

# Use Protocol.PlayerState for network sync compatibility
const Proto = preload("res://multiplayer/protocol.gd")
const STATE_IDLE = Proto.PlayerState.STATE_IDLE
const STATE_WALKING = Proto.PlayerState.STATE_WALKING
const STATE_RUNNING = Proto.PlayerState.STATE_RUNNING
const STATE_ATTACKING = Proto.PlayerState.STATE_ATTACKING
const STATE_BLOCKING = Proto.PlayerState.STATE_BLOCKING
const STATE_JUMPING = Proto.PlayerState.STATE_JUMPING
const STATE_CASTING = Proto.PlayerState.STATE_CASTING
const STATE_DRAWING_BOW = Proto.PlayerState.STATE_DRAWING_BOW
const STATE_HOLDING_BOW = Proto.PlayerState.STATE_HOLDING_BOW

# Archer character and animations (default)
const ARCHER_CHARACTER_PATH = "res://player/character/archer/Archer.fbx"
var ArcherScene: PackedScene = preload("res://player/character/archer/Archer.fbx")
const ARCHER_ANIM_PATHS: Dictionary = {
	"Idle": "res://player/character/archer/Idle.fbx",
	"Walk": "res://player/character/archer/Walk.fbx",
	"Run": "res://player/character/archer/Run.fbx",
	"Jump": "res://player/character/archer/Jump.fbx",
	"Attack": "res://player/character/archer/Attack.fbx",
	"Block": "res://player/character/archer/Block.fbx",
	"Sprint": "res://player/character/archer/Sprint.fbx",
}


func _ready() -> void:
	# Setup collision
	collision_layer = 8  # Layer 4 for remote players
	collision_mask = 1   # Collide with world

	_setup_collision()
	_setup_name_label()
	# Defer character model setup to avoid initialization issues
	call_deferred("_setup_character_model")


func _physics_process(delta: float) -> void:
	# Skip processing until character setup is complete
	if not _setup_complete:
		return

	# Interpolate position (only if we have a target)
	if target_position != Vector3.ZERO:
		global_position = global_position.lerp(target_position, interpolation_speed * delta)

	# Interpolate rotation - apply to model, not body
	if _character_model and is_instance_valid(_character_model):
		_character_model.rotation.y = lerp_angle(_character_model.rotation.y, target_rotation_y, interpolation_speed * delta)

	# Apply gravity and move
	if not is_on_floor():
		velocity.y -= 22.0 * delta
	else:
		velocity.y = 0

	move_and_slide()

	# Update animation based on state
	if _anim_player and is_instance_valid(_anim_player):
		_update_animation()


func update_from_network(data: Dictionary) -> void:
	target_position = data.get("position", target_position)
	target_rotation_y = data.get("rotation_y", target_rotation_y)
	current_state = data.get("state", current_state)
	combat_mode = data.get("combat_mode", combat_mode)
	health = data.get("health", health)
	current_anim_name = data.get("anim_name", current_anim_name)


func _setup_character_model() -> void:
	# Load Archer character (all players start as Archer)
	print("RemotePlayer [%d]: Loading character using preloaded ArcherScene" % player_id)
	var character_scene = ArcherScene
	print("RemotePlayer [%d]: Preloaded scene = %s" % [player_id, character_scene])

	if character_scene == null:
		push_error("RemotePlayer [%d]: ArcherScene preload FAILED!" % player_id)
		_create_fallback_model()
		call_deferred("_finalize_setup")
		return

	_character_model = character_scene.instantiate()
	if _character_model == null:
		push_error("RemotePlayer [%d]: Failed to instantiate character!" % player_id)
		_create_fallback_model()
		call_deferred("_finalize_setup")
		return

	_character_model.name = "Model"
	add_child(_character_model)
	print("RemotePlayer [%d]: Character model instantiated and added" % player_id)

	# Scale character appropriately (same as player.gd)
	var skeleton = _find_skeleton(_character_model)
	print("RemotePlayer [%d]: Found skeleton = %s" % [player_id, skeleton])
	if skeleton and skeleton.get_bone_count() > 0:
		var hips_idx: int = skeleton.find_bone("mixamorig_Hips")
		if hips_idx >= 0:
			var hips_pos: Vector3 = skeleton.get_bone_global_rest(hips_idx).origin
			print("RemotePlayer [%d]: Hips position Y = %f" % [player_id, hips_pos.y])
			if hips_pos.y > 50:
				_character_model.scale = Vector3(0.01, 0.01, 0.01)
			else:
				_character_model.scale = Vector3(1.0, 1.0, 1.0)
		else:
			print("RemotePlayer [%d]: Hips bone not found, using 0.01 scale" % player_id)
			_character_model.scale = Vector3(0.01, 0.01, 0.01)
	else:
		print("RemotePlayer [%d]: No skeleton or no bones, using 0.01 scale" % player_id)
		_character_model.scale = Vector3(0.01, 0.01, 0.01)
	print("RemotePlayer [%d]: Final scale = %s" % [player_id, _character_model.scale])

	# Find existing AnimationPlayer in the model
	_anim_player = _find_animation_player(_character_model)

	if _anim_player == null:
		# Create AnimationPlayer if not found
		_anim_player = AnimationPlayer.new()
		_anim_player.name = "AnimationPlayer"
		_character_model.add_child(_anim_player)

	# Load animations in deferred call
	if skeleton:
		call_deferred("_safe_load_animations", skeleton)

	# Defer animation playback and setup completion to avoid race conditions
	call_deferred("_finalize_setup")


func _finalize_setup() -> void:
	# Play idle animation if available
	if _anim_player and is_instance_valid(_anim_player) and _anim_player.is_inside_tree():
		if _anim_player.has_animation(&"archer/Idle"):
			_anim_player.play(&"archer/Idle")
			_current_playing_anim = &"archer/Idle"
			print("RemotePlayer [%d]: Playing archer/Idle" % player_id)
	_setup_complete = true
	print("RemotePlayer: Setup complete for player %d at position %s" % [player_id, global_position])


func _create_fallback_model() -> void:
	print("RemotePlayer [%d]: CREATING FALLBACK BLUE CAPSULE!" % player_id)
	push_warning("RemotePlayer: Using fallback capsule mesh for player %d" % player_id)
	var mesh_instance = MeshInstance3D.new()
	var capsule = CapsuleMesh.new()
	capsule.radius = 0.4
	capsule.height = 1.8
	mesh_instance.mesh = capsule
	mesh_instance.position.y = 0.9

	var material = StandardMaterial3D.new()
	material.albedo_color = Color(0.2, 0.6, 1.0)  # Blue tint for remote players
	mesh_instance.material_override = material

	add_child(mesh_instance)
	_character_model = mesh_instance


func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node
	for child in node.get_children():
		var result = _find_skeleton(child)
		if result:
			return result
	return null


func _safe_load_animations(skeleton: Skeleton3D) -> void:
	# Safely load animations with error handling
	if not is_instance_valid(_anim_player) or not is_instance_valid(skeleton):
		print("RemotePlayer [%d]: Cannot load animations - invalid references" % player_id)
		return
	if not _anim_player.is_inside_tree() or not skeleton.is_inside_tree():
		print("RemotePlayer [%d]: Cannot load animations - nodes not in tree" % player_id)
		return

	print("RemotePlayer [%d]: Starting deferred animation load" % player_id)
	_load_animations(skeleton)
	print("RemotePlayer [%d]: Animation load complete" % player_id)


func _load_animations(skeleton: Skeleton3D) -> void:
	if _anim_player == null or skeleton == null:
		print("RemotePlayer: Cannot load animations - missing AnimationPlayer or skeleton")
		return

	# Get animation root and skeleton path for retargeting
	var root_path = _anim_player.root_node
	if root_path.is_empty():
		root_path = NodePath("..")
	var anim_root: Node = _anim_player.get_node_or_null(root_path)
	if anim_root == null:
		anim_root = _character_model
	var skel_path: String = str(anim_root.get_path_to(skeleton))

	print("RemotePlayer: Loading animations - skeleton path: ", skel_path)

	# Animation configs: name -> [display_name, loop]
	var anim_configs: Dictionary = {
		"Idle": ["Idle", true],
		"Walk": ["Walk", true],
		"Run": ["Run", true],
		"Jump": ["Jump", false],
		"Attack": ["Attack", false],
		"Block": ["Block", true],
		"Sprint": ["Sprint", true],
	}

	for anim_name in ARCHER_ANIM_PATHS:
		var anim_path = ARCHER_ANIM_PATHS[anim_name]
		var anim_scene = load(anim_path)
		if anim_scene == null:
			print("RemotePlayer: Failed to load animation: ", anim_path)
			continue

		var anim_instance = anim_scene.instantiate()
		var source_anim_player = _find_animation_player(anim_instance)

		if source_anim_player == null:
			print("RemotePlayer: No AnimationPlayer in: ", anim_path)
			anim_instance.queue_free()
			continue

		# Find best animation (most keyframes)
		var best_anim: Animation = null
		var best_key_count: int = 0

		for lib_name in source_anim_player.get_animation_library_list():
			var lib: AnimationLibrary = source_anim_player.get_animation_library(lib_name)
			for src_anim_name in lib.get_animation_list():
				var anim: Animation = lib.get_animation(src_anim_name)
				var total_keys: int = 0
				for t in range(anim.get_track_count()):
					total_keys += anim.track_get_key_count(t)
				var keys_per_track: float = float(total_keys) / max(anim.get_track_count(), 1)
				if total_keys > best_key_count and keys_per_track > 1.5:
					best_anim = anim
					best_key_count = total_keys

		if best_anim != null:
			var new_anim: Animation = best_anim.duplicate()

			# Set loop mode
			var config = anim_configs.get(anim_name, [anim_name, false])
			new_anim.loop_mode = Animation.LOOP_LINEAR if config[1] else Animation.LOOP_NONE

			# Retarget animation tracks to our skeleton
			_retarget_animation(new_anim, skel_path, skeleton)

			# Add to "archer" library like player.gd does
			var lib_name: StringName = &"archer"
			if not _anim_player.has_animation_library(lib_name):
				_anim_player.add_animation_library(lib_name, AnimationLibrary.new())
			_anim_player.get_animation_library(lib_name).add_animation(StringName(anim_name), new_anim)
			print("RemotePlayer: Loaded animation: archer/", anim_name)

		anim_instance.queue_free()

	print("RemotePlayer: Animation library has: ", _anim_player.get_animation_list())


func _retarget_animation(anim: Animation, target_skeleton_path: String, skeleton: Skeleton3D) -> void:
	# Match player.gd's retargeting approach exactly
	var tracks_to_remove: Array[int] = []

	for i in range(anim.get_track_count()):
		var track_path: NodePath = anim.track_get_path(i)
		var path_str: String = str(track_path)

		var colon_pos: int = path_str.find(":")
		if colon_pos == -1:
			continue

		var bone_name: String = path_str.substr(colon_pos + 1)

		# Remove root motion from Hips
		if bone_name == "mixamorig_Hips" and anim.track_get_type(i) == Animation.TYPE_POSITION_3D:
			tracks_to_remove.append(i)
			continue

		# Verify bone exists (with alternative name check like player.gd)
		if skeleton.find_bone(bone_name) == -1:
			var alt_bone_name: String = bone_name.replace("mixamorig:", "mixamorig_")
			if skeleton.find_bone(alt_bone_name) == -1:
				continue  # Skip unknown bones instead of removing
			bone_name = alt_bone_name

		# Retarget to our skeleton path
		var new_path: String = target_skeleton_path + ":" + bone_name
		if path_str != new_path:
			anim.track_set_path(i, NodePath(new_path))

	# Remove only the hips position tracks
	tracks_to_remove.reverse()
	for idx in tracks_to_remove:
		anim.remove_track(idx)


func _setup_collision() -> void:
	var collision = CollisionShape3D.new()
	var capsule = CapsuleShape3D.new()
	capsule.radius = 0.4
	capsule.height = 1.8
	collision.shape = capsule
	collision.position.y = 0.9
	add_child(collision)


func _setup_name_label() -> void:
	_name_label = Label3D.new()
	_name_label.text = "Player %d" % player_id
	_name_label.position = Vector3(0, 2.5, 0)
	_name_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_name_label.no_depth_test = true
	_name_label.font_size = 20
	_name_label.modulate = Color(0.8, 0.9, 1.0)
	add_child(_name_label)


func _apply_remote_player_tint() -> void:
	# Apply a slight blue-ish emission to distinguish remote players
	print("RemotePlayer: Applying tint to character model: %s" % _character_model)
	_apply_tint_recursive(_character_model)


func _apply_tint_recursive(node: Node) -> void:
	if node is MeshInstance3D:
		var mesh_instance = node as MeshInstance3D
		# Create a bright tinted material to make remote player visible
		var mat = StandardMaterial3D.new()
		mat.albedo_color = Color(0.5, 0.8, 1.0)  # Cyan/blue tint
		mat.emission_enabled = true
		mat.emission = Color(0.2, 0.5, 1.0)  # Bright blue glow
		mat.emission_energy_multiplier = 1.0
		mesh_instance.material_override = mat
		print("RemotePlayer: Applied bright tint to mesh: %s" % mesh_instance.name)

	for child in node.get_children():
		_apply_tint_recursive(child)


func _find_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for child in node.get_children():
		var result = _find_animation_player(child)
		if result:
			return result
	return null


func _update_animation() -> void:
	if _anim_player == null or not is_instance_valid(_anim_player):
		return

	# Safety check - ensure animation player is inside tree
	if not _anim_player.is_inside_tree():
		return

	# Use the animation name received from network
	var anim_name = current_anim_name

	# Extract just the animation name (e.g., "archer/Idle" -> "Idle")
	if "/" in anim_name:
		anim_name = anim_name.split("/")[-1]

	# Capitalize first letter if needed
	if not anim_name.is_empty():
		anim_name = anim_name[0].to_upper() + anim_name.substr(1)

	# Build full animation path with "archer/" prefix
	var full_anim_name = "archer/" + anim_name

	# Fallback to state-based animation if name not found
	if not _anim_player.has_animation(full_anim_name):
		match current_state:
			STATE_IDLE:
				full_anim_name = "archer/Idle"
			STATE_WALKING:
				full_anim_name = "archer/Walk"
			STATE_RUNNING:
				full_anim_name = "archer/Run"
			STATE_ATTACKING:
				full_anim_name = "archer/Attack"
			STATE_BLOCKING:
				full_anim_name = "archer/Block"
			STATE_JUMPING:
				full_anim_name = "archer/Jump"
			STATE_CASTING:
				full_anim_name = "archer/Attack"
			STATE_DRAWING_BOW, STATE_HOLDING_BOW:
				full_anim_name = "archer/Attack"

	# Try to play the animation if it exists and different from current
	if _anim_player.has_animation(full_anim_name):
		if _current_playing_anim != full_anim_name:
			_anim_player.play(full_anim_name)
			_current_playing_anim = full_anim_name
