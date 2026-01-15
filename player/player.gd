class_name Player
extends CharacterBody3D
## Douglass, the Keeper of Balance, walking through the Lands of Balance.
## Third-person style controls with mouse look.
## Uses FBX character models with Mixamo animations.
## Supports armed (Paladin with sword & shield) and unarmed (Y Bot) combat modes.

# Lightning addon preloads
const Lightning3DBranchedClass = preload("res://addons/lightning/generators/Lightning3DBranched.gd")
const GameConsoleScript = preload("res://ui/console.gd")  # For checking is_console_open

## Enable multiplayer networking (set to false for singleplayer testing)
@export var enable_multiplayer: bool = true

## Enable FIFO-based server-authoritative mode (test with ./server/fifo_server)
@export var enable_fifo: bool = false
@export var fifo_player_id: int = 1

# FIFO state
var _fifo_client: FifoClient
var _fifo_server_position: Vector3 = Vector3.ZERO
var _fifo_server_rotation: float = 0.0
var _fifo_connected: bool = false
var _fifo_remote_players: Dictionary = {}  # player_id -> Node3D

const WALK_SPEED: float = 3.5
const RUN_SPEED: float = 7.0
const ACCEL: float = 12.0
const DEACCEL: float = 12.0
const JUMP_VELOCITY: float = 6.0
const MOUSE_SENSITIVITY: float = 0.002
const GAMEPAD_SENSITIVITY: float = 2.5  # radians per second at full stick
const CAMERA_VERTICAL_LIMIT: float = 85.0  # degrees
const RUN_THRESHOLD: float = 0.6  # Stick intensity threshold for running (60%)

# Combat mode enum
enum CombatMode { UNARMED, ARMED }

# Character class enum
enum CharacterClass { PALADIN, ARCHER }

# Arrow projectile
const ArrowScene = preload("res://player/arrow.tscn")

# Character model paths - Paladin
const UNARMED_CHARACTER_PATH: String = "res://player/character/unarmed/Paladin.fbx"
const ARMED_CHARACTER_PATH: String = "res://player/character/armed/Paladin.fbx"

# Character model paths - Archer
const ARCHER_CHARACTER_PATH: String = "res://player/character/archer/Archer.fbx"

# Unarmed animations (Paladin without weapons)
const UNARMED_ANIM_PATHS: Dictionary = {
	"idle": "res://player/character/unarmed/Idle.fbx",
	"walk": "res://player/character/unarmed/Walk.fbx",
	"run": "res://player/character/unarmed/Run.fbx",
	"strafe_left": "res://player/character/unarmed/StrafeLeft.fbx",
	"strafe_right": "res://player/character/unarmed/StrafeRight.fbx",
	"jump": "res://player/character/unarmed/Jump.fbx",
	"turn_left": "res://player/character/unarmed/TurnLeft.fbx",
	"turn_right": "res://player/character/unarmed/TurnRight.fbx",
	"attack": "res://player/character/unarmed/Attack.fbx",
	"block": "res://player/character/unarmed/Block.fbx",
	"action_to_idle": "res://player/character/unarmed/ActionIdleToIdle.fbx",
	"idle_to_fight": "res://player/character/unarmed/IdleToFight.fbx",
}

# Armed animations (Paladin with sword & shield)
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

# Archer animations
const ARCHER_ANIM_PATHS: Dictionary = {
	"idle": "res://player/character/archer/Idle.fbx",
	"walk": "res://player/character/archer/Walk.fbx",
	"run": "res://player/character/archer/Run.fbx",
	"jump": "res://player/character/archer/Jump.fbx",
	"attack": "res://player/character/archer/Attack.fbx",
	"block": "res://player/character/archer/Block.fbx",
	"sprint": "res://player/character/archer/Sprint.fbx",
	"spell_cast": "res://player/character/archer/Archer_Spell.fbx",
}

var camera_rotation := Vector2.ZERO  # x = yaw, y = pitch
var _character_model: Node3D  # Container for both characters
var _unarmed_character: Node3D
var _armed_character: Node3D
var _archer_character: Node3D
var _unarmed_anim_player: AnimationPlayer
var _armed_anim_player: AnimationPlayer
var _archer_anim_player: AnimationPlayer
var _current_anim_player: AnimationPlayer
var moving: bool = false
var is_jumping: bool = false
var is_running: bool = false
var _current_anim: StringName = &""

# Character class state
var character_class: CharacterClass = CharacterClass.ARCHER

# Combat state
var combat_mode: CombatMode = CombatMode.ARMED
var is_attacking: bool = false
var is_blocking: bool = false
var is_sheathing: bool = false
var is_transitioning: bool = false  # For attack/idle transitions
var is_casting: bool = false
var attack_combo: int = 0
var _attack_cooldown: float = 0.0

# Archer bow state
var is_drawing_bow: bool = false  # True while holding left-click to draw
var is_holding_bow: bool = false  # True when fully drawn (0.3s) and ready to shoot
var _bow_draw_time: float = 0.0   # How long bow has been drawn
const BOW_DRAW_TIME_REQUIRED: float = 0.3  # Seconds to hold before arrow is ready
var _bow_progress_bar: ProgressBar  # UI progress bar for bow draw

# Damage/knockback state
var _knockback_velocity: Vector3 = Vector3.ZERO
var _is_stunned: bool = false
var _stun_timer: float = 0.0
var _hit_flash_tween: Tween
var _hit_label: Label3D
var _attack_hitbox: Area3D  # Sword hitbox for armed mode
var _unarmed_hitbox: Area3D  # Fist hitbox for unarmed mode
var _sword_bone_attachment: BoneAttachment3D
var _has_hit_this_attack: bool = false
var _hitbox_active_window: bool = false  # Whether we're in the damage-dealing portion of attack
var _attack_anim_progress: float = 0.0
const SWORD_HITBOX_START: float = 0.3  # Enable hitbox at 30% of attack animation
const SWORD_HITBOX_END: float = 0.8    # Disable hitbox at 80% of attack animation
const PLAYER_KNOCKBACK_RESISTANCE: float = 0.8  # Reduce knockback slightly
const PLAYER_ATTACK_DAMAGE: float = 15.0
const PLAYER_KNOCKBACK_FORCE: float = 10.0
const PALADIN_SWORD_DAMAGE: float = 50.0  # Damage to Bobba from Paladin sword

# Health system - varies by character class
const PALADIN_MAX_HP: float = 150.0
const ARCHER_MAX_HP: float = 100.0
const HEAL_RATE: float = 0.5  # HP healed per tick while casting spell
const HEAL_TICK_INTERVAL: float = 0.5  # Seconds between heal ticks
const HEAL_AREA_RADIUS: float = 3.0  # Radius of healing aura during spell cast

var max_health: float = 100.0
var current_health: float = 100.0
var _heal_tick_timer: float = 0.0
var _health_bar: ProgressBar  # UI health bar

signal health_changed(current: float, maximum: float)
signal player_died()

# Spell VFX components (ProceduralThunderChannel)
var _spell_effects_container: Node3D
var _lightning_particles: GPUParticles3D
var _rising_sparks: GPUParticles3D
var _magic_circle: MeshInstance3D
var _spell_light: OmniLight3D
var _lightning_bolts: GPUParticles3D
var _spell_tween: Tween
# Enhanced spell VFX
var _spell_time: float = 0.0  # For sin() flicker calculations
var _lightning_bolts_3d: Array = []  # Lightning3DBranched instances from addon
# Archer fire circle spell
var _fire_circle_particles: Array[GPUParticles3D] = []  # Multiple fire emitters in a circle
var _fire_circle_light: OmniLight3D
var _fire_circle_node: Node3D  # Container for fire circle effects
var _fire_circle_time: float = 0.0  # Track elapsed time for intensity reduction
var _fire_circle_active: bool = false  # Track if fire circle is active
const FIRE_CIRCLE_RADIUS: float = 2.5
const FIRE_CIRCLE_EMITTERS: int = 8
const FIRE_CIRCLE_DURATION: float = 4.0  # 4 seconds with 1/time intensity decay
var _character_aura_material: ShaderMaterial  # Fresnel aura shader
var _original_character_materials: Array[Dictionary] = []  # Store {mesh, material} pairs
const NUM_LIGHTNING_BOLTS: int = 6  # Number of 3D lightning bolts
# Audio system placeholders (assign audio streams in inspector or load at runtime)
var _audio_scream: AudioStreamPlayer3D  # Initial power-up scream
var _audio_static: AudioStreamPlayer3D  # Looping electric static
var _audio_discharge: AudioStreamPlayer3D  # One-shot discharge on spell end
# Force Field / Bubble Shield (V2 Asset Rich)
var _force_field_sphere: MeshInstance3D  # Bubble shield around character
var _force_field_light: OmniLight3D  # Constant light inside force field
var _force_field_material: ShaderMaterial  # Bubble shader with noise distortion

@onready var initial_position := position
@onready var gravity: Vector3 = ProjectSettings.get_setting("physics/3d/default_gravity") * \
		ProjectSettings.get_setting("physics/3d/default_gravity_vector")

@onready var _camera_pivot := $CameraPivot as Node3D
@onready var _camera := $CameraPivot/Camera3D as Camera3D


func _ready() -> void:
	print("Player: _ready() starting")
	_parse_fifo_args()  # Check for --fifo and --player-id command line args
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	_setup_attack_hitbox()  # Must be before _create_characters which attaches hitbox to bones
	_create_characters()
	_create_lightning_particles()
	_create_fire_circle_spell()
	_setup_hit_label()
	_setup_bow_progress_bar()
	_setup_health_bar()
	_setup_multiplayer()
	_setup_fifo()
	# Spawn player on a random hill
	_spawn_at_tower()
	# Apply character selection from GameSettings (character select menu)
	call_deferred("_apply_character_selection")
	# Connect to Bobba death signal for game restart
	call_deferred("_connect_bobba_death_signal")


func _parse_fifo_args() -> void:
	var args := OS.get_cmdline_args()
	for arg in args:
		if arg == "--fifo":
			enable_fifo = true
			print("Player: FIFO mode enabled via command line")
		elif arg.begins_with("--player-id="):
			fifo_player_id = int(arg.substr(12))
			print("Player: FIFO player ID set to %d" % fifo_player_id)


func _setup_multiplayer() -> void:
	# Skip multiplayer setup if disabled (singleplayer mode)
	if not enable_multiplayer:
		print("Player: Multiplayer disabled - running in singleplayer mode")
		return

	# Register with network manager if available
	print("Player: _setup_multiplayer called")
	if has_node("/root/NetworkManager"):
		print("Player: Found NetworkManager, connecting...")
		var network_manager = get_node("/root/NetworkManager")
		network_manager.set_local_player(self)
		# Connect to arrow spawn signal to create arrows from other players
		network_manager.arrow_spawned.connect(_on_network_arrow_spawned)
		# Connect to arrow hit signal to create ground fire for remote arrows
		network_manager.arrow_hit.connect(_on_network_arrow_hit)
		# Connect to joined_game signal to apply character selection
		network_manager.joined_game.connect(_on_joined_game)
		# Connect to game restart signal for synchronized respawn
		network_manager.game_restart_received.connect(_on_game_restart_received)
		print("Player: Multiplayer signals connected")
		# Note: NetworkManager auto-connects as spectator and joins via JoinScreen
	else:
		print("Player: NetworkManager NOT found!")

	# Also apply character selection for singleplayer (when JoinScreen hides)
	call_deferred("_apply_character_selection_if_ready")


func _on_joined_game() -> void:
	print("Player: Joined game - applying character selection")
	_apply_character_selection()


func _apply_character_selection_if_ready() -> void:
	# Check if JoinScreen exists and has already hidden (singleplayer/direct join)
	var join_screen = get_node_or_null("/root/Game/JoinScreen")
	if join_screen == null:
		join_screen = get_tree().get_first_node_in_group("join_screen")

	if join_screen and not join_screen.visible:
		_apply_character_selection()


func _apply_character_selection() -> void:
	# First check GameSettings autoload (from character select menu)
	if GameSettings:
		var selected_class = GameSettings.selected_character_class
		print("Player: Selected character class from GameSettings: %d" % selected_class)
		if selected_class == 0:
			_switch_character_class(CharacterClass.PALADIN)
		else:
			_switch_character_class(CharacterClass.ARCHER)
		return

	# Fallback: check join_screen (legacy multiplayer)
	var join_screen = get_node_or_null("/root/Game/JoinScreen")
	if join_screen == null:
		join_screen = get_tree().get_first_node_in_group("join_screen")

	if join_screen and "selected_character_class" in join_screen:
		var selected_class = join_screen.selected_character_class
		print("Player: Selected character class: %d" % selected_class)
		if selected_class == 0:
			_switch_character_class(CharacterClass.PALADIN)
		else:
			_switch_character_class(CharacterClass.ARCHER)
	else:
		print("Player: No character selection found - using default (Archer)")


func _setup_fifo() -> void:
	if not enable_fifo:
		return

	print("Player: Setting up FIFO mode (player_id=%d)" % fifo_player_id)
	_fifo_client = FifoClient.new()
	_fifo_client.name = "FifoClient"
	add_child(_fifo_client)

	_fifo_client.connected.connect(_on_fifo_connected)
	_fifo_client.disconnected.connect(_on_fifo_disconnected)
	_fifo_client.global_state_received.connect(_on_fifo_state_received)

	# Connect automatically
	if _fifo_client.connect_to_server(fifo_player_id):
		_fifo_server_position = global_position
		print("Player: FIFO connected!")
	else:
		print("Player: FIFO connection failed - is fifo_server running?")


func _on_fifo_connected() -> void:
	_fifo_connected = true
	_fifo_server_position = global_position
	print("Player: FIFO connected")


func _on_fifo_disconnected() -> void:
	_fifo_connected = false
	print("Player: FIFO disconnected")


func _on_fifo_state_received(players: Array) -> void:
	for p in players:
		if p.get("player_id", 0) == fifo_player_id:
			_fifo_server_position = Vector3(p.get("x", 0.0), p.get("y", 0.0), p.get("z", 0.0))
			_fifo_server_rotation = p.get("rotation_y", 0.0)
			break


