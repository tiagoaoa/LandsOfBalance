class_name PlayerAnimTree
extends CharacterBody3D
## Enhanced player controller using AnimationTree for smooth blending.
## Implements upper-body attack layering and triple-click spin attack with root motion.

# Lightning addon preloads
const Lightning3DBranchedClass = preload("res://addons/lightning/generators/Lightning3DBranched.gd")

#region Constants
const WALK_SPEED: float = 3.5
const RUN_SPEED: float = 7.0
const ACCEL: float = 12.0
const DEACCEL: float = 12.0
const JUMP_VELOCITY: float = 6.0
const MOUSE_SENSITIVITY: float = 0.002
const GAMEPAD_SENSITIVITY: float = 2.5
const CAMERA_VERTICAL_LIMIT: float = 85.0
const RUN_THRESHOLD: float = 0.6

# Attack timing
const CLICK_COMBO_WINDOW: float = 0.6  # Time window for triple-click
const LIGHT_ATTACK_DURATION: float = 0.8  # Sword slash duration
const SPIN_ATTACK_DURATION: float = 1.5
const ATTACK_COOLDOWN_TIME: float = 0.15

# Combat values
const PLAYER_KNOCKBACK_RESISTANCE: float = 0.8
const PLAYER_ATTACK_DAMAGE: float = 15.0
const PLAYER_KNOCKBACK_FORCE: float = 10.0
const NUM_LIGHTNING_BOLTS: int = 6
#endregion

#region Enums
enum CombatMode { UNARMED, ARMED }
enum PlayerState { LOCOMOTION, LIGHT_ATTACK, SPIN_ATTACK, SPELL_CAST, BLOCKING, STUNNED }
#endregion

#region Paths
const UNARMED_CHARACTER_PATH: String = "res://player/character/unarmed/Paladin.fbx"
const ARMED_CHARACTER_PATH: String = "res://player/character/armed/Paladin.fbx"

const UNARMED_ANIM_PATHS: Dictionary = {
	"idle": "res://player/character/unarmed/Idle.fbx",
	"walk": "res://player/character/unarmed/Walk.fbx",
	"run": "res://player/character/unarmed/Run.fbx",
	"strafe_left": "res://player/character/unarmed/StrafeLeft.fbx",
	"strafe_right": "res://player/character/unarmed/StrafeRight.fbx",
	"jump": "res://player/character/unarmed/Jump.fbx",
	"attack": "res://player/character/unarmed/Attack.fbx",
	"block": "res://player/character/unarmed/Block.fbx",
}

const ARMED_ANIM_PATHS: Dictionary = {
	"idle": "res://player/character/armed/Idle.fbx",
	"walk": "res://player/character/armed/Walk.fbx",
	"run": "res://player/character/armed/Run.fbx",
	"jump": "res://player/character/armed/Jump.fbx",
	"attack1": "res://player/character/armed/Attack1.fbx",
	"attack2": "res://player/character/armed/Attack2.fbx",
	"sword_slash": "res://player/character/armed/SwordSlash.fbx",
	"block": "res://player/character/armed/Block.fbx",
	"sheath": "res://player/character/armed/Sheath.fbx",
	"spell_cast": "res://player/character/armed/SpellCast.fbx",
}
#endregion

#region Node References
var _character_model: Node3D
var _unarmed_character: Node3D
var _armed_character: Node3D
var _unarmed_anim_tree: AnimationTree
var _armed_anim_tree: AnimationTree
var _anim_tree: AnimationTree  # Current active tree
var _unarmed_anim_player: AnimationPlayer
var _armed_anim_player: AnimationPlayer
var _anim_player: AnimationPlayer  # Current active player
@onready var _camera_pivot := $CameraPivot as Node3D
@onready var _camera := $CameraPivot/Camera3D as Camera3D
#endregion

#region State Variables
var camera_rotation := Vector2.ZERO
var combat_mode: CombatMode = CombatMode.UNARMED
var current_state: PlayerState = PlayerState.LOCOMOTION

# Movement state
var is_jumping: bool = false
var is_running: bool = false
var movement_locked: bool = false  # Lock during spin attack

# Armed blend (0.0 = unarmed, 1.0 = armed) - smooth transition
var armed_blend: float = 0.0
var armed_blend_target: float = 0.0
const ARMED_BLEND_SPEED: float = 8.0

# Attack state
var click_count: int = 0
var click_timer: float = 0.0
var attack_combo: int = 0
var attack_cooldown: float = 0.0
var light_attack_blend: float = 0.0  # For upper body layer

# Blocking
var is_blocking: bool = false

# Knockback/stun
var _knockback_velocity: Vector3 = Vector3.ZERO
var _stun_timer: float = 0.0
#endregion

#region Spell VFX (from original)
var _spell_effects_container: Node3D
var _lightning_particles: GPUParticles3D
var _rising_sparks: GPUParticles3D
var _magic_circle: MeshInstance3D
var _spell_light: OmniLight3D
var _lightning_bolts: GPUParticles3D
var _spell_tween: Tween
var _spell_time: float = 0.0
var _lightning_bolts_3d: Array = []
var _character_aura_material: ShaderMaterial
var _original_character_materials: Array[Dictionary] = []
var _audio_scream: AudioStreamPlayer3D
var _audio_static: AudioStreamPlayer3D
var _audio_discharge: AudioStreamPlayer3D
var _force_field_sphere: MeshInstance3D
var _force_field_light: OmniLight3D
var _force_field_material: ShaderMaterial
#endregion

