class_name Bobba
extends CharacterBody3D
## Bobba - A roaming creature that attacks when the player gets close.
## Roams around the map randomly, switches to attack mode within 10 meters of player.
## Network-synchronized across all players.

signal attack_landed(target: Node3D, knockback_direction: Vector3)

# Use Protocol.BobbaState for network sync compatibility
const Proto = preload("res://multiplayer/protocol.gd")
const HealthComponentClass := preload("res://combat/health_component.gd")
const PoiseComponentClass := preload("res://combat/poise_component.gd")
const State = Proto.BobbaState

# Network synchronization
var entity_id: int = 0  # Unique ID for network sync
var _is_network_controlled: bool = false  # True for non-host clients
var _target_position: Vector3 = Vector3.ZERO
var _target_rotation: float = 0.0

# Health system
const MAX_HEALTH: float = 1000.0
var _health: HealthComponentClass
var _poise: PoiseComponentClass
const SWORD_POISE_DAMAGE: float = 35.0  # ~3 hits = stagger

## Compatibility forwarder — existing code reads/writes `bobba.health`.
var health: float:
	get:
		return _health.current_hp if _health else MAX_HEALTH
	set(value):
		if _health:
			_health.set_current_hp(value)

# Movement constants
const ROAM_SPEED: float = 2.0
const CHASE_SPEED: float = 5.0
const RETREAT_SPEED: float = 3.0  # Speed when retreating from arrows
# Night perception: Bobba is BLIND in the dark like every AI — he can only
# SEE a character that fire reveals (Perception.is_lit_by_fire). But he has
# a sense of SMELL: any character that comes too close is detected no matter
# how dark it is. Once tracking, he only loses the scent when the target
# gets 50 m away.
const DETECTION_RADIUS: float = 10.0   # smell — characters this close are detected
const LOSE_RADIUS: float = 50.0        # tracked targets escape at this distance
const FLEE_HP_FRACTION: float = 0.22   # badly wounded → disengage and run
const REGEN_DELAY: float = 5.0         # seconds without damage before healing starts
const REGEN_PCT_PER_SEC: float = 0.03  # out-of-combat recovery — fleeing has a payoff
const ATTACK_DISTANCE: float = 2.0  # Distance to start attack animation
const ROAM_CHANGE_TIME: float = 3.0  # Time between direction changes
const ROTATION_SPEED: float = 5.0

# Combat constants
const ATTACK_DAMAGE: float = 65.0  # Damage dealt to players per punch
const ARROW_DAMAGE: float = 1.0  # Damage taken from arrows (10x reduced - use fire to trap Bobba!)
const SWORD_DAMAGE: float = 50.0  # Damage taken from Paladin sword
## Bumped from 12 → 22 per round-4-not-fun feedback: a Bobba punch must
## visibly shove the Paladin *out of Bobba's 2 m attack range* instead
## of just jostling them. That positional shove replaces CombatFX juice
## as the hit-feedback channel.
const KNOCKBACK_FORCE: float = 22.0

# Arrow retreat behavior
var _is_retreating: bool = false
var _retreat_timer: float = 0.0
var _retreat_direction: Vector3 = Vector3.ZERO
const RETREAT_DURATION: float = 2.0  # Seconds to retreat after arrow hit

# Block: procedural "cross right arm over body" pose held for BLOCK_DURATION.
# Triggered opportunistically while the target is threatening. Any incoming
# damage is negated as long as is_blocking is true.
var is_blocking: bool = false
var _block_timer: float = 0.0
var _block_check_cooldown: float = 0.0
const BLOCK_DURATION: float = 0.8
const BLOCK_CHECK_INTERVAL: float = 1.5
const BLOCK_CHANCE: float = 0.4
# Procedural "X-guard": both arms raised and crossed in front of the chest.
# Right arm comes across the body, left arm mirrors it; forearms bend hard
# at the elbow to form the X. Values are tuned by eye against the mutant rig.
const BLOCK_RIGHT_ARM_EULER := Vector3(-75.0, -35.0, 0.0)
const BLOCK_RIGHT_FOREARM_EULER := Vector3(-105.0, 0.0, 0.0)
const BLOCK_LEFT_ARM_EULER := Vector3(-75.0, 35.0, 0.0)
const BLOCK_LEFT_FOREARM_EULER := Vector3(-105.0, 0.0, 0.0)
# Slight forward hunch — head tucks down into the guard.
const BLOCK_HEAD_EULER := Vector3(20.0, 0.0, 0.0)
const BLOCK_SPINE_EULER := Vector3(12.0, 0.0, 0.0)

var _skeleton: Skeleton3D = null
var _block_arm_bone: int = -1
var _block_forearm_bone: int = -1
var _block_left_arm_bone: int = -1
var _block_left_forearm_bone: int = -1
var _block_head_bone: int = -1
var _block_spine_bone: int = -1

# Fire avoidance - Bobba actively flees from fire!
var _ground_fires: Array = []  # Track active ground fire positions
var _fire_scan_timer: float = 0.0  # Timer for periodic fire scanning
const FIRE_AVOID_RADIUS: float = 5.0  # Distance to avoid from fire (increased for safety)
const FIRE_PANIC_RADIUS: float = 2.5  # Distance at which Bobba panics and flees immediately
const FIRE_DURATION_MS: int = 45000  # How long to remember fire positions (45 seconds)
const FIRE_SCAN_INTERVAL: float = 1.0  # How often to scan for new fires

signal health_changed(current: float, maximum: float)
signal died()

var state: int = State.ROAMING
var target: Node3D = null  # Current target player
# Strategic flight: when badly wounded Bobba disengages and RUNS, along a
# route scored against every threat, every remembered fire and the map edge.
var _time_since_damage: float = 999.0
var _is_fleeing: bool = false
var _flee_dir: Vector3 = Vector3.ZERO
var _flee_route_timer: float = 0.0
var _flee_cornered_timer: float = 0.0
var _flee_given_up: bool = false  # cornered once → fights to the end
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
var _lurch_tween: Tween
var _model_rest_pos: Vector3 = Vector3.ZERO
var _model_rest_scale: Vector3 = Vector3.ONE
var _squash_tween: Tween
var _flash_materials: Array[StandardMaterial3D] = []
var _telegraph_level: float = -1.0
var _telegraph_materials: Array[StandardMaterial3D] = []

## Hit feedback tuning — the whole surface for "did that land?".
const HIT_FLASH_ENERGY: float = 0.55   # a strong tint; squash+lurch+react carry the rest
const HIT_FLASH_TIME: float = 0.16     # fade back to normal
const HIT_LURCH_DISTANCE: float = 0.32 # metres the model recoils
const HIT_LURCH_OUT: float = 0.06      # snap back fast...
const HIT_LURCH_BACK: float = 0.20     # ...then settle
## The wind-up tell. Amber, so it never reads as the red "you hit me".
const TELEGRAPH_COLOR := Color(1.0, 0.55, 0.12)
const TELEGRAPH_ENERGY: float = 2.2    # on the axe alone, so it can be bright
var _stun_timer: float = 0.0
var _hit_label: Label3D
var _attack_anim_progress: float = 0.0
const HAND_HITBOX_START: float = 0.3  # Enable hitbox at 30% of attack animation
const HAND_HITBOX_END: float = 0.7    # Disable hitbox at 70% of attack animation