func _fifo_send_state() -> void:
	if not _fifo_client or not _fifo_connected:
		return

	var state_id: int = 0  # idle
	if is_attacking:
		state_id = 3
	elif is_blocking:
		state_id = 4
	elif is_jumping:
		state_id = 5
	elif is_running:
		state_id = 2
	elif moving:
		state_id = 1

	var data := {
		"player_id": fifo_player_id,
		"x": global_position.x,
		"y": global_position.y,
		"z": global_position.z,
		"rotation_y": _character_model.rotation.y if _character_model else 0.0,
		"state": state_id,
		"combat_mode": 1 if combat_mode == CombatMode.ARMED else 0,
		"health": 100.0,
		"anim_name": String(_current_anim) if _current_anim else "Idle",
		"active": true,
		"character_class": character_class,
	}
	_fifo_client.send_local_state(data)


## Handle arrow spawn event from network (another player shot an arrow)
func _on_network_arrow_spawned(data: Dictionary) -> void:
	# Create arrow from network data
	var arrow = ArrowScene.instantiate()
	arrow.is_local = false
	arrow.arrow_id = data.get("arrow_id", 0)
	arrow.shooter_id = data.get("shooter_id", 0)

	var spawn_pos: Vector3 = data.get("position", Vector3.ZERO)
	var direction: Vector3 = data.get("direction", Vector3.FORWARD)

	# Find shooter node (remote player or ourselves, though we filter our own)
	if has_node("/root/NetworkManager"):
		var network_manager = get_node("/root/NetworkManager")
		if arrow.shooter_id in network_manager.remote_players:
			arrow.shooter = network_manager.remote_players[arrow.shooter_id]

	# Add arrow to scene
	get_tree().current_scene.add_child(arrow)
	arrow.global_position = spawn_pos
	arrow.launch(direction)

	print("Network arrow spawned: id=%d from player %d" % [arrow.arrow_id, arrow.shooter_id])


## Handle arrow hit event from network (creates ground fire at hit position)
func _on_network_arrow_hit(arrow_id: int, hit_pos: Vector3, hit_entity_id: int) -> void:
	print("Network arrow hit: id=%d at pos=(%.1f, %.1f, %.1f)" % [arrow_id, hit_pos.x, hit_pos.y, hit_pos.z])
	# Create ground fire effect at hit position
	_create_network_ground_fire(hit_pos)


## Creates a ground fire effect at a network-synced position
func _create_network_ground_fire(pos: Vector3) -> void:
	# Create a persistent fire light at landing position
	var fire_node = Node3D.new()
	fire_node.name = "NetworkGroundFire"
	get_tree().current_scene.add_child(fire_node)
	fire_node.global_position = pos

	# Main fireplace light - intense warm glow with 5m radius
	var ground_light = OmniLight3D.new()
	ground_light.name = "FireplaceLight"
	ground_light.light_color = Color(1.0, 0.5, 0.1)
	ground_light.light_energy = 500.0
	ground_light.omni_range = 5.0
	ground_light.omni_attenuation = 0.8
	ground_light.shadow_enabled = true
	ground_light.position = Vector3(0, 0.5, 0)
	fire_node.add_child(ground_light)

	# Secondary fill light
	var fill_light = OmniLight3D.new()
	fill_light.name = "FillLight"
	fill_light.light_color = Color(1.0, 0.7, 0.3)
	fill_light.light_energy = 200.0
	fill_light.omni_range = 8.0
	fill_light.omni_attenuation = 1.5
	fill_light.shadow_enabled = false
	fill_light.position = Vector3(0, 1.0, 0)
	fire_node.add_child(fill_light)

	# Fire particles
	var ground_fire = GPUParticles3D.new()
	ground_fire.name = "GroundFireParticles"
	ground_fire.amount = 80
	ground_fire.lifetime = 0.8
	ground_fire.explosiveness = 0.1
	ground_fire.randomness = 0.6

	var fire_mat = ParticleProcessMaterial.new()
	fire_mat.direction = Vector3(0, 1, 0)
	fire_mat.spread = 35.0
	fire_mat.initial_velocity_min = 1.0
	fire_mat.initial_velocity_max = 4.0
	fire_mat.gravity = Vector3(0, 3.0, 0)
	fire_mat.scale_min = 0.3
	fire_mat.scale_max = 0.8

	var color_ramp = GradientTexture1D.new()
	var gradient = Gradient.new()
	gradient.add_point(0.0, Color(1.0, 1.0, 0.5, 1.0))
	gradient.add_point(0.3, Color(1.0, 0.8, 0.2, 1.0))
	gradient.add_point(0.6, Color(1.0, 0.4, 0.0, 0.9))
	gradient.add_point(1.0, Color(0.8, 0.1, 0.0, 0.0))
	color_ramp.gradient = gradient
	fire_mat.color_ramp = color_ramp
	fire_mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	fire_mat.emission_sphere_radius = 0.4

	ground_fire.process_material = fire_mat

	var fire_mesh = QuadMesh.new()
	fire_mesh.size = Vector2(0.5, 0.5)
	var mesh_mat = StandardMaterial3D.new()
	mesh_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mesh_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mesh_mat.albedo_color = Color(1.0, 0.8, 0.3, 1.0)
	mesh_mat.emission_enabled = true
	mesh_mat.emission = Color(1.0, 0.6, 0.1)
	mesh_mat.emission_energy_multiplier = 5.0
	fire_mesh.material = mesh_mat

	ground_fire.draw_pass_1 = fire_mesh
	ground_fire.position = Vector3(0, 0.2, 0)
	fire_node.add_child(ground_fire)

	# Add light flickering effect
	var flicker_tween = fire_node.create_tween()
	flicker_tween.set_loops()
	flicker_tween.tween_property(ground_light, "light_energy", 600.0, 0.1)
	flicker_tween.tween_property(ground_light, "light_energy", 400.0, 0.15)
	flicker_tween.tween_property(ground_light, "light_energy", 550.0, 0.08)
	flicker_tween.tween_property(ground_light, "light_energy", 450.0, 0.12)

	# Auto-destroy after 30 seconds
	var destroy_timer = get_tree().create_timer(30.0)
	destroy_timer.timeout.connect(fire_node.queue_free)


## Returns the current player state for network synchronization
func get_network_state() -> int:
	const Proto = preload("res://multiplayer/protocol.gd")
	if is_attacking:
		return Proto.PlayerState.STATE_ATTACKING
	elif is_blocking:
		return Proto.PlayerState.STATE_BLOCKING
	elif is_casting:
		return Proto.PlayerState.STATE_CASTING
	elif is_drawing_bow:
		return Proto.PlayerState.STATE_DRAWING_BOW
	elif is_holding_bow:
		return Proto.PlayerState.STATE_HOLDING_BOW
	elif not is_on_floor():
		return Proto.PlayerState.STATE_JUMPING
	elif velocity.length() > 0.5:
		if is_running:
			return Proto.PlayerState.STATE_RUNNING
		else:
			return Proto.PlayerState.STATE_WALKING
	return Proto.PlayerState.STATE_IDLE


## Returns the current animation name for network synchronization
func get_current_animation() -> String:
	return str(_current_anim)


## Returns the character model's facing direction for network synchronization
func get_facing_rotation() -> float:
	if _character_model:
		return _character_model.rotation.y
	return 0.0


func _create_characters() -> void:
	# Create container for both character models
	_character_model = Node3D.new()
	_character_model.name = "CharacterModel"
	add_child(_character_model)

	# Load unarmed character (Paladin without weapons)
	_unarmed_character = _load_character(UNARMED_CHARACTER_PATH, "UnarmedCharacter", Color(0.35, 0.55, 0.75))
	if _unarmed_character:
		_character_model.add_child(_unarmed_character)
		_unarmed_anim_player = _find_animation_player(_unarmed_character)
		print("Unarmed AnimationPlayer found: ", _unarmed_anim_player != null)
		if _unarmed_anim_player:
			_unarmed_anim_player.animation_finished.connect(_on_animation_finished)
			_load_animations_for_character(_unarmed_anim_player, UNARMED_ANIM_PATHS, _get_unarmed_config(), "unarmed", _unarmed_character)
		else:
			# Create AnimationPlayer if not found
			print("Creating AnimationPlayer for unarmed character")
			_unarmed_anim_player = AnimationPlayer.new()
			_unarmed_anim_player.name = "AnimationPlayer"
			_unarmed_character.add_child(_unarmed_anim_player)
			_unarmed_anim_player.animation_finished.connect(_on_animation_finished)
			_load_animations_for_character(_unarmed_anim_player, UNARMED_ANIM_PATHS, _get_unarmed_config(), "unarmed", _unarmed_character)

	# Load armed character (Paladin)
	_armed_character = _load_character(ARMED_CHARACTER_PATH, "ArmedCharacter", Color(0.6, 0.5, 0.3))
	if _armed_character:
		_character_model.add_child(_armed_character)
		_armed_character.visible = false  # Hidden by default (Archer is default class)
		_armed_anim_player = _find_animation_player(_armed_character)
		if _armed_anim_player:
			_armed_anim_player.animation_finished.connect(_on_animation_finished)
			_load_animations_for_character(_armed_anim_player, ARMED_ANIM_PATHS, _get_armed_config(), "armed", _armed_character)
		# Setup sword hitbox bone attachment after character is loaded
		_setup_sword_bone_attachment()

	# Load archer character
	_archer_character = _load_character(ARCHER_CHARACTER_PATH, "ArcherCharacter", Color(0.3, 0.6, 0.4))
	if _archer_character:
		_character_model.add_child(_archer_character)
		_archer_character.visible = true  # Start visible (Archer is default class)
		_archer_anim_player = _find_animation_player(_archer_character)
		if _archer_anim_player:
			_archer_anim_player.animation_finished.connect(_on_animation_finished)
			_load_animations_for_character(_archer_anim_player, ARCHER_ANIM_PATHS, _get_archer_config(), "archer", _archer_character)
		else:
			# Create AnimationPlayer if not found
			print("Creating AnimationPlayer for archer character")
			_archer_anim_player = AnimationPlayer.new()
			_archer_anim_player.name = "AnimationPlayer"
			_archer_character.add_child(_archer_anim_player)
			_archer_anim_player.animation_finished.connect(_on_animation_finished)
			_load_animations_for_character(_archer_anim_player, ARCHER_ANIM_PATHS, _get_archer_config(), "archer", _archer_character)

	# Hide Paladin characters since we start with Archer
	if _unarmed_character:
		_unarmed_character.visible = false
	if _armed_character:
		_armed_character.visible = false

	# Set initial animation player (Archer is default)
	_current_anim_player = _archer_anim_player

	# Play initial idle animation (archer)
	if _archer_anim_player and _archer_anim_player.has_animation(&"archer/Idle"):
		_archer_anim_player.play(&"archer/Idle")
		_current_anim = &"archer/Idle"

	# Add unarmed hitbox to character model
	if _character_model and _unarmed_hitbox:
		_character_model.add_child(_unarmed_hitbox)
		print("Player: Added unarmed hitbox to character model")

	print("Characters loaded - Unarmed: ", _unarmed_character != null, ", Armed: ", _armed_character != null, ", Archer: ", _archer_character != null)


func _create_lightning_particles() -> void:
	# Create container for all spell effects (ProceduralThunderChannel)
	_spell_effects_container = Node3D.new()
	_spell_effects_container.name = "SpellEffects"
	add_child(_spell_effects_container)

	_create_magic_circle()
	_create_force_field_sphere()  # V2: Bubble shield
	_create_spell_light()
	_create_spark_particles()
	_create_rising_sparks()
	_create_lightning_bolts()
	_create_character_aura_shader()
	_create_procedural_lightning_bolts()
	_create_spell_audio_system()


func _create_magic_circle() -> void:
	# Create a glowing magic circle on the ground using a torus mesh
	_magic_circle = MeshInstance3D.new()
	_magic_circle.name = "MagicCircle"

	var torus := TorusMesh.new()
	torus.inner_radius = 1.8
	torus.outer_radius = 2.0
	torus.rings = 32
	torus.ring_segments = 32
	_magic_circle.mesh = torus

	# Create glowing shader material for neon effect
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
render_mode unshaded, cull_disabled;

uniform vec4 glow_color : source_color = vec4(0.2, 0.5, 1.0, 1.0);
uniform float glow_intensity : hint_range(0.0, 10.0) = 3.0;
uniform float pulse_speed : hint_range(0.0, 10.0) = 2.0;
uniform float time_offset : hint_range(0.0, 6.28) = 0.0;