#region Combat Hitbox
var _attack_hitbox: Area3D
var _has_hit_this_attack: bool = false
var _hit_label: Label3D
var _hit_flash_tween: Tween
#endregion

@onready var initial_position := position
@onready var gravity: Vector3 = ProjectSettings.get_setting("physics/3d/default_gravity") * \
		ProjectSettings.get_setting("physics/3d/default_gravity_vector")


func _ready() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	_create_characters()
	_setup_animation_tree()
	_create_spell_effects()
	_setup_hit_label()
	_setup_attack_hitbox()


#region Character Setup
func _create_characters() -> void:
	_character_model = Node3D.new()
	_character_model.name = "CharacterModel"
	add_child(_character_model)

	# Load both characters
	_unarmed_character = _load_character(UNARMED_CHARACTER_PATH, "UnarmedCharacter", Color(0.35, 0.55, 0.75))
	if _unarmed_character:
		_character_model.add_child(_unarmed_character)
		_unarmed_anim_player = _find_animation_player(_unarmed_character)
		if _unarmed_anim_player == null:
			# Create AnimationPlayer if not found in FBX
			print("Creating AnimationPlayer for unarmed character")
			_unarmed_anim_player = AnimationPlayer.new()
			_unarmed_anim_player.name = "AnimationPlayer"
			_unarmed_character.add_child(_unarmed_anim_player)

	_armed_character = _load_character(ARMED_CHARACTER_PATH, "ArmedCharacter", Color(0.6, 0.5, 0.3))
	if _armed_character:
		_character_model.add_child(_armed_character)
		_armed_anim_player = _find_animation_player(_armed_character)
		if _armed_anim_player == null:
			# Create AnimationPlayer if not found in FBX
			print("Creating AnimationPlayer for armed character")
			_armed_anim_player = AnimationPlayer.new()
			_armed_anim_player.name = "AnimationPlayer"
			_armed_character.add_child(_armed_anim_player)

	# Start in unarmed mode
	if _unarmed_character:
		_unarmed_character.visible = true
	if _armed_character:
		_armed_character.visible = false

	# Load animations into respective players
	_load_all_animations()

	# Set current animation player based on combat mode
	_anim_player = _unarmed_anim_player if combat_mode == CombatMode.UNARMED else _armed_anim_player

	print("Characters loaded - Unarmed: ", _unarmed_character != null, " (AnimPlayer: ", _unarmed_anim_player != null, ")")
	print("                  - Armed: ", _armed_character != null, " (AnimPlayer: ", _armed_anim_player != null, ")")


func _load_character(path: String, char_name: String, fallback_color: Color) -> Node3D:
	var scene: PackedScene = load(path) as PackedScene
	if scene == null:
		print("Failed to load character: ", path)
		return null

	var instance: Node3D = scene.instantiate() as Node3D
	if instance == null:
		return null

	instance.name = char_name

	# Scale character appropriately (Mixamo characters are often 100x scale)
	var skeleton: Skeleton3D = _find_skeleton(instance)
	if skeleton and skeleton.get_bone_count() > 0:
		var hips_idx: int = skeleton.find_bone("mixamorig_Hips")
		if hips_idx >= 0:
			var hips_pos: Vector3 = skeleton.get_bone_global_rest(hips_idx).origin
			instance.scale = Vector3(0.01, 0.01, 0.01) if hips_pos.y > 50 else Vector3.ONE
		else:
			instance.scale = Vector3(0.01, 0.01, 0.01)
	else:
		instance.scale = Vector3(0.01, 0.01, 0.01)

	# Apply fallback material only if no textures
	if not _character_has_textures(instance):
		_apply_character_material(instance, fallback_color)

	return instance


func _load_all_animations() -> void:
	# Load unarmed animations into unarmed character's AnimationPlayer
	if _unarmed_anim_player and _unarmed_character:
		var unarmed_skeleton: Skeleton3D = _find_skeleton(_unarmed_character)
		if unarmed_skeleton:
			var unarmed_root: Node = _unarmed_anim_player.get_node(_unarmed_anim_player.root_node)
			var unarmed_skel_path: String = str(unarmed_root.get_path_to(unarmed_skeleton))

			var unarmed_config := {
				"idle": ["Idle", true], "walk": ["Walk", true], "run": ["Run", true],
				"strafe_left": ["StrafeLeft", true], "strafe_right": ["StrafeRight", true],
				"jump": ["Jump", false], "attack": ["Attack", false], "block": ["Block", true],
			}
			print("Loading unarmed animations...")
			_load_animations_for_library(_unarmed_anim_player, UNARMED_ANIM_PATHS, unarmed_config, "unarmed", unarmed_skel_path, unarmed_skeleton)

	# Load armed animations into armed character's AnimationPlayer
	if _armed_anim_player and _armed_character:
		var armed_skeleton: Skeleton3D = _find_skeleton(_armed_character)
		if armed_skeleton:
			var armed_root: Node = _armed_anim_player.get_node(_armed_anim_player.root_node)
			var armed_skel_path: String = str(armed_root.get_path_to(armed_skeleton))

			var armed_config := {
				"idle": ["Idle", true], "walk": ["Walk", true], "run": ["Run", true],
				"jump": ["Jump", false], "attack1": ["Attack1", false], "attack2": ["Attack2", false],
				"sword_slash": ["SwordSlash", false],
				"block": ["Block", true], "sheath": ["Sheath", false], "spell_cast": ["SpellCast", false],
			}
			print("Loading armed animations...")
			_load_animations_for_library(_armed_anim_player, ARMED_ANIM_PATHS, armed_config, "armed", armed_skel_path, armed_skeleton)

			# Create spin attack animation
			_create_spin_attack_animation(armed_skel_path, armed_skeleton)