# Hack-and-slash combo chain: while the target stays in COMBO_CHAIN_RANGE,
# a finished swing flows into the next step — swipe, straight punch, then a
# leaping slam finisher. Each step keeps the orange telegraph flash so the
# chain reads as three separate decisions to dodge/block/parry, and a parry
# on any step breaks the whole chain (on_parried → STUNNED). After the chain
# ends there's a long punish cooldown — that's the player's opening.
## "speed" is the playback rate for the step's clip. The raw mixamo
## jump-attack clip is 3.7 s — far longer than its useful attack portion —
## so the finisher plays at 1.5x (2.47 s total): the slam still reads, the
## recovery tail shrinks to ~0.5 s, and the step ends well inside the 3 s
## stuck-state watchdog. Progress-based windows are playback-rate agnostic.
const COMBO_ATTACKS: Array[Dictionary] = [
	{"anim": &"bobba/Attack", "damage": 65.0, "window": Vector2(0.30, 0.70), "kb_mult": 1.0, "lunge": 1.5, "speed": 1.0},
	{"anim": &"bobba/Punch", "damage": 50.0, "window": Vector2(0.22, 0.60), "kb_mult": 0.8, "lunge": 2.5, "speed": 1.0},
	{"anim": &"bobba/JumpAttack", "damage": 85.0, "window": Vector2(0.35, 0.80), "kb_mult": 1.5, "lunge": 6.0, "speed": 1.5},
]
## The axe swing is a separate decision from the fist chain, not a step in
## it. He carries the axe one-handed and has to commit BOTH hands to use it,
## which is what buys the player the read: it is slow, it is frontal, and it
## reaches much further than a punch.
const AXE_ATTACK: Dictionary = {
	"anim": &"bobba/AxeAttack", "damage": 95.0,
	"window": Vector2(0.68, 0.86),   # the downswing only
	"kb_mult": 1.6, "lunge": 0.9,
	"speed": 0.8,                    # deliberately slower than any fist
}
## Reach of the axe head, measured off the weapon rather than guessed: the
## blade is 1.75 m of haft swung from a shoulder on a 3 m body.
const AXE_ATTACK_RANGE: float = 4.2
## Frontal only — he cannot bring it round onto something beside him.
const AXE_ATTACK_CONE_DEG: float = 40.0
## How wide the axe head's damage volume is. Bigger than a fist because the
## thing doing the damage is bigger; still only the head, never the haft.
const AXE_HITBOX_RADIUS: float = 0.75

## Committing both hands leaves him open — a longer punish than the chain.
const AXE_END_COOLDOWN: float = 1.8

const COMBO_CHAIN_RANGE: float = 4.0   # can still chain if the target backs off a bit
const COMBO_END_COOLDOWN: float = 1.3  # punish window after the chain resolves
var _combo_step: int = 0
## True while the axe swing owns the attack state, so every read of the
## current attack's data resolves to AXE_ATTACK instead of a chain step.
var _axe_attack_active: bool = false
## Alternate the axe with the fist chain. Left to itself he would open with
## the axe every time — it outranges everything, so he would never close —
## and the fight would be one note. Swing, then chain, then swing.
var _last_attack_was_axe: bool = false
var _axe_hitbox: Area3D = null
var _axe_smear: SlashTrail = null
## Torn air off the torso while he folds away from a blow.
var _react_smear: SlashTrail = null
var _left_claw_trail: SlashTrail = null
var _right_claw_trail: SlashTrail = null
const CLAW_TRAIL_COLOR: Color = Color(1.0, 0.4, 0.15, 0.7)

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
	"punch": "res://assets/bobba/mutant punch.fbx",
	"roar": "res://assets/bobba/mutant roaring.fbx",
	"dying": "res://assets/bobba/mutant dying.fbx",
	"jump_attack": "res://assets/bobba/mutant jump attack.fbx",
}

@onready var gravity: Vector3 = ProjectSettings.get_setting("physics/3d/default_gravity") * \
		ProjectSettings.get_setting("physics/3d/default_gravity_vector")


func _ready() -> void:
	add_to_group("bobba")  # Add to group for easy finding
	_setup_health_component()
	_setup_poise_component()
	_find_player()
	_setup_attack_hitbox()  # Must be before _setup_model which attaches hitboxes to bones
	_setup_model()
	_setup_hit_label()
	_pick_new_roam_direction()
	_setup_network()


func _setup_health_component() -> void:
	_health = HealthComponentClass.new()
	_health.name = "HealthComponent"
	_health.max_hp = MAX_HEALTH
	_health.damaged.connect(func(_amount: float) -> void:
		_time_since_damage = 0.0)
	add_child(_health)
	_health.health_changed.connect(func(cur: float, mx: float) -> void:
		health_changed.emit(cur, mx))
	_health.died.connect(_on_death)
	# Every damage event pops the current HP as a big floating label.
	_health.damaged.connect(func(_amount: float) -> void:
		_show_hit_label("%d / %d HP" % [int(round(health)), int(round(MAX_HEALTH))]))


func _setup_poise_component() -> void:
	_poise = PoiseComponentClass.new()
	_poise.name = "PoiseComponent"
	_poise.max_poise = 100.0
	add_child(_poise)
	_poise.staggered.connect(_on_staggered)
	_poise.unstoppable_started.connect(func() -> void:
		_flash_hit(Color(1.0, 0.85, 0.2))
		print("Bobba: UNSTOPPABLE"))


func _on_staggered() -> void:
	# Extended hit-stun — halve knockback doesn't matter here since stagger
	# is its own state; reuse the existing STUNNED state + play a roar
	# animation if available to sell the break-out.
	state = State.STUNNED
	_stun_timer = 0.9  # longer than standard hit stun
	_current_anim = &""
	if _anim_player and _anim_player.has_animation(&"bobba/Roar"):
		_play_anim(&"bobba/Roar")
	Sfx.play3d("bobba_roar", global_position + Vector3(0, 2.0, 0), -2.0)
	print("Bobba: STAGGERED")


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

	# Co-op AI companion is huntable exactly like a player
	for companion in get_tree().get_nodes_in_group("companion"):
		if is_instance_valid(companion) and companion not in _all_players:
			_all_players.append(companion)

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

	# Keep/lose: a tracked target is followed until it BOTH breaks the 50 m
	# scent range AND can no longer be seen — a fire-lit runner stays marked.
	if target and is_instance_valid(target):
		if "is_dead" in target and target.is_dead:
			target = null
		else:
			var dist = global_position.distance_to(target.global_position)
			if dist > LOSE_RADIUS and not Perception.can_see(self, target):
				target = null
				state = State.ROAMING
				_pick_new_roam_direction()
				print("Bobba: lost track of target (>%dm and out of sight)" % int(LOSE_RADIUS))

	# Acquire/switch: run at the CLOSEST perceivable character — smelled
	# (too close in the dark) or visible (moonlight silhouette / fire glow).
	var best: Node3D = null
	var best_dist: float = INF
	for p in _all_players:
		if not is_instance_valid(p):
			continue
		if "is_dead" in p and p.is_dead:
			continue
		var dist = global_position.distance_to(p.global_position)
		var perceivable: bool = dist <= DETECTION_RADIUS or Perception.can_see(self, p)
		if perceivable and dist < best_dist:
			best = p
			best_dist = dist
	if best == null:
		return
	if target == null:
		target = best
		state = State.CHASING
		print("Bobba: New target acquired at %.1fm - %s (%s)" % [best_dist, best.name,
				"smelled" if best_dist <= DETECTION_RADIUS else "seen"])
	elif best != target:
		# Switch only with a clear margin — no ping-ponging between two
		# equally close characters.
		var cur_dist = global_position.distance_to(target.global_position)
		if best_dist < cur_dist * 0.72:
			target = best
			print("Bobba: switching to closer target %s (%.1fm)" % [best.name, best_dist])


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
		# Anchor for the hit lurch — the model node is offset/scaled in the
		# scene, so the recoil has to spring back to THIS, not to zero.
		_model_rest_pos = _model.position
		_model_rest_scale = _model.scale
		_ensure_flash_materials()

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

	# Ember claw streaks — drawn only while the fists are live.
	_left_claw_trail = SlashTrail.attach(self, _left_hand_hitbox,
			Vector3(0, -0.2, 0), Vector3(0, 0.25, 0), CLAW_TRAIL_COLOR)
	_right_claw_trail = SlashTrail.attach(self, _right_hand_hitbox,
			Vector3(0, -0.2, 0), Vector3(0, 0.25, 0), CLAW_TRAIL_COLOR)


