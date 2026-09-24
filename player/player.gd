class_name Player
extends CharacterBody3D
## Douglass, the Keeper of Balance, walking through the Lands of Balance.
## Third-person style controls with mouse look.
## Uses FBX character models with Mixamo animations.
## Supports armed (Paladin with sword & shield) and unarmed (Y Bot) combat modes.

const HealthComponentClass := preload("res://combat/health_component.gd")
const HealAuraAreaClass := preload("res://combat/heal_aura_area.gd")
const BuffAuraAreaClass := preload("res://combat/buff_aura_area.gd")
const StaminaComponentClass := preload("res://combat/stamina_component.gd")
const AttackDataClass := preload("res://combat/attack_data.gd")

# Lightning addon preloads
const RitualVFX = preload("res://combat/ritual_vfx.gd")
const ChannelArc = preload("res://combat/channel_arc.gd")
const GameConsoleScript = preload("res://ui/console.gd")  # For checking is_console_open
const CrosshairScript = preload("res://ui/crosshair.gd")  # Archer sight, centre screen

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
## Horizontal velocity applied at jump-takeoff when the player is holding
## a movement direction. Turns "press Space" into a directional leap —
## core evasion tool per the 2026-04-18 playtest feedback (jump should
## help Paladin cross distance faster than walking).
const JUMP_FORWARD_BOOST: float = 5.5
## Damage multiplier while airborne. Incoming hits that connect while
## `is_on_floor() == false` apply this much of their rated damage.
## Rewards reading a telegraph and jumping over a swing.
const AERIAL_DAMAGE_MULT: float = 0.5
# Crouching braces the body: 25% less damage taken (souls "brace" rule).
const CROUCH_DAMAGE_MULT: float = 0.75
const CROUCH_SPEED_MULT: float = 0.5
# Co-op revive: hold E / gamepad Y beside a fallen ally for 5s. Interruptions (letting
# go, leaving range, taking a hit) reset the whole channel.
const REVIVE_RANGE: float = 2.6
const REVIVE_TIME: float = 5.0
# Archer aim zoom (drawing/holding the bow) — third-person but tighter.
const DEFAULT_SPRING_LENGTH: float = 4.2
const DEFAULT_CAMERA_FOV: float = 55.0
const AIM_ZOOM_SPRING: float = 1.7
const AIM_ZOOM_FOV: float = 44.0
# Over-the-shoulder aim: while the string is drawn the whole camera arm slides
# to the archer's right, so his body sits in the left of the frame instead of
# standing in front of what he is shooting at.
#
# The offset lives on the SpringArm3D and NOT on the camera: a SpringArm3D
# rewrites its child's transform every frame (position = back along its own
# +Z by spring_length), so an offset authored on the Camera3D is silently
# thrown away. Putting it on the arm also starts the collision sweep beside
# the shoulder, so a wall on the right pushes the view in instead of letting
# it clip through.
#
# Expressed as a fraction of the SCREEN width rather than as metres, because
# metres only look right at one aspect ratio: the same 0.5 m that frames him
# nicely on a 16:9 desktop shoves him off the left edge of a phone held
# upright (Godot keeps the vertical FOV, so a narrow window is a narrow
# horizontal cone). 0.24 puts his centre line about a quarter of the way in,
# leaving the whole right of the frame as the shooting lane.
const AIM_SHOULDER_SCREEN: float = 0.24
# ...and a little rise, so the sight line clears the shoulder rather than
# running through it.
const AIM_SHOULDER_LIFT: float = 0.10
# How far the crosshair ray looks for something to shoot at. Past this the
# arrow simply flies along the sight line (see _bow_aim_direction).
const AIM_RAY_LENGTH: float = 300.0
# World + enemies + remote players: everything an arrow can hit, which is
# exactly what the crosshair is allowed to sit on. Deliberately NOT layer 3
# (projectiles) — arrows in flight must not steal the aim point.
const AIM_RAY_MASK: int = 1 | 2 | 8
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
const UNARMED_CHARACTER_PATH: String = "res://assets/characters/paladin_unarmed_v3.glb"
const ARMED_CHARACTER_PATH: String = "res://assets/characters/paladin_armed_v3.glb"

# Character model paths - Archer
const ARCHER_CHARACTER_PATH: String = "res://assets/characters/archer_v3.glb"

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
	# Flinch and collapse: the Paladin packs ship neither. Both are authored
	# on the Archer's Mixamo rig and retarget by bone name (same mixamorig),
	# exactly like the dodge clips the armed set already borrows.
	"react_hit": "res://player/character/archer/standing react small from front.fbx",
	"death": "res://player/character/archer/standing death backward 01.fbx",
	"estus": "res://player/character/armed/PowerUp.fbx",
	"walk_back": "res://player/character/archer/standing walk back.fbx",
	"run_back": "res://player/character/archer/standing run back.fbx",
	# Unarmed shipped no evasion clip at all — the roll moved the body and
	# played whatever it was already playing. Same tumble as armed.
	"roll": "res://player/character/armed/Roll.fbx",
	# Crouch stance, shared with armed — same mixamorig retarget as above.
	"crouch": "res://player/character/armed/Crouch.fbx",
	# Crouch WALK — four directions, shared by every model (same mixamorig
	# retarget as the dodges and the crouch stance itself). Without these,
	# moving while crouched held the static stand-to-crouch pose and the
	# character slid across the ground in a tuck.
	"crouch_walk_f": "res://player/character/armed/Crouch Walk Forward.fbx",
	"crouch_walk_b": "res://player/character/armed/Crouch Walk Back.fbx",
	"crouch_walk_l": "res://player/character/armed/Crouch Walk Left.fbx",
	"crouch_walk_r": "res://player/character/armed/Crouch Walk Right.fbx",
}

# Armed animations (Paladin with sword & shield)
const ARMED_ANIM_PATHS: Dictionary = {
	"idle": "res://player/character/armed/Idle.fbx",
	"walk": "res://player/character/armed/Walk.fbx",
	"run": "res://player/character/armed/Run.fbx",
	"jump": "res://player/character/armed/Jump.fbx",
	"attack1": "res://player/character/armed/Attack1.fbx",
	"attack2": "res://player/character/armed/Attack2.fbx",
	"heavy_attack": "res://player/character/armed/Attack2.fbx",
	"sword_slash": "res://player/character/armed/SwordSlash.fbx",
	"block": "res://player/character/armed/Block.fbx",
	"sheath": "res://player/character/armed/Sheath.fbx",
	"spell_cast": "res://player/character/armed/SpellCast.fbx",
	# Estus drink — the Mixamo "sword and shield power up" flourish (raise
	# off-hand to the face) doubles convincingly as swigging a flask.
	"estus": "res://player/character/armed/PowerUp.fbx",
	# Lock-on strafes: armed has no authored strafe clips, so lock-on
	# strafing used to fall back to forward Walk (foot-sliding sideways).
	# Reuse the unarmed Paladin's strafes — same mixamorig skeleton,
	# retargeted by bone name exactly like the dodge clips below.
	"strafe_left": "res://player/character/unarmed/StrafeLeft.fbx",
	"strafe_right": "res://player/character/unarmed/StrafeRight.fbx",
	# Directional dodge-roll clips. Authored on the Archer's Mixamo rig but
	# retargeted onto the Paladin skeleton by bone name (same mixamorig).
	"dodge_f": "res://player/character/archer/standing dodge forward.fbx",
	"dodge_b": "res://player/character/archer/standing dodge backward.fbx",
	"dodge_l": "res://player/character/archer/standing dodge left.fbx",
	"dodge_r": "res://player/character/archer/standing dodge right.fbx",
	# The dodge-roll proper. Those four clips are SIDESTEPS — quick shuffles
	# that never leave the feet — which is why the roll never read as one.
	# This is a full tumble, played for any directional roll; the sidesteps
	# stay for the neutral backstep, which is a different move in the genre
	# and looks wrong as a somersault. Trimmed and speed-fitted on load
	# (ROLL_CLIP_FROM/TO), and it is the one clip that keeps its vertical
	# root motion.
	"roll": "res://player/character/armed/Roll.fbx",
	# Generic (non-bow) Mixamo clips from the Archer folder, same rig, same
	# bone-name retarget as the dodges above.
	"react_hit": "res://player/character/archer/standing react small from front.fbx",
	"death": "res://player/character/archer/standing death backward 01.fbx",
	"walk_back": "res://player/character/archer/standing walk back.fbx",
	"run_back": "res://player/character/archer/standing run back.fbx",
	"turn_left": "res://player/character/unarmed/TurnLeft.fbx",
	"turn_right": "res://player/character/unarmed/TurnRight.fbx",
	# Crouch used to be a Y-scale squash on the whole model; this is the
	# real stance — Mixamo "sword and shield crouch", a stand-to-crouch
	# transition whose last frame is the held pose.
	"crouch": "res://player/character/armed/Crouch.fbx",
	# Crouch WALK — four directions, shared by every model (same mixamorig
	# retarget as the dodges and the crouch stance itself). Without these,
	# moving while crouched held the static stand-to-crouch pose and the
	# character slid across the ground in a tuck.
	"crouch_walk_f": "res://player/character/armed/Crouch Walk Forward.fbx",
	"crouch_walk_b": "res://player/character/armed/Crouch Walk Back.fbx",
	"crouch_walk_l": "res://player/character/armed/Crouch Walk Left.fbx",
	"crouch_walk_r": "res://player/character/armed/Crouch Walk Right.fbx",
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
	"react_hit": "res://player/character/archer/standing react small from front.fbx",
	"dodge_f": "res://player/character/archer/standing dodge forward.fbx",
	"dodge_b": "res://player/character/archer/standing dodge backward.fbx",
	"dodge_l": "res://player/character/archer/standing dodge left.fbx",
	"dodge_r": "res://player/character/archer/standing dodge right.fbx",
	# Lock-on strafes. These shipped in the pack but were never wired, so
	# strafing sideways played the FORWARD walk and the archer skated.
	"crouch": "res://player/character/archer/standing to crouch.fbx",
	# Crouch WALK — four directions, shared by every model (same mixamorig
	# retarget as the dodges and the crouch stance itself). Without these,
	# moving while crouched held the static stand-to-crouch pose and the
	# character slid across the ground in a tuck.
	"crouch_walk_f": "res://player/character/armed/Crouch Walk Forward.fbx",
	"crouch_walk_b": "res://player/character/armed/Crouch Walk Back.fbx",
	"crouch_walk_l": "res://player/character/armed/Crouch Walk Left.fbx",
	"crouch_walk_r": "res://player/character/armed/Crouch Walk Right.fbx",
	"strafe_left": "res://player/character/archer/standing walk left.fbx",
	"strafe_right": "res://player/character/archer/standing walk right.fbx",
	"run_strafe_left": "res://player/character/archer/standing run left.fbx",
	"run_strafe_right": "res://player/character/archer/standing run right.fbx",
	# Retreating. The character always faces the camera, so walking back
	# used to moonwalk on a forward stride.
	"walk_back": "res://player/character/archer/standing walk back.fbx",
	"run_back": "res://player/character/archer/standing run back.fbx",
	# Aim-locomotion: stepping while the bow is drawn kept the legs but
	# threw the draw pose away. These hold the bow AND stride.
	"aim_walk": "res://player/character/archer/standing aim walk forward.fbx",
	"aim_walk_back": "res://player/character/archer/standing aim walk back.fbx",
	"aim_strafe_left": "res://player/character/archer/standing aim walk left.fbx",
	"aim_strafe_right": "res://player/character/archer/standing aim walk right.fbx",
	"death": "res://player/character/archer/standing death backward 01.fbx",
	"sheath": "res://player/character/archer/standing disarm bow.fbx",
	"turn_left": "res://player/character/archer/standing turn 90 left.fbx",
	"turn_right": "res://player/character/archer/standing turn 90 right.fbx",
	"estus": "res://player/character/armed/PowerUp.fbx",
}

var camera_rotation := Vector2.ZERO  # x = yaw, y = pitch
var _character_model: Node3D  # Container for both characters
var _spread_skeleton: Skeleton3D = null
## Crouch foot grounding (see _apply_crouch_grounding).
var _ground_skeleton: Skeleton3D = null
var _ground_feet: Array[int] = []
var _model_base_y: float = 0.0    #_character_model's authored rest height
var _crouch_sink: float = 0.0     #current model drop, smoothed
var _spread_left: int = -1
var _spread_right: int = -1
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

# Co-op AI companion mode: this player instance is driven by CompanionAI
# instead of human input. The AI writes _ai_move_vec/_ai_run (read where
# the Input singleton would normally be polled) and calls the action
# methods directly. See player/companion_ai.gd.
@export var is_ai_companion: bool = false
## True when a brain — not a human — supplies this body's input. Always true
## for the companion; also true for the PLAYER slot in spectate mode, where
## both classes are bots and the viewport just watches (GameSettings.spectate).
## `is_ai_companion` stays a question of IDENTITY (which half of the party am
## I); this one is a question of CONTROL, and every Input poll keys off it.
var ai_driven: bool = false
var companion_class_override: int = -1
var _ai_move_vec: Vector2 = Vector2.ZERO
var _ai_run: bool = false
var is_dead: bool = false
## True when death fell back to tipping the model over (no Death clip), so
## revive knows whether it has a rotation to undo.
var _tipped_over: bool = false
var is_crouching: bool = false
var is_reviving: bool = false
var _revive_progress: float = 0.0
var _ai_revive_intent: bool = false  # CompanionAI's "E held"
var _ai_crouch: bool = false
## CompanionAI's "block button held". The AI raises the shield for an
## incoming swing it cannot parry or roll: a block only chips, and chipped
## is a great deal better than clean.
var _ai_block: bool = false
var _death_marker: Node3D = null
var _revive_bar_layer: CanvasLayer = null
var _revive_bar: ProgressBar = null

# Combat state
var combat_mode: CombatMode = CombatMode.ARMED
var is_attacking: bool = false
var is_blocking: bool = false
var _left_trigger_down: Dictionary = {}
var is_sheathing: bool = false
var is_transitioning: bool = false  # For attack/idle transitions
var is_casting: bool = false
var attack_combo: int = 0
var _attack_cooldown: float = 0.0

#A recent click chains one swing during recovery. The third swing is slower
#and deals more poise damage; windup and contact remain committed.
const COMBO_ANIMS: Array[StringName] = [&"armed/SwordSlash", &"armed/Attack1", &"armed/Attack2"]
const COMBO_DAMAGE_MULT: Array[float] = [0.9, 1.0, 1.35]
const COMBO_POISE_DAMAGE: Array[float] = [30.0, 35.0, 60.0]
const COMBO_KNOCKBACK: Array[float] = [2.5, 3.0, 5.0]
## Forward step-in per swing — this is where the "longer range" lives: the
## swing carries the character toward the target, so contact stays visual.
const COMBO_LUNGE_SPEED: Array[float] = [2.0, 2.3, 2.8]
## Per-step clip speed — brisk openers, then the finisher slows down so its
## weight reads (souls/GoW heavy-hit pacing: fast light chain, slow payoff).
const SwordMoves = preload("res://player/sword_moves.gd")
const COMBO_DURATIONS = SwordMoves.DURATIONS
const COMBO_WINDOWS = SwordMoves.WINDOWS
const COMBO_RECOVERY = SwordMoves.RECOVERY
const COMBO_TRIMS = SwordMoves.TRIMS
## How far the upper arms are pushed out from the ribs, in degrees, on top of
## whatever the clip poses. Tuned by eye on the GEARSIM turntable — see
## _apply_arm_spread.
const ARM_SPREAD_DEGREES: float = 12.0

#Recovery starts after contact. A roll pays its cost before cancelling.
const ATTACK_CANCEL_POINT: float = 0.72
const ATTACK_CANCEL_COOLDOWN: float = 0.06
const COMBO_CHAIN_STAMINA_COST: float = 23.0
const COMBO_FINISHER_COOLDOWN: float = 0.10
const COMBO_TRAIL_COLOR: Color = Color(1.0, 0.9, 0.55, 0.8)
const COMBO_TRAIL_COLOR_FINISHER: Color = Color(1.0, 0.75, 0.35, 1.0)
var _combo_step: int = 0
var _combo_clicks_buffered: int = 0  #at most one pending follow-up
# Attack input buffer: a tap that lands during the recovery tail or the
# post-swing cooldown is QUEUED for this long and fires the moment the
# next swing is legal — instead of being silently eaten (the single
# biggest "controls feel dead" cause on touch).
const ATTACK_BUFFER_TIME: float = 0.38
var _attack_input_buffer: float = 0.0
var _buffer_heavy := false
var _heavy_attack: Resource
var _dodge_input_buffer: float = 0.0
var _guard_recoil := false
var _swing_targets: Dictionary = {}
var _blade_sweep := preload("res://combat/blade_sweep.gd").new()
var _sprint_exhausted: bool = false
const SPRINT_DRAIN: float = 13.0
const GUARD_BREAK_TIME: float = 1.1
const GUARD_CONE_DOT: float = 0.15
var _attack_lunge_dir: Vector3 = Vector3.ZERO
var _sword_trail: SlashTrail = null
var _sword_smear: SlashTrail = null
## Smear off the torso while the body is folding away from a blow — the same
## displaced-air read as a swing, applied to the recoil.
var _react_smear: SlashTrail = null

# Lock-on / target tracking (souls-like). When a target is locked, the
# camera (and therefore the strafe-facing character) orients to it every
# frame, so block, jump-dodge and the upcoming roll all read relative to
# the threat. This is the keystone fix for "hits come out of nowhere" —
# the camera can no longer be pointed away from the thing hitting you.
# Toggle with T or right-stick click.
var _lock_target: Node3D = null
var _lock_obscured: float = 0.0
var _lock_stick_ready := true
const LOCK_ON_RANGE: float = 22.0          # max distance to acquire a target
const LOCK_ON_BREAK_RANGE: float = 30.0    # auto-drop the lock past this
const LOCK_ON_ACQUIRE_HALF_ANGLE: float = 75.0  # deg off camera-forward to be eligible
const LOCK_ON_PITCH_DEG: float = -10.0     # camera pitch while locked (looks slightly down)
const LOCK_ON_TURN_SPEED: float = 12.0     # how fast the camera slerps onto the target
var _lock_indicator: Sprite3D = null       # billboard reticle drawn over the target

# Dodge-roll (souls-like). A committed directional dash with a brief
# invulnerability window — the genre's core evasion verb, distinct from
# the jump-dodge (which stays for traversal and aerial attacks). Press X /
# gamepad B. Direction comes from the movement stick (camera-relative);
# no input rolls backward (backstep). i-frames mean a well-timed roll
# passes clean through an attack for zero damage.
var is_rolling: bool = false
var _roll_timer: float = 0.0
var _roll_dir: Vector3 = Vector3.ZERO
## True when this roll is an actual tumble (directional) rather than the
## neutral backstep. A tumble turns the body down its own direction of
## travel; a backstep stays squared up to the camera.
var _roll_faces_dir: bool = false
## Held while a roll has cancelled the crouch, so releasing Ctrl — and only
## releasing it — hands the crouch back. See the crouch block in
## _physics_process for why the roll chord makes this necessary.
var _crouch_locked_out: bool = false
const ROLL_SPEED: float = 9.0          # m/s peak — faster than RUN_SPEED (7.0)
## Total roll length. Lengthened from 0.50 s when the tumble clip landed: a
## real forward roll cannot be told in half a second without playing at 3x,
## which reads as a stutter rather than a dodge. 0.72 s is Dark Souls' fast
## roll almost exactly, and the i-frame window below keeps the same share of
## it as before (~58%), so the timing the fight was tuned around is intact.
const ROLL_DURATION: float = 0.64
const ROLL_IFRAME_START: float = 0.09  # i-frames begin shortly after start
const ROLL_IFRAME_END: float = 0.34    # ...and end before recovery, leaving a punish window
const ROLL_STAMINA_COST: float = 22.0
## The slice of "Stand To Roll" that IS the roll. The source is 2.37 s of
## stand, crouch, dive, tumble and stand up; measured on the hips, the dive
## starts around 0.40 s and the body is coming back upright by 1.60 s
## (tools/measure_clip.gd). Everything outside that is a preamble the game
## does not want — the dodge has to be instant.
## Fraction of each stand-to-crouch clip kept: park on a readable half
## crouch (hips at ~75% of standing height, from tools/measure_clip.gd),
## not on the face-in-the-knees full tuck the clips end with.
const CROUCH_CLIP_END := {"archer": 0.48, "armed": 0.44, "unarmed": 0.44}
const ROLL_CLIP_FROM: float = 0.40
const ROLL_CLIP_TO: float = 1.60

# Parry → riposte (souls-like). Press G / gamepad LB to flick the shield.
# A parryable melee hit that lands on the player INSIDE the active window
# is deflected for zero damage and staggers the attacker into a long
# riposte window, during which the next sword hit crits. Missing the
# window leaves the player in recovery, fully vulnerable — the risk that
# makes the reward honest. The deflect only ever fires when the enemy's
# hitbox actually touched us, so the golden rule (no damage/effect
# without visible collision) holds in both directions.
var is_parrying: bool = false
var _parry_timer: float = 0.0          # counts up from 0 toward PARRY_TOTAL
const PARRY_TOTAL: float = 0.65        # full parry animation commitment
# Deflect frames. Bobba's fist-contact moment jitters ~0.25s for the same
# visual windup (depends on range: point-blank touches the instant the
# damage window arms; at arm's length the arc arrives ~0.2s later). The
# active window must cover that spread or identical, well-timed presses
# fail at random — which reads as unfair. 0.33s of actives + 0.27s of
# punishable recovery keeps the parry a commitment, not a free block.
const PARRY_WINDOW_START: float = 0.05
const PARRY_WINDOW_END: float = 0.22
const PARRY_STAMINA_COST: float = 12.0
# Chip damage through a held block. A block SOFTENS a hit, it never erases
# it — only a timed parry cancels damage outright. Shields excel against
# clean weapon strikes (sword, arrow); heavy blunt force (Bobba's fists)
# hurts through the guard.
const BLOCK_CHIP_MULT_WEAPON: float = 0.15
const BLOCK_CHIP_MULT_BLUNT: float = 0.30
## Sword damage multiplier when hitting a parried (riposte-ready) enemy.
const RIPOSTE_DAMAGE_MULT: float = 3.0
## Sword damage multiplier when the hit lands from the enemy's rear cone.
const BACKSTAB_DAMAGE_MULT: float = 2.0
## dot(enemy_forward, dir_to_attacker) below this = attacker is behind.
## -0.45 ≈ a 117° rear cone.
const BACKSTAB_CONE_DOT: float = -0.45