func _create_spin_attack_animation(skel_path: String, skeleton: Skeleton3D) -> void:
	# Create a spinning attack animation based on SwordSlash with full rotation
	if _armed_anim_player == null:
		return

	# Prefer SwordSlash, fall back to Attack1
	var base_anim: Animation
	if _armed_anim_player.has_animation(&"armed/SwordSlash"):
		base_anim = _armed_anim_player.get_animation(&"armed/SwordSlash")
	elif _armed_anim_player.has_animation(&"armed/Attack1"):
		base_anim = _armed_anim_player.get_animation(&"armed/Attack1")
	else:
		return
	var spin_anim: Animation = base_anim.duplicate()
	spin_anim.loop_mode = Animation.LOOP_NONE
	spin_anim.length = SPIN_ATTACK_DURATION

	# Add root rotation track for 360 degree spin
	var rot_track := spin_anim.add_track(Animation.TYPE_ROTATION_3D)
	spin_anim.track_set_path(rot_track, NodePath(skel_path + ":mixamorig_Hips"))
	spin_anim.track_insert_key(rot_track, 0.0, Quaternion.IDENTITY)
	spin_anim.track_insert_key(rot_track, SPIN_ATTACK_DURATION * 0.5, Quaternion(Vector3.UP, PI))
	spin_anim.track_insert_key(rot_track, SPIN_ATTACK_DURATION, Quaternion(Vector3.UP, TAU))

	# Add to library
	if not _armed_anim_player.has_animation_library(&"armed"):
		_armed_anim_player.add_animation_library(&"armed", AnimationLibrary.new())
	_armed_anim_player.get_animation_library(&"armed").add_animation(&"SpinAttack", spin_anim)
	print("Created SpinAttack animation")


func _load_animations_for_library(anim_player: AnimationPlayer, paths: Dictionary, config: Dictionary,
		library_prefix: String, skel_path: String, skeleton: Skeleton3D) -> void:
	for anim_key in paths:
		var fbx_path: String = paths[anim_key]
		var scene: PackedScene = load(fbx_path) as PackedScene
		if scene == null:
			continue

		var instance: Node3D = scene.instantiate()
		var anim_player_src: AnimationPlayer = _find_animation_player(instance)
		if anim_player_src == null:
			instance.queue_free()
			continue

		# Find best animation in FBX
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
			var anim_config: Array = config.get(anim_key, [anim_key, false])
			new_anim.loop_mode = Animation.LOOP_LINEAR if anim_config[1] else Animation.LOOP_NONE

			# Retarget animation to our skeleton
			_retarget_animation(new_anim, skel_path, skeleton)

			# Add to library
			var lib_name: StringName = StringName(library_prefix)
			if not anim_player.has_animation_library(lib_name):
				anim_player.add_animation_library(lib_name, AnimationLibrary.new())
			anim_player.get_animation_library(lib_name).add_animation(StringName(anim_config[0]), new_anim)
			print("  Loaded: ", library_prefix, "/", anim_config[0])

		instance.queue_free()


func _retarget_animation(anim: Animation, target_skeleton_path: String, skeleton: Skeleton3D) -> void:
	var tracks_to_remove: Array[int] = []

	for i in range(anim.get_track_count()):
		var track_path: NodePath = anim.track_get_path(i)
		var path_str: String = str(track_path)

		var colon_pos: int = path_str.find(":")
		if colon_pos == -1:
			continue

		var bone_name: String = path_str.substr(colon_pos + 1)

		# Remove root motion from Hips position track (but keep rotation for spin attack)
		if bone_name == "mixamorig_Hips" and anim.track_get_type(i) == Animation.TYPE_POSITION_3D:
			tracks_to_remove.append(i)
			continue

		# Verify bone exists
		if skeleton.find_bone(bone_name) == -1:
			var alt_bone_name: String = bone_name.replace("mixamorig:", "mixamorig_")
			if skeleton.find_bone(alt_bone_name) == -1:
				continue
			bone_name = alt_bone_name

		var new_path: String = target_skeleton_path + ":" + bone_name
		if path_str != new_path:
			anim.track_set_path(i, NodePath(new_path))

	tracks_to_remove.reverse()
	for track_idx in tracks_to_remove:
		anim.remove_track(track_idx)
#endregion


#region AnimationTree Setup
func _setup_animation_tree() -> void:
	# Create AnimationTree for unarmed character
	if _unarmed_anim_player and _unarmed_character:
		_unarmed_anim_tree = _create_anim_tree_for_character(
			_unarmed_anim_player, _unarmed_character, "UnarmedAnimTree", true)

	# Create AnimationTree for armed character
	if _armed_anim_player and _armed_character:
		_armed_anim_tree = _create_anim_tree_for_character(
			_armed_anim_player, _armed_character, "ArmedAnimTree", false)

	# Set active tree based on combat mode
	_switch_to_combat_mode(combat_mode)

	# Start playback after a frame
	await get_tree().process_frame
	_start_current_anim_tree()

	print("AnimationTree setup complete")