func _create_hand_hitbox(hitbox_name: String) -> Area3D:
	var hitbox = Area3D.new()
	hitbox.name = hitbox_name
	hitbox.collision_layer = 0  # Doesn't collide with anything
	hitbox.collision_mask = 1   # Detects player (layer 1)
	hitbox.monitoring = true    # Always monitoring - damage gated by _hitbox_active_window

	# Rule: only the visible fist/forearm counts as the hit volume. Keep
	# the sphere centered on the hand bone with a radius roughly matching
	# the fist's visible size so misses actually miss.
	var collision_shape = CollisionShape3D.new()
	var sphere = SphereShape3D.new()
	sphere.radius = 0.35  # fist-sized, not arm-length
	collision_shape.shape = sphere
	collision_shape.position = Vector3(0, 0, 0.0)  # on the hand itself

	hitbox.add_child(collision_shape)
	return hitbox


func _setup_hand_bone_attachments() -> void:
	# Attach hand hitboxes to the hand bones
	if _model == null:
		print("Bobba: No model, adding hitboxes to self")
		add_child(_left_hand_hitbox)
		add_child(_right_hand_hitbox)
		# Fallback positions near chest — still fist-sized now.
		_left_hand_hitbox.position = Vector3(-0.5, 1.4, 0.4)
		_right_hand_hitbox.position = Vector3(0.5, 1.4, 0.4)
		return

	var skeleton: Skeleton3D = _find_skeleton(_model)
	_skeleton = skeleton  # Cache for block-pose overrides.
	if skeleton == null:
		print("Bobba: No skeleton found for hand attachments, using fallback on model")
		# Add to _model so hitboxes rotate with Bobba's facing direction
		_model.add_child(_left_hand_hitbox)
		_model.add_child(_right_hand_hitbox)
		# Position in model's local space (forward = +Z in model space)
		_left_hand_hitbox.position = Vector3(-0.5, 1.0, 0.5)
		_right_hand_hitbox.position = Vector3(0.5, 1.0, 0.5)
		return

	# Resolve the right arm / right forearm bones for the procedural block
	# pose. Fallbacks cover both mixamorig_ and mixamorig: naming conventions.
	_block_arm_bone = _find_bone(skeleton, ["mixamorig_RightArm", "mixamorig:RightArm", "RightArm"])
	_block_forearm_bone = _find_bone(skeleton, ["mixamorig_RightForeArm", "mixamorig:RightForeArm", "RightForeArm"])
	_block_left_arm_bone = _find_bone(skeleton, ["mixamorig_LeftArm", "mixamorig:LeftArm", "LeftArm"])
	_block_left_forearm_bone = _find_bone(skeleton, ["mixamorig_LeftForeArm", "mixamorig:LeftForeArm", "LeftForeArm"])
	_block_head_bone = _find_bone(skeleton, ["mixamorig_Head", "mixamorig:Head", "Head"])
	_block_spine_bone = _find_bone(skeleton, ["mixamorig_Spine1", "mixamorig:Spine1", "Spine1", "mixamorig_Spine", "Spine"])
	if _block_arm_bone < 0 or _block_forearm_bone < 0:
		print("Bobba: WARNING — right arm/forearm bones not found, block pose will no-op")

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

	_setup_axe(skeleton)

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


## Look up a bone by any of the given candidate names, returning -1 on miss.
func _find_bone(skeleton: Skeleton3D, candidates: Array) -> int:
	for n in candidates:
		var idx: int = skeleton.find_bone(n)
		if idx != -1:
			return idx
	return -1


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
	# Floating HP label that pops above Bobba on each damage event. Sized
	# for typical combat-camera distance.
	_hit_label = Label3D.new()
	_hit_label.name = "HitLabel"
	_hit_label.text = ""
	_hit_label.font_size = 64
	_hit_label.pixel_size = 0.006
	_hit_label.modulate = Color(1.0, 0.3, 0.3)  # Red — enemy damage feedback
	_hit_label.outline_modulate = Color(0.2, 0.0, 0.0)
	_hit_label.outline_size = 12
	_hit_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_hit_label.no_depth_test = true
	_hit_label.position = Vector3(0, 3.0, 0)
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
	var is_player = body == target or body.is_in_group("player") \
			or body.is_in_group("companion") or body.is_in_group("remote_players")
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

		# Per-combo-step numbers: the punch is quick and light, the
		# jump-slam finisher hits hard and shoves furthest.
		var step_damage: float = _current_attack_data()["damage"]
		var step_kb: float = KNOCKBACK_FORCE * _current_attack_data()["kb_mult"]

		# The defender is the authority on whether the contact counted:
		# take_hit returns false when the hit was negated outright (spawn
		# immunity, roll i-frames, timed parry). Legacy targets whose
		# take_hit returns void report null — treated as landed.
		var hit_applied: Variant = true
		if body.has_method("take_hit"):
			if player_is_blocking:
				# Blocked — pass the FULL damage and let the player's take_hit
				# apply the shield's chip reduction (a block softens a hit, it
				# never erases it; only a timed parry does). The shield also
				# does NOT absorb momentum: push the player back hard enough
				# to see the stagger.
				hit_applied = body.take_hit(step_damage, knockback_dir * step_kb * 0.65, true, self, false)
			else:
				# Not blocked - full damage and knockback
				hit_applied = body.take_hit(step_damage, knockback_dir * step_kb, false, self, false)

		if hit_applied == false:
			# Contact was negated by the defender — no hit confirmation, no
			# impact FX. The swing is still spent (_has_hit_this_attack).
			print("Bobba: hit NEGATED by defender (immunity/i-frames/parry) — combo step %d" % _combo_step)
			return

		if player_is_blocking:
			if has_node("/root/CombatFX"):
				CombatFX.on_hit(0.45)  # hitstop + shake weight 0.45
			print("Bobba: HIT BLOCKED by player (push-back applied)")
		else:
			if has_node("/root/CombatFX"):
				CombatFX.on_hit(0.8)
			print("Bobba: HIT LANDED on player (combo step %d, %.0f dmg)" % [_combo_step, step_damage])
		SlashTrail.spawn_hit_spark(self, body.global_position + Vector3(0, 1.3, 0), Color(1.0, 0.45, 0.2))

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
		if _left_claw_trail != null:
			_left_claw_trail.emitting = false
		if _right_claw_trail != null:
			_right_claw_trail.emitting = false
		if _axe_smear != null:
			_axe_smear.emitting = false
		_set_telegraph(0.0)
		return

	# Calculate animation progress (0.0 to 1.0)
	var anim_length: float = _anim_player.current_animation_length
	var anim_position: float = _anim_player.current_animation_position
	if anim_length > 0:
		_attack_anim_progress = anim_position / anim_length
	else:
		_attack_anim_progress = 0.0

	# Active window comes from the current combo step (each clip's swing
	# lands at a different point in the animation).
	var window: Vector2 = _current_attack_data()["window"]
	var should_be_active: bool = _attack_anim_progress >= window.x and _attack_anim_progress <= window.y

	if should_be_active and not _hitbox_active_window:
		_hitbox_active_window = true
		print("Bobba: Attack window ACTIVE at progress ", _attack_anim_progress)
	elif not should_be_active and _hitbox_active_window:
		_hitbox_active_window = false
		print("Bobba: Attack window ENDED at progress ", _attack_anim_progress)

	# ANTICIPATION — everything before the damage window is the tell.
	#
	# Knightvale models this as a first-class state with its own config; we
	# already have the data (progress < window.x IS the wind-up), it was just
	# never expressed. A souls enemy has to be readable BEFORE the blow, and
	# Bobba's wind-up looked identical to his recovery. Ramping a warning
	# glow across it gives the player something to react to, and changes no
	# damage, timing or reach.
	var anticipating: bool = _attack_anim_progress < window.x
	var tell: float = 0.0
	if anticipating and window.x > 0.001:
		tell = clampf(_attack_anim_progress / window.x, 0.0, 1.0)
		tell = tell * tell            # late bloom — fires just before the hit
	_set_telegraph(tell)

	# Claw streaks draw exactly while the fists can hurt.
	if _left_claw_trail != null:
		_left_claw_trail.emitting = _hitbox_active_window
	if _right_claw_trail != null:
		_right_claw_trail.emitting = _hitbox_active_window
	if _axe_smear != null:
		_axe_smear.emitting = _hitbox_active_window

	# Check for hits during active window
	if _hitbox_active_window and not _has_hit_this_attack:
		# An axe swing damages with the blade; the fists are irrelevant to it
		# (and would otherwise land a punch at axe range).
		if _axe_attack_active:
			if _axe_hitbox != null:
				for body in _axe_hitbox.get_overlapping_bodies():
					_on_attack_hitbox_body_entered(body)
					if _has_hit_this_attack:
						return
			return
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