# Estus flask (souls-like healing). Press H / d-pad down. Limited charges
# per life, refilled on respawn. Drinking is a slow, interruptible channel:
# the charge is spent the moment the drink starts, and taking an unblocked
# hit mid-drink wastes it — healing in melee range is a gamble, as the
# genre demands.
var estus_charges: int = 3
const ESTUS_MAX_CHARGES: int = 3
var is_drinking: bool = false
var _drink_timer: float = 0.0
const ESTUS_DRINK_DURATION: float = 1.1
const ESTUS_HEAL_PCT: float = 0.45     # heal 45% of max HP per flask

# Archer bow state
var is_drawing_bow: bool = false  # True while the string is being pulled
var is_holding_bow: bool = false  # True when fully drawn and waiting on the loose
var _bow_draw_time: float = 0.0   # How long bow has been drawn
var _bow_loose_lock: float = 0.0  # seconds locomotion yields to the loose anim
var _bow_follow_time: float = 0.0
var _lost_release_grace: float = 0.0  # heals dropped touch-release events
## Which of the two shots is on the string.
##
## AIMED (right button / pad trigger held): the camera goes over the shoulder,
## the draw takes 1.5x as long, and the arrow waits at full draw until the
## button comes up — you choose the moment.
## QUICK (left button / F / touch attack, `false`): no zoom, normal draw, and
## the string goes on its own the instant the bar fills. One press, one arrow.
var _bow_aimed: bool = false
## Does this draw wait for a button to come UP, or does it loose itself?
##
#Right mouse and LT draw while held, then loose on release. The attack
#button starts a quick shot that looses itself once the draw completes.
var _bow_hold_release: bool = false
const BOW_DRAW_TIME_REQUIRED: float = 0.3  # Seconds of draw for a quick shot
## A sighted shot is the slower one to set up — that is what buys the zoom,
## the steady hold and the choice of when to loose.
const BOW_AIM_DRAW_MULT: float = 1.5
#Attack supplies the held pose; bow_anims composes the return to idle.
const BOW_DRAW_ANIM_SPEED: float = 3.0   # draw portion playback speed
const BOW_DRAW_POSE_TIME: float = 0.9    # clip-time of the "drawn" hold pose
const BOW_AIM_POWER: float = 1.5
const BOW_LOOSE_LOCK: float = 0.8
const BOW_CAMERA_HOLD: float = 0.45
const BOW_CAMERA_RETURN: float = 0.8
var _bow_progress_bar: ProgressBar  # UI progress bar for bow draw
var _crosshair: Control  # centre-screen sight, shown while the bow is drawn
var _bow_draw_visual: Node3D

# Damage/knockback state
var _knockback_velocity: Vector3 = Vector3.ZERO
var _is_stunned: bool = false
var _stun_timer: float = 0.0
var _hit_label_tween: Tween
var _hit_flash_tween: Tween
var _hit_label: Label3D
var _attack_hitbox: Area3D  # Sword hitbox for armed mode
var _unarmed_hitbox: Area3D  # Fist hitbox for unarmed mode
var _sword_bone_attachment: BoneAttachment3D
var _has_hit_this_attack: bool = false
var _hitbox_active_window: bool = false  # Whether we're in the damage-dealing portion of attack
var _attack_anim_progress: float = 0.0
const SWORD_HITBOX_START: float = 0.30  # Enable hitbox at 15% of attack animation
const SWORD_HITBOX_END: float = 0.53    # Disable hitbox at 95% of attack animation
const PLAYER_KNOCKBACK_RESISTANCE: float = 0.8  # Reduce knockback slightly
const PLAYER_ATTACK_DAMAGE: float = 15.0
const PLAYER_KNOCKBACK_FORCE: float = 10.0
## Knight (Paladin) sword deals this much flat damage per unblocked hit,
## scaled by (1.0 + damage_buff_pct) from the archer's buff spell.
## Blocks by the target fully negate the hit.
const KNIGHT_SWORD_DAMAGE: float = 100.0
## Cap for the damage buff accumulated from the archer's buff circle.
const DAMAGE_BUFF_MAX_PCT: float = 0.5
## How long a character is neutralized (no input, no attacks) after being
## damaged. 1/3 second — short enough to keep combat responsive, long enough
## that the player feels the hit.
const STUN_DURATION: float = 0.333

# Damage buff set by the archer's buff spell.
# While at least one BuffAuraArea is touching the knight, the buff
# accumulates at DAMAGE_BUFF_GROWTH_PER_SEC; while untouched, it decays at
# DAMAGE_BUFF_DECAY_PER_SEC, floored at 0 and capped at DAMAGE_BUFF_MAX_PCT.
const DAMAGE_BUFF_GROWTH_PER_SEC: float = 0.05
const DAMAGE_BUFF_DECAY_PER_SEC: float = 0.05
var damage_buff_pct: float = 0.0
var _buff_sources: int = 0

# Spell spawn/destroy handles — created on spell cast start, destroyed on stop.
var _heal_aura: HealAuraAreaClass = null
var _buff_aura: BuffAuraAreaClass = null

# Health system - varies by character class
const PALADIN_MAX_HP: float = 150.0
const ARCHER_MAX_HP: float = 100.0
const HEAL_RATE: float = 0.5  # HP healed per tick while casting spell
const HEAL_TICK_INTERVAL: float = 0.5  # Seconds between heal ticks
const HEAL_AREA_RADIUS: float = 3.0  # Radius of healing aura during spell cast

var _health: HealthComponentClass
var _heal_tick_timer: float = 0.0
var _health_bar: ProgressBar  # UI health bar

## Compatibility forwarders — external code still reads/writes
## `player.max_health` and `player.current_health` as it always has.
var max_health: float:
	get:
		return _health.max_hp if _health else 100.0
	set(value):
		if _health:
			_health.set_max_hp(value, false)
var current_health: float:
	get:
		return _health.current_hp if _health else 100.0
	set(value):
		if _health:
			_health.set_current_hp(value)

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
var _lightning_bolts_3d: Array = []  #three reusable arc meshes
var _bolt_rejitter_timer: float = 0.0  # irregular re-strike cadence
var _last_damage_ms: int = -100000     # for the paladin battle-focus cast rule
# Archer fire circle spell
var _fire_circle_particles: Array[GPUParticles3D] = []  # Multiple fire emitters in a circle
var _fire_circle_light: OmniLight3D
var _fire_sigil: MeshInstance3D
var _fire_circle_node: Node3D  # Container for fire circle effects
var _fire_circle_time: float = 0.0  # Track elapsed time for intensity reduction
var _fire_circle_active: bool = false  # Track if fire circle is active
const FIRE_CIRCLE_RADIUS: float = 2.5
const FIRE_CIRCLE_EMITTERS: int = 12
const FIRE_CIRCLE_DURATION: float = 4.0  # 4 seconds with 1/time intensity decay
var _character_aura_material: ShaderMaterial  # Fresnel aura shader
var _original_character_materials: Array[Dictionary] = []  # Store {mesh, material} pairs
const NUM_LIGHTNING_BOLTS: int = 7  # Number of 3D lightning bolts
var _spell_audio: Node3D
var _step_was_grounded := false
var _step_fall_speed := 0.0
var _step_timer: float = 0.0
const WALK_STEP_INTERVAL: float = 0.48
const RUN_STEP_INTERVAL: float = 0.30
const STEP_SPEED_THRESHOLD: float = 0.4  # m/s of horizontal speed
# Force Field / Bubble Shield (V2 Asset Rich)
var _force_field_sphere: MeshInstance3D  # Bubble shield around character
var _force_field_light: OmniLight3D  # Constant light inside force field
var _force_field_material: ShaderMaterial  # Bubble shader with noise distortion

@onready var initial_position := position
@onready var gravity: Vector3 = ProjectSettings.get_setting("physics/3d/default_gravity") * \
		ProjectSettings.get_setting("physics/3d/default_gravity_vector")

@onready var _camera_pivot := $CameraPivot as Node3D
@onready var _spring_arm := $CameraPivot/SpringArm3D as SpringArm3D
@onready var _camera := $CameraPivot/SpringArm3D/Camera3D as Camera3D


func _ready() -> void:
	ai_driven = is_ai_companion or _spectating()
	print("Player: _ready() starting (ai_companion=%s, ai_driven=%s)" % [is_ai_companion, ai_driven])
	if is_ai_companion:
		add_to_group("companion")
	else:
		add_to_group("player")  # Add to player group so NetworkManager can find us
	add_to_group("characters")  # every AI perceives via this group
	if not is_ai_companion:
		_parse_fifo_args()  # Check for --fifo and --player-id command line args
		CloudInput.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	# Souls camera: the spring arm must never collide with our own capsule,
	# and the default view sits slightly above the shoulder looking down.
	if _spring_arm != null:
		_spring_arm.add_excluded_object(get_rid())
	camera_rotation.y = deg_to_rad(-10.0)
	_camera_pivot.rotation.x = camera_rotation.y
	_setup_health_component()
	_setup_stamina_component()
	_setup_attack_hitbox()  # Must be before _create_characters which attaches hitbox to bones
	# Slash ribbon follows the sword hitbox wherever it gets bone-attached.
	_sword_trail = SlashTrail.attach(self, _attack_hitbox,
			Vector3(0, 0, 0.15), Vector3(0, 0, 1.55), COMBO_TRAIL_COLOR)
	# Wind smear: a wider, softer band of torn air riding outside the blade.
	_sword_smear = SlashTrail.attach_smear(self, _attack_hitbox,
			Vector3(0, 0, 0.15), Vector3(0, 0, 1.55))
	# The same smear on the BODY, for the whip of getting hit. Cooler and
	# fainter than a swing — this is the character being moved, not moving.
	_react_smear = SlashTrail.attach_smear(self, self,
			Vector3(-0.45, 0.9, 0.0), Vector3(0.45, 1.7, 0.0),
			Color(0.72, 0.80, 0.95, 0.13), 1.0)
	_create_characters()
	_bow_draw_visual = preload("res://player/bow_draw.gd").new()
	add_child(_bow_draw_visual)
	_bow_draw_visual.setup(self, _archer_character)
	preload("res://player/cape.gd").install(_archer_character, _find_skeleton(_archer_character))
	for model in [_armed_character, _unarmed_character]:
		preload("res://player/cape.gd").install(model, _find_skeleton(model), true)
	_create_lightning_particles()
	_create_fire_circle_spell()
	_setup_hit_label()
	_setup_bow_progress_bar()
	_setup_health_bar()
	_setup_multiplayer()
	_setup_fifo()
	if is_ai_companion:
		# The spawner positions the companion; its camera must never take
		# over the viewport and no human input may reach it.
		_camera.current = false
		set_process_input(false)
		set_process_unhandled_input(false)
	else:
		# Spawn player on a random hill
		_spawn_at_tower()
	# Apply character selection from GameSettings (character select menu)
	call_deferred("_apply_character_selection")
	# Connect to Bobba death signal for game restart (companion must not
	# double-trigger the restart)
	if not is_ai_companion:
		call_deferred("_connect_bobba_death_signal")
	# Notify NetworkManager that game scene is ready for remote players
	call_deferred("_notify_network_manager_ready")


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
	# AI companion: class is dictated by the spawner (the opposite of the
	# human's pick), never by menu/GameSettings.
	if is_ai_companion:
		if companion_class_override >= 0:
			_switch_character_class(companion_class_override as CharacterClass)
		return
	# First check GameSettings autoload (from character select menu)
	if GameSettings:
		var selected_class = GameSettings.selected_character_class
		print("Player: Selected character class from GameSettings: %d" % selected_class)
		if selected_class == 0:
			_switch_character_class(CharacterClass.PALADIN)
		else:
			_switch_character_class(CharacterClass.ARCHER)
		call_deferred("_spawn_companion_if_coop")
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


## ------------------------------------------------------------------
## CO-OP REVIVE: one player can raise the other. The fallen body stays
## where it dropped under a bright blue beacon label; the living player
## holds E / gamepad Y beside it (the AI companion "holds" _ai_revive_intent) for 5
## uninterrupted seconds — a progress bar fills, every action except
## crouching is locked, and letting go / walking off / taking a hit
## resets the channel to zero.
## ------------------------------------------------------------------

## The other half of the duo (companion for the human, human for the AI).
func _party_other() -> Node3D:
	var gname := "player" if is_ai_companion else "companion"
	return get_tree().get_first_node_in_group(gname) as Node3D


func _update_revive(delta: float) -> void:
	if is_dead:
		return
	var other := _party_other()
	if other == null or not is_instance_valid(other) \
			or not ("is_dead" in other) or not other.is_dead:
		if is_reviving:
			_cancel_revive("ally gone")
		return
	var wants: bool = _ai_revive_intent if ai_driven \
			else Input.is_action_pressed(&"revive")
	var in_range: bool = global_position.distance_to(other.global_position) <= REVIVE_RANGE
	if wants and in_range:
		if not is_reviving:
			is_reviving = true
			_revive_progress = 0.0
			print("Player(%s): reviving ally…" % name)
		_revive_progress += delta
		_update_revive_bar(_revive_progress / REVIVE_TIME)
		if _revive_progress >= REVIVE_TIME:
			is_reviving = false
			_revive_progress = 0.0
			_update_revive_bar(-1.0)
			other.revive_from_death()
			Sfx.play3d("estus_drink", other.global_position + Vector3(0, 1, 0), -4.0)
			print("Player(%s): ally revived!" % name)
	elif is_reviving:
		_cancel_revive("released or out of range")


func _cancel_revive(reason: String) -> void:
	is_reviving = false
	_revive_progress = 0.0
	_update_revive_bar(-1.0)
	print("Player(%s): revive interrupted (%s) — progress lost" % [name, reason])


## Bottom-centre loading bar, human instance only. value < 0 hides it.
func _update_revive_bar(value: float) -> void:
	if is_ai_companion:
		return
	# Mobile shows revive progress as the arc around the touch button's
	# circular edge (touch_screen_ui.gd) — no bottom bar there.
	if CloudInput.touchscreen_available() or OS.get_name() in ["Android", "iOS"]:
		return
	if _revive_bar_layer == null:
		_revive_bar_layer = CanvasLayer.new()
		_revive_bar_layer.name = "ReviveBarLayer"
		add_child(_revive_bar_layer)
		var panel := Control.new()
		panel.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
		panel.position = Vector2(-160, -140)
		_revive_bar_layer.add_child(panel)
		var label := Label.new()
		label.name = "ReviveLabel"
		label.text = "REVIVING ALLY"
		label.add_theme_color_override("font_color", Color(0.45, 0.8, 1.0))
		label.add_theme_font_size_override("font_size", 18)
		label.position = Vector2(96, -26)
		panel.add_child(label)
		_revive_bar = ProgressBar.new()
		_revive_bar.min_value = 0.0
		_revive_bar.max_value = 1.0
		_revive_bar.show_percentage = false
		_revive_bar.custom_minimum_size = Vector2(320, 18)
		var fill := StyleBoxFlat.new()
		fill.bg_color = Color(0.35, 0.75, 1.0)
		_revive_bar.add_theme_stylebox_override("fill", fill)
		var bg := StyleBoxFlat.new()
		bg.bg_color = Color(0.05, 0.1, 0.18, 0.85)
		_revive_bar.add_theme_stylebox_override("background", bg)
		panel.add_child(_revive_bar)
	_revive_bar_layer.visible = value >= 0.0
	if value >= 0.0:
		_revive_bar.value = value


## Bright blue beacon over the fallen body — visible through everything,
## it POINTS the living player at the revive spot.
func _spawn_death_marker() -> void:
	_clear_death_marker()
	var marker := Node3D.new()
	marker.name = name + "DeathMarker"
	get_tree().current_scene.add_child(marker)
	marker.global_position = global_position
	var label := Label3D.new()
	label.text = "⚑ REVIVE [E]"
	label.font_size = 120
	label.pixel_size = 0.02
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.modulate = Color(0.3, 0.75, 1.0)
	label.outline_modulate = Color(0.0, 0.15, 0.4)
	label.outline_size = 24
	label.position = Vector3(0, 2.4, 0)
	marker.add_child(label)
	var beam := OmniLight3D.new()
	beam.light_color = Color(0.3, 0.6, 1.0)
	beam.light_energy = 6.0
	beam.omni_range = 6.0
	beam.position = Vector3(0, 1.5, 0)
	marker.add_child(beam)
	_death_marker = marker
	print("Player(%s): revive beacon up" % name)


func _clear_death_marker() -> void:
	if _death_marker != null and is_instance_valid(_death_marker):
		_death_marker.queue_free()
	_death_marker = null


## Downed, not gone: the body stays under the beacon awaiting the ally.
func _enter_downed() -> void:
	is_dead = true
	is_attacking = false
	is_reviving = false
	_ai_move_vec = Vector2.ZERO
	velocity = Vector3.ZERO
	_update_revive_bar(-1.0)
	set_physics_process(false)
	# Collapse properly if the library has a death clip; the flat -90 tip
	# is the fallback for a rig that doesn't, and holding the clip's last
	# frame is what keeps the body lying there for the ally.
	_tipped_over = not _play_death_anim()
	if _tipped_over and _character_model:
		_character_model.rotation.x = deg_to_rad(-90.0)
	_spawn_death_marker()


## Plays `<prefix>/Death`. False when the library has no death clip, which
## is the caller's cue to fall back to tipping the model over. The body is
## frozen on the clip's last frame by _on_animation_finished — otherwise it
## would snap back to the idle pose the instant the collapse ended.
func _play_death_anim() -> bool:
	var anim := StringName(_get_current_mode_prefix() + "/Death")
	if _current_anim_player == null or not _current_anim_player.has_animation(anim):
		return false
	_current_anim_player.play(anim)
	_current_anim = anim
	return true


## An ally finished the 5s channel: back on our feet at half strength.
func revive_from_death() -> void:
	is_dead = false
	current_health = max_health * 0.5
	health_changed.emit(current_health, max_health)
	velocity = Vector3.ZERO
	_spawn_immunity_timer = 3.0
	if _tipped_over and _character_model:
		_character_model.rotation.x = 0.0
	_tipped_over = false
	if _current_anim_player != null:
		# Undo the paused death pose; _update_animation takes over again.
		_current_anim_player.play(StringName(_get_current_mode_prefix() + "/Idle"))
		_current_anim = StringName(_get_current_mode_prefix() + "/Idle")
	_clear_death_marker()
	set_physics_process(true)
	print("Player(%s): back from the dead at %.0f hp" % [name, current_health])


## Co-op: the human picked a class in the menu — spawn the OTHER class as
## an AI-driven companion beside them.
func _spawn_companion_if_coop() -> void:
	if is_ai_companion:
		return
	if GameSettings == null or not ("coop_mode" in GameSettings) or not GameSettings.coop_mode:
		return
	if get_tree().get_first_node_in_group("companion") != null:
		return
	var comp: CharacterBody3D = load("res://player/player.tscn").instantiate()
	comp.name = "Companion"
	comp.is_ai_companion = true
	comp.enable_multiplayer = false
	comp.enable_fifo = false
	comp.companion_class_override = CharacterClass.ARCHER \
			if character_class == CharacterClass.PALADIN else CharacterClass.PALADIN
	get_tree().current_scene.add_child(comp)
	# The party spawns SEPARATED, neither knowing where the other is — the
	# companion takes the spawn point FARTHEST from the human's.
	var far_point: Vector3 = SPAWN_POINTS[0]
	var far_dist: float = -1.0
	for sp in SPAWN_POINTS:
		var d: float = global_position.distance_to(sp)
		if d > far_dist:
			far_dist = d
			far_point = sp
	var ang := randf() * TAU
	comp.global_position = far_point \
			+ Vector3(cos(ang) * randf_range(4.0, 10.0), 0.5, sin(ang) * randf_range(4.0, 10.0))
	var ai := CompanionAI.new()
	ai.name = "CompanionAI"
	ai.body = comp
	comp.add_child(ai)
	print("Player: Co-op companion spawned (%s)" % (
			"Archer" if comp.companion_class_override == CharacterClass.ARCHER else "Paladin"))
	if _spectating():
		# Nobody is at the keyboard: this half of the party gets a brain of
		# its own, and the view moves out of both heads into a chase rig.
		var mine := CompanionAI.new()
		mine.name = "CompanionAI"
		mine.body = self
		add_child(mine)
		var rig := SpectateCam.new()
		rig.name = "SpectateCam"
		get_tree().current_scene.add_child(rig)
		rig.watch(self)
		print("Player: SPECTATE — both classes are bots (TAB switches view)")