func _create_anim_tree_for_character(anim_player: AnimationPlayer, character: Node3D,
		tree_name: String, is_unarmed: bool) -> AnimationTree:
	var tree := AnimationTree.new()
	tree.name = tree_name
	_character_model.add_child(tree)

	# Point to the character's AnimationPlayer
	tree.anim_player = tree.get_path_to(anim_player)

	# Create root state machine
	var root_sm := AnimationNodeStateMachine.new()
	tree.tree_root = root_sm

	# Create locomotion blend tree
	var locomotion := _create_simple_locomotion_blend(is_unarmed)
	root_sm.add_node(&"Locomotion", locomotion, Vector2(200, 100))

	if not is_unarmed:
		# Armed-only states: SwordAttack, SpellCast
		var sword_attack := AnimationNodeAnimation.new()
		sword_attack.animation = &"armed/SwordSlash"
		root_sm.add_node(&"SwordAttack", sword_attack, Vector2(400, 200))

		var spell_cast := AnimationNodeAnimation.new()
		spell_cast.animation = &"armed/SpellCast"
		root_sm.add_node(&"SpellCast", spell_cast, Vector2(400, 300))

		# Transitions for armed states
		var trans_to_attack := AnimationNodeStateMachineTransition.new()
		trans_to_attack.switch_mode = AnimationNodeStateMachineTransition.SWITCH_MODE_IMMEDIATE
		root_sm.add_transition(&"Locomotion", &"SwordAttack", trans_to_attack)

		var trans_from_attack := AnimationNodeStateMachineTransition.new()
		trans_from_attack.switch_mode = AnimationNodeStateMachineTransition.SWITCH_MODE_AT_END
		trans_from_attack.advance_mode = AnimationNodeStateMachineTransition.ADVANCE_MODE_AUTO
		root_sm.add_transition(&"SwordAttack", &"Locomotion", trans_from_attack)

		var trans_to_spell := AnimationNodeStateMachineTransition.new()
		trans_to_spell.switch_mode = AnimationNodeStateMachineTransition.SWITCH_MODE_IMMEDIATE
		root_sm.add_transition(&"Locomotion", &"SpellCast", trans_to_spell)

		var trans_from_spell := AnimationNodeStateMachineTransition.new()
		trans_from_spell.switch_mode = AnimationNodeStateMachineTransition.SWITCH_MODE_AT_END
		trans_from_spell.advance_mode = AnimationNodeStateMachineTransition.ADVANCE_MODE_AUTO
		root_sm.add_transition(&"SpellCast", &"Locomotion", trans_from_spell)

	# Start transition
	root_sm.set_node_position(&"Start", Vector2(0, 100))
	var trans_start := AnimationNodeStateMachineTransition.new()
	trans_start.switch_mode = AnimationNodeStateMachineTransition.SWITCH_MODE_IMMEDIATE
	trans_start.advance_mode = AnimationNodeStateMachineTransition.ADVANCE_MODE_AUTO
	root_sm.add_transition(&"Start", &"Locomotion", trans_start)

	# Configure root motion
	var skeleton := _find_skeleton(character)
	if skeleton:
		tree.root_motion_track = NodePath(str(tree.get_path_to(skeleton)) + ":mixamorig_Hips")

	# Connect signals
	tree.animation_finished.connect(_on_animation_tree_finished)

	# Start inactive - we'll activate the current one
	tree.active = false

	print("Created ", tree_name, " for ", character.name)
	return tree


func _create_simple_locomotion_blend(is_unarmed: bool) -> AnimationNodeBlendTree:
	var blend_tree := AnimationNodeBlendTree.new()
	var prefix: String = "unarmed" if is_unarmed else "armed"

	# Create blend space (idle -> walk -> run)
	var loco_blend := AnimationNodeBlendSpace1D.new()
	loco_blend.blend_mode = AnimationNodeBlendSpace1D.BLEND_MODE_INTERPOLATED
	loco_blend.min_space = 0.0
	loco_blend.max_space = 1.0

	var idle := AnimationNodeAnimation.new()
	idle.animation = StringName(prefix + "/Idle")
	var walk := AnimationNodeAnimation.new()
	walk.animation = StringName(prefix + "/Walk")
	var run := AnimationNodeAnimation.new()
	run.animation = StringName(prefix + "/Run")

	loco_blend.add_blend_point(idle, 0.0)
	loco_blend.add_blend_point(walk, 0.5)
	loco_blend.add_blend_point(run, 1.0)

	blend_tree.add_node(&"LocoBlend", loco_blend, Vector2(0, 0))
	blend_tree.connect_node(&"output", 0, &"LocoBlend")

	return blend_tree


func _switch_to_combat_mode(mode: CombatMode) -> void:
	combat_mode = mode

	if mode == CombatMode.UNARMED:
		_anim_tree = _unarmed_anim_tree
		_anim_player = _unarmed_anim_player
		if _unarmed_character:
			_unarmed_character.visible = true
		if _armed_character:
			_armed_character.visible = false
		if _unarmed_anim_tree:
			_unarmed_anim_tree.active = true
		if _armed_anim_tree:
			_armed_anim_tree.active = false
	else:
		_anim_tree = _armed_anim_tree
		_anim_player = _armed_anim_player
		if _armed_character:
			_armed_character.visible = true
		if _unarmed_character:
			_unarmed_character.visible = false
		if _armed_anim_tree:
			_armed_anim_tree.active = true
		if _unarmed_anim_tree:
			_unarmed_anim_tree.active = false

	armed_blend_target = 1.0 if mode == CombatMode.ARMED else 0.0


