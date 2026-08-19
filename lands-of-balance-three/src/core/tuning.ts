/**
 * Every gameplay number in the game, lifted verbatim from the Godot build.
 *
 * Each block cites the GDScript file it came from so the two builds can be
 * diffed by eye. Nothing here should be "tuned for the web" — when the
 * Godot game changes a constant, change it here and the port follows.
 *
 * Coordinate conventions match Godot exactly (right-handed, Y up, -Z
 * forward, +Y rotations right-handed), so vector maths ports 1:1.
 */

// ── player/player.gd — locomotion ───────────────────────────────────────
export const WALK_SPEED = 3.5
export const RUN_SPEED = 7.0
export const ACCEL = 12.0
export const DEACCEL = 12.0
export const JUMP_VELOCITY = 6.0
export const JUMP_FORWARD_BOOST = 5.5
export const GRAVITY = 22.0 // project.godot physics/3d/default_gravity, along -Y
export const CROUCH_SPEED_MULT = 0.5
export const CROUCH_DAMAGE_MULT = 0.75
export const AERIAL_DAMAGE_MULT = 0.5
export const RUN_THRESHOLD = 0.6

// ── player/player.gd — camera ───────────────────────────────────────────
export const DEFAULT_SPRING_LENGTH = 4.2
export const DEFAULT_CAMERA_FOV = 55.0
export const AIM_ZOOM_SPRING = 1.7
export const AIM_ZOOM_FOV = 44.0
export const MOUSE_SENSITIVITY = 0.002
export const GAMEPAD_SENSITIVITY = 2.5
export const CAMERA_VERTICAL_LIMIT = 85.0 // degrees

// ── player/player.gd — melee combo chain ────────────────────────────────
export const COMBO_ANIMS = ['SwordSlash', 'Attack1', 'Attack2'] as const
export const COMBO_DAMAGE_MULT = [0.9, 1.0, 1.35]
export const COMBO_POISE_DAMAGE = [30.0, 35.0, 60.0]
export const COMBO_KNOCKBACK = [8.0, 9.0, 16.0]
export const COMBO_LUNGE_SPEED = [3.5, 4.0, 6.5]
export const COMBO_ANIM_SPEEDS = [1.25, 1.25, 0.95]
export const COMBO_CHAIN_POINT = 0.6
export const COMBO_CHAIN_STAMINA_COST = 15.0
export const COMBO_FINISHER_COOLDOWN = 0.45
export const COMBO_CLICK_WINDOW = 0.5
export const ATTACK_BUFFER_TIME = 0.35
export const COMBO_TRAIL_COLOR = 0xffe68c
export const COMBO_TRAIL_COLOR_FINISHER = 0xffbf59

// ── player/player.gd — lock-on ──────────────────────────────────────────
export const LOCK_ON_RANGE = 22.0
export const LOCK_ON_BREAK_RANGE = 30.0
export const LOCK_ON_ACQUIRE_HALF_ANGLE = 75.0 // degrees
export const LOCK_ON_PITCH_DEG = -10.0
export const LOCK_ON_TURN_SPEED = 12.0

// ── player/player.gd — dodge roll ───────────────────────────────────────
export const ROLL_SPEED = 9.0
export const ROLL_DURATION = 0.5
export const ROLL_IFRAME_START = 0.06
export const ROLL_IFRAME_END = 0.4
export const ROLL_STAMINA_COST = 22.0

// ── player/player.gd — parry / block / crits ────────────────────────────
export const PARRY_TOTAL = 0.65
export const PARRY_WINDOW_START = 0.05
export const PARRY_WINDOW_END = 0.38
export const PARRY_STAMINA_COST = 12.0
export const BLOCK_CHIP_MULT_WEAPON = 0.15
export const BLOCK_CHIP_MULT_BLUNT = 0.3
export const RIPOSTE_DAMAGE_MULT = 3.0
export const BACKSTAB_DAMAGE_MULT = 2.0
export const BACKSTAB_CONE_DOT = -0.45

// ── player/player.gd — estus ────────────────────────────────────────────
export const ESTUS_MAX_CHARGES = 3
export const ESTUS_DRINK_DURATION = 1.1
export const ESTUS_HEAL_PCT = 0.45

// ── player/player.gd — bow ──────────────────────────────────────────────
export const BOW_DRAW_TIME_REQUIRED = 0.3
export const BOW_LOOSE_LOCK = 0.65

// ── player/player.gd — damage / health ──────────────────────────────────
export const PLAYER_ATTACK_DAMAGE = 15.0
export const PLAYER_KNOCKBACK_FORCE = 10.0
export const PLAYER_KNOCKBACK_RESISTANCE = 0.8
export const KNIGHT_SWORD_DAMAGE = 100.0
export const SWORD_STAMINA_COST = 25.0
export const STUN_DURATION = 0.333
export const PALADIN_MAX_HP = 150.0
export const ARCHER_MAX_HP = 100.0
export const DAMAGE_BUFF_MAX_PCT = 0.5
export const SWORD_HITBOX_START = 0.15
export const SWORD_HITBOX_END = 0.95
export const SPAWN_IMMUNITY_DURATION = 2.0
export const SWORD_REACH = 2.6 // world length of the armed hitbox sweep
export const SWORD_HALF_ANGLE = 60.0 // degrees either side of the lunge dir

// ── combat/stamina_component.gd ─────────────────────────────────────────
export const STAMINA_MAX = 100.0
export const STAMINA_RECOVER_RATE = 30.0
export const STAMINA_RECOVER_DELAY = 0.6
export const STAMINA_BLOCK_REGEN_MODIFIER = 0.35