## Parry → riposte state. Set when a player deflects one of our punches;
## while open, the next sword hit crits (multiplier applied player-side,
## where the damage number is computed and synced to the server).
var _riposte_ready: bool = false
const PARRIED_STUN_DURATION: float = 2.5  # how long the riposte window stays open


## Called by a player whose parry deflected our punch (their take_hit saw
## the contact land inside the parry's active frames). We stagger hard —
## much longer than regular hit-stun — and open the riposte window.
func on_parried(parrier: Node3D) -> void:
	if state == State.DEAD:
		return
	state = State.STUNNED
	_stun_timer = PARRIED_STUN_DURATION
	_riposte_ready = true
	_combo_step = 0  # a parry breaks the whole chain
	_axe_attack_active = false
	velocity = Vector3.ZERO
	disable_attack_hitbox()
	_has_hit_this_attack = true  # the deflected swing can't also deal damage
	_flash_hit(Color(1.0, 0.85, 0.2))  # gold, matching the parrier's flash
	if parrier:
		_set_attacker_as_target(parrier)
	# The roar sells "staggered and wide open" — _handle_stunned lets it play out.
	_current_anim = &""
	if _anim_player and _anim_player.has_animation(&"bobba/Roar"):
		_play_anim(&"bobba/Roar")
	Sfx.play3d("bobba_roar", global_position + Vector3(0, 2.0, 0), -1.0)
	print("Bobba: PARRIED — staggered, riposte window open for %.1fs" % PARRIED_STUN_DURATION)


func is_riposte_ready() -> bool:
	return _riposte_ready and state == State.STUNNED


## One riposte per parry — the attacker consumes the window with the crit.
func consume_riposte() -> void:
	_riposte_ready = false


func take_hit(damage: float, knockback: Vector3, _blocked: bool = false, attacker: Node3D = null, _is_fully_blockable: bool = false) -> void:
	# HP label is emitted via the HealthComponent.damaged signal when
	# take_damage runs — take_hit only applies flash, knockback, and stun.

	# If Bobba is currently blocking, the hit is parried: blue flash,
	# reduced knockback, no damage, no stun.
	if is_blocking:
		_flash_hit(Color(0.3, 0.5, 1.0))
		_hit_lurch(knockback * 0.4)   # smaller shove — he absorbed it
		_squash_model(0.05)           # barely gives — he took it on the guard
		_play_hit_react(&"HitReactLight")
		if attacker:
			_set_attacker_as_target(attacker)  # still agro onto them
		# Mild pushback so there's visible recoil on the blocker
		velocity = knockback * 0.25
		print("Bobba: BLOCKED hit from ", attacker)
		return

	_flash_hit(Color(1.0, 0.2, 0.2))
	_hit_lurch(knockback)
	_squash_model(0.11)
	_play_hit_react(&"HitReact")
	_pulse_react_smear()

	# Switch target to attacker (prioritize who is attacking)
	if attacker:
		_set_attacker_as_target(attacker)

	# Poise damage — a heavy hit can stagger Bobba into a longer stun.
	# Sword attacks currently pass damage >= 50; scale poise off that.
	var did_stagger: bool = false
	if _poise and damage >= 50.0:
		did_stagger = _poise.take_poise_damage(SWORD_POISE_DAMAGE)

	# Apply knockback (neutralized for 1/3 second, pushed opposite to strike).
	# If a stagger fired above, _on_staggered already set a longer stun window.
	if knockback.length() > 0 and not did_stagger:
		state = State.STUNNED
		_stun_timer = 0.333
		velocity = knockback
		# Force current animation to clear so it can transition properly after stun
		_current_anim = &""
	elif did_stagger and knockback.length() > 0:
		velocity = knockback * 1.3  # extra shove on the stagger

	# In multiplayer, don't apply damage locally - server is authoritative
	# The player will send MSG_ENTITY_DAMAGE to server which updates our health
	if not _is_network_controlled:
		take_damage(damage)
	print("Bobba took hit! Damage: %.1f HP: %.1f/%.1f" % [damage, health, MAX_HEALTH])


## Take damage from any source (arrows, sword, etc.)
func take_damage(amount: float) -> void:
	var old_health: float = health
	_health.damage_flat(amount)
	print("Bobba: take_damage(%.1f) - HP: %.1f -> %.1f" % [amount, old_health, health])


## Take a percentage of max HP as damage (used by DoT spell effects).
## Server-authoritative: skipped on non-host clients (health is synced from the
## server via apply_network_state).
func take_damage_pct(pct: float) -> void:
	if _is_network_controlled:
		return
	_health.damage_pct(pct)


## Called when Bobba dies
func _on_death() -> void:
	print("Bobba died!")
	Sfx.play3d("death_thud", global_position, 0.0)
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
## Per-frame block logic:
## * if currently blocking, count down and apply the procedural right-arm pose
## * otherwise, roll a chance to enter block on a fixed cadence — but only
##   when there's a target in range, we're not mid-attack, and not stunned.
func _update_block_state(delta: float) -> void:
	if is_blocking:
		_block_timer -= delta
		if _block_timer <= 0.0:
			is_blocking = false
		else:
			_apply_block_pose()
		return

	if state == State.DEAD or state == State.STUNNED or state == State.ATTACKING:
		return
	if target == null or not is_instance_valid(target):
		return

	_block_check_cooldown -= delta
	if _block_check_cooldown > 0.0:
		return
	_block_check_cooldown = BLOCK_CHECK_INTERVAL

	# Only bother blocking when the target is close enough to attack us.
	var dist: float = global_position.distance_to(target.global_position)
	if dist > DETECTION_RADIUS:
		return
	if randf() < BLOCK_CHANCE:
		is_blocking = true
		_block_timer = BLOCK_DURATION
		print("Bobba: entering block")


## Override the right shoulder + right forearm rotations each frame while
## blocking. Runs after AnimationPlayer has advanced (called from
## _physics_process) so these overrides win over whatever the current idle
## / walk clip is driving.
func _apply_block_pose() -> void:
	if _skeleton == null:
		return
	_apply_bone_euler(_block_arm_bone, BLOCK_RIGHT_ARM_EULER)
	_apply_bone_euler(_block_forearm_bone, BLOCK_RIGHT_FOREARM_EULER)
	_apply_bone_euler(_block_left_arm_bone, BLOCK_LEFT_ARM_EULER)
	_apply_bone_euler(_block_left_forearm_bone, BLOCK_LEFT_FOREARM_EULER)
	_apply_bone_euler(_block_head_bone, BLOCK_HEAD_EULER)
	_apply_bone_euler(_block_spine_bone, BLOCK_SPINE_EULER)


func _apply_bone_euler(bone_idx: int, euler_deg: Vector3) -> void:
	if bone_idx < 0 or _skeleton == null:
		return
	_skeleton.set_bone_pose_rotation(bone_idx, Quaternion.from_euler(Vector3(
		deg_to_rad(euler_deg.x),
		deg_to_rad(euler_deg.y),
		deg_to_rad(euler_deg.z))))