## Nobody is playing: both classes are bots and the viewport is a spectator.
func _spectating() -> bool:
	return GameSettings != null and "spectate" in GameSettings and GameSettings.spectate


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
	#The wire vector carries launch strength in its magnitude.
	arrow.shot_power = direction.length()

	# Find shooter node (remote player or ourselves, though we filter our own)
	if has_node("/root/NetworkManager"):
		var network_manager = get_node("/root/NetworkManager")
		if arrow.shooter_id in network_manager.remote_players:
			arrow.shooter = network_manager.remote_players[arrow.shooter_id]

	# Add arrow to scene
	get_tree().current_scene.add_child(arrow)
	if arrow.shooter is PhysicsBody3D:
		arrow.add_collision_exception_with(arrow.shooter)
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
	# Visual-only fire for a remote player's arrow (no local damage aura —
	# the shooter's client owns the DoT). Same FireFX composition as local
	# arrow fires; shadows off since several may burn at once. The name
	# keeps "GroundFire" so Bobba's fire avoidance sees it.
	FireFX.create_ground_fire(get_tree().current_scene, pos,
			"NetworkGroundFire", 30.0, false)


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
		if _armed_anim_player == null:
			# The authored character assets ship geometry and a skeleton but
			# no clips, so there is nothing for the importer to build a player
			# from — the other two classes already handled this, armed did not
			# and would have silently loaded zero animations.
			_armed_anim_player = AnimationPlayer.new()
			_armed_anim_player.name = "AnimationPlayer"
			_armed_character.add_child(_armed_anim_player)
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

	# Only the model on show animates. The other two rigs are hidden, but an
	# AnimationPlayer keeps posing its skeleton whether anyone sees it or
	# not — four full rigs a frame across a player and a companion. Every
	# swap plays Idle on the model it reveals, so a paused rig never shows
	# a stale pose.
	for pair in [[_unarmed_character, _unarmed_anim_player],
			[_armed_character, _armed_anim_player],
			[_archer_character, _archer_anim_player]]:
		var model: Node3D = pair[0]
		var anim: AnimationPlayer = pair[1]
		if model and anim:
			anim.active = model.visible
			model.visibility_changed.connect(func() -> void: anim.active = model.visible)

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
	_magic_circle = RitualVFX.sigil(Color(0.32, 0.65, 1.0), 4.5)
	_magic_circle.name = "MagicCircle"
	_magic_circle.visible = false
	_spell_effects_container.add_child(_magic_circle)


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
render_mode blend_add, depth_draw_never, cull_front, unshaded;

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
	_force_field_material.set_shader_parameter("bubble_color", Color(0.25, 0.5, 0.9, 0.10))
	_force_field_material.set_shader_parameter("fresnel_power", 5.0)
	_force_field_material.set_shader_parameter("edge_intensity", 0.65)
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
	_spell_light.shadow_enabled = false
	_spell_light.position = Vector3(0, 1.5, 0)

	_spell_effects_container.add_child(_spell_light)


func _create_fire_circle_spell() -> void:
	# Create container for Archer's fire circle spell
	_fire_circle_node = Node3D.new()
	_fire_circle_node.name = "FireCircleSpell"
	add_child(_fire_circle_node)
	_fire_sigil = RitualVFX.sigil(Color(1.0, 0.38, 0.08), 5.8)
	_fire_sigil.visible = false
	_fire_circle_node.add_child(_fire_sigil)

	# Create warm fire light (orange/red glow)
	_fire_circle_light = OmniLight3D.new()
	_fire_circle_light.name = "FireCircleLight"
	_fire_circle_light.light_color = Color(1.0, 0.6, 0.2)
	_fire_circle_light.light_energy = 0.0  # Start off
	_fire_circle_light.omni_range = 6.0
	_fire_circle_light.omni_attenuation = 1.5
	_fire_circle_light.shadow_enabled = false
	_fire_circle_light.position = Vector3(0, 0.5, 0)
	_fire_circle_node.add_child(_fire_circle_light)

	for i in range(FIRE_CIRCLE_EMITTERS):
		var angle := TAU * i / FIRE_CIRCLE_EMITTERS
		var pos := Vector3(cos(angle), 0, sin(angle)) * FIRE_CIRCLE_RADIUS
		var fire := RitualVFX.ring_flame(pos + Vector3.UP * .1)
		_fire_circle_node.add_child(fire)
		_fire_circle_particles.append(fire)
	var embers := RitualVFX.sparks(true, Color(1.0, .5, .12))
	embers.process_material.emission_ring_radius = FIRE_CIRCLE_RADIUS
	embers.process_material.emission_ring_inner_radius = FIRE_CIRCLE_RADIUS - .3
	_fire_circle_node.add_child(embers)
	_fire_circle_particles.append(embers)

func _create_spark_particles() -> void:
	_lightning_particles = RitualVFX.sparks(false)
	_lightning_particles.name = "CoreSparks"
	_spell_effects_container.add_child(_lightning_particles)


func _create_rising_sparks() -> void:
	_rising_sparks = RitualVFX.sparks(true)
	_rising_sparks.name = "RisingSparks"
	_spell_effects_container.add_child(_rising_sparks)


func _create_lightning_bolts() -> void:
	# Lightning bolt streaks
	_lightning_bolts = GPUParticles3D.new()
	_lightning_bolts.name = "LightningBolts"
	_lightning_bolts.emitting = false
	_lightning_bolts.amount = 24
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
	mat.scale_min = 0.6
	mat.scale_max = 1.2

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
	bolt_mat.emission_energy_multiplier = 1.2
	bolt_mat.albedo_texture = FireFX._soft_circle_tex()
	bolt_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	bolt_mat.vertex_color_use_as_albedo = true
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
	_character_aura_material.set_shader_parameter("aura_color", Color(0.3, 0.5, 1.0, 0.22))
	_character_aura_material.set_shader_parameter("secondary_color", Color(0.6, 0.3, 1.0, 0.6))
	_character_aura_material.set_shader_parameter("intensity", 0.65)
	_character_aura_material.set_shader_parameter("fresnel_power", 2.5)
	_character_aura_material.set_shader_parameter("pulse_speed", 3.0)


func _create_procedural_lightning_bolts() -> void:
	for i in range(NUM_LIGHTNING_BOLTS):
		var bolt := ChannelArc.new()
		bolt.name = "ChannelArc%d" % i
		bolt.visible = false
		_spell_effects_container.add_child(bolt)
		_lightning_bolts_3d.append(bolt)


func _create_spell_audio_system() -> void:
	_spell_audio = preload("res://combat/spell_audio.gd").new()
	_spell_effects_container.add_child(_spell_audio)


func _randomize_lightning_bolt_endpoints() -> void:
	RitualVFX.place_arcs(_lightning_bolts_3d)


func _update_spell_effects(delta: float) -> void:
	if not is_casting:
		return

	_spell_time += delta

	# Healing during the Paladin spell is now handled by a HealAuraArea spawned
	# in _start_lightning_spell() — it ticks percent-based heals automatically
	# (+5%/sec knight, +10%/sec archer inside the 5m radius).

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
	var base_energy := 2.8
	var flicker := sin(_spell_time * 20.0) * 0.5 + sin(_spell_time * 33.0) * 0.25
	_spell_light.light_energy = base_energy + flicker

	# Irregular re-strikes: bolts jump to new anchor points at a jittered
	# cadence instead of holding one pattern for the whole cast.
	_bolt_rejitter_timer -= delta
	if _bolt_rejitter_timer <= 0.0:
		_bolt_rejitter_timer = randf_range(0.10, 0.30)
		_randomize_lightning_bolt_endpoints()

	# The magic circle breathes: uneven spin and a two-frequency pulse.
	if _magic_circle and _magic_circle.visible:
		_magic_circle.rotation.y += delta * 0.12
		var pulse := 1.0 + 0.012 * sin(_spell_time * 3.0)
		_magic_circle.scale = Vector3(pulse, 1.0, pulse)


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
		_original_character_materials.append({"mesh": node,
			"material": node.material_overlay})
		node.material_overlay = _character_aura_material
	for child in node.get_children():
		_apply_aura_recursive(child)


func _remove_character_aura() -> void:
	for entry: Dictionary in _original_character_materials:
		var mesh_inst: MeshInstance3D = entry.mesh
		if is_instance_valid(mesh_inst):
			mesh_inst.material_overlay = entry.material
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
	_spell_tween.tween_property(_force_field_light, "light_energy", 0.6, 0.4).set_ease(Tween.EASE_OUT)

	# Animate spell light (initial value, will be modulated by _update_spell_effects)
	_spell_light.light_energy = 0.0
	_spell_tween.tween_property(_spell_light, "light_energy", 2.8, 0.3).set_ease(Tween.EASE_OUT)

	# Start all particles
	_lightning_particles.emitting = true
	_rising_sparks.emitting = true
	_lightning_bolts.emitting = true


	# Show 3D lightning bolts (addon-based with animated shader)
	for bolt in _lightning_bolts_3d:
		bolt.visible = true
	_randomize_lightning_bolt_endpoints()

	# Apply character aura
	_apply_character_aura()

	# Spawn the knight heal-circle aura: any Paladin inside recovers 5%/sec,
	# any Archer inside recovers 10%/sec. Parented to the player so it
	# follows the caster until the spell ends.
	_spawn_heal_aura()

	_spell_audio.start(false)

func _spawn_heal_aura() -> void:
	if _heal_aura and is_instance_valid(_heal_aura):
		_heal_aura.queue_free()
	_heal_aura = HealAuraAreaClass.new()
	_heal_aura.name = "KnightHealAura"
	_heal_aura.radius = HEAL_AREA_RADIUS
	_heal_aura.knight_heal_pct_per_sec = 0.05
	_heal_aura.archer_heal_pct_per_sec = 0.10
	_heal_aura.tick_interval = 1.0
	add_child(_heal_aura)


func _destroy_heal_aura() -> void:
	if _heal_aura and is_instance_valid(_heal_aura):
		_heal_aura.queue_free()
	_heal_aura = null


func _start_fire_circle_spell() -> void:
	_spell_audio.start(true)
	# Archer fire circle spell - flames stay lit for FIRE_CIRCLE_DURATION with 1/time decay
	_fire_circle_active = true
	_fire_sigil.visible = true
	_fire_circle_time = 0.0
	# The burning ring is a REAL fire to every AI: it reveals whoever
	# stands in it (including the caster) and Bobba's fire-avoidance and
	# escape-route planning treat it as a hazard.
	if _fire_circle_node and not _fire_circle_node.is_in_group("ground_fire"):
		_fire_circle_node.add_to_group("ground_fire")

	# Start fire light (intensity will be managed by _update_spell_effects)
	_fire_circle_light.light_energy = 4.0

	# Start all fire emitters
	for fire in _fire_circle_particles:
		fire.emitting = true

	# Spawn the archer buff aura: any Knight (Paladin) inside accumulates
	# +5%/sec damage buff (capped at +50%), decays when they leave.
	_spawn_buff_aura()

	# Schedule auto-stop after FIRE_CIRCLE_DURATION
	_spell_tween.tween_callback(_stop_fire_circle_spell).set_delay(FIRE_CIRCLE_DURATION)


func _spawn_buff_aura() -> void:
	if _buff_aura and is_instance_valid(_buff_aura):
		_buff_aura.queue_free()
	_buff_aura = BuffAuraAreaClass.new()
	_buff_aura.name = "ArcherBuffAura"
	# A bit larger than the visual fire ring so a Paladin standing at the
	# edge of the flames still gets buffed.
	_buff_aura.radius = FIRE_CIRCLE_RADIUS * 1.5
	_buff_aura.exclude_node = self
	add_child(_buff_aura)


func _destroy_buff_aura() -> void:
	if _buff_aura and is_instance_valid(_buff_aura):
		_buff_aura.queue_free()
	_buff_aura = null


func _stop_fire_circle_spell() -> void:
	_spell_audio.stop()
	# Stop the Archer fire circle spell effects
	_fire_circle_active = false
	if is_instance_valid(_fire_sigil):
		_fire_sigil.visible = false
	if _fire_circle_node and _fire_circle_node.is_in_group("ground_fire"):
		_fire_circle_node.remove_from_group("ground_fire")

	# Destroy the damage-buff aura so any Paladin inside starts decaying.
	_destroy_buff_aura()

	var fade_tween = create_tween()
	fade_tween.set_parallel(true)

	# Fade out fire light
	if _fire_circle_light:
		fade_tween.tween_property(_fire_circle_light, "light_energy", 0.0, 0.5).set_ease(Tween.EASE_IN)

	# Stop all fire emitters. Validity-checked: the fire circle node sits in
	# the "ground_fire" group, so anything that sweeps that group can free it
	# out from under the caster, and writing to a freed emitter throws.
	for fire in _fire_circle_particles:
		if is_instance_valid(fire):
			fire.emitting = false


func _stop_spell_effects() -> void:
	if _spell_tween:
		_spell_tween.kill()

	# Knight heal circle — despawn regardless of class (safe no-op if unused).
	_destroy_heal_aura()

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

	_spell_audio.stop()

func _get_unarmed_config() -> Dictionary:
	return {
		"idle": ["Idle", true],
		"walk": ["Walk", true],
		"run": ["Run", true],
		"strafe_left": ["StrafeLeft", true],
		"strafe_right": ["StrafeRight", true],
		"crouch": ["Crouch", false],
		"crouch_walk_f": ["CrouchWalkF", true],
		"crouch_walk_b": ["CrouchWalkB", true],
		"crouch_walk_l": ["CrouchWalkL", true],
		"crouch_walk_r": ["CrouchWalkR", true],
		"jump": ["Jump", false],
		"turn_left": ["TurnLeft", false],
		"turn_right": ["TurnRight", false],
		"attack": ["Attack", false],
		"block": ["Block", true],
		"action_to_idle": ["ActionToIdle", false],
		"idle_to_fight": ["IdleToFight", false],
		"react_hit": ["ReactHit", false],
		"death": ["Death", false],
		"estus": ["Estus", false],
		"walk_back": ["WalkBack", true],
		"run_back": ["RunBack", true],
		"roll": ["Roll", false],
	}


func _get_armed_config() -> Dictionary:
	return {
		"idle": ["Idle", true],
		"walk": ["Walk", true],
		"run": ["Run", true],
		"strafe_left": ["StrafeLeft", true],
		"strafe_right": ["StrafeRight", true],
		"crouch": ["Crouch", false],
		"crouch_walk_f": ["CrouchWalkF", true],
		"crouch_walk_b": ["CrouchWalkB", true],
		"crouch_walk_l": ["CrouchWalkL", true],
		"crouch_walk_r": ["CrouchWalkR", true],
		"jump": ["Jump", false],
		"attack1": ["Attack1", false],
		"attack2": ["Attack2", false],
		"heavy_attack": ["HeavyAttack", false],
		"sword_slash": ["SwordSlash", false],
		"block": ["Block", true],
		"sheath": ["Sheath", false],
		"spell_cast": ["SpellCast", false],
		"estus": ["Estus", false],
		"dodge_f": ["DodgeF", false],
		"dodge_b": ["DodgeB", false],
		"dodge_l": ["DodgeL", false],
		"dodge_r": ["DodgeR", false],
		"roll": ["Roll", false],
		"react_hit": ["ReactHit", false],
		"death": ["Death", false],
		"walk_back": ["WalkBack", true],
		"run_back": ["RunBack", true],
		"turn_left": ["TurnLeft", false],
		"turn_right": ["TurnRight", false],
	}