// ── combat/poise_component.gd ───────────────────────────────────────────
export const POISE_MAX = 100.0
export const POISE_RECOVER_DELAY = 3.0
export const POISE_RECOVER_RATE = 15.0
export const POISE_STAGGER_WINDOW = 3.0
export const POISE_MAX_CONSECUTIVE_STAGGERS = 3
export const POISE_UNSTOPPABLE_DURATION = 2.0

// ── combat/perception.gd ────────────────────────────────────────────────
export const FIRE_REVEAL_RADIUS = 12.0
export const ARROW_REVEAL_RADIUS = 5.0
export const MOON_REVEAL_RADIUS = 25.0
export const DAY_REVEAL_RADIUS = 120.0
export const FIRE_SIGHT_RADIUS = 90.0

// ── player/arrow.gd ─────────────────────────────────────────────────────
export const ARROW_SPEED = 50.0
export const ARROW_LIFETIME = 10.0
export const ARROW_DIRECT_HIT_DAMAGE_PCT = 0.05
export const ARROW_AIRBORNE_SHOT_DAMAGE_MULT = 0.5
export const GROUND_FIRE_DAMAGE_PCT_PER_SEC = 0.05
export const GROUND_FIRE_RADIUS = 5.0
export const GROUND_FIRE_LIFETIME = 30.0

// ── enemies/skeleton.gd ─────────────────────────────────────────────────
export const SKEL_MAX_HP = 180.0
export const SKEL_ATTACK_DAMAGE = 16.0
export const SKEL_AGGRO_RANGE = 50.0
export const SKEL_WALK_SPEED = 2.0
export const SKEL_RUN_SPEED = 4.6
export const SKEL_ATTACK_RANGE = 1.9
export const SKEL_ATTACK_HIT_RANGE = 2.4
export const SKEL_ATTACK_LEN = 1.0
export const SKEL_ATTACK_HIT_TIME = 0.5
export const SKEL_SEPARATION_DIST = 1.6
export const SKEL_FIRE_AVOID_DIST = 7.0
export const SKEL_FIRE_HURT_DIST = 4.0
export const SKEL_FIRE_DPS = 26.0
export const SKEL_BURN_DPS = 14.0
export const SKEL_MODEL_SCALE = 0.53

// ── enemies/skeleton_crew.gd ────────────────────────────────────────────
export const CREW_PACK_SIZE = 5
export const CREW_HAUNT_MIN_DIST = 25.0
export const CREW_HAUNT_MAX_DIST = 40.0
export const CREW_CLUSTER_RADIUS = 5.0
export const CREW_REVIVE_SECONDS = 20.0
export const CREW_REVIVE_SCATTER_MIN = 8.0
export const CREW_REVIVE_SCATTER_MAX = 22.0

// ── enemies/bobba.gd ────────────────────────────────────────────────────
export const BOBBA_MAX_HEALTH = 1000.0
export const BOBBA_ROAM_SPEED = 2.0
export const BOBBA_CHASE_SPEED = 5.0
export const BOBBA_RETREAT_SPEED = 3.0
export const BOBBA_DETECTION_RADIUS = 10.0
export const BOBBA_LOSE_RADIUS = 50.0
export const BOBBA_FLEE_HP_FRACTION = 0.22
export const BOBBA_REGEN_DELAY = 5.0
export const BOBBA_REGEN_PCT_PER_SEC = 0.03
export const BOBBA_ATTACK_DISTANCE = 2.0
export const BOBBA_ATTACK_DAMAGE = 65.0
export const BOBBA_ARROW_DAMAGE = 1.0
export const BOBBA_SWORD_DAMAGE = 50.0
export const BOBBA_SWORD_POISE_DAMAGE = 35.0
export const BOBBA_KNOCKBACK_FORCE = 22.0
export const BOBBA_ROAM_CHANGE_TIME = 3.0
export const BOBBA_ROTATION_SPEED = 5.0
export const BOBBA_BLOCK_DURATION = 0.8
export const BOBBA_BLOCK_CHECK_INTERVAL = 1.5
export const BOBBA_BLOCK_CHANCE = 0.4
export const BOBBA_RETREAT_DURATION = 2.0
export const BOBBA_FIRE_AVOID_RADIUS = 5.0
export const BOBBA_FIRE_PANIC_RADIUS = 2.5
export const BOBBA_ATTACK_LEN = 1.2
export const BOBBA_HAND_HITBOX_START = 0.3
export const BOBBA_HAND_HITBOX_END = 0.7
export const BOBBA_RIPOSTE_WINDOW = 2.5 // staggered-open time after a parry

// ── ui/minimap.gd ───────────────────────────────────────────────────────
export const MAP_MIN = { x: -150, z: -150 }
export const MAP_MAX = { x: 150, z: 150 }
export const LANDMARKS: Record<string, [number, number]> = {
  'Village of Eights': [0, 0],
  'Common Ground': [0, 70],
  'Tower of Hakutnas': [-80, -60],
  'Realm of Hudson': [80, -50],
  'The Hills': [-30, 20],
  'The Burning Peaks': [-120, 0],
  'The Silent Woods': [120, 0],
  'Fire Creature Lair': [-115, 5],
  'Silent Creature Lair': [120, 1],
  Fields: [60, -35],
}

// ── player/player.gd — SPAWN_POINTS ─────────────────────────────────────
export const SPAWN_POINTS: [number, number, number][] = [
  [0, 1, 10],
  [-80, 1, -60],
  [80, 1, -50],
  [0, 1, 70],
]