func take_arrow_hit(arrow_position: Vector3, arrow_node: Node3D = null) -> void:
	# NOTE: Damage is now the arrow's responsibility (take_damage_pct 5%).
	# The HP label is also driven by the HealthComponent.damaged signal.
	# This method only handles the visual reaction and retreat behavior.

	# Flash orange for arrow hit
	_flash_hit(Color(1.0, 0.6, 0.2))

	# Start retreat behavior - walk away from arrow
	_is_retreating = true
	_retreat_timer = RETREAT_DURATION
	_retreat_direction = (global_position - arrow_position).normalized()
	_retreat_direction.y = 0  # Keep on ground plane

	# Track the ground fire position for avoidance
	if arrow_node:
		_register_ground_fire(arrow_position)

	# Arrows that actually hurt Bobba pull its attention onto the shooter
	# — mirrors the melee `_set_attacker_as_target` path. The arrow node
	# tracks its shooter; we pick it up here rather than changing the arrow
	# call signature so existing `take_arrow_hit(pos, arrow)` callers work.
	if arrow_node and is_instance_valid(arrow_node) and "shooter" in arrow_node:
		var archer: Node3D = arrow_node.shooter
		if archer and is_instance_valid(archer):
			_set_attacker_as_target(archer)
			print("Bobba: diverted attention to archer ", archer.name)

	print("Bobba hit by arrow! Retreating. HP: %.1f/%.1f" % [health, MAX_HEALTH])


## Register a ground fire position to avoid
func _register_ground_fire(pos: Vector3) -> void:
	# The periodic scene scan re-reports the same burning fires — refresh
	# the timestamp of a known fire instead of stacking duplicates.
	for fire in _ground_fires:
		if fire.position.distance_to(pos) < 1.5:
			fire.time = Time.get_ticks_msec()
			return
	_ground_fires.append({"position": pos, "time": Time.get_ticks_msec()})
	print("Bobba: FIRE registered at position %s! Total fires tracked: %d" % [pos, _ground_fires.size()])
	_cleanup_old_fires()


## Clean up old fire positions
func _cleanup_old_fires() -> void:
	var current_time := Time.get_ticks_msec()
	_ground_fires = _ground_fires.filter(func(fire): return current_time - fire.time < FIRE_DURATION_MS)


## Scan scene for existing ArrowGroundFire nodes and track them
func _scan_for_scene_fires() -> void:
	var fire_nodes := get_tree().get_nodes_in_group("ground_fire")
	for fire_node in fire_nodes:
		if is_instance_valid(fire_node):
			_register_ground_fire(fire_node.global_position)

	# Also search by name pattern for any fire we might have missed
	_find_fire_nodes_recursive(get_tree().current_scene)


## Find fire nodes in the scene by name
func _find_fire_nodes_recursive(node: Node) -> void:
	if node == null:
		return
	if "GroundFire" in node.name or "ArrowGroundFire" in node.name:
		# Check if we already have this fire registered (within 1m)
		var dominated := false
		for fire in _ground_fires:
			if node.global_position.distance_to(fire.position) < 1.0:
				dominated = true
				break
		if not dominated:
			_register_ground_fire(node.global_position)
	for child in node.get_children():
		_find_fire_nodes_recursive(child)


## Check if a position is too close to any ground fire
func _is_near_fire(pos: Vector3) -> bool:
	_cleanup_old_fires()
	for fire in _ground_fires:
		var fire_pos: Vector3 = fire.position
		fire_pos.y = pos.y  # Compare on same Y level
		if pos.distance_to(fire_pos) < FIRE_AVOID_RADIUS:
			return true
	return false


## Check if Bobba is in immediate danger from fire (panic zone)
func _is_in_fire_panic_zone() -> bool:
	_cleanup_old_fires()
	for fire in _ground_fires:
		var fire_pos: Vector3 = fire.position
		fire_pos.y = global_position.y
		if global_position.distance_to(fire_pos) < FIRE_PANIC_RADIUS:
			return true
	return false


## Get direction to avoid nearby fires - stronger avoidance when closer
func _get_fire_avoidance_direction() -> Vector3:
	_cleanup_old_fires()
	var avoidance := Vector3.ZERO
	var closest_fire_dist := INF

	for fire in _ground_fires:
		var fire_pos: Vector3 = fire.position
		fire_pos.y = global_position.y
		var dist := global_position.distance_to(fire_pos)

		if dist < closest_fire_dist:
			closest_fire_dist = dist

		if dist < FIRE_AVOID_RADIUS * 2:
			# Push away from fire, MUCH stronger when closer
			var away := (global_position - fire_pos).normalized()
			# Exponential falloff - very strong when close
			var strength := pow(1.0 - dist / (FIRE_AVOID_RADIUS * 2), 2.0) * 3.0
			avoidance += away * strength

	if avoidance.length() > 0.1:
		return avoidance.normalized()
	return Vector3.ZERO


func _show_hit_label(text: String = "Hit!") -> void:
	if _hit_label == null:
		return

	# Reset and show the label
	_hit_label.text = text
	_hit_label.visible = true
	_hit_label.position = Vector3(0, 3.0, 0)
	_hit_label.modulate = Color(1.0, 0.3, 0.3, 1.0)
	_hit_label.scale = Vector3(0.5, 0.5, 0.5)

	# Animate: scale up, float up, fade out
	var tween = create_tween()
	tween.set_parallel(true)
	tween.tween_property(_hit_label, "scale", Vector3(1.2, 1.2, 1.2), 0.15).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
	tween.tween_property(_hit_label, "position", Vector3(0, 4.5, 0), 0.8).set_ease(Tween.EASE_OUT)
	tween.tween_property(_hit_label, "modulate:a", 0.0, 0.4).set_delay(0.4)
	tween.chain().tween_callback(func(): _hit_label.visible = false)


func _flash_hit(color: Color) -> void:
	if _hit_flash_tween:
		_hit_flash_tween.kill()
	_ensure_flash_materials()
	for mat in _flash_materials:
		mat.emission_enabled = true
		mat.emission = color
		mat.emission_energy_multiplier = HIT_FLASH_ENERGY
	_hit_flash_tween = create_tween()
	_hit_flash_tween.tween_method(
		func(e: float) -> void:
			for mat in _flash_materials:
				mat.emission_energy_multiplier = e,
		HIT_FLASH_ENERGY, 0.0, HIT_FLASH_TIME)
	_hit_flash_tween.tween_callback(func() -> void:
		for mat in _flash_materials:
			mat.emission_enabled = false)


## The flash drives EMISSION on the materials Bobba actually renders with.
##
## It used to require a material_override, which the old code always set
## because the legacy FBX had no usable material. The authored orc ships its
## own textures and deliberately keeps them, so material_override is null and
## the flash silently did nothing — hits registered, Bobba never reacted.
##
## Duplicating each surface material into a surface override keeps the look
## identical (it is the same material) while giving us something safe to
## animate, without touching the shared resource on disk.
func _ensure_flash_materials() -> void:
	if not _flash_materials.is_empty() or _model == null:
		return
	_collect_flash_materials(_model)
	print("Bobba: hit-flash driving %d material(s)" % _flash_materials.size())


func _collect_flash_materials(node: Node) -> void:
	_collect_materials_into(node, _flash_materials)


func _collect_materials_into(node: Node, out: Array[StandardMaterial3D]) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.material_override is StandardMaterial3D:
			out.append(mi.material_override)
		elif mi.mesh:
			for i in range(mi.mesh.get_surface_count()):
				var src: Material = mi.get_surface_override_material(i)
				if src == null:
					src = mi.mesh.surface_get_material(i)
				if src is StandardMaterial3D:
					var dup: StandardMaterial3D = (src as StandardMaterial3D).duplicate()
					mi.set_surface_override_material(i, dup)
					out.append(dup)
	for child in node.get_children():
		_collect_materials_into(child, out)


## Bobba has no hit-reaction clip — the pack ships Attack, Dying, Idle,
## JumpAttack, Punch, Roar, Run and Walk and nothing else. Without one, a
## landed hit only tinted him, so a blow that connected looked identical to
## one that whiffed. Shove the MODEL (not the body) back along the strike and
## let it spring home: collision and the AI are untouched, but the impact
## reads.
## Play a composed reaction clip, but never over a death or an attack that is
## already committed — a hit landing mid-swing should not cancel the swing, or
## Bobba becomes stun-lockable by tapping him.
func _play_hit_react(clip: StringName) -> void:
	if _anim_player == null or state == State.DEAD:
		return
	var full := StringName("bobba/" + String(clip))
	if not _anim_player.has_animation(full):
		return
	if state == State.ATTACKING:
		return
	_anim_player.play(full, 0.06)
	_current_anim = full