void fragment() {
	float pulse = 0.7 + 0.3 * sin(TIME * pulse_speed + time_offset);
	ALBEDO = glow_color.rgb * glow_intensity * pulse;
	ALPHA = glow_color.a * pulse;
	EMISSION = glow_color.rgb * glow_intensity * pulse * 2.0;
}
"""
	var shader_mat := ShaderMaterial.new()
	shader_mat.shader = shader
	shader_mat.set_shader_parameter("glow_color", Color(0.2, 0.5, 1.0, 0.9))
	shader_mat.set_shader_parameter("glow_intensity", 4.0)
	shader_mat.set_shader_parameter("pulse_speed", 3.0)
	_magic_circle.material_override = shader_mat

	_magic_circle.position = Vector3(0, 0.05, 0)
	_magic_circle.rotation_degrees.x = 90  # Lay flat on ground
	_magic_circle.scale = Vector3(0.01, 0.01, 0.01)  # Start tiny
	_magic_circle.visible = false

	_spell_effects_container.add_child(_magic_circle)

	# Add inner circle for more detail
	var inner_circle := MeshInstance3D.new()
	inner_circle.name = "InnerCircle"
	var inner_torus := TorusMesh.new()
	inner_torus.inner_radius = 0.9
	inner_torus.outer_radius = 1.0
	inner_torus.rings = 32
	inner_torus.ring_segments = 32
	inner_circle.mesh = inner_torus

	var inner_shader_mat := ShaderMaterial.new()
	inner_shader_mat.shader = shader
	inner_shader_mat.set_shader_parameter("glow_color", Color(0.4, 0.7, 1.0, 0.8))
	inner_shader_mat.set_shader_parameter("glow_intensity", 5.0)
	inner_shader_mat.set_shader_parameter("pulse_speed", 4.0)
	inner_shader_mat.set_shader_parameter("time_offset", 1.57)  # Offset pulse
	inner_circle.material_override = inner_shader_mat

	_magic_circle.add_child(inner_circle)


func _create_force_field_sphere() -> void:
	# Create a protective bubble/force field shield around the character (V2 Asset Rich)
	_force_field_sphere = MeshInstance3D.new()
	_force_field_sphere.name = "ForceFieldSphere"

	var sphere := SphereMesh.new()
	sphere.radius = 1.8
	sphere.height = 3.6
	sphere.radial_segments = 32
	sphere.rings = 16
	_force_field_sphere.mesh = sphere

	# Create bubble/force field shader with Fresnel edge glow and noise distortion
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
render_mode blend_add, depth_draw_opaque, cull_front, unshaded;

uniform vec4 bubble_color : source_color = vec4(0.0, 0.8, 1.0, 0.3);
uniform float fresnel_power : hint_range(0.5, 8.0) = 3.0;
uniform float edge_intensity : hint_range(0.0, 5.0) = 2.5;
uniform float pulse_speed : hint_range(0.0, 10.0) = 2.0;
uniform float distortion_scale : hint_range(0.0, 2.0) = 0.5;
uniform float distortion_speed : hint_range(0.0, 5.0) = 1.0;

// Simple noise function
float noise(vec3 p) {
	return fract(sin(dot(p, vec3(12.9898, 78.233, 45.543))) * 43758.5453);
}

float smooth_noise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);

	float n000 = noise(i);
	float n001 = noise(i + vec3(0.0, 0.0, 1.0));
	float n010 = noise(i + vec3(0.0, 1.0, 0.0));
	float n011 = noise(i + vec3(0.0, 1.0, 1.0));
	float n100 = noise(i + vec3(1.0, 0.0, 0.0));
	float n101 = noise(i + vec3(1.0, 0.0, 1.0));
	float n110 = noise(i + vec3(1.0, 1.0, 0.0));
	float n111 = noise(i + vec3(1.0, 1.0, 1.0));

	float nx00 = mix(n000, n100, f.x);
	float nx01 = mix(n001, n101, f.x);
	float nx10 = mix(n010, n110, f.x);
	float nx11 = mix(n011, n111, f.x);

	float nxy0 = mix(nx00, nx10, f.y);
	float nxy1 = mix(nx01, nx11, f.y);

	return mix(nxy0, nxy1, f.z);
}

void fragment() {
	// Calculate Fresnel effect for edge glow
	float fresnel = pow(1.0 - abs(dot(NORMAL, VIEW)), fresnel_power);

	// Animated noise for bubble distortion effect
	vec3 world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float noise_val = smooth_noise(world_pos * distortion_scale + TIME * distortion_speed);
	float noise_val2 = smooth_noise(world_pos * distortion_scale * 0.5 - TIME * distortion_speed * 0.7);

	// Pulsing effect
	float pulse = 0.7 + 0.3 * sin(TIME * pulse_speed);

	// Combine effects
	float intensity = fresnel * edge_intensity * pulse;
	intensity += (noise_val * 0.3 + noise_val2 * 0.2) * fresnel;

	ALBEDO = bubble_color.rgb * intensity;
	ALPHA = bubble_color.a * intensity * 0.8;
	EMISSION = bubble_color.rgb * intensity * 1.5;
}
"""
	_force_field_material = ShaderMaterial.new()
	_force_field_material.shader = shader
	_force_field_material.set_shader_parameter("bubble_color", Color(0.0, 0.9, 1.0, 0.4))
	_force_field_material.set_shader_parameter("fresnel_power", 3.0)
	_force_field_material.set_shader_parameter("edge_intensity", 2.5)
	_force_field_material.set_shader_parameter("pulse_speed", 3.0)
	_force_field_material.set_shader_parameter("distortion_scale", 0.8)
	_force_field_material.set_shader_parameter("distortion_speed", 1.2)
	_force_field_sphere.material_override = _force_field_material

	_force_field_sphere.position = Vector3(0, 1.0, 0)  # Center on character
	_force_field_sphere.scale = Vector3(0.01, 0.01, 0.01)  # Start tiny
	_force_field_sphere.visible = false

	_spell_effects_container.add_child(_force_field_sphere)

	# Add constant light inside the force field (non-flickering)
	_force_field_light = OmniLight3D.new()
	_force_field_light.name = "ForceFieldLight"
	_force_field_light.light_color = Color(0.0, 1.0, 1.0)  # Cyan
	_force_field_light.light_energy = 0.0  # Start off
	_force_field_light.omni_range = 4.0
	_force_field_light.omni_attenuation = 1.2
	_force_field_light.shadow_enabled = false
	_force_field_light.position = Vector3(0, 1.0, 0)

	_spell_effects_container.add_child(_force_field_light)


func _create_spell_light() -> void:
	# Create OmniLight3D for blue area illumination
	_spell_light = OmniLight3D.new()
	_spell_light.name = "SpellLight"
	_spell_light.light_color = Color(0.3, 0.5, 1.0)
	_spell_light.light_energy = 0.0  # Start off
	_spell_light.omni_range = 8.0
	_spell_light.omni_attenuation = 1.5
	_spell_light.shadow_enabled = true
	_spell_light.position = Vector3(0, 1.5, 0)

	_spell_effects_container.add_child(_spell_light)


func _create_fire_circle_spell() -> void:
	# Create container for Archer's fire circle spell
	_fire_circle_node = Node3D.new()
	_fire_circle_node.name = "FireCircleSpell"
	add_child(_fire_circle_node)

	# Create warm fire light (orange/red glow)
	_fire_circle_light = OmniLight3D.new()
	_fire_circle_light.name = "FireCircleLight"
	_fire_circle_light.light_color = Color(1.0, 0.6, 0.2)
	_fire_circle_light.light_energy = 0.0  # Start off
	_fire_circle_light.omni_range = 6.0
	_fire_circle_light.omni_attenuation = 1.5
	_fire_circle_light.shadow_enabled = true
	_fire_circle_light.position = Vector3(0, 0.5, 0)
	_fire_circle_node.add_child(_fire_circle_light)

	# Create fire emitters in a circle around the player
	for i in range(FIRE_CIRCLE_EMITTERS):
		var angle = (float(i) / FIRE_CIRCLE_EMITTERS) * TAU
		var x = cos(angle) * FIRE_CIRCLE_RADIUS
		var z = sin(angle) * FIRE_CIRCLE_RADIUS

		var fire = GPUParticles3D.new()
		fire.name = "FireEmitter_%d" % i
		fire.emitting = false
		fire.amount = 80  # More particles for smoother look
		fire.lifetime = 1.2  # Longer lifetime
		fire.explosiveness = 0.05  # More gradual emission
		fire.randomness = 0.5
		fire.position = Vector3(x, 0.1, z)

		var fire_mat = ParticleProcessMaterial.new()
		fire_mat.direction = Vector3(0, 1, 0)
		fire_mat.spread = 20.0
		fire_mat.initial_velocity_min = 1.0
		fire_mat.initial_velocity_max = 2.5
		fire_mat.gravity = Vector3(0, 0.5, 0)  # Fire rises gently
		fire_mat.damping_min = 0.5
		fire_mat.damping_max = 1.5

		# Color gradient: white core -> yellow -> orange -> red -> dark red
		var color_gradient = Gradient.new()
		color_gradient.offsets = PackedFloat32Array([0.0, 0.15, 0.35, 0.55, 0.75, 1.0])
		color_gradient.colors = PackedColorArray([
			Color(1.0, 1.0, 0.9, 0.9),   # White-yellow core
			Color(1.0, 0.85, 0.3, 1.0),  # Bright yellow
			Color(1.0, 0.5, 0.1, 1.0),   # Orange
			Color(0.95, 0.25, 0.05, 0.9), # Bright red
			Color(0.7, 0.1, 0.02, 0.6),  # Deep red
			Color(0.3, 0.05, 0.01, 0.0)  # Dark red fade out
		])
		var color_tex = GradientTexture1D.new()
		color_tex.gradient = color_gradient
		color_tex.width = 256  # Smoother gradient
		fire_mat.color_ramp = color_tex

		# Scale curve: grow then shrink for organic flame shape
		var scale_curve = Curve.new()
		scale_curve.add_point(Vector2(0.0, 0.3))
		scale_curve.add_point(Vector2(0.2, 1.0))
		scale_curve.add_point(Vector2(0.6, 0.7))
		scale_curve.add_point(Vector2(1.0, 0.1))
		var scale_tex = CurveTexture.new()
		scale_tex.curve = scale_curve
		fire_mat.scale_curve = scale_tex
		fire_mat.scale_min = 0.4
		fire_mat.scale_max = 0.8

		fire_mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
		fire_mat.emission_sphere_radius = 0.25
		fire.process_material = fire_mat

		# Larger, softer fire mesh
		var fire_mesh = QuadMesh.new()
		fire_mesh.size = Vector2(0.6, 0.8)  # Taller flame shape
		var mesh_mat = StandardMaterial3D.new()
		mesh_mat.albedo_color = Color(1.0, 0.8, 0.5, 0.9)
		mesh_mat.emission_enabled = true
		mesh_mat.emission = Color(1.0, 0.4, 0.1)
		mesh_mat.emission_energy_multiplier = 3.0
		mesh_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		mesh_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mesh_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD  # Additive blending for glow
		mesh_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mesh_mat.vertex_color_use_as_albedo = true  # Use particle color
		fire_mesh.material = mesh_mat
		fire.draw_pass_1 = fire_mesh

		_fire_circle_node.add_child(fire)
		_fire_circle_particles.append(fire)


func _create_spark_particles() -> void:
	# Core sparks around player body (ProceduralThunderChannel SparkShower)
	_lightning_particles = GPUParticles3D.new()
	_lightning_particles.name = "CoreSparks"
	_lightning_particles.emitting = false
	_lightning_particles.amount = 150  # Increased per JSON spec
	_lightning_particles.lifetime = 0.5
	_lightning_particles.one_shot = false
	_lightning_particles.explosiveness = 0.6
	_lightning_particles.visibility_aabb = AABB(Vector3(-4, -2, -4), Vector3(8, 6, 8))

	var mat := ParticleProcessMaterial.new()
	mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	mat.emission_sphere_radius = 0.8
	mat.direction = Vector3(0, 0, 0)
	mat.spread = 180.0
	mat.initial_velocity_min = 3.0
	mat.initial_velocity_max = 6.0
	mat.gravity = Vector3(0, 0, 0)
	mat.scale_min = 0.02
	mat.scale_max = 0.08
	mat.damping_min = 2.0
	mat.damping_max = 4.0

	# Updated gradient per JSON spec
	var gradient := Gradient.new()
	gradient.add_point(0.0, Color(0.9, 0.95, 1.0, 1.0))  # Near-white start
	gradient.add_point(0.5, Color(0.3, 0.6, 1.0, 1.0))   # Blue mid
	gradient.add_point(1.0, Color(0.1, 0.3, 1.0, 0.0))   # Dark blue fade
	var gradient_tex := GradientTexture1D.new()
	gradient_tex.gradient = gradient
	mat.color_ramp = gradient_tex

	_lightning_particles.process_material = mat

	var mesh := SphereMesh.new()
	mesh.radius = 0.04
	mesh.height = 0.08
	mesh.radial_segments = 4
	mesh.rings = 2

	# Additive blend for glow effect
	var spark_mat := StandardMaterial3D.new()
	spark_mat.albedo_color = Color(0.9, 0.95, 1.0)
	spark_mat.emission_enabled = true
	spark_mat.emission = Color(0.4, 0.6, 1.0)
	spark_mat.emission_energy_multiplier = 6.0
	spark_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD  # Additive blending
	spark_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mesh.material = spark_mat

	_lightning_particles.draw_pass_1 = mesh
	_lightning_particles.position = Vector3(0, 1.0, 0)

	_spell_effects_container.add_child(_lightning_particles)


func _create_rising_sparks() -> void:
	# Rising sparks from the magic circle
	_rising_sparks = GPUParticles3D.new()
	_rising_sparks.name = "RisingSparks"
	_rising_sparks.emitting = false
	_rising_sparks.amount = 60
	_rising_sparks.lifetime = 1.5
	_rising_sparks.one_shot = false
	_rising_sparks.explosiveness = 0.1
	_rising_sparks.visibility_aabb = AABB(Vector3(-4, -1, -4), Vector3(8, 8, 8))

	var mat := ParticleProcessMaterial.new()
	mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
	mat.emission_ring_axis = Vector3(0, 1, 0)
	mat.emission_ring_height = 0.1
	mat.emission_ring_radius = 1.8
	mat.emission_ring_inner_radius = 1.6
	mat.direction = Vector3(0, 1, 0)
	mat.spread = 15.0
	mat.initial_velocity_min = 2.0
	mat.initial_velocity_max = 4.0
	mat.gravity = Vector3(0, 0.5, 0)  # Slight upward pull
	mat.scale_min = 0.03
	mat.scale_max = 0.1

	var gradient := Gradient.new()
	gradient.add_point(0.0, Color(0.5, 0.8, 1.0, 0.0))
	gradient.add_point(0.2, Color(0.4, 0.7, 1.0, 1.0))
	gradient.add_point(0.8, Color(0.3, 0.5, 1.0, 0.8))
	gradient.add_point(1.0, Color(0.2, 0.3, 1.0, 0.0))
	var gradient_tex := GradientTexture1D.new()
	gradient_tex.gradient = gradient
	mat.color_ramp = gradient_tex

	_rising_sparks.process_material = mat

	var mesh := SphereMesh.new()
	mesh.radius = 0.05
	mesh.height = 0.1
	mesh.radial_segments = 6
	mesh.rings = 3

	# Additive blend for glow effect
	var spark_mat := StandardMaterial3D.new()
	spark_mat.albedo_color = Color(0.5, 0.7, 1.0)
	spark_mat.emission_enabled = true
	spark_mat.emission = Color(0.3, 0.5, 1.0)
	spark_mat.emission_energy_multiplier = 5.0
	spark_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD  # Additive blending
	spark_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mesh.material = spark_mat

	_rising_sparks.draw_pass_1 = mesh
	_rising_sparks.position = Vector3(0, 0.1, 0)

	_spell_effects_container.add_child(_rising_sparks)