func _get_archer_config() -> Dictionary:
	return {
		"idle": ["Idle", true],
		"walk": ["Walk", true],
		"run": ["Run", true],
		"crouch": ["Crouch", false],
		"crouch_walk_f": ["CrouchWalkF", true],
		"crouch_walk_b": ["CrouchWalkB", true],
		"crouch_walk_l": ["CrouchWalkL", true],
		"crouch_walk_r": ["CrouchWalkR", true],
		"jump": ["Jump", false],
		"attack": ["Attack", false],
		"block": ["Block", true],
		"sprint": ["Sprint", true],
		"spell_cast": ["SpellCast", false],
		"react_hit": ["ReactHit", false],
		"dodge_f": ["DodgeF", false],
		"dodge_b": ["DodgeB", false],
		"dodge_l": ["DodgeL", false],
		"dodge_r": ["DodgeR", false],
		"strafe_left": ["StrafeLeft", true],
		"strafe_right": ["StrafeRight", true],
		"run_strafe_left": ["RunStrafeLeft", true],
		"run_strafe_right": ["RunStrafeRight", true],
		"walk_back": ["WalkBack", true],
		"run_back": ["RunBack", true],
		"aim_walk": ["AimWalk", true],
		"aim_walk_back": ["AimWalkBack", true],
		"aim_strafe_left": ["AimStrafeLeft", true],
		"aim_strafe_right": ["AimStrafeRight", true],
		"death": ["Death", false],
		"sheath": ["Sheath", false],
		"turn_left": ["TurnLeft", false],
		"turn_right": ["TurnRight", false],
		"estus": ["Estus", false],
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

	preload("res://player/character_materials.gd").apply(instance)

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
			_retarget_animation(new_anim, skel_path, skeleton, anim_key == "roll")
			if library_prefix == "armed" and COMBO_TRIMS.has(anim_key):
				var trim: Vector2 = COMBO_TRIMS[anim_key]
				new_anim = ClipTrim.sub(new_anim, trim.x, trim.y)
			if anim_key == "crouch":
				# The tail of the stand-to-crouch clips is a maximal tuck —
				# body folded flat, face in the knees. Park on the readable
				# half-crouch partway in instead; the grounding pass
				# (_apply_crouch_grounding) keeps whatever frame we park on
				# standing on its feet.
				new_anim = ClipTrim.sub(new_anim, 0.0,
						new_anim.length * CROUCH_CLIP_END[library_prefix])
			if anim_key == "roll":
				new_anim = ClipTrim.sub(new_anim, ROLL_CLIP_FROM, ROLL_CLIP_TO)
				new_anim.loop_mode = Animation.LOOP_NONE

			var lib_name: StringName = StringName(library_prefix)
			if not anim_player.has_animation_library(lib_name):
				anim_player.add_animation_library(lib_name, AnimationLibrary.new())
			anim_player.get_animation_library(lib_name).add_animation(StringName(anim_config[0]), new_anim)
			print("  Loaded: ", library_prefix, "/", anim_config[0])

		instance.queue_free()

	# Neither Paladin set ships a hit reaction and the Archer's is a single
	# front-on flinch, so a blow from any angle looked the same. Build four.
	HitReactAnim.compose(anim_player, skeleton, library_prefix)

	# Borrowed retreat clips swing the arms loose — put the character's own
	# weapon carriage back on top before anything is composed from them.
	DerivedAnims.compose(anim_player, library_prefix)

	# No rig ships a block-walk clip, so build one: guard on the arms,
	# stride on the legs. Without this, raising the shield froze the legs
	# mid-step while the character kept sliding forward.
	BlockStanceAnim.compose(anim_player, library_prefix)
	preload("res://player/bow_anims.gd").compose(anim_player, library_prefix)


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


## `keep_vertical` keeps the Hips' UP motion while still discarding the
## horizontal travel. Almost every clip wants root motion gone outright —
## code drives the character and a clip that also walks it fights that. A
## roll is the exception: the hips genuinely drop to the floor and come back
## up, and flattening that leaves the body pirouetting around standing hip
## height with its head through the ground.
func _retarget_animation(anim: Animation, target_skeleton_path: String,
		skeleton: Skeleton3D, keep_vertical: bool = false) -> void:
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
			if keep_vertical:
				_flatten_hips_track(anim, i, skeleton)
			else:
				tracks_to_remove.append(i)
				continue

		# Verify bone exists. A clip retargeted from another rig carries tracks
		# for bones this one has not got — the paladin's Estus animation names
		# mixamorig_Sword_joint and mixamorig_Shield_joint, which the archer
		# skeleton has never heard of, and several `armed/` clips reference
		# mixamorig_Left_arch1 / mixamorig_RightArmour1. Leaving them in place
		# meant AnimationMixer failed to resolve each one EVERY TIME the clip
		# played (25 warnings from a single Estus drink). A track pointing at a
		# bone that does not exist can never animate anything, so it goes.
		if skeleton.find_bone(bone_name) == -1:
			var alt_bone_name: String = bone_name.replace("mixamorig:", "mixamorig_")
			if skeleton.find_bone(alt_bone_name) == -1:
				tracks_to_remove.append(i)
				continue
			bone_name = alt_bone_name

		var new_path: String = target_skeleton_path + ":" + bone_name
		if path_str != new_path:
			anim.track_set_path(i, NodePath(new_path))

	tracks_to_remove.reverse()
	for track_idx in tracks_to_remove:
		anim.remove_track(track_idx)


## Rewrite a Hips position track to vertical-only, anchored so the clip's
## first frame sits exactly at the bone's rest height. Without the anchor the
## character pops down (or up) the instant the clip starts, because Mixamo's
## standing hip height is not this skeleton's.
func _flatten_hips_track(anim: Animation, track: int, skeleton: Skeleton3D) -> void:
	var hips: int = skeleton.find_bone("mixamorig_Hips")
	if hips == -1 or anim.track_get_key_count(track) == 0:
		return
	var rest: Vector3 = skeleton.get_bone_rest(hips).origin
	var anchor: float = (anim.track_get_key_value(track, 0) as Vector3).y
	for k in range(anim.track_get_key_count(track)):
		var v: Vector3 = anim.track_get_key_value(track, k)
		anim.track_set_key_value(track, k,
				Vector3(rest.x, rest.y + (v.y - anchor), rest.z))


func _on_animation_finished(anim_name: StringName) -> void:
	# A finished collapse holds its last frame: the body has to stay down
	# under the revive beacon, not pop back up into idle.
	if is_dead and String(anim_name).ends_with("/Death"):
		_current_anim_player.seek(_current_anim_player.get_animation(anim_name).length, true)
		_current_anim_player.pause()
		return

	# Reset archer bow states when attack animation finishes
	if character_class == CharacterClass.ARCHER \
			and anim_name in [&"archer/Attack", &"archer/Loose"]:
		is_drawing_bow = false
		is_holding_bow = false
		is_attacking = false
		_attack_cooldown = 0.0  # No cooldown - allow immediate next action
		_bow_draw_time = 0.0
		#The recovery ends in the idle pose; blend into its breathing cycle.
		if _archer_anim_player and _archer_anim_player.has_animation(&"archer/Idle"):
			_archer_anim_player.play(&"archer/Idle", .2)
			_current_anim = &"archer/Idle"
		return

	if is_attacking:
		if _buffer_heavy and _attack_input_buffer > 0.0:
			if _start_combo_swing(2, true):
				return
		# Banked step still pending at clip end (click landed past the chain
		# point): chain here instead of dropping the combo.
		if _combo_clicks_buffered > 0 and _attack_input_buffer > 0.0 \
				and combat_mode == CombatMode.ARMED \
				and _combo_step < COMBO_ANIMS.size() - 1:
			_combo_clicks_buffered -= 1
			if _start_combo_swing(_combo_step + 1):
				return
			_combo_clicks_buffered = 0
		is_attacking = false
		disable_attack_hitbox()  # Disable hitbox when attack ends
		# Finisher commits: longer recovery after the third swing.
		_attack_cooldown = COMBO_FINISHER_COOLDOWN if _combo_step >= COMBO_ANIMS.size() - 1 else 0.05
		_combo_step = 0
		_combo_clicks_buffered = 0
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
	# `_current_anim` is only trustworthy while that clip is genuinely the
	# one running. A direct play() elsewhere (parry, bow pose, hit react,
	# class switch) or a finished one-shot leaves the cache stale, and a
	# stale match here silently refuses to restart locomotion — the body
	# then slides around in whatever pose it was left in.
	if _current_anim == anim_name:
		if _current_anim_player.is_playing() \
				and _current_anim_player.current_animation == anim_name:
			return
		# Cache is stale. Re-firing a ONE-SHOT (jump, dodge) would loop it
		# forever, so only the looping clips — locomotion, idle, guard —
		# are restarted from here.
		var current: Animation = _current_anim_player.get_animation(anim_name)
		if current == null or current.loop_mode == Animation.LOOP_NONE:
			return
	if _current_anim_player.has_animation(anim_name):
		# Cross-blend locomotion changes — pose pops read as cheap; a short
		# blend is most of what makes movement look "weighted".
		_current_anim_player.play(anim_name, 0.25)
		_current_anim = anim_name


## Guard = "the block button is down right now", re-derived every physics
## frame rather than remembered from input edges. A held button that never
## reported its release (app pause, focus loss, touch cancel, analog
## trigger snap-back) can no longer strand the shield up, and a guard that
## an action cancelled comes back on its own the moment that action ends
## — the button is still held, and only an edge would ever have restored
## it. The AI companion keeps its own state; human input must not leak in.
## ARM SPREAD. The authored clips hold the paladin's upper arms clamped
## against his ribs — no daylight between elbow and torso, the shield folded
## flat across his chest — which reads as a man hugging himself rather than a
## knight holding a guard. Widening a whole animation set by hand is not on;
## this pushes the upper arms out a few degrees AFTER the clip has posed them,
## so every clip keeps its motion and simply gets room to breathe.
##
## ADDITIVE, deliberately: an absolute pose (the trick Bobba's block uses) is
## fine for one static guard, but applied here it would flatten the swing, the
## roll and the walk into the same T of a stance. This multiplies whatever the
## animation asked for by a fixed offset, so a clip that already lifts the arm
## still lifts it, from further out.
##
## Runs late — from _process, after the AnimationMixer has written the frame —
## because anything applied earlier is simply overwritten by the clip.
func _apply_arm_spread() -> void:
	if character_class != CharacterClass.PALADIN or is_attacking or is_rolling:
		return
	# Cached hard: this runs every rendered frame, and _find_skeleton_in walks
	# the model subtree. Re-resolve only when the body swaps its rig (class
	# change, armed/unarmed toggle), which is what invalidates the handle.
	var skeleton := _spread_skeleton
	if skeleton == null or not is_instance_valid(skeleton) \
			or not skeleton.is_inside_tree():
		skeleton = _find_skeleton_in(_character_model)
		if skeleton == null:
			return
		_spread_skeleton = skeleton
		_spread_left = skeleton.find_bone("mixamorig_LeftArm")
		_spread_right = skeleton.find_bone("mixamorig_RightArm")
	_abduct(skeleton, _spread_left, -ARM_SPREAD_DEGREES)
	_abduct(skeleton, _spread_right, ARM_SPREAD_DEGREES)


## Swing one upper arm away from the body, by `degrees`, on top of the pose the
## clip just wrote.
##
## The axis comes from the BODY, not from the bone. Euler offsets in bone-local
## space are a guess at whatever convention the rig was exported with — tried
## on this skeleton, Z turned out to be flexion (the arm swings forward and up)
## and X pulled the arms in TIGHTER, which is the opposite of the ask. Rotating
## about the character's own forward axis is abduction by definition, on any
## rig, and it stays correct if the model is ever replaced.
func _abduct(skeleton: Skeleton3D, bone: int, degrees: float) -> void:
	if bone < 0:
		return
	var parent: int = skeleton.get_bone_parent(bone)
	# The body's forward (+Z in model space), expressed in the parent bone's
	# frame so the rotation composes with the pose already there.
	var axis := Vector3(0.0, 0.0, 1.0)
	if parent >= 0:
		axis = skeleton.get_bone_global_pose(parent).basis.inverse() * axis
	if axis.length_squared() < 0.000001:
		return
	# Pre-multiplied: the rotation happens in the PARENT's space (about the
	# body axis), not in the bone's own twisted frame.
	var offset := Quaternion(axis.normalized(), deg_to_rad(degrees))
	skeleton.set_bone_pose_rotation(bone, offset * skeleton.get_bone_pose_rotation(bone))


## CROUCH GROUNDING. The retarget strips every clip's hip-position track so
## locomotion cannot bounce the body — which leaves a crouch pose hanging in
## the air: hips pinned at standing height, legs folded up under them.
## Re-adding the authored hip drop looked wrong (the track is in the source
## rig's scale and proportions), so instead the pose itself is measured: after
## the mixer has posed the skeleton, take the lowest foot bone, compare it with
## where that bone sits in the rest pose, and sink the whole model by the
## difference. Feet end up exactly where they stand when idle, on any rig,
## for any crouch clip. Sink only — a clip may never hoist the body.
func _apply_crouch_grounding(delta: float) -> void:
	if _character_model == null:
		return
	# _character_model holds ALL the rigs (two hidden). A hidden rig never
	# animates, its bones sit at rest and measure a drop of exactly zero —
	# so resolve the skeleton from the character that is actually driving.
	var active: Node3D = _archer_character
	if character_class == CharacterClass.PALADIN:
		active = _armed_character if combat_mode == CombatMode.ARMED else _unarmed_character
	if active == null:
		return
	var skeleton := _ground_skeleton
	if skeleton == null or not is_instance_valid(skeleton) \
			or not skeleton.is_inside_tree() \
			or not active.is_ancestor_of(skeleton):
		skeleton = _find_skeleton_in(active)
		if skeleton == null:
			return
		_ground_skeleton = skeleton
		_ground_feet.clear()
		for bone_name in ["mixamorig_LeftToeBase", "mixamorig_RightToeBase",
				"mixamorig_LeftFoot", "mixamorig_RightFoot"]:
			var b := skeleton.find_bone(bone_name)
			if b != -1:
				_ground_feet.append(b)
		_model_base_y = _character_model.position.y - _crouch_sink

	var want := 0.0
	if is_crouching and is_on_floor() and not _ground_feet.is_empty():
		# Model space, so the measurement is blind to the sink already applied.
		# Compare the LOWEST posed point against the LOWEST rest point — the
		# supporting foot against where soles sit when standing. A per-bone
		# difference would let the tucked-under back foot of a kneel (toes up
		# behind the body) drive the sink and bury the front foot.
		var to_model := _character_model.global_transform.affine_inverse() \
				* skeleton.global_transform
		var posed_low := INF
		var rest_low := INF
		for b in _ground_feet:
			posed_low = minf(posed_low, (to_model * skeleton.get_bone_global_pose(b).origin).y)
			rest_low = minf(rest_low, (to_model * skeleton.get_bone_global_rest(b).origin).y)
		if posed_low != INF:
			want = clampf(rest_low - posed_low, -1.0, 0.0)
	_crouch_sink = lerpf(_crouch_sink, want, minf(12.0 * delta, 1.0))
	if absf(want - _crouch_sink) < 0.001:
		_crouch_sink = want
	_character_model.position.y = _model_base_y + _crouch_sink


func _find_skeleton_in(node: Node) -> Skeleton3D:
	if node == null:
		return null
	if node is Skeleton3D:
		return node as Skeleton3D
	for child in node.get_children():
		var found := _find_skeleton_in(child)
		if found != null:
			return found
	return null


func _update_block_state() -> void:
	var held := _ai_block if ai_driven else Input.is_action_pressed(&"block")
	if held and is_attacking and character_class == CharacterClass.PALADIN and _can_cancel_attack():
		_cancel_attack_for("guard")
	# A blocked impact keeps the shield raised through its short recoil.
	if is_parrying or is_dead or is_reviving or is_attacking or is_rolling \
			or (_is_stunned and not _guard_recoil) or is_drinking or is_casting:
		is_blocking = false
		return
	# An archer cannot guard with the hand that is on the string: aiming or
	# drawing drops the guard outright. What is left of it is the pad's
	# right trigger, which is a block and nothing else for him — the mouse's
	# right button and the touch guard are his aim (see _aim_input_held),
	# and pressing them therefore raises no shield. The companion's bow AI
	# is untouched and still uses _ai_block.
	if character_class == CharacterClass.ARCHER and not ai_driven \
			and (_aim_input_held() or is_drawing_bow or is_holding_bow):
		is_blocking = false
		return
	# The companion's "button" is _ai_block, written by its role each frame —
	# same re-derived-every-frame rule as the human's, so a guard raised for a
	# swing that never came cannot strand the shield up.
	is_blocking = held


## Clips that _update_animation itself owns — if one of these is running,
## no action clip is in charge of the body any more.
const FREE_BODY_ANIMS: Array[String] = ["Idle", "Walk", "Run", "Sprint",
		"StrafeLeft", "StrafeRight", "Jump", "Block", "BlockWalk", "BlockRun",
		"BlockSprint", "BlockStrafeLeft", "BlockStrafeRight"]

## How long a contradictory state must hold before it is cleared. Long
## enough to ride out a cross-blend frame, short enough to be invisible.
const ANIM_GATE_STALE_TIME: float = 0.15

var _anim_gate_stale: float = 0.0


func _is_free_body_anim(clip: String) -> bool:
	var leaf: String = clip.substr(clip.rfind("/") + 1) if "/" in clip else clip
	return leaf in FREE_BODY_ANIMS


## Drops action state that no clip backs any more (see the call site).
func _clear_stale_anim_gates() -> void:
	if not (is_attacking or is_sheathing or is_transitioning or is_casting):
		_anim_gate_stale = 0.0
		return

	var body_free: bool = true
	if _current_anim_player != null:
		var clip := String(_current_anim_player.current_animation)
		if clip != "" and not _is_free_body_anim(clip):
			# An action clip still owns the body. A PAUSED player normally
			# means the clip is over and forgotten — except for the
			# archer's aim hold, which parks its clip on purpose.
			body_free = not _current_anim_player.is_playing() \
					and not (is_drawing_bow or is_holding_bow)
	if not body_free:
		_anim_gate_stale = 0.0
		return

	_anim_gate_stale += get_physics_process_delta_time()
	if _anim_gate_stale < ANIM_GATE_STALE_TIME:
		return

	var held := "attack=%s sheath=%s transition=%s cast=%s" % [
			str(is_attacking), str(is_sheathing), str(is_transitioning), str(is_casting)]
	if is_attacking:
		is_attacking = false
		disable_attack_hitbox()
		_combo_step = 0
		_combo_clicks_buffered = 0
	if is_casting:
		is_casting = false
		_stop_spell_effects()
	is_sheathing = false
	is_transitioning = false
	_anim_gate_stale = 0.0
	# Forget the cached clip name too, so the locomotion request right
	# below this always reaches the AnimationPlayer.
	_current_anim = &""
	print("Player: cleared stale animation state (%s) while '%s' was playing" % [
			held, String(_current_anim_player.current_animation) if _current_anim_player else "nil"])


## Picks the guard-up clip matching how the character is moving. Falls
## back down the list (strafe -> run -> walk -> planted Block) so a rig
## missing a composed twin still gets a sensible guard.
func _block_stance_anim(prefix: String, input_dir: Vector2) -> StringName:
	var candidates: Array[String] = []
	if input_dir.length() > 0.1:
		if abs(input_dir.x) > 0.5 and abs(input_dir.y) < 0.3:
			var side: String = "Left" if input_dir.x < 0 else "Right"
			if is_running:
				candidates.append("BlockRunStrafe" + side)
			candidates.append("BlockStrafe" + side)
		elif input_dir.y > 0.5 and abs(input_dir.x) < 0.5:
			# Shield up while backing off — the bread and butter of a
			# souls fight, and the one direction that used to moonwalk.
			if is_running:
				candidates.append("BlockRunBack")
			candidates.append("BlockWalkBack")
		if is_running:
			candidates.append("BlockRun")
			candidates.append("BlockSprint")
		candidates.append("BlockWalk")
	# Standing guard prefers the composed HOLD — the raw Block clip is a
	# raise-block-lower reaction on two of the three rigs and pumps when
	# looped.
	candidates.append("BlockHold")
	candidates.append("Block")
	for clip in candidates:
		var anim := StringName(prefix + "/" + clip)
		if _current_anim_player.has_animation(anim):
			return anim
	return &""


## First clip in `names` the current library actually has, as a full
## "<prefix>/<clip>" name. Empty entries are skipped, so a caller can put a
## conditional candidate in the list without branching. Returns &"" if the
## library has none of them.
func _first_anim(prefix: String, names: Array) -> StringName:
	for clip in names:
		if String(clip).is_empty():
			continue
		var anim := StringName(prefix + "/" + String(clip))
		if _current_anim_player.has_animation(anim):
			return anim
	return &""


## Aim-walk clip matching how a drawing/holding archer is moving, or &""
## when the rig has no aim-locomotion at all (the Paladin) — the caller
## then falls through to ordinary locomotion.
func _aim_locomotion_anim(prefix: String, input_dir: Vector2) -> StringName:
	var candidates: Array = []
	if abs(input_dir.x) > 0.5 and abs(input_dir.y) < 0.3:
		candidates.append("AimStrafeLeft" if input_dir.x < 0 else "AimStrafeRight")
	elif input_dir.y > 0.5:
		candidates.append("AimWalkBack")
	candidates.append("AimWalk")
	return _first_anim(prefix, candidates)


func _get_current_mode_prefix() -> String:
	if character_class == CharacterClass.ARCHER:
		return "archer"
	return "armed" if combat_mode == CombatMode.ARMED else "unarmed"


func _update_animation(input_dir: Vector2) -> void:
	if _current_anim_player == null:
		return

	# Safety net: is_attacking must always correspond to the archer\'s
	# Attack clip actually playing. If anything replaced the clip (an
	# interruption, a mid-burst state change) the flag would otherwise
	# stick and freeze locomotion forever.
	if character_class == CharacterClass.ARCHER and is_attacking \
			and _archer_anim_player \
			and _archer_anim_player.current_animation not in ["archer/Attack", "archer/Loose"]:
		is_attacking = false

	# Watchdog BEFORE the gate: is_attacking / is_sheathing /
	# is_transitioning / is_casting are each cleared by the
	# animation_finished callback of the clip that set them. Whenever that
	# clip gets REPLACED instead of finishing (hit react, dodge, class
	# switch, another action, a mode toggle) the callback never arrives
	# with that name and the flag sticks TRUE for the rest of the life —
	# which freezes every locomotion update below it. Rather than patch
	# each path, detect the contradiction: a gate is held while the body
	# is visibly free. (is_rolling / is_parrying / is_drinking are timer
	# driven and clear themselves, so they are not watched.)
	_clear_stale_anim_gates()

	# The unarmed fight-stance -> idle transition is pure cosmetics and
	# runs for over two seconds. It must never hold the legs hostage while
	# the player is asking to move (same principle as the paladin's
	# attack-recovery cancel).
	if is_transitioning and input_dir.length() > 0.1:
		is_transitioning = false

	if is_attacking or is_sheathing or is_transitioning or is_casting or is_rolling or is_parrying or is_drinking:
		return
	# Aiming archer: standing still holds the drawn pose (restoring it if
	# a walk cycle had taken over). On the move the pack's authored
	# aim-locomotion keeps the bow up AND strides; without it the plain
	# walk cycle threw the draw away every time the archer took a step.
	if is_drawing_bow or is_holding_bow:
		if input_dir.length() < 0.15:
			_restore_aim_pose()
			return
		var aim_anim: StringName = _aim_locomotion_anim(
				_get_current_mode_prefix(), input_dir)
		if aim_anim != &"":
			_play_anim(aim_anim)
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

	# Blocking (both modes - shield in armed, center block in unarmed).
	# Guard up does NOT stop the feet: while there is movement input the
	# composed BlockWalk/BlockRun/BlockStrafe* clips keep the stride and
	# only the upper body holds the guard.
	elif is_blocking:
		desired_anim = _block_stance_anim(prefix, input_dir)

	# Crouching. The clip is a stand-to-crouch transition (LOOP_NONE):
	# _play_anim fires it once, refuses to re-fire a finished one-shot,
	# and the body parks on the last frame — the crouched pose — until
	# Ctrl comes up. Movement while crouched keeps the braced pose; the
	# half-speed shuffle reads fine and beats swapping to a full stride.
	elif is_crouching:
		desired_anim = _crouch_locomotion_anim(prefix, input_dir)

	# Strafe. Run-strafes first when the rig has them, so circling an enemy
	# at speed does not play a walk cycle at a run.
	elif abs(input_dir.x) > 0.5 and abs(input_dir.y) < 0.3:
		var side: String = "Left" if input_dir.x < 0 else "Right"
		desired_anim = _first_anim(prefix, [
				("RunStrafe" + side) if is_running else "",
				"Strafe" + side,
				"StrafeLeft",
				"Walk"])

	# Retreating. The character always faces camera-forward, so walking
	# backward on a forward stride moonwalks. Diagonals keep the forward
	# cycle — only a committed backstep swaps clips.
	elif input_dir.y > 0.5 and abs(input_dir.x) < 0.5:
		desired_anim = _first_anim(prefix, [
				"RunBack" if is_running else "",
				"WalkBack",
				"Run" if is_running else "",
				"Walk"])

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
		_match_stride(desired_anim)


## Crouched, moving or still. Standing still parks on the stand-to-crouch
## pose (its last frame IS the held crouch); moving picks the crouch-walk
## cycle for the direction being asked for, in the same camera-relative
## convention the strafes and the backstep use. Falls back to the stance —
## and then to Idle — for any model whose set is incomplete.
func _crouch_locomotion_anim(prefix: String, input_dir: Vector2) -> StringName:
	if input_dir.length() <= 0.1:
		return _first_anim(prefix, ["Crouch", "Idle"])
	if absf(input_dir.x) > absf(input_dir.y):
		return _first_anim(prefix, [
				"CrouchWalkL" if input_dir.x < 0.0 else "CrouchWalkR",
				"CrouchWalkF", "Crouch", "Idle"])
	return _first_anim(prefix, [
			"CrouchWalkB" if input_dir.y > 0.0 else "CrouchWalkF",
			"CrouchWalkF", "Crouch", "Idle"])


func _match_stride(anim: StringName) -> void:
	var clip := String(anim).get_slice("/", 1)
	var stride := clip.contains("Walk") or clip.contains("Run") \
			or clip.contains("Strafe") or clip == "Sprint"
	if not stride:
		_current_anim_player.speed_scale = 1.0
		return
	var speed := Vector2(velocity.x, velocity.z).length()
	var authored := RUN_SPEED if clip.contains("Run") else WALK_SPEED
	if clip.begins_with("Crouch"):
		authored = WALK_SPEED * CROUCH_SPEED_MULT
	_current_anim_player.speed_scale = clampf(speed / authored, 0.35, 1.25)


func _toggle_combat_mode() -> void:
	if is_sheathing:
		return
	_spread_skeleton = null   # armed and unarmed are different rigs
	_ground_skeleton = null

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
	if is_archer():
		_cancel_bow_draw()
		_bow_follow_time = 0.0
		_bow_loose_lock = 0.0
		is_attacking = false
	_spread_skeleton = null   # different rig — the cached arm bones are stale
	_ground_skeleton = null

	# Hide all characters first
	if _unarmed_character:
		_unarmed_character.visible = false
	if _armed_character:
		_armed_character.visible = false
	if _archer_character:
		_archer_character.visible = false

	character_class = new_class
	_stamina.cost_multiplier = ARCHER_STAMINA_COST_MULT if is_archer() else 1.0

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


## The world point the crosshair is sitting on: the first thing an arrow could
## hit along the ray out of the centre of the screen.
##
#An empty ray uses a distant point so shoulder-camera shots still converge.
func crosshair_target() -> Dictionary:
	var miss := {"hit": false, "point": Vector3.ZERO, "from": Vector3.ZERO,
			"dir": Vector3.FORWARD, "collider": null}
	if _camera == null or not is_inside_tree():
		return miss
	var centre: Vector2 = get_viewport().get_visible_rect().size * 0.5
	var ray_from: Vector3 = _camera.project_ray_origin(centre)
	var ray_dir: Vector3 = _camera.project_ray_normal(centre)
	miss["from"] = ray_from
	miss["dir"] = ray_dir
	miss["point"] = ray_from + ray_dir * AIM_RAY_LENGTH
	var space := get_world_3d().direct_space_state
	if space == null:
		return miss
	var query := PhysicsRayQueryParameters3D.create(ray_from,
			ray_from + ray_dir * AIM_RAY_LENGTH, AIM_RAY_MASK, [get_rid()])
	var hit: Dictionary = space.intersect_ray(query)
	if hit.is_empty():
		return miss
	return {"hit": true, "point": hit.position, "from": ray_from, "dir": ray_dir,
			"collider": hit.get("collider")}


#Aim from the bow toward the sight, without adding elevation. Gravity acts
#after release; distant targets require the player to aim above them.
func _bow_aim_direction(from: Vector3) -> Vector3:
	var aim: Dictionary = crosshair_target()
	var sight: Vector3 = aim["dir"]
	var to_target: Vector3 = aim["point"] - from
	#A camera obstruction behind the bow must not turn the arrow backward.
	if to_target.dot(sight) <= 0.0:
		return sight
	return to_target.normalized()


#The AI supplies its own ballistic solution from chest height.
func _shoot_arrow(aim_override: Vector3 = Vector3.ZERO) -> void:
	Sfx.play3d("bow_release", global_position + Vector3(0, 1.4, 0), -4.0)
	# Create arrow instance
	var arrow = ArrowScene.instantiate()
	arrow.shooter = self
	arrow.is_local = true
	# A mid-air loose is weaker: half-bright flame, reduced damage.
	arrow.airborne_shot = not is_on_floor()
	# A MOVING loose has no planted stance behind it: half the launch force
	# (≈ quarter of the ballistic range) and damage cut proportionally.
	if Vector2(velocity.x, velocity.z).length() > 1.0:
		arrow.shot_power = 0.5
	if _bow_aimed:
		arrow.shot_power *= BOW_AIM_POWER

	var spawn_pos := global_position + Vector3(0, 1.5, 0)
	if aim_override.length_squared() <= 0.001 and _bow_draw_visual:
		spawn_pos = _bow_draw_visual.release_position()

	#Sample the sight before release changes the camera zoom.
	var aim_direction: Vector3
	if aim_override.length_squared() > 0.001:
		aim_direction = aim_override.normalized()
	else:
		aim_direction = _bow_aim_direction(spawn_pos)

	# Broadcast arrow spawn to network
	if has_node("/root/NetworkManager"):
		var network_manager = get_node("/root/NetworkManager")
		arrow.shooter_id = network_manager.my_player_id
		arrow.arrow_id = network_manager.send_arrow_spawn(spawn_pos,
				aim_direction * arrow.shot_power, network_manager.my_player_id)

	# Add arrow to scene
	get_tree().current_scene.add_child(arrow)
	#The shooter's capsule must not deflect the arrow on release.
	arrow.add_collision_exception_with(self)
	arrow.global_position = spawn_pos
	arrow.launch(aim_direction)


## Is the archer holding AIM? On a pad that is the LEFT TRIGGER held (the
## camera goes over the shoulder for as long as it is down and comes back when
## it is released); on a mouse it is the right button. A phone has neither, so
## there the guard button doubles as the aim — an archer's shield hand is on
## the string anyway, which is also why he cannot block while drawing (see
## _update_block_state).
func _aim_input_held() -> bool:
	if Input.is_action_pressed(&"aim"):
		return true
	return CloudInput.touchscreen_available() and Input.is_action_pressed(&"block")


## Seconds of draw before the arrow is ready. A sighted draw is the slower
## one — see BOW_AIM_DRAW_MULT.
func _bow_draw_required() -> float:
	return BOW_DRAW_TIME_REQUIRED * (BOW_AIM_DRAW_MULT if _bow_aimed else 1.0)


## `aimed` picks the shot: true for the sighted one (1.5x the draw, camera
## over the shoulder), false for the quick one. `hold_release` says the draw
## belongs to a button that is still down and will loose it when it comes up —
## right mouse or the controller's left trigger.
func _start_bow_draw(aimed: bool = false, hold_release: bool = false) -> void:
	if is_drawing_bow or is_holding_bow or is_attacking or _attack_cooldown > 0 \
			or is_reviving or is_dead:
		return
	# No archery in the air: jumping is flight, the bow stays down.
	if not is_on_floor():
		return

	Sfx.play3d("bow_draw", global_position + Vector3.UP, -8.0)
	_bow_aimed = aimed
	_bow_follow_time = 0.0
	_bow_hold_release = hold_release
	is_drawing_bow = true
	is_holding_bow = false
	_bow_draw_time = 0.0
	_lost_release_grace = 0.0

	# Show progress bar
	if _bow_progress_bar:
		_bow_progress_bar.value = 0.0
		_bow_progress_bar.visible = true
		var ready_label = _bow_progress_bar.get_parent().get_node_or_null("ReadyLabel")
		if ready_label:
			ready_label.text = ""

	# Play draw animation from the beginning, sped up so the visual draw
	# roughly tracks the gameplay draw — which is longer when aiming, so the
	# clip is slowed by the same ratio and the two still finish together.
	if _archer_anim_player and _archer_anim_player.has_animation(&"archer/Attack"):
		var anim_speed: float = BOW_DRAW_ANIM_SPEED \
				* BOW_DRAW_TIME_REQUIRED / _bow_draw_required()
		_archer_anim_player.play(&"archer/Attack", 0.1, anim_speed)
		_current_anim = &"archer/Attack"


## Cancel an in-progress draw/hold (early release, jump, interruption).
func _cancel_bow_draw() -> void:
	is_drawing_bow = false
	is_holding_bow = false
	_bow_aimed = false
	_bow_hold_release = false
	_bow_draw_time = 0.0
	if _bow_progress_bar:
		_bow_progress_bar.visible = false
	if _archer_anim_player and _archer_anim_player.has_animation(&"archer/Idle"):
		_archer_anim_player.play(&"archer/Idle", .3)
		_current_anim = &"archer/Idle"


## A stationary aiming archer holds the drawn pose. If locomotion played
## over it (aim-walking), stepping still brings the pose right back.
func _restore_aim_pose() -> void:
	if _archer_anim_player == null \
			or not _archer_anim_player.has_animation(&"archer/Attack"):
		return
	if _archer_anim_player.current_animation != "archer/Attack":
		_archer_anim_player.play(&"archer/Attack")
		_current_anim = &"archer/Attack"
	if is_holding_bow:
		_archer_anim_player.seek(BOW_DRAW_POSE_TIME, true)
		_archer_anim_player.pause()
	else:
		var frac: float = clampf(_bow_draw_time / _bow_draw_required(), 0.0, 1.0)
		_archer_anim_player.seek(frac * BOW_DRAW_POSE_TIME, true)


func _update_bow_draw(delta: float) -> void:
	# Leaving the ground cancels any draw or hold — no airborne archery.
	if (is_drawing_bow or is_holding_bow) and not is_on_floor():
		_cancel_bow_draw()
		return
	# LOST-RELEASE HEALING (the mobile killer): a finger sliding off the
	# touch button (or a cancelled touch) resets the held action without
	# ever delivering the release EVENT — the draw would stay stuck
	# forever and every following press would be refused. If the action
	# has been up for a grace period while we still think the bow is
	# drawn, perform the release that never arrived. The aim input is an
	# action on every path it can arrive by (right mouse, pad trigger,
	# touch guard), so its state is authoritative.
	#
	# Only a draw that WAITS for a release needs it. A shot the progress bar
	# looses by itself has no release at all, so the same healing there
	# would cancel every tap that came up inside the grace window.
	if _bow_hold_release and (is_drawing_bow or is_holding_bow) and not ai_driven:
		if not _aim_input_held():
			_lost_release_grace += delta
			if _lost_release_grace > 0.25:
				_lost_release_grace = 0.0
				print("Player: lost touch-release healed — releasing bow")
				_release_bow()
				return
		else:
			_lost_release_grace = 0.0
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
	var progress: float = clampf(_bow_draw_time / _bow_draw_required(), 0.0, 1.0)
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
	if _bow_draw_time >= _bow_draw_required():
		is_drawing_bow = false
		is_holding_bow = true
		# Fired from a SHOOT button: there is nothing to hold. The press was
		# the whole input, so the string goes the moment the bar fills —
		# whether this was the quick shot or the sighted one.
		if not _bow_hold_release:
			_release_bow()
			return
		# Freeze on the drawn pose — but only if the aim clip is what is
		# actually playing (aim-walking legs must never be paused).
		if _archer_anim_player \
				and _archer_anim_player.current_animation == "archer/Attack":
			_archer_anim_player.seek(BOW_DRAW_POSE_TIME, true)
			_archer_anim_player.pause()


func _release_bow() -> void:
	# Loose the arrow (aim button released, or the quick shot's timer).
	if not is_drawing_bow and not is_holding_bow:
		return
	# A shot the bar owns cannot be cancelled by letting go of the button
	# that started it, or a fast tap would fire nothing.
	if is_drawing_bow and not _bow_hold_release:
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

	# Released early, before the string was back: cancel, no arrow.
	if is_drawing_bow and not is_holding_bow:
		_cancel_bow_draw()
		return

	# Arrow is ready - shoot it
	is_holding_bow = false
	_bow_draw_time = 0.0

	# Shoot the arrow (aimed at the crosshair — see _bow_aim_direction),
	# then drop back to the quick stance for the next press.
	_shoot_arrow()
	if _bow_aimed and not ai_driven:
		_bow_follow_time = BOW_CAMERA_HOLD + BOW_CAMERA_RETURN
	_bow_aimed = false
	_bow_hold_release = false

	#The recovery starts in the same held pose, then lowers both arms.
	if _archer_anim_player and _archer_anim_player.has_animation(&"archer/Loose"):
		is_attacking = true
		_bow_loose_lock = BOW_LOOSE_LOCK
		_archer_anim_player.play(&"archer/Loose", .1)
		_current_anim = &"archer/Loose"


func _do_attack(heavy: bool = false) -> void:
	if is_dead or is_reviving or is_casting or is_sheathing:
		return
	_dodge_input_buffer = 0.0
	_buffer_heavy = heavy
	if is_rolling or is_parrying or is_drinking or _is_stunned:
		_attack_input_buffer = ATTACK_BUFFER_TIME
		return
	# Jumping is FLIGHT, not offense: an airborne paladin cannot swing at
	# all — leaping away halves incoming damage (AERIAL_DAMAGE_MULT) but
	# buys zero attack. The archer may still loose arrows mid-air.
	if character_class == CharacterClass.PALADIN and not is_on_floor():
		return

	#One pending press; holding or mashing never queues a whole combo.
	if is_attacking:
		_attack_input_buffer = ATTACK_BUFFER_TIME
		_combo_clicks_buffered = 1 if _combo_step < 2 else 0
		return

	if _attack_cooldown > 0:
		# Tap during cooldown — buffer instead of eating it.
		_attack_input_buffer = ATTACK_BUFFER_TIME
		return

	if character_class == CharacterClass.PALADIN and combat_mode == CombatMode.ARMED:
		_combo_clicks_buffered = 0
		_start_combo_swing(2 if heavy else 0, heavy)
		return

	# Legacy non-combo paths (unarmed boxing, archer melee fallback).
	if character_class == CharacterClass.PALADIN and _stamina != null:
		if not _stamina.try_spend(SWORD_STAMINA_COST):
			return

	_current_attack = null
	is_attacking = true
	enable_attack_hitbox()  # Enable hitbox when attack starts

	if combat_mode == CombatMode.ARMED:
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


## Kick off combo step `step` (0-based). Pays stamina, arms the hitbox for a
## fresh swing (each chain step may land its own hit) and starts the clip at
## combo speed. Returns false when the step can't start (no clip / winded).
func _start_combo_swing(step: int, heavy: bool = false) -> bool:
	var attack_anim: StringName = &"armed/HeavyAttack" if heavy else COMBO_ANIMS[step]
	if _current_anim_player == null or not _current_anim_player.has_animation(attack_anim):
		return false
	var cost: float = 32.0 if heavy else (SWORD_STAMINA_COST if step == 0 else COMBO_CHAIN_STAMINA_COST)
	if _stamina != null and not _stamina.try_spend(cost):
		return false

	_combo_step = step
	_current_attack = _get_heavy_attack() if heavy else _get_combo_attack(step)
	is_attacking = true
	enable_attack_hitbox()  # resets _has_hit_this_attack — each swing can hit
	_current_anim_player.speed_scale = 1.0
	var clip := _current_anim_player.get_animation(attack_anim)
	_current_anim_player.play(attack_anim, 0.08,
			clip.length / COMBO_DURATIONS[3 if heavy else step])
	_attack_input_buffer = 0.0
	_buffer_heavy = false
	_combo_clicks_buffered = 0
	is_blocking = false
	_current_anim = attack_anim

	# Lunge direction: locked target when locked, else straight ahead of the
	# camera. The character always faces camera-forward (mouse-controlled),
	# so the swing always goes where the player is looking — never backward.
	if _lock_target != null and is_instance_valid(_lock_target):
		var to_target: Vector3 = _lock_target.global_position - global_position
		to_target.y = 0.0
		_attack_lunge_dir = to_target.normalized() if to_target.length() > 0.05 else Vector3.ZERO
	else:
		var move := _ai_move_vec if ai_driven else Input.get_vector(
				&"move_left", &"move_right", &"move_forward", &"move_back", 0.15)
		_attack_lunge_dir = Vector3(move.x, 0, move.y).rotated(Vector3.UP, _camera_pivot.rotation.y).normalized() \
				if move.length() > 0.25 else _character_model.global_basis.z.normalized()
		_attack_lunge_dir = _assist_swing_direction(_attack_lunge_dir)

	if _sword_trail != null:
		_sword_trail.color = COMBO_TRAIL_COLOR_FINISHER if step == COMBO_ANIMS.size() - 1 else COMBO_TRAIL_COLOR
	return true


## Per-combo-step sword AttackData, lazily built. Damage escalates through
## the chain; the finisher hits hardest and shoves furthest.
var _combo_attacks: Array[Resource] = []

func _get_combo_attack(step: int) -> Resource:
	if _combo_attacks.is_empty():
		for i in range(COMBO_ANIMS.size()):
			var a = AttackDataClass.new()
			a.attack_name = "KnightSwordCombo%d" % (i + 1)
			a.damage = KNIGHT_SWORD_DAMAGE * COMBO_DAMAGE_MULT[i]
			a.poise_damage = COMBO_POISE_DAMAGE[i]
			a.stamina_cost = SWORD_STAMINA_COST if i == 0 else COMBO_CHAIN_STAMINA_COST
			a.knockback_magnitude = COMBO_KNOCKBACK[i]
			a.is_fully_blockable = true
			a.hit_window_start = COMBO_WINDOWS[i].x
			a.hit_window_end = COMBO_WINDOWS[i].y
			a.recovery_start = COMBO_RECOVERY[i]
			_combo_attacks.append(a)
	return _combo_attacks[step]


func _get_heavy_attack() -> Resource:
	if _heavy_attack == null:
		_heavy_attack = _get_combo_attack(2).duplicate()
		_heavy_attack.attack_name = "KnightHeavy"
		_heavy_attack.damage = KNIGHT_SWORD_DAMAGE * 1.7
		_heavy_attack.poise_damage = 85.0
		_heavy_attack.stamina_cost = 32.0
		_heavy_attack.knockback_magnitude = 4.0
		_heavy_attack.recovery_start = SwordMoves.RECOVERY[3]
	return _heavy_attack


## A landed hit (blocked or clean) breaks the paladin's channelled rite
## and stamps the battle clock the casting rule checks.
func _interrupt_paladin_spell() -> void:
	_last_damage_ms = Time.get_ticks_msec()
	if is_casting and character_class == CharacterClass.PALADIN:
		is_casting = false
		_stop_spell_effects()
		_show_hit_label("SPELL BROKEN")
		print("Player: paladin spell interrupted by hit")


## Distance to the closest live enemy — the "direct combat" test for the
## paladin's casting rule.
func _nearest_combat_threat_dist() -> float:
	var best: float = INF
	for b in get_tree().get_nodes_in_group("bobba"):
		if is_instance_valid(b) and ("health" in b and float(b.health) > 0.0):
			best = minf(best, global_position.distance_to(b.global_position))
	for sk in get_tree().get_nodes_in_group("skeletons"):
		if sk is Node3D and is_instance_valid(sk) \
				and not ("is_dead_skeleton" in sk and sk.is_dead_skeleton):
			best = minf(best, global_position.distance_to((sk as Node3D).global_position))
	return best


func _do_spell_cast() -> void:
	# Allow spell cast in armed mode (Paladin) or for Archer class
	if character_class == CharacterClass.PALADIN and combat_mode != CombatMode.ARMED:
		return
	# PALADIN battle-focus rule: the lightning rite demands calm. It cannot
	# be STARTED in direct combat — a live enemy within melee reach, or a
	# hit taken moments ago — and a landed hit shatters it (see take_hit).
	if character_class == CharacterClass.PALADIN:
		if Time.get_ticks_msec() - _last_damage_ms < 2500:
			_show_hit_label("TOO HURT TO FOCUS")
			return
		if _nearest_combat_threat_dist() < 8.0:
			_show_hit_label("IN COMBAT!")
			return
	if is_casting or is_attacking or _attack_cooldown > 0 or is_parrying or is_drinking \
			or is_reviving or is_dead:
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


## Combat - Take damage and knockback from enemy attacks.
## `blocked` is provided by the caller for non-player attackers (e.g. Bobba
## tracks the player's block state when it hits). `is_fully_blockable` is
## set by the attacker when the hit is a clean weapon strike a shield is
## made for (Knight sword swings, archer arrows) — those chip for less
## through a block than blunt force (Bobba punches, DoT auras). No block
## ever negates a hit entirely; only a timed parry cancels damage.
##
## The HP label is emitted automatically by the HealthComponent.damaged
## signal (see _on_damage_taken) — take_hit only applies the flash,
## knockback and stun.
## Returns true when the hit actually connected (damage/knockback applied,
## even if chip-reduced by a block) and false when the defender negated it
## outright (roll i-frames, spawn immunity, timed parry) — so the attacker
## can confirm its hit honestly instead of assuming contact always counts.
func _guard_faces(attacker: Node3D) -> bool:
	if not is_instance_valid(attacker) or not _character_model:
		return false
	var dir := attacker.global_position - global_position
	dir.y = 0.0
	var facing := _character_model.global_basis.z
	facing.y = 0.0
	return facing.normalized().dot(dir.normalized()) >= GUARD_CONE_DOT


func take_hit(damage: float, knockback: Vector3, blocked: bool,
		attacker: Node3D = null, is_fully_blockable: bool = false) -> bool:
	# Dodge-roll i-frames: a hit that lands during the roll's invulnerable
	# window passes clean through — no damage, no knockback. This is the
	# souls payoff for timing a roll into the swing. Startup and recovery
	# of the roll are still vulnerable (the punish window).
	if is_rolling:
		var roll_elapsed: float = ROLL_DURATION - _roll_timer
		if roll_elapsed >= ROLL_IFRAME_START and roll_elapsed <= ROLL_IFRAME_END:
			print("Player: Hit dodged - roll i-frames (t=%.2f)" % roll_elapsed)
			return false

	if is_dead:
		return false

	# Check spawn immunity
	if is_spawn_immune():
		print("Player: Hit ignored - spawn immunity active (%.1fs remaining)" % _spawn_immunity_timer)
		return false

	# Parry deflect: the enemy's hit visually connected with us while the
	# shield flick was in its active frames, and the attacker is something
	# that can be parried (exposes on_parried). The hit is negated and the
	# attacker staggers into a riposte window. Outside the active frames
	# (the parry's recovery) this falls through to full, unblocked damage.
	if is_parrying and attacker != null and is_instance_valid(attacker) \
			and attacker.has_method("on_parried") and _guard_faces(attacker) \
			and _parry_timer >= PARRY_WINDOW_START and _parry_timer <= PARRY_WINDOW_END:
		_flash_hit(Color(1.0, 0.85, 0.2))  # gold — distinct from block blue
		_show_hit_label("PARRY!")
		Sfx.play3d("parry_ring", global_position + Vector3(0, 1.2, 0), -2.0)
		attacker.on_parried(self)
		print("Player: PARRY! deflected %.1f damage from %s (t=%.2f)" % [
			damage, attacker.name, _parry_timer])
		return false

	# CALL IT OUT. A hit that lands is the party's best intelligence in a
	# field where nothing is visible past eight metres: it posts a BEARING on
	# the attacker for every co-op AI (SquadBrain), which is what sends the
	# archer's next fire arrow onto the thing punching us out of the dark.
	# Deliberately after the negations above — a hit that never landed
	# (i-frames, spawn immunity, a parry) tells us nothing.
	SquadBrain.note_attack(self, attacker)

	# Airborne mitigation: jumping over a swing halves the damage. The
	# player "sells" the dodge visually by being off the floor when the
	# hit lands, so the system rewards timing reads, not stand-and-trade.
	# Stacks with block (so a jumping block is nearly full mitigation).
	var airborne_mult: float = 1.0
	if not is_on_floor():
		airborne_mult = AERIAL_DAMAGE_MULT

	var guard_broken := false
	blocked = is_blocking and _guard_faces(attacker)
	if blocked and _stamina:
		guard_broken = not _stamina.absorb(maxf(12.0, damage * 0.8))
		if guard_broken:
			blocked = false
			is_blocking = false
	var actual_damage := damage * airborne_mult
	_guard_recoil = blocked
	if blocked:
		# Blocked hit - blue flash, knockback carried through from the
		# attacker's side with only the standard resistance applied. The
		# shield eats damage, not momentum — a Bobba punch on the shield
		# still shoves the Paladin back visibly (rule: blocked or not,
		# an impact has to LOOK like an impact).
		_flash_hit(Color(0.2, 0.4, 1.0))
		_knockback_velocity = knockback * PLAYER_KNOCKBACK_RESISTANCE * 0.35
		_is_stunned = true
		_stun_timer = 0.13
		# A block never erases a hit — chip damage always gets through;
		# only a timed parry cancels a hit outright. Clean weapon strikes
		# (sword, arrow) are what shields are best at; heavy blunt force
		# (Bobba's fists) hurts through the guard. Compounds with the
		# aerial mitigation.
		var chip_mult: float = BLOCK_CHIP_MULT_WEAPON if is_fully_blockable else BLOCK_CHIP_MULT_BLUNT
		actual_damage = damage * chip_mult * airborne_mult
		Sfx.play3d("block_chip", global_position + Vector3(0, 1.2, 0), -4.0)
		_interrupt_paladin_spell()
	else:
		# Unblocked hit - red flash, full knockback, 1/3s stun, attack cancel
		_flash_hit(Color(1.0, 0.2, 0.2))
		_knockback_velocity = knockback * PLAYER_KNOCKBACK_RESISTANCE
		Sfx.play3d("hit_flesh", global_position + Vector3(0, 1.2, 0), -3.0)
		_interrupt_paladin_spell()
		_is_stunned = true
		_stun_timer = GUARD_BREAK_TIME if guard_broken else STUN_DURATION
		if is_drawing_bow or is_holding_bow:
			_cancel_bow_draw()
		is_attacking = false  # Cancel attack if hit
		is_rolling = false
		disable_attack_hitbox()
		_attack_input_buffer = 0.0
		_dodge_input_buffer = 0.0
		if guard_broken:
			_show_hit_label("GUARD BROKEN")
		_combo_step = 0  # a clean hit breaks the combo chain
		_combo_clicks_buffered = 0
		# A clean hit knocks the player out of a parry attempt (recovery
		# punish) and ruins an estus drink — the charge was already spent
		# when the drink started, so the heal is simply lost.
		is_parrying = false
		if is_drinking:
			is_drinking = false
			_show_hit_label("Estus lost!")
			print("Player: estus drink INTERRUPTED — charge wasted (%d left)" % estus_charges)
		# Curl around the blow — knockback points the way the hit travelled.
		_play_hit_react_animation(knockback)
		_pulse_react_smear()
		# Rumble scales with how much of the bar it took.
		if HitFeedback.is_local_human(self):
			HitFeedback.haptic(clampf(damage / 40.0, 0.35, 1.0))

		# Interrupt spell casting if hit (Bobba hit stops spells)
		if is_casting:
			_interrupt_spell()

	# Crouching braces for impact — 25% off everything that lands.
	if is_crouching:
		actual_damage *= CROUCH_DAMAGE_MULT
	# A hit shatters an in-progress revive channel — back to zero.
	if is_reviving:
		_cancel_revive("hit")

	# Apply damage
	if actual_damage > 0.0:
		take_damage(actual_damage)
	print("Player hit! Damage: %.1f (blocked: %s, blockable: %s) HP: %.1f/%.1f" % [
		actual_damage, blocked, is_fully_blockable, current_health, max_health
	])
	# Juice: hitstop + screen shake on any damage we actually take. Blocked
	# hits get a lighter cue so blocking feels distinct from tanking.
	if has_node("/root/CombatFX") and actual_damage > 0.0:
		var weight: float = 0.35 if blocked else 0.75
		CombatFX.on_hit(weight)
	return true


## Take damage from any source
func take_damage(amount: float) -> void:
	# Check spawn immunity
	if is_spawn_immune():
		print("Player: Damage ignored - spawn immunity active (%.1fs remaining)" % _spawn_immunity_timer)
		return

	var old_health: float = current_health
	_health.damage_flat(amount)
	print("Player: take_damage(%.1f) - HP: %.1f -> %.1f" % [amount, old_health, current_health])


## Flat HP damage from a source that is not a weapon swing — an arrow, a
## burning patch of ground. Absolute, like every other damage number in the
## game: see the note on Arrow.DIRECT_HIT_DAMAGE for why this stopped being a
## percentage of max HP.
func take_damage_flat(amount: float) -> void:
	if is_spawn_immune():
		return
	_health.damage_flat(amount)


## Heal the player (from spells, potions, etc.)
func heal(amount: float) -> void:
	_health.heal_flat(amount)


## Heal a percentage of max HP (e.g. paladin circle = 0.05/sec for paladin, 0.10/sec for archer).
func heal_pct(pct: float) -> void:
	_health.heal_pct(pct)


## Current sword damage for this Knight/Paladin, scaled by the damage buff.
## Base 30 HP × (1.0 + damage_buff_pct). Used by the sword hitbox callback.
func get_knight_sword_damage() -> float:
	return KNIGHT_SWORD_DAMAGE * (1.0 + clampf(damage_buff_pct, 0.0, DAMAGE_BUFF_MAX_PCT))


## Returns true if this player is the Knight (Paladin) class.
## Used by HealAuraArea and BuffAuraArea to determine eligibility.
func is_paladin() -> bool:
	return character_class == CharacterClass.PALADIN


## Returns true if this player is the Archer class.
func is_archer() -> bool:
	return character_class == CharacterClass.ARCHER


## Register that a buff-aura is currently touching this player. Called by
## BuffAuraArea.body_entered. While at least one source is active, the
## damage buff grows every frame; when the last source leaves (or the aura
## despawns), the buff decays.
func add_buff_source() -> void:
	_buff_sources += 1


func remove_buff_source() -> void:
	_buff_sources = max(0, _buff_sources - 1)


## Called every physics frame to advance the damage buff accumulator.
func _update_damage_buff(delta: float) -> void:
	if _buff_sources > 0:
		damage_buff_pct = minf(damage_buff_pct + DAMAGE_BUFF_GROWTH_PER_SEC * delta, DAMAGE_BUFF_MAX_PCT)
	elif damage_buff_pct > 0.0:
		damage_buff_pct = maxf(0.0, damage_buff_pct - DAMAGE_BUFF_DECAY_PER_SEC * delta)


func _setup_health_component() -> void:
	_health = HealthComponentClass.new()
	_health.name = "HealthComponent"
	_health.max_hp = 100.0  # Will be overridden by character class selection
	add_child(_health)
	# Forward HealthComponent signals to the existing Player signals
	_health.health_changed.connect(func(cur: float, mx: float) -> void:
		health_changed.emit(cur, mx))
	_health.died.connect(_on_player_death)
	# Every damage event (sword, arrow, DoT tick, network sync) pops the
	# current HP as a big floating label above the player.
	_health.damaged.connect(_on_damage_taken)


## Shared stamina pool; class discounts apply to spending, not recovery.
var _stamina: StaminaComponentClass
const SWORD_STAMINA_COST: float = 25.0
const ARCHER_STAMINA_COST_MULT: float = 0.4


func _setup_stamina_component() -> void:
	_stamina = StaminaComponentClass.new()
	_stamina.name = "StaminaComponent"
	_stamina.max_stamina = 100.0
	_stamina.cost_multiplier = ARCHER_STAMINA_COST_MULT if is_archer() else 1.0
	add_child(_stamina)


func _step_surface() -> String:
	for i in range(get_slide_collision_count()):
		var hit := get_slide_collision(i)
		if hit.get_normal().y > .5:
			return Sfx.surface(hit.get_collider())
	return "grass"


func _tick_footstep_timer(delta: float) -> void:
	var grounded := is_on_floor()
	if not grounded:
		_step_fall_speed = maxf(_step_fall_speed, -velocity.y)
	elif not _step_was_grounded and _step_fall_speed > 3.0 and not is_dead:
		Sfx.play3d("land", global_position, clampf(_step_fall_speed - 12.0, -8, 0))
	if grounded:
		_step_fall_speed = 0.0
	_step_was_grounded = grounded
	var speed := Vector2(velocity.x, velocity.z).length()
	if not grounded or speed < STEP_SPEED_THRESHOLD or is_rolling or is_dead:
		_step_timer = 0.0
		return
	#Cadence follows travelled distance, including slowed guard/aim movement.
	_step_timer -= delta * speed / (RUN_SPEED if is_running else WALK_SPEED)
	if _step_timer > 0.0:
		return
	Sfx.play3d("step_" + _step_surface(), global_position, -2.0 if is_running else -6.0)
	if combat_mode == CombatMode.ARMED and not is_archer():
		Sfx.play3d("armor_step", global_position + Vector3.UP, -12.0)
	_step_timer = RUN_STEP_INTERVAL if is_running else WALK_STEP_INTERVAL


## Paladin sword attack definition — a runtime-mutated Resource (damage
## is scaled by the archer buff at swing time).
var _knight_sword_attack: Resource = null


func _get_knight_sword_attack() -> Resource:
	if _knight_sword_attack == null:
		var a = AttackDataClass.new()
		a.attack_name = "KnightSword"
		a.damage = KNIGHT_SWORD_DAMAGE
		a.poise_damage = 35.0
		a.stamina_cost = SWORD_STAMINA_COST
		a.knockback_magnitude = PLAYER_KNOCKBACK_FORCE
		a.is_fully_blockable = true
		a.hit_window_start = SWORD_HITBOX_START
		a.hit_window_end = SWORD_HITBOX_END
		_knight_sword_attack = a
	return _knight_sword_attack


## AttackData owning the currently-playing attack animation's hit window.
## Set in _do_attack; read by _update_attack_hitbox_timing.
var _current_attack: Resource = null


## Called whenever the HealthComponent registers damage — shows the HP label.
func _on_damage_taken(amount: float) -> void:
	_show_hit_label("-%d" % int(round(amount)))


## Smear the air around the torso for the length of the recoil, then stop.
## Tied to the reaction's own duration so it ends with the movement rather
## than lingering on a body that has already settled.
func _pulse_react_smear() -> void:
	if _react_smear == null:
		return
	_react_smear.emitting = true
	var t := get_tree().create_timer(HitReactAnim.LENGTH * 0.6)
	t.timeout.connect(func() -> void:
		if _react_smear != null:
			_react_smear.emitting = false)


## Play the current character's hit-react animation if one is available.
## Archer has a dedicated "react small from front" FBX; Paladin does not,
## so this is a no-op for Paladin (the flash + stun + knockback are the
## feedback instead).
func _play_hit_react_animation(from_dir: Vector3 = Vector3.ZERO) -> void:
	if _current_anim_player == null:
		return
	var library_prefix := "archer" if character_class == CharacterClass.ARCHER else ("armed" if combat_mode == CombatMode.ARMED else "unarmed")
	# Prefer the composed directional clip so the body curls around the blow;
	# fall back to the single borrowed flinch, then to nothing.
	var dir := HitReactAnim.dir_for(self, from_dir)
	for candidate in [library_prefix + "/ReactHit" + dir, library_prefix + "/ReactHit"]:
		var anim_name := StringName(candidate)
		if _current_anim_player.has_animation(anim_name):
			_current_anim_player.play(anim_name, 0.05)
			_current_anim = anim_name
			return


## Called when player health reaches 0
func _on_player_death() -> void:
	Sfx.play3d("death_thud", global_position, -2.0)
	var other := _party_other()
	var ally_alive: bool = other != null and is_instance_valid(other) \
			and not ("is_dead" in other and other.is_dead)
	if is_ai_companion:
		# Companion down: the body stays under a revive beacon. Match only
		# ends if the human is ALSO already down.
		print("Companion died — awaiting revive")
		_enter_downed()
		if not ally_alive and other != null:
			other._trigger_game_restart("Player died!")
		return
	print("Player died!")
	player_died.emit()
	if GameSettings and "coop_mode" in GameSettings and GameSettings.coop_mode \
			and ally_alive:
		# Downed, not lost: the AI ally can still raise us.
		_enter_downed()
		return
	# No ally left standing — the match is lost.
	_trigger_game_restart("Player died!")


## Trigger game restart (called when player or Bobba dies)
func _trigger_game_restart(reason: String) -> void:
	print("Game restarting: ", reason)

	# Determine caption and color based on reason
	var caption: String = ""
	var caption_color: Color = Color.WHITE
	if "Player" in reason or "died" in reason:
		caption = "LOST"
		caption_color = Color(1.0, 0.2, 0.2)  # Red
	elif "Bobba" in reason:
		caption = "WON!"
		caption_color = Color(0.2, 1.0, 0.4)  # Green
	else:
		caption = "RESTARTING"
		caption_color = Color(1.0, 1.0, 0.3)  # Yellow

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
			# Show caption while waiting for server response
			_show_game_result_caption(caption, caption_color)
			return

	# Singleplayer: show caption. The arena scene (when
	# GameSettings.arena_mode is true) owns the reload so it can collect
	# a fun/not-fun rating from the player first.
	_show_game_result_caption(caption, caption_color)
	var gs := get_node_or_null("/root/GameSettings")
	if gs and "arena_mode" in gs and gs.arena_mode:
		return
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


## Show big game result caption (LOST/WON) to all players
func _show_game_result_caption(text: String, color: Color) -> void:
	# Create a dramatic centered caption overlay
	var canvas = CanvasLayer.new()
	canvas.name = "GameResultOverlay"
	canvas.layer = 100  # Above everything
	get_tree().current_scene.add_child(canvas)

	# Semi-transparent dark background
	var panel = ColorRect.new()
	panel.color = Color(0, 0, 0, 0.8)
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	canvas.add_child(panel)

	# Container to center the label
	var container = CenterContainer.new()
	container.set_anchors_preset(Control.PRESET_FULL_RECT)
	canvas.add_child(container)

	# Big dramatic caption
	var label = Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 140)
	label.add_theme_color_override("font_color", color)
	label.add_theme_constant_override("outline_size", 12)
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	container.add_child(label)

	# Animate the caption: scale up and fade in
	label.modulate.a = 0.0
	label.scale = Vector2(0.3, 0.3)
	label.pivot_offset = label.size / 2

	var tween = create_tween()
	tween.set_parallel(true)
	tween.tween_property(label, "modulate:a", 1.0, 0.3).set_ease(Tween.EASE_OUT)
	tween.tween_property(label, "scale", Vector2(1.0, 1.0), 0.5).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)

	print("Player: Showing game result caption: %s" % text)