## The tell glows the WEAPON, not the body.
##
## Emission on a full-body material saturates the whole silhouette at any
## useful energy, which threw away the matte stone skin the moment he wound
## up. Lighting the axe reads better anyway — the thing about to hit you is
## the thing that should be charging — and it leaves the character intact.
## Falls back to the body only if there is no weapon to light.
func _ensure_telegraph_materials() -> void:
	if not _telegraph_materials.is_empty():
		return
	if _axe != null and is_instance_valid(_axe):
		_collect_materials_into(_axe, _telegraph_materials)
	if _telegraph_materials.is_empty():
		_ensure_flash_materials()
		_telegraph_materials = _flash_materials.duplicate()
	print("Bobba: telegraph driving %d material(s)" % _telegraph_materials.size())


## Warning glow that ramps through the wind-up and snaps off when the blow
## actually lands. Deliberately a different colour from the red hit flash —
## this is "it is coming", not "it connected" — and it drives the same
## materials, so it costs nothing extra.
func _set_telegraph(amount: float) -> void:
	if is_equal_approx(amount, _telegraph_level):
		return
	_telegraph_level = amount
	if _hit_flash_tween and _hit_flash_tween.is_running():
		return          # a real hit flash outranks the tell
	_ensure_telegraph_materials()
	for mat in _telegraph_materials:
		if amount <= 0.001:
			mat.emission_enabled = false
		else:
			mat.emission_enabled = true
			mat.emission = TELEGRAPH_COLOR
			mat.emission_energy_multiplier = amount * TELEGRAPH_ENERGY


## Compress on impact. Bobba is a heavy body, so he gives less than a person
## would — the amount is deliberately below the shared default.
func _squash_model(amount: float) -> void:
	if _model == null:
		return
	if _squash_tween:
		_squash_tween.kill()
		_model.scale = _model_rest_scale
	_squash_tween = HitFeedback.squash(_model, _model_rest_scale, amount)


## Smear the air around the torso for the length of the recoil.
func _pulse_react_smear() -> void:
	if _react_smear == null:
		_react_smear = SlashTrail.attach_smear(self, self,
				Vector3(-0.7, 1.1, 0.0), Vector3(0.7, 2.3, 0.0),
				Color(0.75, 0.82, 0.95, 0.12), 1.0)
	_react_smear.emitting = true
	var t := get_tree().create_timer(0.33)
	t.timeout.connect(func() -> void:
		if _react_smear != null:
			_react_smear.emitting = false)


func _hit_lurch(knockback: Vector3) -> void:
	if _model == null:
		return
	if _lurch_tween:
		_lurch_tween.kill()
		_model.position = _model_rest_pos
	var dir: Vector3 = knockback
	dir.y = 0.0
	if dir.length() < 0.01:
		dir = -global_transform.basis.z
	dir = dir.normalized()
	var local: Vector3 = global_transform.basis.inverse() * dir
	_lurch_tween = create_tween()
	_lurch_tween.tween_property(_model, "position",
			_model_rest_pos + local * HIT_LURCH_DISTANCE, HIT_LURCH_OUT) 		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_lurch_tween.tween_property(_model, "position", _model_rest_pos, HIT_LURCH_BACK) 		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


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

		# The legacy material exists because the old FBX imported without a
		# usable one. The authored model ships its own textured material, and
		# force-overriding it painted the orc's green skin and torn cloth flat
		# grey — so this is now a FALLBACK, only for meshes that have none.
		if _has_own_material(mesh_inst):
			print("Bobba: %s keeps its authored material" % mesh_inst.name)
		else:
			mesh_inst.material_override = mat
			if mesh_inst.mesh:
				for i in range(mesh_inst.mesh.get_surface_count()):
					mesh_inst.set_surface_override_material(i, mat)
			print("Bobba: applied fallback material to ", mesh_inst.name)

	for child in node.get_children():
		_apply_material_recursive(child, mat)


## Bobba's axe: a rigid mesh on a BoneAttachment3D at the right hand, so every
## existing mutant clip carries it without touching the animations.
##
## The offsets are in BOBBA'S OWN frame rather than the bone's — the mixamorig
## hand bone points down the arm, so a hand-guessed euler there is unreadable.
## `_axe_local_basis` solves for the bone-local rotation that lands the axe
## upright-and-forward relative to the body, the same trick the player's gear
## uses.
const AXE_SCENE := "res://assets/bobba/war_axe.glb"
const AXE_POS := Vector3(0.0, -0.05, 0.06)   # metres, in Bobba's frame
const AXE_ROT := Vector3(-18.0, 0.0, 8.0)    # degrees: haft near-upright, head up, raked back
const AXE_SCALE := 1.0

var _axe: Node3D


func _setup_axe(skeleton: Skeleton3D) -> void:
	var idx: int = _find_hand_bone(skeleton, "Right")
	if idx == -1:
		print("Bobba: no right hand bone — axe not attached")
		return
	var scene: PackedScene = load(AXE_SCENE) as PackedScene
	if scene == null:
		print("Bobba: axe asset missing at ", AXE_SCENE)
		return

	var attach := BoneAttachment3D.new()
	attach.name = "AxeAttachment"
	attach.bone_name = skeleton.get_bone_name(idx)
	skeleton.add_child(attach)

	_axe = scene.instantiate() as Node3D
	_axe.name = "WarAxe"
	var rest: Basis = (skeleton.global_transform
			* skeleton.get_bone_global_rest(idx)).basis.orthonormalized()
	var want: Basis = global_transform.basis.orthonormalized() \
			* Basis.from_euler(AXE_ROT * (PI / 180.0))
	_axe.transform = Transform3D(
			rest.inverse() * want * Basis().scaled(Vector3.ONE * AXE_SCALE),
			rest.inverse() * AXE_POS)
	attach.add_child(_axe)
	# Wind smear along the haft and out past the head — a long axe moves a lot
	# of air, and the arc is what makes a heavy swing read as heavy.
	# Damage comes from the HEAD of the axe, not his fist — the golden rule
	# is that the volume matches the thing you can see hitting you. It sits
	# up the haft where the blade is, and only ever monitors during the
	# downswing window.
	_axe_hitbox = Area3D.new()
	_axe_hitbox.name = "AxeHitbox"
	_axe_hitbox.collision_layer = 0
	_axe_hitbox.collision_mask = 1
	_axe_hitbox.monitoring = true
	var axe_shape := CollisionShape3D.new()
	var axe_sphere := SphereShape3D.new()
	axe_sphere.radius = AXE_HITBOX_RADIUS
	axe_shape.shape = axe_sphere
	axe_shape.position = Vector3(0, 1.30, 0)   # at the head, up the haft
	_axe_hitbox.add_child(axe_shape)
	_axe.add_child(_axe_hitbox)
	_axe_hitbox.body_entered.connect(_on_attack_hitbox_body_entered)

	_axe_smear = SlashTrail.attach_smear(self, _axe,
			Vector3(0, -0.30, 0), Vector3(0, 1.45, 0),
			Color(0.86, 0.90, 1.0, 0.16), 1.2)
	print("Bobba: axe attached to bone ", attach.bone_name)


## True when the mesh already carries a real, textured material of its own.
func _has_own_material(mesh_inst: MeshInstance3D) -> bool:
	if mesh_inst.mesh == null:
		return false
	for i in range(mesh_inst.mesh.get_surface_count()):
		var m: Material = mesh_inst.mesh.surface_get_material(i)
		if m is BaseMaterial3D and (m as BaseMaterial3D).albedo_texture != null:
			return true
	return false


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
		"punch": ["Punch", false],
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

	# The pack has no hit reaction and nothing that swings an axe — compose
	# them onto the clips it does have.
	BobbaAnims.compose(_anim_player, skeleton)


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


func _play_anim(anim_name: StringName, speed: float = 1.0) -> void:
	if _anim_player == null:
		return
	if _current_anim == anim_name:
		return  # Already playing this animation
	if _anim_player.has_animation(anim_name):
		# Short cross-blend so state flips (chase→attack→chase) don't pop.
		_anim_player.play(anim_name, 0.2, speed)
		_current_anim = anim_name