func _start_current_anim_tree() -> void:
	if _anim_tree == null:
		return
	var playback: AnimationNodeStateMachinePlayback = _anim_tree.get("parameters/playback")
	if playback:
		playback.start(&"Locomotion")
		print("Started playback at Locomotion for ", _anim_tree.name)


#endregion


#region Animation Updates
func _update_animation_parameters(delta: float) -> void:
	if _anim_tree == null or not _anim_tree.active:
		return

	# Calculate normalized speed for blend space
	var horizontal_speed := Vector2(velocity.x, velocity.z).length()
	var normalized_speed: float = clamp(horizontal_speed / RUN_SPEED, 0.0, 1.0)

	# Map to blend space: 0 = idle, 0.5 = walk, 1.0 = run
	var blend_speed: float
	if normalized_speed < 0.1:
		blend_speed = 0.0
	elif normalized_speed < 0.5:
		blend_speed = remap(normalized_speed, 0.1, 0.5, 0.0, 0.5)
	else:
		blend_speed = remap(normalized_speed, 0.5, 1.0, 0.5, 1.0)

	# Set blend space position (unified path for both trees)
	_anim_tree.set(&"parameters/Locomotion/LocoBlend/blend_position", blend_speed)


func _on_animation_tree_finished(anim_name: StringName) -> void:
	match str(anim_name):
		"armed/SwordSlash":
			if current_state == PlayerState.LIGHT_ATTACK:
				_end_sword_attack()
		"armed/SpellCast":
			if current_state == PlayerState.SPELL_CAST:
				_end_spell_cast()
#endregion


#region Input Handling
func _input(event: InputEvent) -> void:
	# Fullscreen toggle
	if event is InputEventKey and event.pressed and event.keycode == KEY_F11:
		if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		else:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

	# Quit with Q
	if event is InputEventKey and event.pressed and event.keycode == KEY_Q:
		get_tree().quit()

	# Release mouse with Escape
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

	# Double-click to recapture
	if event is InputEventMouseButton and event.pressed and event.double_click and event.button_index == MOUSE_BUTTON_LEFT:
		if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

	# Toggle combat mode
	if event.is_action_pressed(&"toggle_combat") or \
			(event is InputEventKey and event.pressed and event.keycode == KEY_TAB) or \
			(event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_MIDDLE):
		_toggle_combat_mode()

	# Attack input
	if (event.is_action_pressed(&"attack") or \
			(event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED) or \
			(event is InputEventKey and event.pressed and event.keycode == KEY_F)):
		if current_state != PlayerState.SPELL_CAST:
			_handle_attack_input()

	# Block
	if event.is_action_pressed(&"block") or \
			(event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED):
		is_blocking = true
		current_state = PlayerState.BLOCKING
	elif event.is_action_released(&"block") or \
			(event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and not event.pressed):
		is_blocking = false
		if current_state == PlayerState.BLOCKING:
			current_state = PlayerState.LOCOMOTION

	# Spell cast
	if event.is_action_pressed(&"spell_cast") or event.is_action_pressed(&"cast_spell_rb"):
		if combat_mode == CombatMode.ARMED and current_state == PlayerState.LOCOMOTION:
			_start_spell_cast()

	# Mouse look
	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		camera_rotation.x -= event.relative.x * MOUSE_SENSITIVITY
		camera_rotation.y -= event.relative.y * MOUSE_SENSITIVITY
		camera_rotation.y = clamp(camera_rotation.y, deg_to_rad(-CAMERA_VERTICAL_LIMIT), deg_to_rad(CAMERA_VERTICAL_LIMIT))
		_camera_pivot.rotation.y = camera_rotation.x
		_camera_pivot.rotation.x = camera_rotation.y
#endregion


#region Attack System
func _handle_attack_input() -> void:
	if attack_cooldown > 0 or current_state == PlayerState.LIGHT_ATTACK:
		return

	_perform_sword_attack()


func _perform_sword_attack() -> void:
	if combat_mode != CombatMode.ARMED:
		# TODO: unarmed attack
		return

	current_state = PlayerState.LIGHT_ATTACK
	enable_attack_hitbox()

	# Travel to sword attack state in AnimationTree
	var playback = _anim_tree.get(&"parameters/playback") as AnimationNodeStateMachinePlayback
	if playback:
		playback.travel(&"SwordAttack")

	# Safety timer to end attack (animation auto-returns to Locomotion)
	get_tree().create_timer(LIGHT_ATTACK_DURATION).timeout.connect(_end_sword_attack, CONNECT_ONE_SHOT)


func _end_sword_attack() -> void:
	if current_state != PlayerState.LIGHT_ATTACK:
		return

	current_state = PlayerState.LOCOMOTION
	attack_cooldown = ATTACK_COOLDOWN_TIME
	disable_attack_hitbox()
#endregion


#region Combat Mode
func _toggle_combat_mode() -> void:
	if current_state == PlayerState.LIGHT_ATTACK or current_state == PlayerState.SPELL_CAST:
		return

	var new_mode := CombatMode.ARMED if combat_mode == CombatMode.UNARMED else CombatMode.UNARMED
	_switch_to_combat_mode(new_mode)
	_start_current_anim_tree()
	print("Switched to ", "ARMED" if new_mode == CombatMode.ARMED else "UNARMED", " mode")
#endregion