func _reload_game() -> void:
	get_tree().reload_current_scene()


## Handle game restart broadcast from server (synchronized respawn)
func _on_game_restart_received(reason: int) -> void:
	print("Player: Game restart received from server (reason: %d)" % reason)

	# Remove any existing restart overlay
	var existing_overlay = get_tree().current_scene.get_node_or_null("RestartOverlay")
	if existing_overlay:
		existing_overlay.queue_free()

	# Show result caption to all players
	var caption: String = ""
	var caption_color: Color = Color.WHITE
	match reason:
		0:  # Player died
			caption = "LOST"
			caption_color = Color(1.0, 0.2, 0.2)  # Red
		1:  # Bobba died (victory)
			caption = "WON!"
			caption_color = Color(0.2, 1.0, 0.4)  # Green
		_:  # Manual restart or other
			caption = "RESTARTING"
			caption_color = Color(1.0, 1.0, 0.3)  # Yellow

	# Show the big caption overlay
	_show_game_result_caption(caption, caption_color)

	# Wait for caption to display, then respawn
	await get_tree().create_timer(2.0).timeout

	# Remove caption overlay
	var caption_overlay = get_tree().current_scene.get_node_or_null("GameResultOverlay")
	if caption_overlay:
		caption_overlay.queue_free()

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
	is_parrying = false
	is_drinking = false
	_is_stunned = false
	_stun_timer = 0.0
	_knockback_velocity = Vector3.ZERO
	velocity = Vector3.ZERO

	# A fresh life comes with a full flask — the souls respawn contract.
	estus_charges = ESTUS_MAX_CHARGES

	# Stop any spell effects
	_stop_spell_effects()

	# Spawn on a random hill
	_spawn_at_tower()

	# Re-connect to Bobba's death signal (Bobba was also respawned)
	call_deferred("_connect_bobba_death_signal")