func _on_animation_finished(anim_name: StringName) -> void:
	print("Bobba: Animation finished: ", anim_name)
	if anim_name == &"bobba/Attack" or anim_name == &"bobba/Punch" or anim_name == &"bobba/JumpAttack":
		disable_attack_hitbox()
		_current_anim = &""  # Clear so attack can replay
		_attack_state_time = 0.0  # Reset attack timer
		# Chain the combo: target still in reach, this wasn't the finisher,
		# and nothing (parry stun, death, fire panic) broke the chain.
		if state == State.ATTACKING and not _axe_attack_active \
				and _combo_step < COMBO_ATTACKS.size() - 1 \
				and target != null and is_instance_valid(target) \
				and global_position.distance_to(target.global_position) <= COMBO_CHAIN_RANGE \
				and not _is_in_fire_panic_zone():
			print("Bobba: Combo chain → step %d" % (_combo_step + 1))
			_start_combo_attack(_combo_step + 1)
			return
		# Chain over — the deeper the combo went, the longer the punish window.
		print("Bobba: Attack chain finished at step %d, cooldown and state=CHASING" % _combo_step)
		attack_cooldown = AXE_END_COOLDOWN if _axe_attack_active \
				else (COMBO_END_COOLDOWN if _combo_step > 0 else 0.7)
		_combo_step = 0
		_axe_attack_active = false
		if state == State.ATTACKING:
			state = State.CHASING
	elif anim_name == &"bobba/Roar":
		# After roar finishes, start chasing — unless we're mid-stun
		# (poise stagger or parry riposte window): there the stun timer in
		# _handle_stunned owns the state transition, not the animation.
		if state != State.STUNNED:
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

	# Periodically scan for new fire in the scene
	_fire_scan_timer -= delta
	if _fire_scan_timer <= 0:
		_fire_scan_timer = FIRE_SCAN_INTERVAL
		_scan_for_scene_fires()

	# Update hand hitbox timing based on attack animation progress
	_update_attack_hitbox_timing()

	# Block state machine: tick timers and maybe enter block.
	_update_block_state(delta)

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

	# Natural toughness: whenever he is not swinging and hasn't been hurt
	# for a few seconds he knits back together — running away is a
	# STRATEGY (escape, heal in the dark, come back), not a forfeit.
	_time_since_damage += delta
	if state != State.ATTACKING and _time_since_damage >= REGEN_DELAY \
			and health > 0.0 and health < MAX_HEALTH:
		_health.heal_pct(REGEN_PCT_PER_SEC * delta)

	# Survival intelligence: badly wounded with a threat on him → break off
	# and run. He re-plots the route continuously and only calms down once
	# nobody can perceive him any more (melts back into the dark).
	if _flee_given_up and health > MAX_HEALTH * 0.5:
		_flee_given_up = false  # recovered — fleeing is an option again
	if not _is_fleeing and not _flee_given_up and target != null \
			and health <= MAX_HEALTH * FLEE_HP_FRACTION:
		_is_fleeing = true
		_flee_route_timer = 0.0
		_flee_cornered_timer = 0.0
		print("Bobba: FLEEING at %.0f hp — plotting escape route" % health)
	if _is_fleeing:
		_handle_fleeing(delta)
		move_and_slide()
		return

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


## Wounded flight: run the scored escape route at full sprint, replanning
## twice a second. Escape succeeds when no character could still perceive
## him (beyond scent range and out of sight) — then he melts back into the
## night and resumes roaming (and, unseen, can ambush again by smell).
func _handle_fleeing(delta: float) -> void:
	var nearest: float = INF
	for p in _all_players:
		if is_instance_valid(p) and not ("is_dead" in p and p.is_dead):
			nearest = minf(nearest, global_position.distance_to(p.global_position))
	if nearest > LOSE_RADIUS + 5.0:
		_is_fleeing = false
		_flee_given_up = false
		target = null
		state = State.ROAMING
		_pick_new_roam_direction()
		print("Bobba: escaped into the dark (nearest character %.0fm)" % nearest)
		return
	# Cornered check: a faster pursuer glued to him means flight is
	# hopeless — the smart move flips to fighting with his back to the wall.
	if nearest < 5.0:
		_flee_cornered_timer += delta
		if _flee_cornered_timer > 3.0:
			_is_fleeing = false
			_flee_given_up = true
			state = State.CHASING
			print("Bobba: cornered — turning to fight to the end")
			return
	else:
		_flee_cornered_timer = 0.0
	_flee_route_timer -= delta
	if _flee_route_timer <= 0.0:
		_flee_route_timer = 0.5
		_flee_dir = _plot_escape_route()
	state = State.CHASING  # closest network state for the sprint anim/sync
	velocity.x = _flee_dir.x * CHASE_SPEED * 1.2
	velocity.z = _flee_dir.z * CHASE_SPEED * 1.2
	if _model and _flee_dir.length() > 0.1:
		var flee_rot := atan2(_flee_dir.x, _flee_dir.z)
		_model.rotation.y = lerp_angle(_model.rotation.y, flee_rot, ROTATION_SPEED * delta)
	_play_anim(&"bobba/Run")


## Score 16 headings and pick the best escape route. The route must gain
## distance from EVERY character, never pass through a remembered fire
## (arrow fires and spell rings burn — their positions live in
## _ground_fires), and stay on the map.
func _plot_escape_route() -> Vector3:
	var best_dir := Vector3(1, 0, 0)
	var best_score: float = -INF
	for i in range(16):
		var ang := TAU * float(i) / 16.0
		var dir := Vector3(cos(ang), 0.0, sin(ang))
		var probe := global_position + dir * 18.0
		var score: float = 0.0
		for p in _all_players:
			if is_instance_valid(p) and not ("is_dead" in p and p.is_dead):
				score += probe.distance_to(p.global_position)
		for fire in _ground_fires:
			for d in [6.0, 12.0, 18.0]:
				if (global_position + dir * d).distance_to(fire.position) < 7.0:
					score -= 60.0
		if absf(probe.x) > 220.0 or absf(probe.z) > 220.0:
			score -= 150.0
		if score > best_score:
			best_score = score
			best_dir = dir
	return best_dir