#region Physics Process
func _physics_process(delta: float) -> void:
	# Skip when console is open
	if GameConsole.is_console_open:
		velocity += gravity * delta
		move_and_slide()
		return

	# Update timers
	if attack_cooldown > 0:
		attack_cooldown -= delta

	if click_timer > 0:
		click_timer -= delta
		if click_timer <= 0:
			click_count = 0  # Combo window expired

	# Handle stun state (with safety timeout)
	if current_state == PlayerState.STUNNED:
		_stun_timer -= delta
		velocity.x = _knockback_velocity.x
		velocity.z = _knockback_velocity.z
		velocity.y += gravity.y * delta
		_knockback_velocity = _knockback_velocity.move_toward(Vector3.ZERO, 30.0 * delta)
		# Safety: max stun of 1 second
		if _stun_timer <= 0 or _stun_timer < -0.75:
			current_state = PlayerState.LOCOMOTION
			_knockback_velocity = Vector3.ZERO
			is_blocking = false
		move_and_slide()
		return


	# Update spell effects
	_update_spell_effects(delta)

	# Gamepad camera control
	var look_x: float = Input.get_action_strength(&"camera_look_right") - Input.get_action_strength(&"camera_look_left")
	var look_y: float = Input.get_action_strength(&"camera_look_down") - Input.get_action_strength(&"camera_look_up")
	if abs(look_x) > 0.01 or abs(look_y) > 0.01:
		camera_rotation.x -= look_x * GAMEPAD_SENSITIVITY * delta
		camera_rotation.y -= look_y * GAMEPAD_SENSITIVITY * delta
		camera_rotation.y = clamp(camera_rotation.y, deg_to_rad(-CAMERA_VERTICAL_LIMIT), deg_to_rad(CAMERA_VERTICAL_LIMIT))
		_camera_pivot.rotation.y = camera_rotation.x
		_camera_pivot.rotation.x = camera_rotation.y

	# Reset position check
	if Input.is_action_pressed(&"reset_position") or global_position.y < -12:
		position = initial_position
		velocity = Vector3.ZERO
		reset_physics_interpolation()

	# Gravity
	velocity += gravity * delta

	# Handle movement
	_process_movement(delta)

	move_and_slide()

	# Update animation parameters
	_update_animation_parameters(delta)


func _process_movement(delta: float) -> void:
	# Handle jumping
	if is_on_floor():
		if is_jumping:
			is_jumping = false
		if Input.is_action_just_pressed(&"jump") and current_state == PlayerState.LOCOMOTION:
			velocity.y = JUMP_VELOCITY
			is_jumping = true

	# Get input
	var input_dir := Input.get_vector(&"move_left", &"move_right", &"move_forward", &"move_back", 0.15)
	var input_strength := input_dir.length()

	# Determine run state
	var keyboard_run := Input.is_action_pressed(&"run") if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED else false
	is_running = keyboard_run or input_strength > RUN_THRESHOLD

	var current_max_speed: float = RUN_SPEED if is_running else WALK_SPEED
	var horizontal_velocity := Vector3(velocity.x, 0, velocity.z)

	# Normalize input
	if input_dir.length() > 0.1:
		input_dir = input_dir.normalized()

	# Reduce speed during light attack
	if current_state == PlayerState.LIGHT_ATTACK:
		input_dir *= 0.5

	# Convert to world direction
	var cam_yaw: float = _camera_pivot.rotation.y
	var forward := Vector3.FORWARD.rotated(Vector3.UP, cam_yaw)
	var right := Vector3.RIGHT.rotated(Vector3.UP, cam_yaw)
	var movement_direction := (forward * -input_dir.y + right * input_dir.x).normalized()

	if is_on_floor():
		if movement_direction.length() > 0.1:
			horizontal_velocity = horizontal_velocity.move_toward(movement_direction * current_max_speed, ACCEL * delta)
		else:
			horizontal_velocity = horizontal_velocity.move_toward(Vector3.ZERO, DEACCEL * delta)
	else:
		# Air control
		if movement_direction.length() > 0.1:
			horizontal_velocity += movement_direction * (ACCEL * 0.3 * delta)
			if horizontal_velocity.length() > current_max_speed:
				horizontal_velocity = horizontal_velocity.normalized() * current_max_speed

	# Always rotate character to face camera/mouse direction (strafe-style movement)
	if _character_model:
		var target_rotation: float = _camera_pivot.rotation.y + PI
		_character_model.rotation.y = lerp_angle(_character_model.rotation.y, target_rotation, 12.0 * delta)

	velocity = horizontal_velocity + Vector3.UP * velocity.y


func _apply_root_motion(delta: float) -> void:
	if _anim_tree == null:
		return

	# Get root motion from AnimationTree
	var root_rotation := _anim_tree.get_root_motion_rotation()

	# Apply rotation to character model (for spin attack)
	if _character_model:
		_character_model.quaternion *= root_rotation

	# Optional: apply positional root motion if needed
	# var root_motion := _anim_tree.get_root_motion_position()
	# var global_motion := _character_model.global_transform.basis * root_motion
	# velocity.x = global_motion.x / delta
	# velocity.z = global_motion.z / delta
#endregion


#region Spell System
func _start_spell_cast() -> void:
	if current_state != PlayerState.LOCOMOTION:
		return

	current_state = PlayerState.SPELL_CAST
	_start_spell_effects()

	var playback = _anim_tree.get(&"parameters/playback") as AnimationNodeStateMachinePlayback
	if playback:
		playback.travel(&"SpellCast")