## Notify NetworkManager that game scene is ready for remote player creation
func _notify_network_manager_ready() -> void:
	var nm = get_node_or_null("/root/NetworkManager")
	if nm == null:
		nm = get_tree().get_first_node_in_group("network_manager")
	if nm and nm.has_method("mark_game_scene_ready"):
		nm.mark_game_scene_ready()
		print("Player: Notified NetworkManager that game scene is ready")


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

	# Apply color flash only to the character model that's currently visible.
	# Previously this chose between _armed and _unarmed based on combat_mode
	# but missed the Archer path and recursed into hidden siblings too,
	# producing a "red ghost" silhouette on the Archer and sometimes on
	# Paladin when the inactive model stayed in the subtree.
	var active_char: Node3D = _get_active_character_model()
	if active_char == null:
		return
	_apply_hit_flash_recursive(active_char, color)

	# Reset after short delay
	_hit_flash_tween = create_tween()
	_hit_flash_tween.tween_callback(func() -> void:
		if is_instance_valid(active_char):
			_clear_hit_flash_recursive(active_char)
	).set_delay(0.15)


func _get_active_character_model() -> Node3D:
	if character_class == CharacterClass.ARCHER:
		return _archer_character
	if combat_mode == CombatMode.ARMED:
		return _armed_character
	return _unarmed_character


func _apply_hit_flash_recursive(node: Node, color: Color) -> void:
	# Skip anything that is hidden — the old recursion tinted hidden sibling
	# models, and a single stale visibility bit was enough to make the
	# "ghost" silhouette appear in captures.
	if node is Node3D:
		var n3 := node as Node3D
		if not n3.visible:
			return
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
			mat.emission_energy_multiplier = 0.45

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
	# Floating HP label above the player shown on every damage event.
	# Sized to be readable at typical camera distance without dominating
	# the screen. (Dragon's label uses its own, much larger, settings
	# because the dragon mesh is scaled 35×.)
	_hit_label = Label3D.new()
	_hit_label.name = "HitLabel"
	_hit_label.text = ""
	_hit_label.font_size = 48
	_hit_label.pixel_size = 0.003
	_hit_label.modulate = Color(1.0, 0.4, 0.3)  # Red — damage feedback
	_hit_label.outline_modulate = Color(0.1, 0.0, 0.0)
	_hit_label.outline_size = 6
	_hit_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_hit_label.no_depth_test = true
	_hit_label.position = Vector3(0, 2.3, 0)
	_hit_label.visible = false
	add_child(_hit_label)


func _setup_bow_progress_bar() -> void:
	# Create CanvasLayer for HUD elements
	var canvas = CanvasLayer.new()
	canvas.name = "BowHUD"
	add_child(canvas)

	#The sight marks launch direction at the centre of the viewport.
	_crosshair = CrosshairScript.new()
	canvas.add_child(_crosshair)

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
	# Spawn the gothic HUD overlay (ornate HP/stamina, ability slots, buff
	# counter). The ongoing references used by other parts of player.gd
	# (_health_bar, HealthBarUI, CombatHUD) are created below the gothic
	# layer so any code that reaches into HealthBarUI/Control/... still
	# finds its nodes — just hidden behind the new frame.
	# SPECTATING: the gothic frame is a PLAYER's HUD — his own HP, his stamina,
	# his ability slots, his buff counter. With nobody at the keyboard there is
	# no "his", and it just sits on top of the fight you came to watch. The
	# spectator reads both bodies out of the tactic overlay instead.
	if not _spectating():
		var gothic_script := preload("res://ui/gothic_hud.gd")
		var gothic: CanvasLayer = gothic_script.new()
		gothic.name = "GothicHUD"
		add_child(gothic)

	# Legacy canvas kept for backwards-compat references (HPText path used
	# by _on_health_changed). Hidden so it doesn't double-render.
	var canvas = CanvasLayer.new()
	canvas.name = "HealthBarUI"
	canvas.layer = 10
	canvas.visible = false
	add_child(canvas)

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

	# (Combatants panel moved to the gothic HUD — see ui/gothic_hud.gd.)

	# Connect health_changed signal to update UI (legacy hidden canvas;
	# gothic HUD polls independently).
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

	# Rule: only the visible sword blade counts as the hit volume. Use a
	# narrow capsule oriented along the blade so strikes register when the
	# blade actually intersects the target, not any time the hand is near.
	var sword_shape = CollisionShape3D.new()
	var capsule = CapsuleShape3D.new()
	capsule.radius = 0.1         # blade thickness ~ 20cm diameter — still narrow
	capsule.height = 1.5         # long-reach blade for the hack-and-slash combos
	sword_shape.shape = capsule
	# Capsule is Y-axis aligned by default. Rotate so it lies along the
	# hand's forward (+Z local) and shift so the blade spans from the grip
	# outward instead of centering on the hand.
	sword_shape.rotation = Vector3(deg_to_rad(90.0), 0, 0)
	sword_shape.position = Vector3(0, 0, 0.8)  # midpoint of blade

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
	#The animated rig may scale bones; physics keeps the blade rigid.
	_attack_hitbox.top_level = true
	print("Player: Attached sword hitbox to bone: ", skeleton.get_bone_name(hand_bone_idx))


func _on_attack_hitbox_body_entered(body: Node3D) -> void:
	# Only process hits during the active damage window
	if not _hitbox_active_window:
		return

	if _swing_targets.has(body.get_instance_id()):
		return
	if not _lock_visible(body):
		return

	# Airborne paladin deals NO damage — belt and braces for the no-swing
	# rule (e.g. a swing carried off a ledge).
	if character_class == CharacterClass.PALADIN and not is_on_floor():
		return

	# No friendly fire. A swing that clips an ally does nothing at all — it
	# does not even consume the swing, so brawling shoulder to shoulder
	# around a fire costs the party nothing.
	if Factions.is_ally(self, body):
		return

	# Check if we hit an enemy with take_hit method
	if body.has_method("take_hit"):
		_has_hit_this_attack = true
		_swing_targets[body.get_instance_id()] = true

		# Calculate knockback direction (from player to enemy)
		var knockback_dir = (body.global_position - global_position).normalized()
		knockback_dir.y = 0.2  # Slight upward component

		# Determine damage. Knight (Paladin) in armed mode fires the
		# KnightSword AttackData resource (scaled by current damage buff);
		# everything else still uses the legacy unarmed path.
		var damage: float = PLAYER_ATTACK_DAMAGE
		var fully_blockable: bool = false
		if character_class == CharacterClass.PALADIN and combat_mode == CombatMode.ARMED:
			# Positional/stateful crits. Both require the sword hitbox to have
			# visually connected (we're inside this callback), so the golden
			# rule holds — the crit only changes how much the contact hurts.
			# Riposte: the enemy is staggered from our parry; consume it.
			# Backstab: the contact came from the enemy's rear cone.
			var crit_mult: float = 1.0
			var crit_label: String = ""
			if body.has_method("is_riposte_ready") and body.is_riposte_ready():
				crit_mult = RIPOSTE_DAMAGE_MULT
				crit_label = "RIPOSTE!"
				if body.has_method("consume_riposte"):
					body.consume_riposte()
			elif _is_behind_target(body):
				crit_mult = BACKSTAB_DAMAGE_MULT
				crit_label = "BACKSTAB!"
			# Per-combo-step AttackData when a chain swing is live; damage
			# escalates through the chain and the finisher hits hardest.
			var atk: Resource = _current_attack if _current_attack != null else _get_knight_sword_attack()
			var step_mult: float = 1.7 if _current_attack == _heavy_attack and _heavy_attack != null \
					else (COMBO_DAMAGE_MULT[_combo_step] if _current_attack != null else 1.0)
			atk.damage = KNIGHT_SWORD_DAMAGE * step_mult * (1.0 + clampf(damage_buff_pct, 0.0, DAMAGE_BUFF_MAX_PCT)) * crit_mult
			damage = atk.damage
			fully_blockable = atk.is_fully_blockable
			if crit_label != "":
				_show_hit_label(crit_label)
				print("Knight sword CRIT (%s): %.1f HP (x%.1f)" % [crit_label, damage, crit_mult])
			else:
				print("Knight sword attack: %.1f HP (buff +%.0f%%)" % [damage, damage_buff_pct * 100.0])
			damage = atk.apply_to(body, self)
			if damage <= 0.0:
				return
		else:
			# Unarmed fallback — still the old flat-damage path.
			body.take_hit(damage, knockback_dir * PLAYER_KNOCKBACK_FORCE, false, self, fully_blockable)
		print("Player: HIT LANDED on enemy: ", body.name)
		# Spark burst where the blade met the body — hack-and-slash "clang".
		var spark_pos: Vector3 = _attack_hitbox.global_transform * Vector3(0, 0, 0.9) \
				if combat_mode == CombatMode.ARMED else body.global_position + Vector3(0, 1.2, 0)
		SlashTrail.spawn_hit_spark(self, spark_pos, Color(1.0, 0.85, 0.45))
		Sfx.play3d("hit_metal" if combat_mode == CombatMode.ARMED else "hit_flesh", spark_pos, -4.0)
		# Juice: hitstop + screen shake. Sword hits are heavy (weight 0.9);
		# unarmed jabs lighter (0.5).
		if has_node("/root/CombatFX"):
			CombatFX.on_hit(0.9 if fully_blockable else 0.5)
		# Rumble the swing that connected — sword heavier than a jab. On a
		# phone this is the clearest "it landed" signal there is.
		if HitFeedback.is_local_human(self):
			HitFeedback.haptic(0.85 if combat_mode == CombatMode.ARMED else 0.45)

		# In multiplayer, send entity damage to server
		if enable_multiplayer and has_node("/root/NetworkManager") and "entity_id" in body:
			var network_manager = get_node("/root/NetworkManager")
			if network_manager.has_method("is_network_connected") and network_manager.is_network_connected():
				network_manager.send_entity_damage(body.entity_id, damage, network_manager.my_player_id)
				print("Player: Sent entity damage to server - entity_id=%d damage=%.1f" % [body.entity_id, damage])
	else:
		print("Player: Body has no take_hit method")