func _create_lightning_bolts() -> void:
	# Lightning bolt streaks
	_lightning_bolts = GPUParticles3D.new()
	_lightning_bolts.name = "LightningBolts"
	_lightning_bolts.emitting = false
	_lightning_bolts.amount = 20
	_lightning_bolts.lifetime = 0.3
	_lightning_bolts.one_shot = false
	_lightning_bolts.explosiveness = 0.8
	_lightning_bolts.visibility_aabb = AABB(Vector3(-4, -1, -4), Vector3(8, 6, 8))

	var mat := ParticleProcessMaterial.new()
	mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	mat.emission_sphere_radius = 1.5
	mat.direction = Vector3(0, 1, 0)
	mat.spread = 60.0
	mat.initial_velocity_min = 8.0
	mat.initial_velocity_max = 15.0
	mat.gravity = Vector3(0, 0, 0)
	mat.scale_min = 0.02
	mat.scale_max = 0.04

	var gradient := Gradient.new()
	gradient.add_point(0.0, Color(1.0, 1.0, 1.0, 1.0))
	gradient.add_point(0.5, Color(0.5, 0.8, 1.0, 1.0))
	gradient.add_point(1.0, Color(0.2, 0.4, 1.0, 0.0))
	var gradient_tex := GradientTexture1D.new()
	gradient_tex.gradient = gradient
	mat.color_ramp = gradient_tex

	_lightning_bolts.process_material = mat

	# Use stretched quads for bolt-like appearance
	var mesh := QuadMesh.new()
	mesh.size = Vector2(0.02, 0.3)

	# Additive blend for glow effect
	var bolt_mat := StandardMaterial3D.new()
	bolt_mat.albedo_color = Color(0.7, 0.9, 1.0)
	bolt_mat.emission_enabled = true
	bolt_mat.emission = Color(0.5, 0.7, 1.0)
	bolt_mat.emission_energy_multiplier = 10.0
	bolt_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD  # Additive blending
	bolt_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bolt_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mesh.material = bolt_mat

	_lightning_bolts.draw_pass_1 = mesh
	_lightning_bolts.position = Vector3(0, 0.5, 0)

	_spell_effects_container.add_child(_lightning_bolts)


func _create_character_aura_shader() -> void:
	# Create Fresnel aura shader for character glow during casting
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
render_mode unshaded, cull_front;

uniform vec4 aura_color : source_color = vec4(0.3, 0.5, 1.0, 1.0);
uniform vec4 secondary_color : source_color = vec4(0.6, 0.3, 1.0, 1.0);
uniform float intensity : hint_range(0.0, 10.0) = 2.0;
uniform float fresnel_power : hint_range(0.1, 10.0) = 2.0;
uniform float pulse_speed : hint_range(0.0, 20.0) = 8.0;
uniform float scale_offset : hint_range(1.0, 1.2) = 1.02;

void vertex() {
	// Expand mesh slightly outward for aura effect
	VERTEX *= scale_offset;
}