func _end_spell_cast() -> void:
	current_state = PlayerState.LOCOMOTION
	_stop_spell_effects()

	var playback = _anim_tree.get(&"parameters/playback") as AnimationNodeStateMachinePlayback
	if playback:
		playback.travel(&"Locomotion")
#endregion


#region Combat - Take Damage
func take_hit(damage: float, knockback: Vector3, blocked: bool) -> void:
	_show_hit_label()

	# Reset blocking state if we get hit
	is_blocking = false

	if blocked:
		_flash_hit(Color(0.2, 0.4, 1.0))
		_knockback_velocity = knockback * PLAYER_KNOCKBACK_RESISTANCE * 0.3
		# Stay in locomotion when blocking
		current_state = PlayerState.LOCOMOTION
	else:
		_flash_hit(Color(0.2, 0.4, 1.0))
		_knockback_velocity = knockback * PLAYER_KNOCKBACK_RESISTANCE
		current_state = PlayerState.STUNNED
		_stun_timer = 0.25

	print("Player hit! Damage: ", damage, " Blocked: ", blocked, " State: ", PlayerState.keys()[current_state])
#endregion


#region Attack Hitbox
func _setup_attack_hitbox() -> void:
	_attack_hitbox = Area3D.new()
	_attack_hitbox.name = "AttackHitbox"
	_attack_hitbox.collision_layer = 0
	_attack_hitbox.collision_mask = 2
	_attack_hitbox.monitoring = false

	var collision_shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1.5, 1.5, 2.0)
	collision_shape.shape = box
	collision_shape.position = Vector3(0, 1.0, 1.2)

	_attack_hitbox.add_child(collision_shape)

	if _character_model:
		_character_model.add_child(_attack_hitbox)
	else:
		add_child(_attack_hitbox)

	_attack_hitbox.body_entered.connect(_on_attack_hitbox_body_entered)


func _on_attack_hitbox_body_entered(body: Node3D) -> void:
	if _has_hit_this_attack:
		return

	if body.has_method("take_hit"):
		_has_hit_this_attack = true
		var knockback_dir := (body.global_position - global_position).normalized()
		knockback_dir.y = 0.2
		body.take_hit(PLAYER_ATTACK_DAMAGE, knockback_dir * PLAYER_KNOCKBACK_FORCE, false)


func enable_attack_hitbox() -> void:
	_has_hit_this_attack = false
	_attack_hitbox.monitoring = true


func disable_attack_hitbox() -> void:
	_attack_hitbox.monitoring = false
#endregion


#region Utility Functions
func _find_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node as AnimationPlayer
	for child in node.get_children():
		var result := _find_animation_player(child)
		if result != null:
			return result
	return null


func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node as Skeleton3D
	for child in node.get_children():
		var result := _find_skeleton(child)
		if result != null:
			return result
	return null


func _character_has_textures(node: Node) -> bool:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		for i in range(mi.get_surface_override_material_count()):
			var mat: Material = mi.get_surface_override_material(i)
			if mat == null and mi.mesh:
				mat = mi.mesh.surface_get_material(i)
			if mat is StandardMaterial3D and mat.albedo_texture != null:
				return true
	for child in node.get_children():
		if _character_has_textures(child):
			return true
	return false


func _apply_character_material(node: Node, color: Color) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		var material := StandardMaterial3D.new()
		material.albedo_color = color
		material.roughness = 0.7
		for i in range(mi.get_surface_override_material_count()):
			mi.set_surface_override_material(i, material)
	for child in node.get_children():
		_apply_character_material(child, color)
#endregion


#region Hit Effects
func _setup_hit_label() -> void:
	_hit_label = Label3D.new()
	_hit_label.name = "HitLabel"
	_hit_label.text = "Hit!"
	_hit_label.font_size = 64
	_hit_label.modulate = Color(0.2, 0.4, 1.0)
	_hit_label.outline_modulate = Color(0.0, 0.0, 0.3)
	_hit_label.outline_size = 8
	_hit_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_hit_label.no_depth_test = true
	_hit_label.position = Vector3(0, 2.5, 0)
	_hit_label.visible = false
	add_child(_hit_label)


func _show_hit_label() -> void:
	if _hit_label == null:
		return
	_hit_label.visible = true
	_hit_label.position = Vector3(0, 2.5, 0)
	_hit_label.modulate.a = 1.0
	_hit_label.scale = Vector3(0.5, 0.5, 0.5)

	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(_hit_label, "scale", Vector3.ONE, 0.15).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
	tween.tween_property(_hit_label, "position", Vector3(0, 3.5, 0), 0.6).set_ease(Tween.EASE_OUT)
	tween.tween_property(_hit_label, "modulate:a", 0.0, 0.4).set_delay(0.2)
	tween.chain().tween_callback(func(): _hit_label.visible = false)


func _flash_hit(color: Color) -> void:
	if _hit_flash_tween:
		_hit_flash_tween.kill()
	var active_char := _armed_character if combat_mode == CombatMode.ARMED else _unarmed_character
	if active_char:
		_apply_hit_flash_recursive(active_char, color)
		_hit_flash_tween = create_tween()
		_hit_flash_tween.tween_callback(func(): _clear_hit_flash_recursive(active_char)).set_delay(0.15)