## True when this player stands inside `body`'s rear cone — the backstab
## position. Uses the same facing convention the enemies use for movement:
## model rotation θ means world-forward (sin θ, 0, cos θ).
func _is_behind_target(body: Node3D) -> bool:
	if not body.has_method("get_facing_rotation"):
		return false
	var facing: float = body.get_facing_rotation()
	var fwd := Vector3(sin(facing), 0.0, cos(facing))
	var to_me: Vector3 = global_position - body.global_position
	to_me.y = 0.0
	if to_me.length() < 0.01:
		return false
	return fwd.dot(to_me.normalized()) < BACKSTAB_CONE_DOT


func enable_attack_hitbox() -> void:
	# Reset attack hit tracking - called when attack starts
	print("Player: enable_attack_hitbox() - resetting _has_hit_this_attack to false")
	_has_hit_this_attack = false
	_swing_targets.clear()
	_blade_sweep.reset()
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
		if _sword_trail != null:
			_sword_trail.emitting = false
		if _sword_smear != null:
			_sword_smear.emitting = false
		return

	# Calculate animation progress (0.0 to 1.0)
	var anim_length: float = _current_anim_player.current_animation_length
	var anim_position: float = _current_anim_player.current_animation_position
	if anim_length > 0:
		_attack_anim_progress = anim_position / anim_length
	else:
		_attack_anim_progress = 0.0

	if _buffer_heavy and _attack_input_buffer > 0.0 and _can_cancel_attack():
		if _start_combo_swing(2, true):
			return
		_buffer_heavy = false
		_combo_clicks_buffered = 0
	# Banked combo step cancels the recovery tail of the current swing:
	# once past the chain point the next swing starts immediately.
	if _combo_clicks_buffered > 0 and _attack_input_buffer > 0.0 \
			and combat_mode == CombatMode.ARMED \
			and _can_cancel_attack() \
			and _combo_step < COMBO_ANIMS.size() - 1:
		_combo_clicks_buffered -= 1
		if _start_combo_swing(_combo_step + 1):
			return  # fresh swing — timing restarts next frame
		_combo_clicks_buffered = 0  # couldn't chain (winded) — drop the bank

	# Select the correct hitbox based on combat mode
	var active_hitbox: Area3D = _attack_hitbox if combat_mode == CombatMode.ARMED else _unarmed_hitbox

	# Active window is sourced from the current AttackData when available,
	# otherwise falls back to the legacy hardcoded constants.
	var win_start: float = _current_attack.hit_window_start if _current_attack else SWORD_HITBOX_START
	var win_end: float = _current_attack.hit_window_end if _current_attack else SWORD_HITBOX_END
	var should_be_active: bool = _attack_anim_progress >= win_start and _attack_anim_progress <= win_end

	if should_be_active and not _hitbox_active_window:
		_hitbox_active_window = true
		if combat_mode == CombatMode.ARMED:
			Sfx.play3d("sword_whoosh_%d" % (_combo_step + 1), global_position, -6.0)
		print("Player: Attack window ACTIVE at progress ", _attack_anim_progress, " (mode: ", "armed" if combat_mode == CombatMode.ARMED else "unarmed", ")")
	elif not should_be_active and _hitbox_active_window:
		_hitbox_active_window = false
		print("Player: Attack window ENDED at progress ", _attack_anim_progress)


	# The slash ribbon draws exactly while the blade can hurt — the visible
	# arc IS the hit volume's path (golden rule made legible).
	if _sword_trail != null:
		_sword_trail.emitting = _hitbox_active_window and combat_mode == CombatMode.ARMED
	if _sword_smear != null:
		_sword_smear.emitting = _hitbox_active_window and combat_mode == CombatMode.ARMED

	if _hitbox_active_window:
		if combat_mode == CombatMode.ARMED:
			for body in _blade_sweep.contacts(get_world_3d().direct_space_state,
					active_hitbox.global_transform, [get_rid()]):
				_on_attack_hitbox_body_entered(body)
		else:
			for body in active_hitbox.get_overlapping_bodies():
				_on_attack_hitbox_body_entered(body)
	else:
		_blade_sweep.reset()


func _show_hit_label(text: String = "Hit!") -> void:
	if _hit_label == null:
		return
	if _hit_label_tween:
		_hit_label_tween.kill()
	_hit_label.text = text
	_hit_label.visible = true
	_hit_label.position = Vector3(0, 2.1, 0)
	_hit_label.scale = Vector3.ONE
	var critical := text in ["PARRY!", "RIPOSTE!", "BACKSTAB!"]
	_hit_label.modulate = Color(1.0, 0.85, 0.45) if critical else Color(1.0, 0.5, 0.4)
	_hit_label_tween = create_tween().set_parallel(true)
	_hit_label_tween.tween_property(_hit_label, "position:y", 2.5, 0.65).set_ease(Tween.EASE_OUT)
	_hit_label_tween.tween_property(_hit_label, "modulate:a", 0.0, 0.25).set_delay(0.4)
	_hit_label_tween.chain().tween_callback(func(): _hit_label.visible = false)


# ----------------------------------------------------------------------------
# Lock-on / target tracking
# ----------------------------------------------------------------------------

func _toggle_lock_on() -> void:
	if _lock_target != null and is_instance_valid(_lock_target):
		_drop_lock_on()
	else:
		_acquire_lock_target()


func _combat_targets() -> Array:
	var targets: Array = []
	for group in [&"bobba", &"skeletons", &"dragon"]:
		targets.append_array(get_tree().get_nodes_in_group(group))
	return targets


func _assist_swing_direction(direction: Vector3) -> Vector3:
	var best := cos(deg_to_rad(42.0))
	var result := direction
	for enemy in _combat_targets():
		if not is_instance_valid(enemy) or not _lock_alive(enemy) or Factions.is_ally(self, enemy):
			continue
		var offset: Vector3 = enemy.global_position - global_position
		if offset.length() > 3.2 or absf(offset.y) > 1.5:
			continue
		offset.y = 0.0
		var alignment := direction.dot(offset.normalized())
		if alignment > best and _lock_visible(enemy):
			best = alignment
			result = offset.normalized()
	return result


func _switch_lock_target(side: float) -> void:
	if not is_instance_valid(_lock_target):
		return
	var current := _lock_target.global_position - global_position
	current.y = 0.0
	var best := INF
	var selected: Node3D = null
	for enemy in _combat_targets():
		if enemy == _lock_target or not _lock_alive(enemy) or Factions.is_ally(self, enemy):
			continue
		var offset: Vector3 = enemy.global_position - global_position
		if offset.length() > LOCK_ON_RANGE or not _lock_visible(enemy):
			continue
		offset.y = 0.0
		var angle := -current.signed_angle_to(offset, Vector3.UP)
		if angle * side > 0.04 and absf(angle) < best:
			best = absf(angle)
			selected = enemy
	if selected != null:
		_lock_target = selected
		_lock_obscured = 0.0
		_show_lock_indicator()


func _acquire_lock_target() -> void:
	# Pick the enemy best aligned with where the camera is already pointing,
	# within range and inside the acquire cone. Prefers what you're looking at,
	# then proximity.
	var candidates: Array = []
	candidates.append_array(get_tree().get_nodes_in_group(&"bobba"))
	candidates.append_array(get_tree().get_nodes_in_group(&"skeletons"))
	candidates.append_array(get_tree().get_nodes_in_group(&"dragon"))
	var cam_fwd: Vector3 = -_camera.global_transform.basis.z
	var half_cos: float = cos(deg_to_rad(LOCK_ON_ACQUIRE_HALF_ANGLE))
	var best: Node3D = null
	var best_score: float = -INF
	for c in candidates:
		if c == null or not is_instance_valid(c) or c == self or not (c is Node3D):
			continue
		if not _lock_alive(c) or Factions.is_ally(self, c):
			continue  # skip corpses
		var n3d: Node3D = c
		var to: Vector3 = n3d.global_position - global_position
		var dist: float = to.length()
		if dist < 0.1 or dist > LOCK_ON_RANGE:
			continue
		var aim: float = (to / dist).dot(cam_fwd)
		if aim < half_cos:
			continue
		if not _lock_visible(n3d):
			continue
		var score: float = aim - dist * 0.02  # well-aimed first, then nearer
		if score > best_score:
			best_score = score
			best = n3d
	if best != null:
		_lock_target = best
		_lock_obscured = 0.0
		_show_lock_indicator()


func _lock_alive(target: Node) -> bool:
	if "health" in target:
		return target.health > 0.0
	if "hp" in target:
		return target.hp > 0.0
	return true


func _lock_visible(target: Node3D) -> bool:
	var excluded: Array[RID] = [get_rid()]
	# Allies crossing the camera or blade must not shield an enemy from us.
	for group in Factions.PARTY_GROUPS:
		for ally in get_tree().get_nodes_in_group(group):
			if ally is CollisionObject3D and ally != self:
				excluded.append(ally.get_rid())
	var ray := PhysicsRayQueryParameters3D.create(
			global_position + Vector3.UP * 1.3,
			target.global_position + Vector3.UP * 1.2, 1, excluded)
	var hit := get_world_3d().direct_space_state.intersect_ray(ray)
	return hit.is_empty() or hit.collider == target


func _drop_lock_on() -> void:
	_lock_target = null
	_lock_obscured = 0.0
	if _lock_indicator != null:
		_lock_indicator.visible = false


func _update_lock_on(delta: float) -> void:
	if _lock_target == null:
		return
	# Validate: still exists, still in range, not a corpse.
	var lost: bool = not is_instance_valid(_lock_target)
	if not lost:
		if global_position.distance_to(_lock_target.global_position) > LOCK_ON_BREAK_RANGE:
			lost = true
		elif not _lock_alive(_lock_target):
			lost = true
		else:
			_lock_obscured = 0.0 if _lock_visible(_lock_target) else _lock_obscured + delta
			lost = _lock_obscured > 0.35
	if lost:
		_drop_lock_on()
		return

	# Park the reticle over the target (roughly head height).
	if _lock_indicator != null:
		_lock_indicator.global_position = _lock_target.global_position + Vector3.UP * 1.5

	# Steer the camera to face the target. atan2(-x, -z) matches the engine's
	# yaw convention used for movement (Vector3.FORWARD rotated by cam yaw).
	var to: Vector3 = _lock_target.global_position - _camera_pivot.global_position
	var flat := Vector3(to.x, 0.0, to.z)
	if flat.length() < 0.05:
		return
	var desired_yaw: float = atan2(-flat.x, -flat.z)
	camera_rotation.x = lerp_angle(camera_rotation.x, desired_yaw, minf(LOCK_ON_TURN_SPEED * delta, 1.0))
	var target_height := _lock_target.global_position.y + 1.2 - _camera_pivot.global_position.y
	var pitch := atan2(target_height, flat.length() + DEFAULT_SPRING_LENGTH) - deg_to_rad(6.0)
	camera_rotation.y = lerp_angle(camera_rotation.y, clampf(pitch, -0.55, 0.35), minf(LOCK_ON_TURN_SPEED * delta, 1.0))
	_camera_pivot.rotation.y = camera_rotation.x
	_camera_pivot.rotation.x = camera_rotation.y


func _show_lock_indicator() -> void:
	if _lock_indicator == null:
		_lock_indicator = Sprite3D.new()
		_lock_indicator.name = "LockOnReticle"
		_lock_indicator.texture = _make_reticle_texture()
		_lock_indicator.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_lock_indicator.no_depth_test = true   # always visible over the target
		_lock_indicator.fixed_size = true      # constant on-screen size
		_lock_indicator.pixel_size = 0.00055
		_lock_indicator.render_priority = 20
		add_child(_lock_indicator)
	_lock_indicator.visible = true


func _make_reticle_texture() -> ImageTexture:
	# A bronze diamond ring, matching the gothic HUD palette. Drawn as an
	# L1-distance band so it reads as a crisp rotated-square outline.
	var size: int = 64
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var col := Color(0.96, 0.84, 0.46, 1.0)  # bronze-gold
	var c: float = size / 2.0
	var r: float = size * 0.40
	for i in range(size):
		for j in range(size):
			var d: float = abs(i - c) + abs(j - c)  # L1 -> diamond
			if abs(d - r) <= 1.7:
				img.set_pixel(i, j, col)
	return ImageTexture.create_from_image(img)


# ----------------------------------------------------------------------------
# Dodge-roll
# ----------------------------------------------------------------------------

#Only the recovery tail permits cancelling a swing.
func _can_cancel_attack() -> bool:
	var point: float = _current_attack.recovery_start \
			if _current_attack else ATTACK_CANCEL_POINT
	return is_attacking and _attack_anim_progress >= point


## Drop the swing (and the rest of the chain) so something else can happen.
## The blade stops being dangerous the instant the decision changes — the
## golden rule cuts both ways, and a hitbox left live through a roll would
## deal damage from a sword nobody is swinging any more.
func _cancel_attack_for(what: String) -> void:
	is_attacking = false
	disable_attack_hitbox()
	_combo_step = 0
	_combo_clicks_buffered = 0
	_attack_cooldown = ATTACK_CANCEL_COOLDOWN
	if _sword_trail != null:
		_sword_trail.emitting = false
	if _sword_smear != null:
		_sword_smear.emitting = false
	print("Player: swing cancelled into a %s" % what)


func _try_dodge() -> void:
	if is_dead or is_reviving:
		return
	_attack_input_buffer = 0.0
	_combo_clicks_buffered = 0
	_buffer_heavy = false
	if (is_attacking and character_class != CharacterClass.ARCHER and not _can_cancel_attack()) \
			or is_rolling or _is_stunned or is_parrying:
		_dodge_input_buffer = ATTACK_BUFFER_TIME
		return
	if not is_on_floor():
		return
	# Stamina gate — a roll you can't afford simply doesn't happen.
	if _stamina != null and not _stamina.try_spend(ROLL_STAMINA_COST):
		return

	if is_drawing_bow or is_holding_bow:
		_cancel_bow_draw()
	if is_casting:
		_interrupt_spell()
	is_drinking = false
	_bow_follow_time = 0.0
	if is_attacking:
		_cancel_attack_for("roll")
	_dodge_input_buffer = 0.0
	_attack_input_buffer = 0.0

	# Direction from the movement stick, converted to world space via camera
	# yaw (same convention as walking). No input → roll straight backward.
	var raw: Vector2 = _ai_move_vec if ai_driven \
			else Input.get_vector(&"move_left", &"move_right",
			&"move_forward", &"move_back", 0.15)
	var cam_yaw: float = _camera_pivot.rotation.y
	var fwd := Vector3.FORWARD.rotated(Vector3.UP, cam_yaw)
	var rt := Vector3.RIGHT.rotated(Vector3.UP, cam_yaw)
	var anim_key: String = "dodge_b"
	_roll_faces_dir = false
	var directional: bool = false
	if raw.length() > 0.15:
		var n: Vector2 = raw.normalized()
		_roll_dir = (fwd * -n.y + rt * n.x).normalized()
		# Pick the directional clip from the dominant input axis.
		if absf(n.y) >= absf(n.x):
			anim_key = "dodge_f" if n.y < 0.0 else "dodge_b"
		else:
			anim_key = "dodge_l" if n.x < 0.0 else "dodge_r"
		directional = true
	else:
		_roll_dir = -fwd  # backstep away from where the camera faces

	is_rolling = true
	_roll_timer = ROLL_DURATION
	Sfx.play3d("roll", global_position, -8.0)

	var prefix: String = _get_current_mode_prefix()

	# A DIRECTIONAL roll is a tumble down its own line of travel — the body
	# turns to face where it is going and rolls forward, exactly as the genre
	# does it, which is why one clip covers all four directions. Neutral is a
	# backstep: a different move, and a somersault backwards would read as a
	# mistake. Falls back to the old sidestep clips for any set without the
	# tumble (the archer keeps hers).
	if directional:
		var roll_name := StringName("%s/Roll" % prefix)
		if _current_anim_player != null and _current_anim_player.has_animation(roll_name):
			_roll_faces_dir = true
			var clip: Animation = _current_anim_player.get_animation(roll_name)
			# Fit the trimmed tumble to the roll's own duration, so the body
			# is never still mid-somersault when the i-frames end.
			var rate: float = clip.length / ROLL_DURATION if clip.length > 0.0 else 1.0
			_current_anim_player.play(roll_name, 0.05, rate)
			_current_anim = roll_name
			# Snap, do not ease: the roll commits on the frame it starts, and
			# a body still swinging round to face the direction it is already
			# travelling in looks like a slide.
			if _character_model != null:
				_character_model.rotation.y = atan2(_roll_dir.x, _roll_dir.z)
			return

	# Backstep (or no tumble available): the old directional clip.
	var anim_name := StringName("%s/%s" % [prefix, _dodge_anim_suffix(anim_key)])
	if _current_anim_player != null and _current_anim_player.has_animation(anim_name):
		var length := _current_anim_player.get_animation(anim_name).length
		_current_anim_player.play(anim_name, 0.08, length / ROLL_DURATION)
		_current_anim = anim_name


func _dodge_anim_suffix(key: String) -> String:
	match key:
		"dodge_f": return "DodgeF"
		"dodge_b": return "DodgeB"
		"dodge_l": return "DodgeL"
		"dodge_r": return "DodgeR"
	return "DodgeB"


## Start a parry attempt. Paladin (shield) only — the archer's evasion
## verbs are the roll and the jump. The shield flick is the armed Block
## clip played fast; the deflect frames and recovery are tracked by
## _parry_timer in _physics_process.
func _try_parry() -> void:
	if character_class != CharacterClass.PALADIN or combat_mode != CombatMode.ARMED:
		return
	if is_parrying or is_attacking or is_rolling or _is_stunned or is_casting or is_drinking \
			or is_reviving or is_dead:
		return
	if not is_on_floor():
		return
	if _stamina != null and not _stamina.try_spend(PARRY_STAMINA_COST):
		return

	is_parrying = true
	_parry_timer = 0.0
	is_blocking = false  # parry replaces any held block for its duration
	if _current_anim_player != null and _current_anim_player.has_animation(&"armed/Block"):
		_current_anim_player.play(&"armed/Block", -1, 2.2)
		_current_anim = &"armed/Block"


## Start drinking an estus flask. The charge is consumed up front; the
## heal lands only if the channel completes uninterrupted.
func _try_estus() -> void:
	if is_drinking or is_attacking or is_rolling or is_parrying or _is_stunned or is_casting \
			or is_reviving or is_dead:
		return
	if is_drawing_bow or is_holding_bow:
		return
	if estus_charges <= 0:
		_show_hit_label("No estus!")
		return
	if current_health >= max_health:
		return

	estus_charges -= 1
	is_drinking = true
	_drink_timer = ESTUS_DRINK_DURATION
	Sfx.play3d("estus_drink", global_position + Vector3(0, 1.4, 0), -6.0)
	print("Player: drinking estus (%d left)" % estus_charges)
	var prefix: String = _get_current_mode_prefix()
	var drink_anim := StringName(prefix + "/Estus")
	if _current_anim_player != null and _current_anim_player.has_animation(drink_anim):
		_current_anim_player.play(drink_anim)
		_current_anim = drink_anim


## Completes the estus channel: heal lands, green feedback.
func _finish_estus() -> void:
	is_drinking = false
	heal_pct(ESTUS_HEAL_PCT)
	_flash_hit(Color(0.2, 1.0, 0.35))
	_show_hit_label("+%d HP  (%d estus left)" % [int(max_health * ESTUS_HEAL_PCT), estus_charges])
	print("Player: estus drunk — HP %.1f/%.1f (%d charges left)" % [
		current_health, max_health, estus_charges])