void fragment() {
	// Fresnel effect: stronger glow at edges
	float fresnel = pow(1.0 - abs(dot(NORMAL, VIEW)), fresnel_power);

	// Pulse effect
	float pulse = 0.7 + 0.3 * sin(TIME * pulse_speed);

	// Color mix between blue and purple
	float color_mix = 0.5 + 0.5 * sin(TIME * 3.0);
	vec3 final_color = mix(aura_color.rgb, secondary_color.rgb, color_mix);

	ALBEDO = final_color * intensity * pulse;
	ALPHA = fresnel * aura_color.a * pulse;
	EMISSION = final_color * intensity * fresnel * pulse * 2.0;
}
"""
	_character_aura_material = ShaderMaterial.new()
	_character_aura_material.shader = shader
	_character_aura_material.set_shader_parameter("aura_color", Color(0.3, 0.5, 1.0, 0.8))
	_character_aura_material.set_shader_parameter("secondary_color", Color(0.6, 0.3, 1.0, 0.6))
	_character_aura_material.set_shader_parameter("intensity", 3.0)
	_character_aura_material.set_shader_parameter("fresnel_power", 2.5)
	_character_aura_material.set_shader_parameter("pulse_speed", 12.0)


func _create_procedural_lightning_bolts() -> void:
	# Create Lightning3DBranched instances from the lightning addon
	# Each bolt shoots from the character upward/outward with branching
	for i in range(NUM_LIGHTNING_BOLTS):
		# Create Lightning3DBranched with parameters:
		# subdivisions=10, max_deviation=0.6, branches=4, branch_deviation=0.4, bias=0.5
		var bolt := Lightning3DBranchedClass.new(10, 0.6, 4, 0.4, 0.5, Lightning3DBranchedClass.UPDATE_MODE.ON_PROCESS)
		bolt.name = "LightningBolt3D_%d" % i
		bolt.visible = false
		bolt.maximum_update_delta = 0.08  # Update every ~80ms for animation
		bolt.branches_to_end = false  # Branches spread out

		# Set initial origin/end points (will be updated when spell starts)
		var angle := TAU * i / NUM_LIGHTNING_BOLTS
		bolt.origin = Vector3(0, 0.5, 0)
		bolt.end = Vector3(cos(angle) * 1.5, 3.0, sin(angle) * 1.5)

		_spell_effects_container.add_child(bolt)
		_lightning_bolts_3d.append(bolt)


func _create_spell_audio_system() -> void:
	# Create audio players for spell sound effects
	# NOTE: Audio streams not provided - assign .ogg/.wav files in inspector or load at runtime

	# Scream/power-up sound - plays once at spell start
	_audio_scream = AudioStreamPlayer3D.new()
	_audio_scream.name = "SpellScream"
	_audio_scream.volume_db = -3.0  # Default volume, range [-5, 0]
	_audio_scream.pitch_scale = 1.0  # Range [0.9, 1.1] for variation
	_audio_scream.max_distance = 20.0
	_audio_scream.unit_size = 3.0
	_spell_effects_container.add_child(_audio_scream)

	# Electric static - loops during spell cast
	_audio_static = AudioStreamPlayer3D.new()
	_audio_static.name = "SpellStatic"
	_audio_static.volume_db = -10.0
	_audio_static.max_distance = 15.0
	_audio_static.unit_size = 2.0
	# Note: Set stream.loop = true when audio is assigned
	_spell_effects_container.add_child(_audio_static)

	# Discharge sound - plays once at spell end
	_audio_discharge = AudioStreamPlayer3D.new()
	_audio_discharge.name = "SpellDischarge"
	_audio_discharge.volume_db = -3.0
	_audio_discharge.max_distance = 25.0
	_audio_discharge.unit_size = 4.0
	_spell_effects_container.add_child(_audio_discharge)


func _randomize_lightning_bolt_endpoints() -> void:
	# Set random endpoints for each Lightning3DBranched bolt
	for i in range(_lightning_bolts_3d.size()):
		var bolt = _lightning_bolts_3d[i]
		if not bolt.visible:
			continue

		# Random start/end points around the character
		var angle := TAU * i / _lightning_bolts_3d.size() + randf_range(-0.3, 0.3)
		var height_start := randf_range(0.3, 0.8)
		var height_end := randf_range(2.5, 4.0)
		var radius_start := randf_range(0.2, 0.4)
		var radius_end := randf_range(1.0, 2.0)

		var start := Vector3(cos(angle) * radius_start, height_start, sin(angle) * radius_start)
		var end_angle := angle + randf_range(-0.5, 0.5)
		var end := Vector3(cos(end_angle) * radius_end, height_end, sin(end_angle) * radius_end)

		bolt.set_origin(start)
		bolt.set_end(end)


func _update_spell_effects(delta: float) -> void:
	if not is_casting:
		return

	_spell_time += delta

	# === HEALING DURING SPELL CAST ===
	# Paladin heals self and nearby allies while casting
	_heal_tick_timer += delta
	if _heal_tick_timer >= HEAL_TICK_INTERVAL:
		_heal_tick_timer -= HEAL_TICK_INTERVAL
		_apply_spell_healing()

	# Archer fire circle - update intensity with 1/time decay
	if character_class == CharacterClass.ARCHER and _fire_circle_active:
		_fire_circle_time += delta
		# 1/time intensity decay: starts at full, decays over duration
		# Using 1/(1 + time * decay_rate) to avoid division by zero and smooth start
		var decay_rate := 1.0  # Adjust for speed of decay
		var intensity := 4.0 / (1.0 + _fire_circle_time * decay_rate)
		# Add subtle flicker
		var flicker := sin(_fire_circle_time * 15.0) * 0.3
		_fire_circle_light.light_energy = max(0.2, intensity + flicker)
		return

	# Paladin lightning - flickering light using sin() with high frequency
	var base_energy := 6.0
	var flicker := sin(_spell_time * 20.0) * 2.0 + sin(_spell_time * 33.0) * 1.0 + sin(_spell_time * 47.0) * 0.5
	_spell_light.light_energy = base_energy + flicker

	# Lightning3DBranched auto-updates via ON_PROCESS mode - no manual regeneration needed


## Apply healing to self and nearby players during spell cast
func _apply_spell_healing() -> void:
	# Heal self (but not above max)
	if current_health < max_health:
		heal(HEAL_RATE)
		print("Spell healing: +%.1f HP (now %.1f/%.1f)" % [HEAL_RATE, current_health, max_health])

	# Heal nearby players within HEAL_AREA_RADIUS
	var nearby_players := _get_players_in_range(HEAL_AREA_RADIUS)
	for player in nearby_players:
		if player != self and player.has_method("heal"):
			# Don't heal above their max health
			if player.current_health < player.max_health:
				player.heal(HEAL_RATE)


## Get all players within range of this player
func _get_players_in_range(radius: float) -> Array:
	var players := []

	# Check local player (self is already local)
	# Check remote players from NetworkManager
	if has_node("/root/NetworkManager"):
		var network_manager = get_node("/root/NetworkManager")
		if "remote_players" in network_manager:
			for player_id in network_manager.remote_players:
				var remote_player = network_manager.remote_players[player_id]
				if is_instance_valid(remote_player):
					var dist := global_position.distance_to(remote_player.global_position)
					if dist <= radius:
						players.append(remote_player)

	return players


func _apply_character_aura() -> void:
	# Apply the Fresnel aura shader as overlay on the active character
	var active_char := _armed_character if combat_mode == CombatMode.ARMED else _unarmed_character
	if active_char == null:
		return

	# Find all MeshInstance3D nodes recursively and apply aura
	_original_character_materials.clear()
	_apply_aura_recursive(active_char)
	print("Applied aura to ", _original_character_materials.size(), " meshes")


func _apply_aura_recursive(node: Node) -> void:
	if node is MeshInstance3D:
		var mesh_inst := node as MeshInstance3D
		# Store original material
		_original_character_materials.append({"mesh": mesh_inst, "material": mesh_inst.material_override})
		# Apply aura as next_pass to create overlay effect
		if mesh_inst.material_override:
			var mat := mesh_inst.material_override.duplicate() as Material
			mat.next_pass = _character_aura_material
			mesh_inst.material_override = mat
		else:
			# Create a simple pass-through material with the aura as next_pass
			var base_mat := StandardMaterial3D.new()
			base_mat.next_pass = _character_aura_material
			mesh_inst.material_override = base_mat

	for child in node.get_children():
		_apply_aura_recursive(child)


func _remove_character_aura() -> void:
	# Remove the aura shader and restore original materials
	for entry: Dictionary in _original_character_materials:
		var mesh_inst: MeshInstance3D = entry.mesh
		if is_instance_valid(mesh_inst):
			mesh_inst.material_override = entry.material
	_original_character_materials.clear()


func _start_spell_effects() -> void:
	if _spell_tween:
		_spell_tween.kill()

	# Reset spell time for flickering
	_spell_time = 0.0

	_spell_tween = create_tween()
	_spell_tween.set_parallel(true)

	# Archer uses fire circle, Paladin uses lightning
	if character_class == CharacterClass.ARCHER:
		_start_fire_circle_spell()
	else:
		_start_lightning_spell()


func _start_lightning_spell() -> void:
	# Paladin lightning spell effects
	# Show and animate magic circle
	_magic_circle.visible = true
	_magic_circle.scale = Vector3(0.01, 0.01, 0.01)
	_spell_tween.tween_property(_magic_circle, "scale", Vector3(1.0, 1.0, 1.0), 0.4).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)

	# Show and animate force field sphere (V2: bubble shield)
	_force_field_sphere.visible = true
	_force_field_sphere.scale = Vector3(0.01, 0.01, 0.01)
	_spell_tween.tween_property(_force_field_sphere, "scale", Vector3(1.0, 1.0, 1.0), 0.5).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_ELASTIC)

	# Animate force field constant light (non-flickering, steady glow)
	_force_field_light.light_energy = 0.0
	_spell_tween.tween_property(_force_field_light, "light_energy", 2.0, 0.4).set_ease(Tween.EASE_OUT)

	# Animate spell light (initial value, will be modulated by _update_spell_effects)
	_spell_light.light_energy = 0.0
	_spell_tween.tween_property(_spell_light, "light_energy", 6.0, 0.3).set_ease(Tween.EASE_OUT)

	# Start all particles
	_lightning_particles.emitting = true
	_rising_sparks.emitting = true
	_lightning_bolts.emitting = true

	# Rotate magic circle
	_spell_tween.tween_property(_magic_circle, "rotation_degrees:y", 360.0, 2.0).from(0.0)

	# Show 3D lightning bolts (addon-based with animated shader)
	for bolt in _lightning_bolts_3d:
		bolt.visible = true
	_randomize_lightning_bolt_endpoints()

	# Apply character aura
	_apply_character_aura()

	# Start audio (only plays if streams are assigned)
	if _audio_scream.stream:
		_audio_scream.pitch_scale = randf_range(0.9, 1.1)  # Slight pitch variation
		_audio_scream.play()
	if _audio_static.stream:
		_audio_static.play()


func _start_fire_circle_spell() -> void:
	# Archer fire circle spell - flames stay lit for FIRE_CIRCLE_DURATION with 1/time decay
	_fire_circle_active = true
	_fire_circle_time = 0.0

	# Start fire light (intensity will be managed by _update_spell_effects)
	_fire_circle_light.light_energy = 4.0

	# Start all fire emitters
	for fire in _fire_circle_particles:
		fire.emitting = true

	# Schedule auto-stop after FIRE_CIRCLE_DURATION
	_spell_tween.tween_callback(_stop_fire_circle_spell).set_delay(FIRE_CIRCLE_DURATION)


func _stop_fire_circle_spell() -> void:
	# Stop the Archer fire circle spell effects
	_fire_circle_active = false

	var fade_tween = create_tween()
	fade_tween.set_parallel(true)

	# Fade out fire light
	if _fire_circle_light:
		fade_tween.tween_property(_fire_circle_light, "light_energy", 0.0, 0.5).set_ease(Tween.EASE_IN)

	# Stop all fire emitters
	for fire in _fire_circle_particles:
		fire.emitting = false


func _stop_spell_effects() -> void:
	if _spell_tween:
		_spell_tween.kill()

	# Branch by character class
	if character_class == CharacterClass.ARCHER:
		_stop_fire_circle_spell()
		return

	# Paladin lightning spell cleanup
	_spell_tween = create_tween()
	_spell_tween.set_parallel(true)

	# Shrink magic circle
	_spell_tween.tween_property(_magic_circle, "scale", Vector3(0.01, 0.01, 0.01), 0.3).set_ease(Tween.EASE_IN)
	_spell_tween.tween_callback(func(): _magic_circle.visible = false).set_delay(0.3)

	# Shrink and hide force field sphere (V2: bubble shield collapse)
	_spell_tween.tween_property(_force_field_sphere, "scale", Vector3(0.01, 0.01, 0.01), 0.4).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_BACK)
	_spell_tween.tween_callback(func(): _force_field_sphere.visible = false).set_delay(0.4)

	# Fade out force field constant light
	_spell_tween.tween_property(_force_field_light, "light_energy", 0.0, 0.3).set_ease(Tween.EASE_IN)

	# Fade out spell light
	_spell_tween.tween_property(_spell_light, "light_energy", 0.0, 0.4).set_ease(Tween.EASE_IN)

	# Stop particles
	_lightning_particles.emitting = false
	_rising_sparks.emitting = false
	_lightning_bolts.emitting = false

	# Hide 3D lightning bolts
	for bolt in _lightning_bolts_3d:
		bolt.visible = false

	# Remove character aura
	_remove_character_aura()

	# Stop audio and play discharge (only plays if streams are assigned)
	if _audio_static.playing:
		_audio_static.stop()
	if _audio_discharge.stream:
		_audio_discharge.play()


func _get_unarmed_config() -> Dictionary:
	return {
		"idle": ["Idle", true],
		"walk": ["Walk", true],
		"run": ["Run", true],
		"strafe_left": ["StrafeLeft", true],
		"strafe_right": ["StrafeRight", true],
		"jump": ["Jump", false],
		"turn_left": ["TurnLeft", false],
		"turn_right": ["TurnRight", false],
		"attack": ["Attack", false],
		"block": ["Block", true],
		"action_to_idle": ["ActionToIdle", false],
		"idle_to_fight": ["IdleToFight", false],
	}


func _get_armed_config() -> Dictionary:
	return {
		"idle": ["Idle", true],
		"walk": ["Walk", true],
		"run": ["Run", true],
		"jump": ["Jump", false],
		"attack1": ["Attack1", false],
		"attack2": ["Attack2", false],
		"sword_slash": ["SwordSlash", false],
		"block": ["Block", true],
		"sheath": ["Sheath", false],
		"spell_cast": ["SpellCast", false],
	}


func _get_archer_config() -> Dictionary:
	return {
		"idle": ["Idle", true],
		"walk": ["Walk", true],
		"run": ["Run", true],
		"jump": ["Jump", false],
		"attack": ["Attack", false],
		"block": ["Block", true],
		"sprint": ["Sprint", true],
		"spell_cast": ["SpellCast", false],
	}


func _load_character(path: String, name: String, fallback_color: Color) -> Node3D:
	var scene: PackedScene = load(path) as PackedScene
	if scene == null:
		print("Failed to load character: ", path)
		return null

	var instance: Node3D = scene.instantiate() as Node3D
	if instance == null:
		print("Failed to instantiate character: ", path)
		return null

	instance.name = name

	# Scale character appropriately
	var skeleton: Skeleton3D = _find_skeleton(instance)
	if skeleton and skeleton.get_bone_count() > 0:
		var hips_idx: int = skeleton.find_bone("mixamorig_Hips")
		if hips_idx >= 0:
			var hips_pos: Vector3 = skeleton.get_bone_global_rest(hips_idx).origin
			if hips_pos.y > 50:
				instance.scale = Vector3(0.01, 0.01, 0.01)
			else:
				instance.scale = Vector3(1.0, 1.0, 1.0)
		else:
			instance.scale = Vector3(0.01, 0.01, 0.01)
	else:
		instance.scale = Vector3(0.01, 0.01, 0.01)

	# Only apply fallback material if character has no textures (like Y Bot)
	# Paladin and other textured characters keep their original materials
	if not _character_has_textures(instance):
		_apply_character_material(instance, fallback_color)

	print("Loaded character: ", name, " from ", path)
	return instance


func _character_has_textures(node: Node) -> bool:
	# Check if any mesh has a material with a texture
	if node is MeshInstance3D:
		var mi: MeshInstance3D = node as MeshInstance3D
		for i in range(mi.get_surface_override_material_count()):
			var mat: Material = mi.get_surface_override_material(i)
			if mat == null and mi.mesh:
				mat = mi.mesh.surface_get_material(i)
			if mat is StandardMaterial3D:
				var std_mat: StandardMaterial3D = mat as StandardMaterial3D
				if std_mat.albedo_texture != null:
					return true

	for child in node.get_children():
		if _character_has_textures(child):
			return true

	return false


func _load_animations_for_character(anim_player: AnimationPlayer, paths: Dictionary, config: Dictionary, library_prefix: String, character: Node3D) -> void:
	var skeleton: Skeleton3D = _find_skeleton(character)
	if skeleton == null:
		print("ERROR: No skeleton found for character!")
		return

	var anim_root: Node = anim_player.get_node(anim_player.root_node)
	var skel_path: String = str(anim_root.get_path_to(skeleton))
	print("Loading animations for ", library_prefix, " - skeleton path: ", skel_path)

	for anim_key in paths:
		var fbx_path: String = paths[anim_key]
		var scene: PackedScene = load(fbx_path) as PackedScene
		if scene == null:
			print("  Failed to load FBX: ", fbx_path)
			continue

		var instance: Node3D = scene.instantiate()
		var anim_player_src: AnimationPlayer = _find_animation_player(instance)
		if anim_player_src == null:
			print("  No AnimationPlayer in: ", fbx_path)
			instance.queue_free()
			continue

		# Find best animation
		var best_anim: Animation = null
		var best_anim_name: String = ""
		var best_key_count: int = 0

		for src_lib_name in anim_player_src.get_animation_library_list():
			var src_lib: AnimationLibrary = anim_player_src.get_animation_library(src_lib_name)
			for src_anim_name in src_lib.get_animation_list():
				var anim: Animation = src_lib.get_animation(src_anim_name)
				var total_keys: int = 0
				for t in range(anim.get_track_count()):
					total_keys += anim.track_get_key_count(t)
				var keys_per_track: float = float(total_keys) / max(anim.get_track_count(), 1)
				if total_keys > best_key_count and keys_per_track > 1.5:
					best_anim = anim
					best_anim_name = src_anim_name
					best_key_count = total_keys

		if best_anim != null:
			var new_anim: Animation = best_anim.duplicate()
			var anim_config: Array = config.get(anim_key, [anim_key, false])
			new_anim.loop_mode = Animation.LOOP_LINEAR if anim_config[1] else Animation.LOOP_NONE

			# Retarget animation
			_retarget_animation(new_anim, skel_path, skeleton)

			var lib_name: StringName = StringName(library_prefix)
			if not anim_player.has_animation_library(lib_name):
				anim_player.add_animation_library(lib_name, AnimationLibrary.new())
			anim_player.get_animation_library(lib_name).add_animation(StringName(anim_config[0]), new_anim)
			print("  Loaded: ", library_prefix, "/", anim_config[0])

		instance.queue_free()


func _find_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node as AnimationPlayer
	for child in node.get_children():
		var result: AnimationPlayer = _find_animation_player(child)
		if result != null:
			return result
	return null


func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node as Skeleton3D
	for child in node.get_children():
		var result: Skeleton3D = _find_skeleton(child)
		if result != null:
			return result
	return null


func _apply_character_material(node: Node, color: Color) -> void:
	if node is MeshInstance3D:
		var mi: MeshInstance3D = node as MeshInstance3D
		var material := StandardMaterial3D.new()
		material.albedo_color = color
		material.roughness = 0.7
		material.metallic = 0.0
		for i in range(mi.get_surface_override_material_count()):
			mi.set_surface_override_material(i, material)

	for child in node.get_children():
		_apply_character_material(child, color)


func _retarget_animation(anim: Animation, target_skeleton_path: String, skeleton: Skeleton3D) -> void:
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


func _on_animation_finished(anim_name: StringName) -> void:
	# Reset archer bow states when attack animation finishes
	if character_class == CharacterClass.ARCHER and anim_name == &"archer/Attack":
		is_drawing_bow = false
		is_holding_bow = false
		is_attacking = false
		_attack_cooldown = 0.0  # No cooldown - allow immediate next action
		_bow_draw_time = 0.0
		# Immediately transition to idle (allows walking right away)
		if _archer_anim_player and _archer_anim_player.has_animation(&"archer/Idle"):
			_archer_anim_player.play(&"archer/Idle")
			_current_anim = &"archer/Idle"
		return

	if is_attacking:
		is_attacking = false
		disable_attack_hitbox()  # Disable hitbox when attack ends
		_attack_cooldown = 0.2
		# Play transition from attack to idle (unarmed mode only)
		if combat_mode == CombatMode.UNARMED and _current_anim_player.has_animation(&"unarmed/ActionToIdle"):
			is_transitioning = true
			_current_anim_player.play(&"unarmed/ActionToIdle")
			_current_anim = &"unarmed/ActionToIdle"
	if is_casting:
		is_casting = false
		_stop_spell_effects()
	if is_transitioning:
		# Transition animation finished
		if anim_name == &"unarmed/ActionToIdle" or anim_name == &"unarmed/IdleToFight":
			is_transitioning = false
	if is_sheathing:
		is_sheathing = false


func _play_anim(anim_name: StringName) -> void:
	if _current_anim_player == null:
		return
	if _current_anim == anim_name:
		return
	if _current_anim_player.has_animation(anim_name):
		_current_anim_player.play(anim_name)
		_current_anim = anim_name


func _get_current_mode_prefix() -> String:
	if character_class == CharacterClass.ARCHER:
		return "archer"
	return "armed" if combat_mode == CombatMode.ARMED else "unarmed"


func _update_animation(input_dir: Vector2) -> void:
	if _current_anim_player == null:
		return

	if is_attacking or is_sheathing or is_transitioning or is_casting or is_drawing_bow or is_holding_bow:
		return

	var prefix: String = _get_current_mode_prefix()
	var desired_anim: StringName = &""

	# Jump takes priority
	if not is_on_floor():
		if is_jumping:
			var jump_anim: StringName = StringName(prefix + "/Jump")
			if _current_anim_player.has_animation(jump_anim):
				desired_anim = jump_anim
		if desired_anim == &"":
			return

	# Blocking (both modes - shield in armed, center block in unarmed)
	elif is_blocking:
		var block_anim: StringName = StringName(prefix + "/Block")
		if _current_anim_player.has_animation(block_anim):
			desired_anim = block_anim

	# Strafe
	elif abs(input_dir.x) > 0.5 and abs(input_dir.y) < 0.3:
		var strafe_dir: String = "StrafeLeft" if input_dir.x < 0 else "StrafeRight"
		var strafe_anim: StringName = StringName(prefix + "/" + strafe_dir)
		if _current_anim_player.has_animation(strafe_anim):
			desired_anim = strafe_anim
		else:
			# Fallback to left strafe or walk
			var fallback_strafe: StringName = StringName(prefix + "/StrafeLeft")
			if _current_anim_player.has_animation(fallback_strafe):
				desired_anim = fallback_strafe
			else:
				var walk_anim: StringName = StringName(prefix + "/Walk")
				if _current_anim_player.has_animation(walk_anim):
					desired_anim = walk_anim

	# Running/Sprinting (Shift key held)
	elif is_running and input_dir.length() > 0.1:
		# Try Run first, then Sprint, then Walk
		var run_anim: StringName = StringName(prefix + "/Run")
		var sprint_anim: StringName = StringName(prefix + "/Sprint")
		if _current_anim_player.has_animation(run_anim):
			desired_anim = run_anim
		elif _current_anim_player.has_animation(sprint_anim):
			desired_anim = sprint_anim
		else:
			var walk_anim: StringName = StringName(prefix + "/Walk")
			if _current_anim_player.has_animation(walk_anim):
				desired_anim = walk_anim

	# Walking
	elif input_dir.length() > 0.1:
		var walk_anim: StringName = StringName(prefix + "/Walk")
		if _current_anim_player.has_animation(walk_anim):
			desired_anim = walk_anim

	# Idle
	else:
		var idle_anim: StringName = StringName(prefix + "/Idle")
		if _current_anim_player.has_animation(idle_anim):
			desired_anim = idle_anim

	if desired_anim != &"":
		_play_anim(desired_anim)


func _toggle_combat_mode() -> void:
	if is_sheathing:
		return

	# Archer class doesn't have unarmed/armed modes
	if character_class == CharacterClass.ARCHER:
		print("Archer class only has one combat mode")
		return

	if combat_mode == CombatMode.UNARMED:
		# Switch to armed mode
		combat_mode = CombatMode.ARMED
		_unarmed_character.visible = false
		_armed_character.visible = true
		_current_anim_player = _armed_anim_player
		_current_anim = &""

		# Play idle animation
		if _armed_anim_player.has_animation(&"armed/Idle"):
			_armed_anim_player.play(&"armed/Idle")
			_current_anim = &"armed/Idle"

		print("Switched to ARMED mode (Paladin)")
	else:
		# Switch to unarmed mode
		combat_mode = CombatMode.UNARMED
		_armed_character.visible = false
		_unarmed_character.visible = true
		_current_anim_player = _unarmed_anim_player
		_current_anim = &""

		# Play idle animation
		if _unarmed_anim_player.has_animation(&"unarmed/Idle"):
			_unarmed_anim_player.play(&"unarmed/Idle")
			_current_anim = &"unarmed/Idle"

		print("Switched to UNARMED mode (Paladin)")


func _switch_character_class(new_class: CharacterClass) -> void:
	if character_class == new_class:
		return

	# Hide all characters first
	if _unarmed_character:
		_unarmed_character.visible = false
	if _armed_character:
		_armed_character.visible = false
	if _archer_character:
		_archer_character.visible = false

	character_class = new_class

	match new_class:
		CharacterClass.PALADIN:
			# Set Paladin health
			max_health = PALADIN_MAX_HP
			current_health = PALADIN_MAX_HP
			# Show Paladin based on current combat mode
			if combat_mode == CombatMode.ARMED:
				if _armed_character:
					_armed_character.visible = true
				_current_anim_player = _armed_anim_player
				if _armed_anim_player and _armed_anim_player.has_animation(&"armed/Idle"):
					_armed_anim_player.play(&"armed/Idle")
					_current_anim = &"armed/Idle"
			else:
				if _unarmed_character:
					_unarmed_character.visible = true
				_current_anim_player = _unarmed_anim_player
				if _unarmed_anim_player and _unarmed_anim_player.has_animation(&"unarmed/Idle"):
					_unarmed_anim_player.play(&"unarmed/Idle")
					_current_anim = &"unarmed/Idle"
			print("Switched to PALADIN class (HP: %.0f)" % max_health)

		CharacterClass.ARCHER:
			# Set Archer health
			max_health = ARCHER_MAX_HP
			current_health = ARCHER_MAX_HP
			# Show Archer character
			if _archer_character:
				_archer_character.visible = true
			_current_anim_player = _archer_anim_player
			if _archer_anim_player and _archer_anim_player.has_animation(&"archer/Idle"):
				_archer_anim_player.play(&"archer/Idle")
				_current_anim = &"archer/Idle"
			print("Switched to ARCHER class (HP: %.0f)" % max_health)

	health_changed.emit(current_health, max_health)


func _shoot_arrow() -> void:
	# Create arrow instance
	var arrow = ArrowScene.instantiate()
	arrow.shooter = self
	arrow.is_local = true

	# Get camera direction for aiming
	var camera = _camera_pivot.get_node("Camera3D") as Camera3D
	var spawn_pos = global_position + Vector3(0, 1.5, 0)  # Spawn at chest height

	# Calculate direction from camera
	var forward = -camera.global_transform.basis.z
	var aim_direction = forward.normalized()

	# Add some upward arc for parabolic trajectory
	aim_direction.y += 0.15

	# Broadcast arrow spawn to network
	if has_node("/root/NetworkManager"):
		var network_manager = get_node("/root/NetworkManager")
		arrow.shooter_id = network_manager.my_player_id
		arrow.arrow_id = network_manager.send_arrow_spawn(spawn_pos, aim_direction, network_manager.my_player_id)

	# Add arrow to scene
	get_tree().current_scene.add_child(arrow)
	arrow.global_position = spawn_pos
	arrow.launch(aim_direction)


func _start_bow_draw() -> void:
	# Start drawing the bow (on left-click press)
	if is_drawing_bow or is_holding_bow or is_attacking or _attack_cooldown > 0:
		return

	is_drawing_bow = true
	is_holding_bow = false
	_bow_draw_time = 0.0

	# Show progress bar
	if _bow_progress_bar:
		_bow_progress_bar.value = 0.0
		_bow_progress_bar.visible = true
		var ready_label = _bow_progress_bar.get_parent().get_node_or_null("ReadyLabel")
		if ready_label:
			ready_label.text = ""

	# Play draw animation from the beginning
	if _archer_anim_player and _archer_anim_player.has_animation(&"archer/Attack"):
		_archer_anim_player.play(&"archer/Attack")
		_current_anim = &"archer/Attack"


func _update_bow_draw(delta: float) -> void:
	# Update bow draw progress based on time
	if not is_drawing_bow:
		# Hide progress bar when not drawing
		if _bow_progress_bar and _bow_progress_bar.visible and not is_holding_bow:
			_bow_progress_bar.visible = false
		return

	if is_holding_bow:
		return

	# Increment draw time
	_bow_draw_time += delta

	# Update progress bar
	var progress: float = clampf(_bow_draw_time / BOW_DRAW_TIME_REQUIRED, 0.0, 1.0)
	if _bow_progress_bar:
		_bow_progress_bar.value = progress

		# Update ready label and bar color when complete
		var ready_label = _bow_progress_bar.get_parent().get_node_or_null("ReadyLabel")
		if progress >= 1.0:
			if ready_label:
				ready_label.text = "READY!"
			# Change bar to green when ready
			var style_fill = _bow_progress_bar.get_theme_stylebox("fill") as StyleBoxFlat
			if style_fill:
				style_fill.bg_color = Color(0.2, 1.0, 0.3)  # Green

	# Check if draw time reached
	if _bow_draw_time >= BOW_DRAW_TIME_REQUIRED:
		is_drawing_bow = false
		is_holding_bow = true
		# Pause animation at current position
		if _archer_anim_player:
			_archer_anim_player.pause()


func _release_bow() -> void:
	# Release the arrow (on left-click release)
	if not is_drawing_bow and not is_holding_bow:
		return

	# Hide progress bar
	if _bow_progress_bar:
		_bow_progress_bar.visible = false
		# Reset bar color to orange
		var style_fill = _bow_progress_bar.get_theme_stylebox("fill") as StyleBoxFlat
		if style_fill:
			style_fill.bg_color = Color(1.0, 0.6, 0.2)  # Orange
		var ready_label = _bow_progress_bar.get_parent().get_node_or_null("ReadyLabel")
		if ready_label:
			ready_label.text = ""

	# If still drawing (released early before 0.3s), just cancel
	if is_drawing_bow and not is_holding_bow:
		is_drawing_bow = false
		_bow_draw_time = 0.0
		# Return to idle
		if _archer_anim_player and _archer_anim_player.has_animation(&"archer/Idle"):
			_archer_anim_player.play(&"archer/Idle")
			_current_anim = &"archer/Idle"
		return

	# Arrow is ready - shoot it
	is_holding_bow = false
	_bow_draw_time = 0.0

	# Shoot the arrow
	_shoot_arrow()

	# Quick transition back to idle for responsiveness
	if _archer_anim_player and _archer_anim_player.has_animation(&"archer/Idle"):
		_archer_anim_player.play(&"archer/Idle")
		_current_anim = &"archer/Idle"


func _do_attack() -> void:
	if is_attacking or _attack_cooldown > 0:
		return

	is_attacking = true

	# Paladin class uses melee attacks
	enable_attack_hitbox()  # Enable hitbox when attack starts

	if combat_mode == CombatMode.ARMED:
		# Use SwordSlash as primary attack, fall back to Attack1/Attack2
		var attack_anim: StringName = &"armed/SwordSlash"
		if not _current_anim_player.has_animation(attack_anim):
			attack_combo = (attack_combo + 1) % 2
			attack_anim = &"armed/Attack1" if attack_combo == 0 else &"armed/Attack2"
		if _current_anim_player.has_animation(attack_anim):
			_current_anim_player.play(attack_anim)
			_current_anim = attack_anim
		else:
			is_attacking = false
			disable_attack_hitbox()
	else:
		# Unarmed boxing attack - play transition first if coming from idle
		if _current_anim == &"unarmed/Idle" and _current_anim_player.has_animation(&"unarmed/IdleToFight"):
			# Play idle to fight transition, then queue attack
			_current_anim_player.play(&"unarmed/IdleToFight")
			_current_anim_player.queue(&"unarmed/Attack")
			_current_anim = &"unarmed/IdleToFight"
		elif _current_anim_player.has_animation(&"unarmed/Attack"):
			_current_anim_player.play(&"unarmed/Attack")
			_current_anim = &"unarmed/Attack"
		else:
			is_attacking = false
			disable_attack_hitbox()


func _do_spell_cast() -> void:
	# Allow spell cast in armed mode (Paladin) or for Archer class
	if character_class == CharacterClass.PALADIN and combat_mode != CombatMode.ARMED:
		return
	if is_casting or is_attacking or _attack_cooldown > 0:
		return
	# Archer cannot cast while drawing/holding bow
	if is_drawing_bow or is_holding_bow:
		return

	is_casting = true

	# Start all spell effects
	_start_spell_effects()

	# Play spell cast animation based on character class
	var spell_anim: StringName
	if character_class == CharacterClass.ARCHER:
		spell_anim = &"archer/SpellCast"
	else:
		spell_anim = &"armed/SpellCast"

	if _current_anim_player.has_animation(spell_anim):
		_current_anim_player.play(spell_anim)
		_current_anim = spell_anim
	else:
		is_casting = false
		_stop_spell_effects()
		print("SpellCast animation not found: ", spell_anim)


## Combat - Take damage and knockback from enemy attacks
func take_hit(damage: float, knockback: Vector3, blocked: bool) -> void:
	# Check spawn immunity
	if is_spawn_immune():
		print("Player: Hit ignored - spawn immunity active (%.1fs remaining)" % _spawn_immunity_timer)
		return

	# Show floating "Hit!" label
	_show_hit_label()

	var actual_damage := damage
	if blocked:
		# Blocked hit - blue flash, reduced knockback, reduced damage
		_flash_hit(Color(0.2, 0.4, 1.0))
		_knockback_velocity = knockback * PLAYER_KNOCKBACK_RESISTANCE * 0.3
		actual_damage = damage * 0.3  # Block reduces damage by 70%
	else:
		# Unblocked hit - red flash, full knockback, stun
		_flash_hit(Color(1.0, 0.2, 0.2))
		_knockback_velocity = knockback * PLAYER_KNOCKBACK_RESISTANCE
		_is_stunned = true
		_stun_timer = 0.25
		is_attacking = false  # Cancel attack if hit

		# Interrupt spell casting if hit (Bobba hit stops spells)
		if is_casting:
			_interrupt_spell()

	# Apply damage
	take_damage(actual_damage)
	print("Player hit! Damage: %.1f (blocked: %s) HP: %.1f/%.1f" % [actual_damage, blocked, current_health, max_health])


## Take damage from any source
func take_damage(amount: float) -> void:
	# Check spawn immunity
	if is_spawn_immune():
		print("Player: Damage ignored - spawn immunity active (%.1fs remaining)" % _spawn_immunity_timer)
		return

	var old_health = current_health
	current_health = maxf(0.0, current_health - amount)
	print("Player: take_damage(%.1f) - HP: %.1f -> %.1f" % [amount, old_health, current_health])
	health_changed.emit(current_health, max_health)

	if current_health <= 0:
		_on_player_death()


## Heal the player (from spells, potions, etc.)
func heal(amount: float) -> void:
	# Can't heal above max health
	current_health = minf(max_health, current_health + amount)
	health_changed.emit(current_health, max_health)


## Called when player health reaches 0
func _on_player_death() -> void:
	print("Player died!")
	player_died.emit()
	# Restart the game after a short delay
	_trigger_game_restart("Player died!")


## Trigger game restart (called when player or Bobba dies)
func _trigger_game_restart(reason: String) -> void:
	print("Game restarting: ", reason)

	# In multiplayer, send restart to server which broadcasts to all clients
	if enable_multiplayer and has_node("/root/NetworkManager"):
		var network_manager = get_node("/root/NetworkManager")
		# Defensive check for method existence (handles script caching issues)
		if network_manager.has_method("is_network_connected") and network_manager.is_network_connected():
			# Determine restart reason code
			var reason_code := 2  # Manual restart
			if "Player" in reason or "died" in reason:
				reason_code = 0  # Player died
			elif "Bobba" in reason:
				reason_code = 1  # Bobba died
			network_manager.send_game_restart(reason_code)
			# Show message while waiting for server response
			_show_restart_message(reason + "\n\nWaiting for respawn...")
			return

	# Singleplayer: show message and reload scene
	_show_restart_message(reason)
	var timer = get_tree().create_timer(2.0)
	timer.timeout.connect(_reload_game)


func _show_restart_message(reason: String) -> void:
	# Create a centered message overlay
	var canvas = CanvasLayer.new()
	canvas.name = "RestartOverlay"
	canvas.layer = 100  # Above everything
	get_tree().current_scene.add_child(canvas)

	var panel = ColorRect.new()
	panel.color = Color(0, 0, 0, 0.7)
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	canvas.add_child(panel)

	var label = Label.new()
	label.text = reason + "\n\nRestarting..."
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.set_anchors_preset(Control.PRESET_FULL_RECT)
	label.add_theme_font_size_override("font_size", 48)
	label.add_theme_color_override("font_color", Color(1, 0.3, 0.3))
	canvas.add_child(label)


func _reload_game() -> void:
	get_tree().reload_current_scene()


## Handle game restart broadcast from server (synchronized respawn)
func _on_game_restart_received(reason: int) -> void:
	print("Player: Game restart received from server (reason: %d)" % reason)

	# Remove any restart overlay
	var overlay = get_tree().current_scene.get_node_or_null("RestartOverlay")
	if overlay:
		overlay.queue_free()

	# Respawn this player
	_respawn()


## Spawn positions at foot of hills near Tower of Hakutnas (matching server)
const SPAWN_POINTS = [
	Vector3(-60.0, 2.0, -80.0),   # Near tower, foot of hills area
	Vector3(-40.0, 2.0, -100.0),  # Between tower and TheHills
	Vector3(-80.0, 2.0, -40.0),   # Other side of tower
]

## Spawn immunity duration in seconds
const SPAWN_IMMUNITY_DURATION: float = 2.0

## Current spawn immunity timer
var _spawn_immunity_timer: float = 0.0


## Check if player is currently immune to damage (just spawned)
func is_spawn_immune() -> bool:
	return _spawn_immunity_timer > 0.0


## Spawn player at foot of hills near tower (called at game start and respawn)
func _spawn_at_tower() -> void:
	var spawn_idx = randi() % SPAWN_POINTS.size()
	var angle = randf() * TAU
	var offset = randf_range(0.0, 8.0)
	var spawn_pos = SPAWN_POINTS[spawn_idx] + Vector3(
		cos(angle) * offset,
		0.0,
		sin(angle) * offset
	)
	global_position = spawn_pos

	# Grant spawn immunity
	_spawn_immunity_timer = SPAWN_IMMUNITY_DURATION
	print("Player: Spawned at point %d (%.1f, %.1f, %.1f) - immune for %.1fs" % [spawn_idx + 1, spawn_pos.x, spawn_pos.y, spawn_pos.z, SPAWN_IMMUNITY_DURATION])


## Respawn player without reloading scene (keeps character class, resets health/position)
func _respawn() -> void:
	print("Player: Respawning...")

	# Reset health
	current_health = max_health
	health_changed.emit(current_health, max_health)

	# Reset state
	is_attacking = false
	is_blocking = false
	is_casting = false
	is_drawing_bow = false
	is_holding_bow = false
	_is_stunned = false
	_stun_timer = 0.0
	_knockback_velocity = Vector3.ZERO
	velocity = Vector3.ZERO

	# Stop any spell effects
	_stop_spell_effects()

	# Spawn on a random hill
	_spawn_at_tower()

	# Re-connect to Bobba's death signal (Bobba was also respawned)
	call_deferred("_connect_bobba_death_signal")


## Connect to Bobba's death signal for game restart
func _connect_bobba_death_signal() -> void:
	# Find Bobba in the scene
	var bobba = get_tree().get_first_node_in_group("bobba")
	if bobba == null:
		# Try to find by class name
		for node in get_tree().get_nodes_in_group(""):
			if node is Bobba:
				bobba = node
				break
	if bobba == null:
		# Search the scene tree
		bobba = _find_node_by_class(get_tree().current_scene, "Bobba")

	if bobba and bobba.has_signal("died"):
		if not bobba.died.is_connected(_on_bobba_died):
			bobba.died.connect(_on_bobba_died)
			print("Player: Connected to Bobba death signal")
	else:
		print("Player: Could not find Bobba to connect death signal")


func _find_node_by_class(node: Node, class_name_str: String) -> Node:
	if node.get_class() == class_name_str or (node.get_script() and node.get_script().get_global_name() == class_name_str):
		return node
	for child in node.get_children():
		var result = _find_node_by_class(child, class_name_str)
		if result:
			return result
	return null


func _on_bobba_died() -> void:
	print("Bobba defeated!")
	_trigger_game_restart("Bobba defeated!")


## Interrupt spell casting (called when hit by Bobba)
func _interrupt_spell() -> void:
	if not is_casting:
		return

	print("Spell interrupted!")
	is_casting = false
	_stop_spell_effects()
	_heal_tick_timer = 0.0


func _flash_hit(color: Color) -> void:
	if _hit_flash_tween:
		_hit_flash_tween.kill()

	# Apply color flash to active character model
	var active_char = _armed_character if combat_mode == CombatMode.ARMED else _unarmed_character
	if active_char:
		_apply_hit_flash_recursive(active_char, color)

		# Reset after short delay
		_hit_flash_tween = create_tween()
		_hit_flash_tween.tween_callback(func(): _clear_hit_flash_recursive(active_char)).set_delay(0.15)


func _apply_hit_flash_recursive(node: Node, color: Color) -> void:
	if node is MeshInstance3D:
		var mesh_inst := node as MeshInstance3D
		var mat = mesh_inst.material_override
		if mat == null and mesh_inst.mesh:
			# Create override material if needed
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


func _setup_hit_label() -> void:
	# Create floating "Hit!" label above player
	_hit_label = Label3D.new()
	_hit_label.name = "HitLabel"
	_hit_label.text = "Hit!"
	_hit_label.font_size = 64
	_hit_label.modulate = Color(0.2, 0.4, 1.0)  # Blue for player
	_hit_label.outline_modulate = Color(0.0, 0.0, 0.3)
	_hit_label.outline_size = 8
	_hit_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_hit_label.no_depth_test = true  # Always visible
	_hit_label.position = Vector3(0, 2.5, 0)  # Above head
	_hit_label.visible = false
	add_child(_hit_label)


func _setup_bow_progress_bar() -> void:
	# Create CanvasLayer for HUD elements
	var canvas = CanvasLayer.new()
	canvas.name = "BowHUD"
	add_child(canvas)

	# Create container centered at bottom of screen
	var container = CenterContainer.new()
	container.name = "ProgressContainer"
	container.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	container.offset_top = -100
	container.offset_bottom = -60
	container.offset_left = -100
	container.offset_right = 100
	canvas.add_child(container)

	# Create VBox for progress bar and label
	var vbox = VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	container.add_child(vbox)

	# Create progress bar
	_bow_progress_bar = ProgressBar.new()
	_bow_progress_bar.name = "BowProgressBar"
	_bow_progress_bar.custom_minimum_size = Vector2(200, 20)
	_bow_progress_bar.min_value = 0.0
	_bow_progress_bar.max_value = 1.0
	_bow_progress_bar.value = 0.0
	_bow_progress_bar.show_percentage = false
	_bow_progress_bar.visible = false

	# Style the progress bar
	var style_bg = StyleBoxFlat.new()
	style_bg.bg_color = Color(0.1, 0.1, 0.1, 0.8)
	style_bg.corner_radius_top_left = 4
	style_bg.corner_radius_top_right = 4
	style_bg.corner_radius_bottom_left = 4
	style_bg.corner_radius_bottom_right = 4
	_bow_progress_bar.add_theme_stylebox_override("background", style_bg)

	var style_fill = StyleBoxFlat.new()
	style_fill.bg_color = Color(1.0, 0.6, 0.2)  # Orange like fire arrow
	style_fill.corner_radius_top_left = 4
	style_fill.corner_radius_top_right = 4
	style_fill.corner_radius_bottom_left = 4
	style_fill.corner_radius_bottom_right = 4
	_bow_progress_bar.add_theme_stylebox_override("fill", style_fill)

	vbox.add_child(_bow_progress_bar)

	# Add "Ready!" label below progress bar
	var ready_label = Label.new()
	ready_label.name = "ReadyLabel"
	ready_label.text = ""
	ready_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ready_label.add_theme_color_override("font_color", Color(0.2, 1.0, 0.2))
	ready_label.add_theme_font_size_override("font_size", 16)
	vbox.add_child(ready_label)


func _setup_health_bar() -> void:
	# Create a CanvasLayer for the health bar UI
	var canvas = CanvasLayer.new()
	canvas.name = "HealthBarUI"
	canvas.layer = 10  # Above other UI
	add_child(canvas)

	# Create container for health bar (top-right corner)
	var anchor_container = Control.new()
	anchor_container.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	anchor_container.set_offsets_preset(Control.PRESET_TOP_RIGHT)
	canvas.add_child(anchor_container)

	var margin = MarginContainer.new()
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_top", 20)
	margin.position = Vector2(-220, 0)  # Offset left from anchor
	anchor_container.add_child(margin)

	var vbox = VBoxContainer.new()
	margin.add_child(vbox)

	# Health label
	var health_label = Label.new()
	health_label.name = "HealthLabel"
	health_label.text = "HP"
	health_label.add_theme_color_override("font_color", Color(1.0, 0.9, 0.8))
	health_label.add_theme_font_size_override("font_size", 16)
	vbox.add_child(health_label)

	# Create health bar
	_health_bar = ProgressBar.new()
	_health_bar.name = "HealthBar"
	_health_bar.custom_minimum_size = Vector2(200, 24)
	_health_bar.min_value = 0.0
	_health_bar.max_value = max_health
	_health_bar.value = current_health
	_health_bar.show_percentage = false

	# Style the health bar background
	var style_bg = StyleBoxFlat.new()
	style_bg.bg_color = Color(0.2, 0.0, 0.0, 0.8)
	style_bg.corner_radius_top_left = 4
	style_bg.corner_radius_top_right = 4
	style_bg.corner_radius_bottom_left = 4
	style_bg.corner_radius_bottom_right = 4
	style_bg.border_width_bottom = 2
	style_bg.border_width_top = 2
	style_bg.border_width_left = 2
	style_bg.border_width_right = 2
	style_bg.border_color = Color(0.4, 0.1, 0.1)
	_health_bar.add_theme_stylebox_override("background", style_bg)

	# Style the health bar fill (red/green gradient based on health)
	var style_fill = StyleBoxFlat.new()
	style_fill.bg_color = Color(0.8, 0.2, 0.2)  # Red health bar
	style_fill.corner_radius_top_left = 4
	style_fill.corner_radius_top_right = 4
	style_fill.corner_radius_bottom_left = 4
	style_fill.corner_radius_bottom_right = 4
	_health_bar.add_theme_stylebox_override("fill", style_fill)

	vbox.add_child(_health_bar)

	# HP text showing current/max
	var hp_text = Label.new()
	hp_text.name = "HPText"
	hp_text.text = "%.0f / %.0f" % [current_health, max_health]
	hp_text.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0))
	hp_text.add_theme_font_size_override("font_size", 14)
	vbox.add_child(hp_text)

	# Connect health_changed signal to update UI
	health_changed.connect(_on_health_changed)


func _on_health_changed(current: float, maximum: float) -> void:
	if _health_bar:
		_health_bar.max_value = maximum
		_health_bar.value = current

		# Update fill color based on health percentage
		var health_pct = current / maximum
		var fill_color: Color
		if health_pct > 0.5:
			fill_color = Color(0.2, 0.8, 0.2)  # Green when healthy
		elif health_pct > 0.25:
			fill_color = Color(0.9, 0.7, 0.1)  # Yellow when damaged
		else:
			fill_color = Color(0.9, 0.2, 0.2)  # Red when critical

		var style_fill = _health_bar.get_theme_stylebox("fill") as StyleBoxFlat
		if style_fill:
			style_fill.bg_color = fill_color

		# Update HP text
		var canvas = get_node_or_null("HealthBarUI")
		if canvas:
			var hp_text = canvas.get_node_or_null("Control/MarginContainer/VBoxContainer/HPText")
			if hp_text:
				hp_text.text = "%.0f / %.0f" % [current, maximum]


func _setup_attack_hitbox() -> void:
	# Create sword hitbox Area3D for armed attacks
	# This will be attached to the right hand bone when the armed character is loaded
	_attack_hitbox = Area3D.new()
	_attack_hitbox.name = "SwordHitbox"
	_attack_hitbox.collision_layer = 0  # Doesn't collide with anything
	_attack_hitbox.collision_mask = 2   # Detects enemies (layer 2 - Bobba)
	_attack_hitbox.monitoring = true    # Always monitoring - damage gated by _hitbox_active_window

	# Create collision shape - large sphere for easier hit detection
	var sword_shape = CollisionShape3D.new()
	var sphere = SphereShape3D.new()
	sphere.radius = 1.5  # Large radius for reliable hit detection
	sword_shape.shape = sphere
	sword_shape.position = Vector3(0, 0, 1.0)  # Offset forward from hand

	_attack_hitbox.add_child(sword_shape)

	# Connect signal
	_attack_hitbox.body_entered.connect(_on_attack_hitbox_body_entered)

	# Create unarmed hitbox for fist attacks
	_unarmed_hitbox = Area3D.new()
	_unarmed_hitbox.name = "FistHitbox"
	_unarmed_hitbox.collision_layer = 0
	_unarmed_hitbox.collision_mask = 2
	_unarmed_hitbox.monitoring = true  # Always monitoring - damage gated by _hitbox_active_window

	# Create collision shape - box in front of player for punch
	var fist_shape = CollisionShape3D.new()
	var box = BoxShape3D.new()
	box.size = Vector3(1.2, 1.2, 1.5)  # Wide and deep for punches
	fist_shape.shape = box
	fist_shape.position = Vector3(0, 1.0, 1.0)  # In front, at chest height

	_unarmed_hitbox.add_child(fist_shape)
	_unarmed_hitbox.body_entered.connect(_on_attack_hitbox_body_entered)

	# Add unarmed hitbox to character model so it rotates with player
	# (will be added after _character_model is created)


func _setup_sword_bone_attachment() -> void:
	# Attach sword hitbox to the right hand bone of the armed character
	if _armed_character == null:
		print("Player: No armed character, adding hitbox to character model")
		if _character_model:
			_character_model.add_child(_attack_hitbox)
			_attack_hitbox.position = Vector3(0, 1.0, 1.0)
		else:
			add_child(_attack_hitbox)
			_attack_hitbox.position = Vector3(0, 1.0, 1.0)
		return

	var skeleton: Skeleton3D = _find_skeleton(_armed_character)
	if skeleton == null:
		print("Player: No skeleton found for sword attachment, using fallback")
		if _character_model:
			_character_model.add_child(_attack_hitbox)
			_attack_hitbox.position = Vector3(0, 1.0, 1.0)
		return

	# Debug: print all bone names
	print("Player: Armed skeleton has ", skeleton.get_bone_count(), " bones:")
	for i in range(skeleton.get_bone_count()):
		print("  Bone ", i, ": ", skeleton.get_bone_name(i))

	# Find the right hand bone (Mixamo naming convention)
	var hand_bone_idx: int = skeleton.find_bone("mixamorig_RightHand")
	if hand_bone_idx == -1:
		hand_bone_idx = skeleton.find_bone("mixamorig:RightHand")
	if hand_bone_idx == -1:
		# Try alternative names
		for i in range(skeleton.get_bone_count()):
			var bone_name = skeleton.get_bone_name(i)
			if "RightHand" in bone_name or "Right_Hand" in bone_name or "right_hand" in bone_name.to_lower():
				hand_bone_idx = i
				break

	if hand_bone_idx == -1:
		print("Player: Right hand bone not found, using fallback position")
		# Fallback: add hitbox to character model
		if _character_model:
			_character_model.add_child(_attack_hitbox)
			_attack_hitbox.position = Vector3(0, 1.0, 1.0)
		return

	print("Player: Found right hand bone at index ", hand_bone_idx, ": ", skeleton.get_bone_name(hand_bone_idx))

	# Create BoneAttachment3D for the sword
	_sword_bone_attachment = BoneAttachment3D.new()
	_sword_bone_attachment.name = "SwordAttachment"
	_sword_bone_attachment.bone_name = skeleton.get_bone_name(hand_bone_idx)

	skeleton.add_child(_sword_bone_attachment)
	_sword_bone_attachment.add_child(_attack_hitbox)
	print("Player: Attached sword hitbox to bone: ", skeleton.get_bone_name(hand_bone_idx))


func _on_attack_hitbox_body_entered(body: Node3D) -> void:
	# Only process hits during the active damage window
	if not _hitbox_active_window:
		return

	if _has_hit_this_attack:
		return

	print("Player: Sword hitbox detected body: ", body.name, " (class: ", body.get_class(), ")")

	# Check if we hit an enemy with take_hit method
	if body.has_method("take_hit"):
		_has_hit_this_attack = true

		# Calculate knockback direction (from player to enemy)
		var knockback_dir = (body.global_position - global_position).normalized()
		knockback_dir.y = 0.2  # Slight upward component

		# Determine damage - Paladin sword does 50 damage to Bobba
		var damage: float = PLAYER_ATTACK_DAMAGE
		if character_class == CharacterClass.PALADIN and body is Bobba:
			damage = PALADIN_SWORD_DAMAGE
			print("Player: Paladin sword attack - dealing %d damage to Bobba" % int(damage))

		# Apply damage and knockback (pass self as attacker)
		body.take_hit(damage, knockback_dir * PLAYER_KNOCKBACK_FORCE, false, self)
		print("Player: HIT LANDED on enemy: ", body.name)

		# In multiplayer, send entity damage to server
		if enable_multiplayer and has_node("/root/NetworkManager") and "entity_id" in body:
			var network_manager = get_node("/root/NetworkManager")
			if network_manager.has_method("is_network_connected") and network_manager.is_network_connected():
				network_manager.send_entity_damage(body.entity_id, damage, network_manager.my_player_id)
				print("Player: Sent entity damage to server - entity_id=%d damage=%.1f" % [body.entity_id, damage])
	else:
		print("Player: Body has no take_hit method")


func enable_attack_hitbox() -> void:
	# Reset attack hit tracking - called when attack starts
	print("Player: enable_attack_hitbox() - resetting _has_hit_this_attack to false")
	_has_hit_this_attack = false
	_attack_anim_progress = 0.0
	_hitbox_active_window = false
	# Keep hitboxes monitoring always - we control damage via _hitbox_active_window
	_attack_hitbox.monitoring = true
	if _unarmed_hitbox:
		_unarmed_hitbox.monitoring = true


func disable_attack_hitbox() -> void:
	_hitbox_active_window = false
	_attack_anim_progress = 0.0
	# Keep monitoring on - avoids state confusion when toggling
	print("Player: Attack ended")


func _update_attack_hitbox_timing() -> void:
	# Track attack animation progress and set active window for damage dealing
	# Skip for Archer class - they use projectiles, not melee hitboxes
	if character_class == CharacterClass.ARCHER:
		return
	if not is_attacking or _current_anim_player == null:
		_hitbox_active_window = false
		return

	# Calculate animation progress (0.0 to 1.0)
	var anim_length: float = _current_anim_player.current_animation_length
	var anim_position: float = _current_anim_player.current_animation_position
	if anim_length > 0:
		_attack_anim_progress = anim_position / anim_length
	else:
		_attack_anim_progress = 0.0

	# Select the correct hitbox based on combat mode
	var active_hitbox: Area3D = _attack_hitbox if combat_mode == CombatMode.ARMED else _unarmed_hitbox

	# Active window is during the attack portion (30% to 80% of animation)
	var should_be_active: bool = _attack_anim_progress >= SWORD_HITBOX_START and _attack_anim_progress <= SWORD_HITBOX_END

	if should_be_active and not _hitbox_active_window:
		_hitbox_active_window = true
		print("Player: Attack window ACTIVE at progress ", _attack_anim_progress, " (mode: ", "armed" if combat_mode == CombatMode.ARMED else "unarmed", ")")
	elif not should_be_active and _hitbox_active_window:
		_hitbox_active_window = false
		print("Player: Attack window ENDED at progress ", _attack_anim_progress)

	# Check for hits during active window
	if _hitbox_active_window and not _has_hit_this_attack:
		for body in active_hitbox.get_overlapping_bodies():
			_on_attack_hitbox_body_entered(body)
			if _has_hit_this_attack:
				return


func _show_hit_label() -> void:
	if _hit_label == null:
		return

	# Reset and show the label
	_hit_label.visible = true
	_hit_label.position = Vector3(0, 2.5, 0)
	_hit_label.modulate.a = 1.0
	_hit_label.scale = Vector3(0.5, 0.5, 0.5)

	# Animate: scale up, float up, fade out
	var tween = create_tween()
	tween.set_parallel(true)
	tween.tween_property(_hit_label, "scale", Vector3(1.0, 1.0, 1.0), 0.15).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
	tween.tween_property(_hit_label, "position", Vector3(0, 3.5, 0), 0.6).set_ease(Tween.EASE_OUT)
	tween.tween_property(_hit_label, "modulate:a", 0.0, 0.4).set_delay(0.2)
	tween.chain().tween_callback(func(): _hit_label.visible = false)


func _input(event: InputEvent) -> void:
	# Toggle fullscreen with F11
	if event is InputEventKey and event.pressed and event.keycode == KEY_F11:
		if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		else:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

	# Quit with Q key
	if event is InputEventKey and event.pressed and event.keycode == KEY_Q:
		get_tree().quit()

	# Release mouse with Escape
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

	# Double-click to recapture mouse
	if event is InputEventMouseButton and event.pressed and event.double_click and event.button_index == MOUSE_BUTTON_LEFT:
		if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

	# Toggle combat mode with Tab, middle mouse button, or gamepad Back button
	if event.is_action_pressed(&"toggle_combat"):
		_toggle_combat_mode()
	elif event is InputEventKey and event.pressed and event.keycode == KEY_TAB:
		_toggle_combat_mode()
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_MIDDLE:
		_toggle_combat_mode()

	# Attack with left mouse button, F key, or gamepad X button
	# Archer: press to draw bow, release to shoot
	# Others: press to attack
	if character_class == CharacterClass.ARCHER:
		# Archer bow mechanics: hold to draw, release to shoot
		if event.is_action_pressed(&"attack"):
			_start_bow_draw()
		elif event.is_action_released(&"attack"):
			_release_bow()
		elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
				if event.pressed:
					_start_bow_draw()
				else:
					_release_bow()
		elif event is InputEventKey and event.keycode == KEY_F:
			if event.pressed:
				_start_bow_draw()
			else:
				_release_bow()
	else:
		# Paladin: attack on press
		if event.is_action_pressed(&"attack"):
			_do_attack()
		elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
				_do_attack()
		elif event is InputEventKey and event.pressed and event.keycode == KEY_F:
			_do_attack()

	# Block with right mouse button or gamepad LB
	if event.is_action_pressed(&"block"):
		is_blocking = true
	elif event.is_action_released(&"block"):
		is_blocking = false
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
			is_blocking = event.pressed

	# Spell cast with C key, gamepad B button, or RB (armed mode only)
	if event.is_action_pressed(&"spell_cast") or event.is_action_pressed(&"cast_spell_rb"):
		_do_spell_cast()

	# Switch character class: 2 (Paladin), 3 (Archer) - Archer is default
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_2:
			_switch_character_class(CharacterClass.PALADIN)
		elif event.keycode == KEY_3:
			_switch_character_class(CharacterClass.ARCHER)

	# Mouse look (also works on mobile via touch look emitting mouse motion)
	var is_mobile: bool = OS.get_name() in ["Android", "iOS"]
	if event is InputEventMouseMotion and (is_mobile or Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED):
		camera_rotation.x -= event.relative.x * MOUSE_SENSITIVITY
		camera_rotation.y -= event.relative.y * MOUSE_SENSITIVITY
		camera_rotation.y = clamp(camera_rotation.y, deg_to_rad(-CAMERA_VERTICAL_LIMIT), deg_to_rad(CAMERA_VERTICAL_LIMIT))

		_camera_pivot.rotation.y = camera_rotation.x
		_camera_pivot.rotation.x = camera_rotation.y


func _physics_process(delta: float) -> void:
	# Skip movement when console is open (still apply gravity)
	if GameConsoleScript.is_console_open:
		velocity += gravity * delta
		move_and_slide()
		return

	if _attack_cooldown > 0:
		_attack_cooldown -= delta

	# Update spawn immunity timer
	if _spawn_immunity_timer > 0:
		_spawn_immunity_timer -= delta

	# Update sword hitbox timing based on attack animation progress
	_update_attack_hitbox_timing()

	# Update bow draw state (time-based progress)
	_update_bow_draw(delta)

	# Handle stun/knockback state
	if _is_stunned:
		_stun_timer -= delta
		# Apply knockback velocity directly
		velocity.x = _knockback_velocity.x
		velocity.z = _knockback_velocity.z
		velocity.y += gravity.y * delta
		# Decelerate knockback
		_knockback_velocity = _knockback_velocity.move_toward(Vector3.ZERO, 30.0 * delta)
		if _stun_timer <= 0:
			_is_stunned = false
			_knockback_velocity = Vector3.ZERO
		move_and_slide()
		return

	# Update spell effects (flickering light, procedural bolts)
	_update_spell_effects(delta)

	# Gamepad camera control (right stick)
	var look_x: float = Input.get_action_strength(&"camera_look_right") - Input.get_action_strength(&"camera_look_left")
	var look_y: float = Input.get_action_strength(&"camera_look_down") - Input.get_action_strength(&"camera_look_up")
	if abs(look_x) > 0.01 or abs(look_y) > 0.01:
		camera_rotation.x -= look_x * GAMEPAD_SENSITIVITY * delta
		camera_rotation.y -= look_y * GAMEPAD_SENSITIVITY * delta
		camera_rotation.y = clamp(camera_rotation.y, deg_to_rad(-CAMERA_VERTICAL_LIMIT), deg_to_rad(CAMERA_VERTICAL_LIMIT))
		_camera_pivot.rotation.y = camera_rotation.x
		_camera_pivot.rotation.x = camera_rotation.y

	if Input.is_action_pressed(&"reset_position") or global_position.y < -12:
		_spawn_at_tower()
		velocity = Vector3.ZERO
		reset_physics_interpolation()

	velocity += gravity * delta

	# Handle jumping
	if is_on_floor():
		if is_jumping:
			is_jumping = false
		if Input.is_action_just_pressed(&"jump") and not is_attacking:
			velocity.y = JUMP_VELOCITY
			is_jumping = true

	# Get movement input with analog stick support
	var input_dir := Input.get_vector(&"move_left", &"move_right", &"move_forward", &"move_back", 0.15)

	# Determine run state: Shift key for keyboard, stick intensity > 60% for gamepad only
	var keyboard_run := Input.is_action_pressed(&"run") if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED else false
	# Check if using gamepad (joy axis) vs keyboard (digital input)
	var joy_input := Vector2(
		Input.get_joy_axis(0, JOY_AXIS_LEFT_X),
		Input.get_joy_axis(0, JOY_AXIS_LEFT_Y)
	)
	var using_gamepad := joy_input.length() > 0.1
	var gamepad_run := using_gamepad and joy_input.length() > RUN_THRESHOLD
	is_running = keyboard_run or gamepad_run

	var current_max_speed: float = RUN_SPEED if is_running else WALK_SPEED
	var horizontal_velocity := Vector3(velocity.x, 0, velocity.z)

	# Normalize input direction for consistent movement
	if input_dir.length() > 0.1:
		input_dir = input_dir.normalized()

	# Reduce movement speed while attacking
	if is_attacking:
		input_dir *= 0.3

	# Convert to world direction based on camera yaw
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
		var mesh_target_rotation: float = _camera_pivot.rotation.y + PI
		_character_model.rotation.y = lerp_angle(_character_model.rotation.y, mesh_target_rotation, 12.0 * delta)

	velocity = horizontal_velocity + Vector3.UP * velocity.y

	move_and_slide()

	# FIFO mode: send state to server and apply server-confirmed position
	if enable_fifo and _fifo_connected:
		_fifo_send_state()
		# Apply server-confirmed position (pure server-authoritative)
		global_position = _fifo_server_position

	# Update animation based on movement state
	_update_animation(input_dir)