func _handle_roaming(delta: float, distance_to_target: float) -> void:
	# FIRE PANIC CHECK - if too close to fire, flee immediately!
	if _is_in_fire_panic_zone():
		var fire_avoid := _get_fire_avoidance_direction()
		if fire_avoid.length() > 0.1:
			velocity.x = fire_avoid.x * CHASE_SPEED  # Run speed when fleeing fire
			velocity.z = fire_avoid.z * CHASE_SPEED
			if _model:
				var flee_rot := atan2(fire_avoid.x, fire_avoid.z)
				_model.rotation.y = lerp_angle(_model.rotation.y, flee_rot, ROTATION_SPEED * 2.0 * delta)
			_play_anim(&"bobba/Run")
			print("Bobba: PANIC! Fleeing from fire!")
			return

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
		# Blend avoidance with roam direction, STRONGLY prioritizing fire avoidance
		move_dir = (move_dir + fire_avoid * 4.0).normalized()

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
	# FIRE PANIC CHECK - if too close to fire, flee even while chasing!
	if _is_in_fire_panic_zone():
		var fire_avoid := _get_fire_avoidance_direction()
		if fire_avoid.length() > 0.1:
			velocity.x = fire_avoid.x * CHASE_SPEED
			velocity.z = fire_avoid.z * CHASE_SPEED
			if _model:
				var flee_rot := atan2(fire_avoid.x, fire_avoid.z)
				_model.rotation.y = lerp_angle(_model.rotation.y, flee_rot, ROTATION_SPEED * 2.0 * delta)
			_play_anim(&"bobba/Run")
			print("Bobba: PANIC while chasing! Fire too close, fleeing!")
			return

	# If target escapes beyond LOSE_RADIUS, _select_target will clear it
	# Here we just check if we lost target
	if target == null or not is_instance_valid(target):
		state = State.ROAMING
		_pick_new_roam_direction()
		return

	# Don't attack if standing near fire - back off first
	var near_fire := _is_near_fire(global_position)
	if near_fire and distance_to_target <= ATTACK_DISTANCE:
		# Back away from fire instead of attacking
		var fire_avoid := _get_fire_avoidance_direction()
		if fire_avoid.length() > 0.1:
			velocity.x = fire_avoid.x * RETREAT_SPEED
			velocity.z = fire_avoid.z * RETREAT_SPEED
			if _model:
				var retreat_rot := atan2(fire_avoid.x, fire_avoid.z)
				_model.rotation.y = lerp_angle(_model.rotation.y, retreat_rot, ROTATION_SPEED * delta)
			_play_anim(&"bobba/Walk")
			print("Bobba: Won't attack - too close to fire, backing off")
			return

	# The axe outreaches the fists, so it is what he uses at the range where
	# only it can land — a punch chain there would swing at empty air. Inside
	# fist range he still prefers the chain, which keeps close quarters fast
	# and keeps the slow swing as the thing you see coming from further out.
	if attack_cooldown <= 0 and not _last_attack_was_axe \
			and _can_axe_attack(distance_to_target):
		_start_axe_attack()
		return

	# If close enough, open the combo chain
	if distance_to_target <= ATTACK_DISTANCE and attack_cooldown <= 0:
		print("Bobba: Starting new attack (distance=%.1f, cooldown=%.2f)" % [distance_to_target, attack_cooldown])
		_start_combo_attack(0)
		return

	# Chase the target with fire avoidance
	var direction: Vector3 = (target.global_position - global_position).normalized()
	direction.y = 0

	# Check for fire in the path and avoid it
	var fire_avoid: Vector3 = _get_fire_avoidance_direction()
	var move_dir: Vector3 = direction
	if fire_avoid.length() > 0.1:
		# Blend chase direction with fire avoidance
		# Fire avoidance is now much stronger (3x weight)
		move_dir = (direction + fire_avoid * 3.0).normalized()

	var horizontal_velocity = move_dir * CHASE_SPEED
	velocity.x = horizontal_velocity.x
	velocity.z = horizontal_velocity.z

	# Rotate to face movement direction (not target, since we might be dodging fire)
	if _model and move_dir.length() > 0.1:
		var target_rot = atan2(move_dir.x, move_dir.z)
		_model.rotation.y = lerp_angle(_model.rotation.y, target_rot, ROTATION_SPEED * delta)

	_play_anim(&"bobba/Run")


var _attack_state_time: float = 0.0


## The attack currently driving the state — an axe swing or a chain step.
func _current_attack_data() -> Dictionary:
	if _axe_attack_active:
		return AXE_ATTACK
	return COMBO_ATTACKS[_combo_step]


## Can he bring the axe down on the target from here? Needs the reach AND
## the target roughly in front — this swing has no sideways version.
func _can_axe_attack(distance: float) -> bool:
	if _axe == null or _anim_player == null:
		return false
	if not _anim_player.has_animation(AXE_ATTACK["anim"]):
		return false
	if distance > AXE_ATTACK_RANGE or target == null or not is_instance_valid(target):
		return false
	var to_target: Vector3 = (target as Node3D).global_position - global_position
	to_target.y = 0.0
	if to_target.length() < 0.1:
		return false
	var facing: Vector3 = -(_model if _model else self).global_transform.basis.z
	facing.y = 0.0
	return rad_to_deg(facing.normalized().angle_to(to_target.normalized())) \
			<= AXE_ATTACK_CONE_DEG


## Commit to the two-handed swing.
func _start_axe_attack() -> void:
	_axe_attack_active = true
	_last_attack_was_axe = true
	_combo_step = 0
	state = State.ATTACKING
	_current_anim = &""
	_play_anim(AXE_ATTACK["anim"], AXE_ATTACK["speed"])
	Sfx.play3d("punch_whoosh", global_position + Vector3(0, 1.8, 0), -1.0)
	enable_attack_hitbox()
	velocity.x = 0
	velocity.z = 0
	_attack_state_time = 0.0
	print("Bobba: AXE SWING — two-handed, frontal")


## Start combo step `step`. Every step keeps the orange telegraph flash —
## the wind-up must stay readable even mid-chain (fun rule: visible
## decision → visible consequence).
func _start_combo_attack(step: int) -> void:
	_axe_attack_active = false
	if step == 0:
		_last_attack_was_axe = false   # chain done, the axe is available again
	_combo_step = step
	_flash_hit(Color(1.0, 0.55, 0.10))
	state = State.ATTACKING
	var attack_anim: StringName = COMBO_ATTACKS[step]["anim"]
	if _anim_player == null or not _anim_player.has_animation(attack_anim):
		attack_anim = &"bobba/Attack"  # clip failed to load — fall back to the swipe
	_current_anim = &""  # force replay even if the same clip
	_play_anim(attack_anim, COMBO_ATTACKS[step].get("speed", 1.0))
	Sfx.play3d("punch_whoosh", global_position + Vector3(0, 1.5, 0),
			-2.0 if step == COMBO_ATTACKS.size() - 1 else -5.0)
	enable_attack_hitbox()  # fresh swing — each chain step can land its own hit
	velocity.x = 0
	velocity.z = 0
	_attack_state_time = 0.0


func _handle_attacking(delta: float) -> void:
	# FIRE PANIC - abort attack if too close to fire!
	if _is_in_fire_panic_zone():
		print("Bobba: ABORTING ATTACK - fire too close!")
		disable_attack_hitbox()
		_combo_step = 0
		_axe_attack_active = false
		attack_cooldown = 0.2  # Short cooldown after abort
		state = State.CHASING
		_current_anim = &""
		_attack_state_time = 0.0
		return

	# Stay in attacking state until animation finishes. Early in the swing
	# the step lunges toward the target — a small drift on swipe/punch, a
	# real leap on the jump-slam finisher — so the chain tracks a backing-
	# off player instead of whiffing in place.
	velocity.x = 0
	velocity.z = 0
	if _attack_anim_progress < 0.45 and target != null and is_instance_valid(target):
		var lunge_speed: float = _current_attack_data()["lunge"]
		var lunge_dir: Vector3 = target.global_position - global_position
		lunge_dir.y = 0.0
		if lunge_dir.length() > 0.6 and lunge_speed > 0.0:
			lunge_dir = lunge_dir.normalized()
			velocity.x = lunge_dir.x * lunge_speed
			velocity.z = lunge_dir.z * lunge_speed
			if _model:
				var lunge_rot: float = atan2(lunge_dir.x, lunge_dir.z)
				_model.rotation.y = lerp_angle(_model.rotation.y, lunge_rot, ROTATION_SPEED * delta)
	_attack_state_time += delta
	# Watchdog: no attack step should ever take 3 s. If one does (clip
	# failed to finish, animation_finished lost to a blend, etc.), RECOVER —
	# end the chain exactly like _on_animation_finished's chain-over branch —
	# instead of printing forever while Bobba stands frozen.
	if _attack_state_time > 3.0:
		print("Bobba: WARNING - Stuck in ATTACKING state for %.1f seconds! Animation: %s — force-ending attack" % [_attack_state_time, _current_anim])
		disable_attack_hitbox()
		attack_cooldown = AXE_END_COOLDOWN if _axe_attack_active \
				else (COMBO_END_COOLDOWN if _combo_step > 0 else 0.7)
		_combo_step = 0
		_axe_attack_active = false
		_attack_state_time = 0.0
		_current_anim = &""
		state = State.CHASING


func _handle_stunned(delta: float) -> void:
	# Decelerate knockback velocity
	velocity.x = move_toward(velocity.x, 0, 20.0 * delta)
	velocity.z = move_toward(velocity.z, 0, 20.0 * delta)

	# Play idle during stun — but let a stagger Roar run its course so the
	# "I'm wide open" tell stays visible for the whole riposte window.
	if _current_anim != &"bobba/Roar":
		_play_anim(&"bobba/Idle")

	_stun_timer -= delta
	if _stun_timer <= 0:
		_riposte_ready = false  # window closed — crits are off again
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