func _input(event: InputEvent) -> void:
	var lt_attack := false
	if event is InputEventJoypadMotion and event.axis == JOY_AXIS_TRIGGER_LEFT:
		var was_down: bool = _left_trigger_down.get(event.device, false)
		var down: bool = event.axis_value > (0.35 if was_down else 0.5)
		_left_trigger_down[event.device] = down
		lt_attack = down and not was_down
	# Toggle fullscreen with F11
	if event is InputEventKey and event.pressed and event.keycode == KEY_F11:
		if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		else:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
			CloudInput.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

	# Quit with Q key
	# Q sits next to WASD; on a cloud session a brushed key must not end
	# the stream ("Session ended: game exited"). Desktop keeps the shortcut.
	if event is InputEventKey and event.pressed and event.keycode == KEY_Q \
			and not CloudInput.is_cloud_session:
		get_tree().quit()

	# Release mouse with Escape
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		CloudInput.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

	# Click on the game to recapture the mouse after Escape let it go. That
	# click is spent on the grab — it must not also swing the sword or start
	# a bow draw, so the event stops here (release is gated on capture too).
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT \
			and not CloudInput.touchscreen_available() \
			and CloudInput.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
		CloudInput.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		get_viewport().set_input_as_handled()
		return

	# A brain is driving this body — the only human keys left are the window
	# ones handled above. The view lives in spectate_cam.gd and takes the
	# rest (TAB, mouse look, wheel) for itself.
	if ai_driven:
		return

	# Toggle combat mode with Tab, middle mouse button, or gamepad Back button
	if event.is_action_pressed(&"toggle_combat"):
		_toggle_combat_mode()
	elif event is InputEventKey and event.pressed and event.keycode == KEY_TAB:
		_toggle_combat_mode()
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_MIDDLE:
		_toggle_combat_mode()

	# Lock-on toggle (T key or right-stick click). Souls-style target lock.
	if event.is_action_pressed(&"lock_on"):
		_toggle_lock_on()

	# Dodge-roll (X, Ctrl+Space, or gamepad B). Direction from the
	# movement stick.
	#
	# The chord overlaps two other bindings and Godot's input map cannot
	# separate them: an action bound to plain Space ALSO matches Ctrl+Space
	# (modifiers are not required to match when the binding declares none),
	# and Ctrl on its own is the crouch key. So jump and crouch are
	# suppressed in code — see _physics_process. Verified, not assumed:
	# Ctrl+Space reports is_action("jump") == true.
	if event.is_action_pressed(&"dodge"):
		_try_dodge()

	# Parry (G key or gamepad LB). Shield flick with a short deflect window.
	if event.is_action_pressed(&"parry"):
		_try_parry()

	# Estus flask (H key or d-pad down). Slow, interruptible heal channel.
	if event.is_action_pressed(&"estus"):
		_try_estus()

	# Attack with left mouse, F, RB, or LT (paladin).
	# Archer: two shots on two buttons (see below)
	# Others: press to attack
	if character_class == CharacterClass.ARCHER:
		# The archer has two shots. AIM decides which one a press gives him,
		# and the two devices ask for it differently:
		#
		#   MOUSE — right button is the whole sighted shot: hold to draw
		#     (camera over the shoulder, 1.5x the draw time), let go to
		#     loose, let go early to cancel. Left button is the quick shot.
		#   PAD — hold LT to zoom and draw; release to loose the arrow.
		#     RB remains the quick shot.
		#   TOUCH — the guard button is the aim (a phone has no trigger),
		#     the attack button shoots.
		#
		# AIM owns its release. ATTACK owns an automatic quick shot.
		var mb := event as InputEventMouseButton
		var captured: bool = CloudInput.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED
		var key := event as InputEventKey
		# Captured-mouse fallbacks: the cloud client feeds raw button events
		# whose action mapping cannot be relied on, so the button index is
		# read directly as well. Both paths land in the same branch, and
		# _start_bow_draw/_release_bow are idempotent.
		var rmb: bool = captured and mb != null and mb.button_index == MOUSE_BUTTON_RIGHT
		var lmb: bool = captured and mb != null and mb.button_index == MOUSE_BUTTON_LEFT
		if event.is_action_pressed(&"aim") or (rmb and mb.pressed):
			#Further analog motion cannot restart a draw already in progress.
			_start_bow_draw(true, true)
		elif event.is_action_released(&"aim") or (rmb and not mb.pressed):
			if _bow_hold_release:
				_release_bow()
		elif event.is_action_pressed(&"attack") or (lmb and mb.pressed) \
				or (key != null and key.keycode == KEY_F and key.pressed and not key.echo):
			# A shoot button. Sighted if he is holding aim, quick if not;
			# either way the bar looses it — no release to wait for.
			_start_bow_draw(_aim_input_held(), false)
	else:
		# Paladin: attack on press
		if event.is_action_pressed(&"heavy_attack"):
			_do_attack(true)
		elif lt_attack or event.is_action_pressed(&"attack"):
			_do_attack()
		elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			if CloudInput.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
				_do_attack()
		elif event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F:
			_do_attack()

	# Blocking is NOT handled here. It used to be edge-driven (press sets,
	# release clears) and any missed release — app pause, focus change,
	# touch cancel, an analog trigger snapping back past the deadzone —
	# pinned the shield up for good. It is reconciled against the real
	# button state every physics frame instead: see _update_block_state().

	# Spell cast with C, gamepad X, or Guide (armed mode only).
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
	if event is InputEventMouseMotion and _lock_target == null \
			and (is_mobile or CloudInput.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED):
		camera_rotation.x -= event.relative.x * MOUSE_SENSITIVITY
		camera_rotation.y -= event.relative.y * MOUSE_SENSITIVITY
		camera_rotation.y = clamp(camera_rotation.y, deg_to_rad(-CAMERA_VERTICAL_LIMIT), deg_to_rad(CAMERA_VERTICAL_LIMIT))

		_camera_pivot.rotation.y = camera_rotation.x
		_camera_pivot.rotation.x = camera_rotation.y


## Late pass, after the AnimationMixer has posed the skeleton for this frame.
## Anything that has to sit ON TOP of a clip belongs here — applied in
## _physics_process it would simply be overwritten.
func _process(_delta: float) -> void:
	_apply_arm_spread()
	_apply_crouch_grounding(_delta)


func _update_combat_camera(delta: float) -> void:
	# Gamepad camera control (right stick)
	var look_x: float = 0.0 if ai_driven \
			else Input.get_action_strength(&"camera_look_right") - Input.get_action_strength(&"camera_look_left")
	var look_y: float = 0.0 if ai_driven \
			else Input.get_action_strength(&"camera_look_down") - Input.get_action_strength(&"camera_look_up")
	if _lock_target != null:
		if absf(look_x) < 0.3:
			_lock_stick_ready = true
		elif absf(look_x) > 0.7 and _lock_stick_ready:
			_lock_stick_ready = false
			_switch_lock_target(signf(look_x))
	elif abs(look_x) > 0.01 or abs(look_y) > 0.01:
		camera_rotation.x -= look_x * GAMEPAD_SENSITIVITY * delta
		camera_rotation.y -= look_y * GAMEPAD_SENSITIVITY * delta
		camera_rotation.y = clamp(camera_rotation.y, deg_to_rad(-CAMERA_VERTICAL_LIMIT), deg_to_rad(CAMERA_VERTICAL_LIMIT))
		_camera_pivot.rotation.y = camera_rotation.x
		_camera_pivot.rotation.x = camera_rotation.y

	# Lock-on steers the camera onto the target, overriding mouse/stick look.
	_update_lock_on(delta)

	#Hold the sight after release so the flight is readable, then ease back.
	if _spring_arm != null and _camera != null:
		var wants_aim: bool = _aim_input_held() \
				or (_bow_aimed and (is_drawing_bow or is_holding_bow))
		var aiming: bool = character_class == CharacterClass.ARCHER \
				and wants_aim and not ai_driven and is_on_floor() \
				and not (is_dead or is_rolling or _is_stunned or is_casting) \
				and Vector2(velocity.x, velocity.z).length() < 0.8
		var zoom := 1.0 if aiming else smoothstep(0.0, BOW_CAMERA_RETURN, _bow_follow_time)
		var want_len := lerpf(DEFAULT_SPRING_LENGTH, AIM_ZOOM_SPRING, zoom)
		var want_fov := lerpf(DEFAULT_CAMERA_FOV, AIM_ZOOM_FOV, zoom)
		# Screen fraction -> metres: at `AIM_ZOOM_SPRING` behind him, half the
		# frame spans `tan(hfov/2) * dist`, so a shift of `f` widths needs
		# 2*f*tan(hfov/2)*dist of lateral travel.
		var vp: Vector2 = get_viewport().get_visible_rect().size
		var aspect: float = vp.x / maxf(vp.y, 1.0)
		var tan_half_h: float = tan(deg_to_rad(AIM_ZOOM_FOV * 0.5)) * aspect
		var want_side := 2.0 * AIM_SHOULDER_SCREEN * tan_half_h * AIM_ZOOM_SPRING * zoom
		var want_lift := AIM_SHOULDER_LIFT * zoom
		_spring_arm.spring_length = lerpf(_spring_arm.spring_length, want_len, minf(10.0 * delta, 1.0))
		_camera.fov = lerpf(_camera.fov, want_fov, minf(10.0 * delta, 1.0))
		# Same easing rate as the zoom: the slide and the pull-in are one move.
		var arm_pos: Vector3 = _spring_arm.position
		arm_pos.x = lerpf(arm_pos.x, want_side, minf(10.0 * delta, 1.0))
		arm_pos.y = lerpf(arm_pos.y, want_lift, minf(10.0 * delta, 1.0))
		_spring_arm.position = arm_pos

	#Keep the sight through the follow-through, too.
	if _crosshair != null:
		_crosshair.visible = character_class == CharacterClass.ARCHER \
				and (_aim_input_held() \
					or (_bow_aimed and (is_drawing_bow or is_holding_bow)) \
					or _bow_follow_time > 0.0) \
				and not ai_driven and not is_dead



func _physics_process(delta: float) -> void:
	_bow_follow_time = maxf(_bow_follow_time - delta, 0.0)
	if is_dead or is_rolling or _is_stunned or is_casting:
		_bow_follow_time = 0.0
	# Skip movement when console is open (still apply gravity)
	if GameConsoleScript.is_console_open:
		velocity += gravity * delta
		move_and_slide()
		return

	if _attack_cooldown > 0:
		_attack_cooldown -= delta

	if is_attacking or is_rolling or is_parrying or is_drinking or is_casting:
		if _current_anim_player:
			_current_anim_player.speed_scale = 1.0

	# Advance the parry attempt — active frames then recovery, then done.
	if is_parrying:
		_parry_timer += delta
		if _parry_timer >= PARRY_TOTAL:
			is_parrying = false

	# Advance the estus channel — heal lands when the timer empties.
	if is_drinking:
		_drink_timer -= delta
		if _drink_timer <= 0.0:
			_finish_estus()

	# Guard state, reconciled with the actual button (see _input).
	_update_block_state()

	# Feed blocking state to the stamina component so regen halves.
	if _stamina != null:
		_stamina.blocking = is_blocking
		_stamina.committed = is_attacking or is_rolling or is_parrying \
				or is_drinking or is_casting

	# Track player position with SimpleGrass so blades bend away as we walk.
	var sgt_singleton := get_node_or_null("/root/SimpleGrass")
	if sgt_singleton and sgt_singleton.has_method("set_player_position"):
		sgt_singleton.set_player_position(global_position)

	# Update spawn immunity timer
	if _spawn_immunity_timer > 0:
		_spawn_immunity_timer -= delta

	# Accumulate or decay the archer damage buff. While at least one
	# BuffAuraArea is touching us, the buff grows; otherwise it decays.
	_update_damage_buff(delta)

	if _dodge_input_buffer > 0.0:
		_dodge_input_buffer = maxf(0.0, _dodge_input_buffer - delta)
		if _dodge_input_buffer > 0.0 and not (is_rolling or _is_stunned or is_parrying) \
				and (not is_attacking or character_class == CharacterClass.ARCHER or _can_cancel_attack()):
			_try_dodge()
	if _attack_input_buffer <= 0.0:
		_combo_clicks_buffered = 0

	# Update sword hitbox timing based on attack animation progress
	if _sword_bone_attachment:
		_attack_hitbox.global_transform = \
				_sword_bone_attachment.global_transform.orthonormalized()
	_update_attack_hitbox_timing()

	# Update bow draw state (time-based progress)
	_update_bow_draw(delta)
	# Fire a buffered attack tap the moment a swing becomes legal.
	if _attack_input_buffer > 0.0:
		_attack_input_buffer -= delta
		if _attack_input_buffer > 0.0 and not is_attacking and _attack_cooldown <= 0.0 \
				and not (is_rolling or is_parrying or is_drinking or is_reviving \
				or is_dead or _is_stunned or is_casting):
			_attack_input_buffer = 0.0
			_do_attack(_buffer_heavy)
	# Crouch: held stance — slower, braced (25% less damage), body lowered.
	#
	# Ctrl is both the crouch key and half the roll chord, so rolling engages
	# the crouch and — because crouch is a HOLD — leaves the character
	# crouched for the whole roll and afterwards, until the hand comes off a
	# key the player is still legitimately holding. Latch it off instead: a
	# roll cancels crouch, and crouch stays cancelled until Ctrl is actually
	# released, so the roll ends standing.
	if is_rolling:
		_crouch_locked_out = true
	elif _crouch_locked_out and not Input.is_action_pressed(&"crouch"):
		_crouch_locked_out = false
	is_crouching = _ai_crouch if ai_driven \
			else (Input.is_action_pressed(&"crouch") and not _crouch_locked_out)
	_update_revive(delta)
	# The loose burst borrows the body only briefly — then locomotion gets
	# it back even though the (long) source clip keeps running underneath.
	if _bow_loose_lock > 0.0:
		_bow_loose_lock -= delta
		if _bow_loose_lock <= 0.0 and character_class == CharacterClass.ARCHER \
				and is_attacking:
			is_attacking = false

	_update_combat_camera(delta)

	# Handle stun/knockback state
	if _is_stunned:
		_stun_timer -= delta
		# Apply knockback velocity directly
		velocity.x = _knockback_velocity.x
		velocity.z = _knockback_velocity.z
		velocity.y += gravity.y * delta
		# Decelerate knockback
		# Softer knockback decay so a Bobba punch carries the Paladin
		# clear of the 2 m attack range before the stun ends, per
		# round-4-not-fun feedback ("just push the hit character away
		# from reach"). Previously 30 m/s² killed the shove too fast.
		_knockback_velocity = _knockback_velocity.move_toward(Vector3.ZERO, 12.0 * delta)
		if _stun_timer <= 0:
			_is_stunned = false
			_knockback_velocity = Vector3.ZERO
		move_and_slide()
		return

	# Update spell effects (flickering light, procedural bolts)
	_update_spell_effects(delta)


	if (not ai_driven and Input.is_action_pressed(&"reset_position")) or global_position.y < -12:
		_spawn_at_tower()
		velocity = Vector3.ZERO
		reset_physics_interpolation()

	velocity += gravity * delta

	# Handle jumping
	if is_on_floor():
		if is_jumping:
			is_jumping = false
		# `not just-pressed dodge`: the roll chord is Ctrl+SPACE and jump is
		# SPACE, so every roll is also a jump press as far as the input map
		# is concerned. `not is_rolling` covers a roll that happens; this
		# covers one that is REFUSED — out of stamina, mid-swing, airborne —
		# where the jump would otherwise fire in its place and the button
		# would feel like it did something random.
		# A jump cancels the swing too, on the same reasoning as the roll: it is
		# the other way out of a decision that has stopped being a good one.
		if not ai_driven and Input.is_action_just_pressed(&"jump") and is_attacking \
				and not is_rolling and not is_reviving \
				and not Input.is_action_just_pressed(&"dodge") and _can_cancel_attack():
			_cancel_attack_for("jump")
		if not ai_driven and Input.is_action_just_pressed(&"jump") and not is_attacking \
				and not is_rolling and not is_reviving and not is_casting \
				and not is_drinking and not is_parrying and not is_dead \
				and not Input.is_action_just_pressed(&"dodge"):
			velocity.y = JUMP_VELOCITY
			is_jumping = true
			Sfx.play3d("jump", global_position, -5.0)
			# Forward jump: if the player is holding a movement direction,
			# the takeoff launches in that direction. Lets jump serve as
			# a quick horizontal dodge away from Bobba's strikes instead
			# of a pure up/down platformer move.
			var raw: Vector2 = Input.get_vector(&"move_left", &"move_right",
					&"move_forward", &"move_back", 0.15)
			if raw.length() > 0.15:
				var raw_n: Vector2 = raw.normalized()
				# Convert local input into world direction using the camera yaw.
				var cam_yaw: float = _camera_pivot.rotation.y
				var fwd := Vector3.FORWARD.rotated(Vector3.UP, cam_yaw)
				var rt := Vector3.RIGHT.rotated(Vector3.UP, cam_yaw)
				var world_dir := (fwd * -raw_n.y + rt * raw_n.x).normalized()
				velocity.x = world_dir.x * JUMP_FORWARD_BOOST
				velocity.z = world_dir.z * JUMP_FORWARD_BOOST

	# Get movement input with analog stick support (includes touch joystick)
	# Don't normalize yet - we need the raw length to determine run vs walk
	var input_dir_raw := _ai_move_vec if ai_driven \
			else Input.get_vector(&"move_left", &"move_right", &"move_forward", &"move_back", 0.15)
	# Reviving roots the medic and casting roots the caster: no walking
	# mid-channel. The camera is untouched — you can look around, just not
	# leave. Crouching halves pace.
	if is_reviving or is_casting:
		input_dir_raw = Vector2.ZERO
	elif is_crouching:
		input_dir_raw *= CROUCH_SPEED_MULT
	var input_dir := input_dir_raw

	# Sprint requires Shift or L3. Touch retains an outer-stick sprint zone.
	# Keyboard sprint only counts while the game window owns the mouse — but
	# the headless display server can't capture at all (set_mouse_mode is a
	# no-op there), which would permanently veto sprint in automated
	# scenarios. Treat headless as "captured".
	var mouse_owned := CloudInput.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED \
			or DisplayServer.get_name() == "headless"
	var keyboard_run := _ai_run if ai_driven \
			else (Input.is_action_pressed(&"run") if mouse_owned else false)

	var touch_run := OS.get_name() in ["Android", "iOS"] \
			and _lock_target == null and input_dir_raw.length() > 0.8
	is_running = keyboard_run or touch_run
	if not is_running or (_stamina and _stamina.current_stamina >= 24.0):
		_sprint_exhausted = false
	is_running = is_running and not _sprint_exhausted and not is_crouching \
			and not is_blocking and not is_attacking and not is_drinking
	if is_running and is_on_floor() and input_dir.length() > 0.1 and _stamina:
		if not _stamina.try_spend(SPRINT_DRAIN * delta):
			_sprint_exhausted = true
			is_running = false

	var current_max_speed: float = RUN_SPEED if is_running else WALK_SPEED
	var horizontal_velocity := Vector3(velocity.x, 0, velocity.z)

	# Normalize input direction for consistent movement
	input_dir = input_dir.limit_length(1.0)

	# Reduce movement speed while attacking, parrying, or drinking estus
	if is_attacking:
		input_dir *= 0.65 if _can_cancel_attack() else 0.2
	elif is_parrying or is_drinking:
		input_dir *= 0.18
	elif is_blocking:
		input_dir *= 0.48

	# Convert to world direction based on camera yaw
	var cam_yaw: float = _camera_pivot.rotation.y
	var forward := Vector3.FORWARD.rotated(Vector3.UP, cam_yaw)
	var right := Vector3.RIGHT.rotated(Vector3.UP, cam_yaw)

	var movement_direction := forward * -input_dir.y + right * input_dir.x

	if is_rolling:
		# Committed dash along the locked roll direction with an ease-out;
		# movement input is ignored for the duration. Tick the roll clock here.
		_roll_timer -= delta
		var roll_t: float = clampf(_roll_timer / ROLL_DURATION, 0.0, 1.0)  # 1 → 0
		var roll_speed: float = ROLL_SPEED * (0.25 + 0.75 * roll_t)
		horizontal_velocity = _roll_dir * roll_speed
		if _roll_timer <= 0.0:
			is_rolling = false
	elif is_attacking and is_on_floor() and combat_mode == CombatMode.ARMED \
			and character_class == CharacterClass.PALADIN:
		# Combo lunge: the swing carries the character forward, front-loaded
		# into the first half of the clip. This is the sword's extra reach —
		# the blade still has to visually connect.
		var lunge_t: float = sin(clampf(_attack_anim_progress / 0.58, 0.0, 1.0) * PI)
		horizontal_velocity = _attack_lunge_dir * COMBO_LUNGE_SPEED[_combo_step] * lunge_t
		if _can_cancel_attack():
			horizontal_velocity += movement_direction * WALK_SPEED
	elif is_on_floor():
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

	# Free movement follows the stick; guard and lock-on keep strafing available.
	var strafing := _lock_target != null or is_blocking or is_parrying \
			or character_class == CharacterClass.ARCHER
	if _character_model:
		var mesh_target_rotation: float = _character_model.rotation.y
		if strafing:
			mesh_target_rotation = _camera_pivot.rotation.y + PI
		elif movement_direction.length() > 0.1:
			mesh_target_rotation = atan2(movement_direction.x, movement_direction.z)
		if is_attacking and _attack_lunge_dir.length() > 0.1:
			mesh_target_rotation = atan2(_attack_lunge_dir.x, _attack_lunge_dir.z)
		elif is_rolling and _roll_faces_dir:
			mesh_target_rotation = atan2(_roll_dir.x, _roll_dir.z)
		_character_model.rotation.y = lerp_angle(_character_model.rotation.y,
				mesh_target_rotation, minf(18.0 * delta, 1.0))

	velocity = horizontal_velocity + Vector3.UP * velocity.y

	move_and_slide()

	# Footstep cadence — tick based on actual horizontal speed after
	# move_and_slide() resolved. Faster movement = tighter interval.
	_tick_footstep_timer(delta)

	# FIFO mode: send state to server and apply server-confirmed position
	if enable_fifo and _fifo_connected:
		_fifo_send_state()
		# Apply server-confirmed position (pure server-authoritative)
		global_position = _fifo_server_position

	# Update animation based on movement state
	_update_animation(input_dir if strafing else Vector2(0, -input_dir.length()))