func _apply_hit_flash_recursive(node: Node, color: Color) -> void:
	if node is MeshInstance3D:
		var mesh_inst := node as MeshInstance3D
		var mat = mesh_inst.material_override
		if mat == null and mesh_inst.mesh:
			for i in range(mesh_inst.mesh.get_surface_count()):
				var surface_mat = mesh_inst.mesh.surface_get_material(i)
				if surface_mat is StandardMaterial3D:
					mat = surface_mat
					break
		if mat is StandardMaterial3D:
			mat.emission_enabled = true
			mat.emission = color
			mat.emission_energy_multiplier = 3.0
	for child in node.get_children():
		_apply_hit_flash_recursive(child, color)


func _clear_hit_flash_recursive(node: Node) -> void:
	if node is MeshInstance3D:
		var mesh_inst := node as MeshInstance3D
		var mat = mesh_inst.material_override
		if mat == null and mesh_inst.mesh:
			for i in range(mesh_inst.mesh.get_surface_count()):
				var surface_mat = mesh_inst.mesh.surface_get_material(i)
				if surface_mat is StandardMaterial3D:
					mat = surface_mat
					break
		if mat is StandardMaterial3D:
			mat.emission_enabled = false
	for child in node.get_children():
		_clear_hit_flash_recursive(child)
#endregion


#region Spell Effects (Preserved from original)
func _create_spell_effects() -> void:
	_spell_effects_container = Node3D.new()
	_spell_effects_container.name = "SpellEffects"
	add_child(_spell_effects_container)
	# Note: Full spell effect creation omitted for brevity
	# Copy the spell effect creation functions from the original player.gd


func _update_spell_effects(delta: float) -> void:
	if current_state != PlayerState.SPELL_CAST:
		return
	_spell_time += delta
	if _spell_light:
		var base_energy := 6.0
		var flicker := sin(_spell_time * 20.0) * 2.0 + sin(_spell_time * 33.0) * 1.0
		_spell_light.light_energy = base_energy + flicker


func _start_spell_effects() -> void:
	if _spell_tween:
		_spell_tween.kill()

	_spell_time = 0.0
	_spell_tween = create_tween()
	_spell_tween.set_parallel(true)

	# Show and animate magic circle
	if _magic_circle:
		_magic_circle.visible = true
		_magic_circle.scale = Vector3(0.01, 0.01, 0.01)
		_spell_tween.tween_property(_magic_circle, "scale", Vector3(1.0, 1.0, 1.0), 0.4).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
		_spell_tween.tween_property(_magic_circle, "rotation_degrees:y", 360.0, 2.0).from(0.0)

	# Show and animate force field sphere
	if _force_field_sphere:
		_force_field_sphere.visible = true
		_force_field_sphere.scale = Vector3(0.01, 0.01, 0.01)
		_spell_tween.tween_property(_force_field_sphere, "scale", Vector3(1.0, 1.0, 1.0), 0.5).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_ELASTIC)

	# Animate force field light
	if _force_field_light:
		_force_field_light.light_energy = 0.0
		_spell_tween.tween_property(_force_field_light, "light_energy", 2.0, 0.4).set_ease(Tween.EASE_OUT)

	# Animate spell light
	if _spell_light:
		_spell_light.light_energy = 0.0
		_spell_tween.tween_property(_spell_light, "light_energy", 6.0, 0.3).set_ease(Tween.EASE_OUT)

	# Start particles
	if _lightning_particles:
		_lightning_particles.emitting = true
	if _rising_sparks:
		_rising_sparks.emitting = true
	if _lightning_bolts:
		_lightning_bolts.emitting = true

	# Show 3D lightning bolts
	for bolt in _lightning_bolts_3d:
		bolt.visible = true

	# Play audio
	if _audio_scream and _audio_scream.stream:
		_audio_scream.pitch_scale = randf_range(0.9, 1.1)
		_audio_scream.play()
	if _audio_static and _audio_static.stream:
		_audio_static.play()


func _stop_spell_effects() -> void:
	if _spell_tween:
		_spell_tween.kill()

	_spell_tween = create_tween()
	_spell_tween.set_parallel(true)

	# Shrink magic circle
	if _magic_circle:
		_spell_tween.tween_property(_magic_circle, "scale", Vector3(0.01, 0.01, 0.01), 0.3).set_ease(Tween.EASE_IN)
		_spell_tween.tween_callback(func(): _magic_circle.visible = false).set_delay(0.3)

	# Shrink and hide force field sphere
	if _force_field_sphere:
		_spell_tween.tween_property(_force_field_sphere, "scale", Vector3(0.01, 0.01, 0.01), 0.4).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_BACK)
		_spell_tween.tween_callback(func(): _force_field_sphere.visible = false).set_delay(0.4)

	# Fade out lights
	if _force_field_light:
		_spell_tween.tween_property(_force_field_light, "light_energy", 0.0, 0.3).set_ease(Tween.EASE_IN)
	if _spell_light:
		_spell_tween.tween_property(_spell_light, "light_energy", 0.0, 0.4).set_ease(Tween.EASE_IN)

	# Stop particles
	if _lightning_particles:
		_lightning_particles.emitting = false
	if _rising_sparks:
		_rising_sparks.emitting = false
	if _lightning_bolts:
		_lightning_bolts.emitting = false

	# Hide 3D lightning bolts
	for bolt in _lightning_bolts_3d:
		bolt.visible = false

	# Stop audio
	if _audio_static and _audio_static.playing:
		_audio_static.stop()
	if _audio_discharge and _audio_discharge.stream:
		_audio_discharge.play()
#endregion
