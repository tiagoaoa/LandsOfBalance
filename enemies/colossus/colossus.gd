class_name ColossusBoss
extends Node3D

## Ssethrak fights across the platform rim with claws, grabs and its skull;
## an iron muzzle locks its jaw. The paladin parries and punishes grounded
## hands and the grounded skull; the archer covers grab rescues and keeps
## the braziers lit.
## A stagger lowers the head and leaves both hands vulnerable. The supplied
## reptilian has no chest core. Legacy bodies remain explicit dev overrides.
## Skin poses and hitboxes share the same two-bone arm IK pivots.

signal died
signal phase_changed(phase: int)
## Everything the arena counts for the match report (and the HUD banners).
signal combat_event(kind: String, data: Dictionary)

const COLOSSUS_NAME := "VAELGOR, THE CHAINED COLOSSUS"
const LIZARD_NAME := "SSETHRAK, THE CHAINED LIZARD-KING"
const COLOSSUS_PATH := "res://assets/characters/colossus/colossus.glb"
const LIZARD_PATH := "res://assets/characters/lizard/lizard_reference.glb"
const DRAGON_NAME := "KHARVAEL, THE ASHEN DREAD"
## The stage boss is a bipedal lizard man. Other bodies require an explicit override.
var model_kind: String = _pick_model()
var display_name: String = {"dragon": DRAGON_NAME, "lizard": LIZARD_NAME,
		"reptilian": LIZARD_NAME}.get(model_kind, COLOSSUS_NAME)
## The skinned wyvern (dragon mode): builds the pivots, drives the bones.
var rig: DragonRig
var reptile: ReptilianRig
var _punch_hold := 0.0
var _punch_wrist := Vector3.ZERO
var _punch_basis := Basis.IDENTITY
var _punch_sink := 0.0
var _terrain: RefCounted
var _terrain_back := 0.0
var _withdraw := 0.0
var _arm_stopped := [false, false]
var _safe_wrist := [Vector3.ZERO, Vector3.ZERO]
var _safe_basis := [Basis.IDENTITY, Basis.IDENTITY]
var _arm_pose := [{}, {}]
var _pending_slam := -1
var _pending_sweep: Array = []
var _brace_from := Vector3.ZERO
var _brace_basis := Basis.IDENTITY


static func _pick_model() -> String:
	var want := OS.get_environment("LOB_BOSS_MODEL")
	if want == "colossus":
		return "colossus"
	if want == "dragon" and DragonRig.available():
		return "dragon"
	if want != "lizard" and ResourceLoader.exists(ReptilianRig.path()):
		return "reptilian"
	return "lizard" if ResourceLoader.exists(LIZARD_PATH) else "colossus"

# --- tuning ------------------------------------------------------------------
const MAX_HP := 4700.0
const PHASE2_FRAC := 0.6
const ARMOR_MULT := 0.08          # anything that hits stone/bronze
const HAND_MELEE_MULT := 0.45     # sword on a pinned fist
const HAND_ARROW_MULT := 0.25
const HAND_ARROW_POISE := 0.15    # an arrow's share of poise vs a blade's
const CORE_ARROW_MULT := 2.5
const CORE_MELEE_MULT := 1.5
const HEAD_MELEE_MULT := 1.8
const HEAD_ARROW_MULT := 1.0
const HIDE_MULT := 0.22
const SKULL_MULT := 1.8
const SKULL_OPEN_MULT := 2.5
const CLAW_MELEE_MULT := 0.45
const CLAW_ARROW_MULT := 0.3
const POISE_MAX := 360.0         # ~4 sword hits: a pinned fist and a half, or one and a parry
const POISE_DECAY := 40.0         # per second, after POISE_GRACE without a poise hit
const POISE_GRACE := 3.0
const PARRY_POISE := 150.0

const SLAM_WINDUP := 1.15
const SLAM_STRIKE := 0.22
const SLAM_PINNED := 3.2
const SLAM_PINNED_PARRIED := 4.4
const SLAM_RECOVER := 0.8
const PUNCH_OPEN := 4.0
const PUNCH_PARRIED := 5.2
const SLAM_RADIUS := 2.6
## The reptile's downward punch covers the platform from the near rim to its
## centre, wherever around the rim it stands. The body alone cannot carry it
## there: any lunge, rise and lean that brings a shoulder within arm's length
## of the centre drives the spine and chest through the platform's side, its
## ramps or a pillar. So a far blow rears the body up, slides it in and leans
## out over the rim as far as the stone allows (the terrain guard still has the
## last word), and the arm uncoils the rest of the way.
const SLAM_LUNGE := 1.6          # metres (x sz) the body may slide in
const SLAM_RISE := 3.0           # metres (x sz) it rears up to clear the rim
const SLAM_LEAN_FAR := 28.0      # degrees of lean on a full-reach punch
const REPTILE_LEAN_CAP := 10.0   # degrees, every other act
const ARM_STRETCH_MAX := 1.4     # upper arm + forearm, never the claw
const SLAM_FAR_SPAN := 6.0       # metres (x sz) past the arm for a full-reach blow
## A far punch is an overhead hammer blow, not a jab along the floor: the
## elbow arches high (a straight arm from beyond the rim to the centre ran
## through the towers and ramps at head height) and the claw drops steeply.
const SLAM_ARCH := 0.12          # extra length that buys the elbow its arch
## The forearm only lengthens a little: skin at the wrist is partly weighted
## to it, and a stretched forearm dragged those vertices past the wrist and
## into the stone on a steep blow. The upper arm, bending in the air, takes
## the rest of the length.
const FOREARM_STRETCH_MAX := 1.1
const SLAM_DAMAGE := 45.0
const SLAM_KNOCK := 4.0         # knocks you DOWN, not across the arena

const SWEEP_WINDUP := 1.45
const SWEEP_TIME := 0.8
const SWEEP_RECOVER := 1.9
const SWEEP_REST := 1.8            # the arm lies on the rim after a sweep, bare
const SWEEP_ARC := deg_to_rad(75.0)   # each side of straight ahead
## Feet above this (a jump, the stump, a perch) = clear. A player jump only
## lifts the feet ~0.8 m, so this is set where a well-timed hop clears it.
const SWEEP_CLEAR_Y := 0.45
const SWEEP_DAMAGE := 35.0
const SWEEP_KNOCK := 7.0
const COVER_DIST := 2.3               # a raised shield this close upstream covers you

const GRAB_WINDUP := 1.05
const GRAB_REACH := 0.3
const GRAB_HOLD := 4.6
const GRAB_THROW := 0.7
const GRAB_MISS_PINNED := 1.6
const GRAB_RADIUS := 1.7
const GRAB_SQUEEZE_DPS := 9.0
const RESCUE_DAMAGE := 70.0
const GRAB_COOLDOWN := 26.0

const ROAR_WINDUP := 1.2
const ROAR_RECOVER := 1.1
const ROAR_DAMAGE := 10.0
const ROAR_KNOCK := 10.0

const GAZE_CHARGE := 2.2
const GAZE_BEAM := 1.5
const GAZE_RECOVER := 0.9
const GAZE_DAMAGE := 28.0
const GAZE_INTERRUPT := 35.0      # one solid arrow in the eye
const GAZE_COOLDOWN := 18.0

const STAGGER_TIME := 6.5

## It does not stand in one place: every so often it WADES through the mist
## to another side of the platform — the perches, the safe corners and the
## angle of every attack change with it.
const SHIFT_TIME := 6.6
const SHIFT_SINK := 4.0
const SHIFT_COOLDOWN := Vector2(20.0, 30.0)

## Climbing it (Shadow of the Colossus / God of War): from a pinned fist a
## player can scramble up the forearm onto a SHOULDER LEDGE that carries them.
## Up there the head is in sword reach. It answers with a telegraphed SHAKE —
## crouch to cling, or be flung back onto the platform.
const CLIMB_SPEED := 2.8
const CLIMB_REACH := 2.3           # how close to a pinned fist you must be
const HEAD_MOUNT_MULT := 1.0       # sword on the head from its shoulder
const HEAD_MOUNT_POISE := 0.6
const SHAKE_WINDUP := 0.9
## The muzzled reptile's head is a weapon, not a mouth: it rears the helmeted
## skull up and back, then drives it down onto a marked spot. The iron lock
## under the chin leads; the skull stays down on the stone a while after, a
## punish window as rich as a grounded claw's.
const HEAD_WINDUP := 1.4
const HEAD_STRIKE := 0.26
const HEAD_DOWN := 2.6
const HEAD_RECOVER := 1.0
const HEAD_RADIUS := 2.4          # telegraph ring (x sz)
const HEAD_DAMAGE := 60.0
const HEAD_KNOCK := 6.0
const HEAD_COOLDOWN := 7.0
const HEAD_LEAN := 24.0           # degrees of torso lean behind the blow
const HEAD_SINK := 1.2            # metres (x sz) the body drops into it
const HEAD_REACH := 12.0          # flat metres (x sz) from the boss's anchor
## Braziers: what knocks them out, and how far.
const DOUSE_SLAM := 4.5
const DOUSE_HEAD := 5.5
const DOUSE_CLAW := 2.4
const DOUSE_ROAR := 9.0
const SHAKE_TIME := 1.5
const SHAKE_AFTER := Vector2(3.0, 4.5)   # seconds a rider gets before it reacts
const SHAKE_DAMAGE := 15.0
const FLINCH_TIME := 4.0           # a rescue or an interrupted gaze
const RISE_TIME := 1.5

# --- skeleton dimensions (match tools/build_colossus.py) ----------------------
const UPPER := 6.5
const FORE := 6.0
var FIST := 1.3                    # wrist -> claw contact centre
const FIST_HALF_THICK := 0.9

enum Act { IDLE, SLAM, SWEEP, GRAB, ROAR, GAZE, STAGGER, RELOCATE, DEAD, SHIFT, SHAKE, TAIL, HEAD_SLAM }

## The legacy bodies' answer to "stand where the fists cannot reach": a
## TAIL LASH that rakes the far band of the platform. (No acid anywhere.)
const TAIL_WINDUP := 1.5
const TAIL_TIME := 0.9
const TAIL_RECOVER := 1.0
const TAIL_DAMAGE := 30.0
## Plunging strike: fall at least this far with the blade out onto a fist.
const PLUNGE_MIN_DROP := 2.2
const PLUNGE_DAMAGE := 170.0
const PLUNGE_POISE := 220.0
## Hunter's Mark: arrow (or blade) on a marked weak point.
const MARK_MULT := 2.0
const MARK_POISE := 0.6

var arena: Node = null             # BossArena: platform geometry + party
## How big it stands (the arena sets it before adding it): 1.0 = the original
## colossus. Every world-space length below is multiplied by it.
var sz := 1.0
var hp := MAX_HP
var phase := 1
var act: int = Act.IDLE
var act_t := 0.0                   # seconds into the current act
var act_len := 1.5
var act_serial := 0                # bumps on every new act: "is this the same swing?"
var poise := 0.0
var _poise_quiet := 0.0

# Parts (pivot nodes), index 0 = left, 1 = right.
var _torso: Node3D
var _head: Node3D
var _eye: Node3D
var _core: Node3D
var _shutters: Array[Node3D] = []
## Shutter yaw (radians) when the core is shut / bare, per shutter. The
## Blender model rests OPEN (blinkers out); the grey-box rests closed.
var _shutter_shut: Array[float] = []
var _shutter_bare: Array[float] = []
var _ua: Array[Node3D] = [null, null]
var _fa: Array[Node3D] = [null, null]
var _hand: Array[Node3D] = [null, null]
var _hand_body: Array[ColossusPart] = [null, null]
var _lip: ColossusPart
var _tail: Node3D
var _jaw: Node3D
var _tail_rest: Transform3D
var _jaw_open := 0.0
var _jaw_goal := 0.0
var _ember_mats: Array[StandardMaterial3D] = []
var _eye_mat: StandardMaterial3D
var _core_mat: StandardMaterial3D

# Per-arm pose state (world space).
var _wrist: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var _hand_basis: Array[Basis] = [Basis.IDENTITY, Basis.IDENTITY]
var _pinned_left: Array[float] = [0.0, 0.0]   # seconds a fist stays pinned + vulnerable

# Body pose (applied to the torso pivot).
var _lean := 0.0       # forward pitch, radians
var _twist := 0.0
var _legs: Array[Node3D] = []
var _shins: Array[Node3D] = []
var _sink := 0.0       # metres below rest
var _lean_goal := deg_to_rad(18.0)
var _sink_goal := 0.0
var _rest_torso: Transform3D
var _rest_head: Transform3D
var _anchor_angle := 0.0           # where around the platform it stands (radians)
var _anchor_goal := 0.0
var _lunge := 0.0                  # metres the body has slid in toward the centre
var _lunge_goal := 0.0
var _slam_far := 0.0               # 0 = punch within the arm, 1 = at the centre
## How far each arm is uncoiled past its rest length (1 = rest). The rig
## stretches the upper-arm and forearm bones along their length to match.
var arm_stretch: Array[float] = [1.0, 1.0]
var _arm_len: Array[Vector2] = [Vector2.ZERO, Vector2.ZERO]   # rest upper, fore (local)

# Act data.
var _hand_i := 0                   # the acting hand
var _slam_windup := SLAM_WINDUP    # shorter on a chained follow-up
var _strike_from := Vector3.ZERO
var _strike_basis := Basis.IDENTITY
var _strike_captured := false
var _reach_checks: Array[Dictionary] = []
var _sweep_lift_from := Vector3.ZERO
var _sweep_lift_basis := Basis.IDENTITY
var _chained := false
var _target := Vector3.ZERO        # slam point / grab point
var _victim: Node3D = null
var _sweep_dir := 1.0
## Phase 2 alternates: a LOW sweep (hop it, or stand high) and a HIGH one at
## chest height that jumping and the perches do not escape — you duck it.
## High ground beat 39 of 47 sweeps before this; now the read is the skill.
var _sweep_high := false
var _sweep_from := 0.0
var _sweep_to := 0.0
var _sweep_prev := 0.0
var _swept: Array = []             # bodies already hit by this sweep / beam / roar
var _beam_covered: Array = []      # ...and those the pillars hid from this beam
var _struck := false
var _rescue_dmg := 0.0
var _eye_dmg := 0.0
var _beam_from := Vector3.ZERO
var _beam_to := Vector3.ZERO
var _core_open := false
var _head_open := false
var _head_cd := 4.0
var _head_from := Transform3D()     # the skull's global pose when the blow began
var _head_down_at := Transform3D()  # where it came to rest on the stone (local)
var _head_victim: Node3D = null
var _nostrils: Array[GPUParticles3D] = []
var _breath_t := 0.0
var _return_t := [-1.0, -1.0]
var _return_from := [Vector3.ZERO, Vector3.ZERO]
var _return_basis := [Basis.IDENTITY, Basis.IDENTITY]
var _grab_cd := 12.0
var _shift_cd := 18.0
var _shift_from := 0.0
var _shift_to := 0.0
var _pads: Array[AnimatableBody3D] = []
var _climbing := {}                 #Player -> surface anchor, normal, arm and progress
var _ride_total := 0.0
var _roll := 0.0
var _climb_surface: RefCounted
var _dropped_until := {}
var _ride_t := 0.0                  # how long anyone has been riding it
var _shake_due := 4.0
var _grace := 0.0                   # a breath after someone goes down
var _gaze_cd := 8.0
var _last_acts: Array = []
var _idle_len := 2.0

# Telegraph visuals (top-level, in the arena's space).
var _fx_ring: MeshInstance3D
var _fx_ring_fill: MeshInstance3D
var _fx_sweep: MeshInstance3D
var _fx_beam: MeshInstance3D
var _fx_ring_mat: StandardMaterial3D
var _fx_fill_mat: StandardMaterial3D
var _fx_sweep_mat: StandardMaterial3D
var _fx_beam_mat: StandardMaterial3D
var _voice: AudioStreamPlayer3D


func _ready() -> void:
	scale = Vector3.ONE * sz
	add_to_group("colossus")
	process_physics_priority = 50   # after the players: a held victim stays held
	_build_body()
	if _skin:
		_climb_surface = preload("res://enemies/colossus/climb_surface.gd").new(_skin)
	_build_fx()
	if reptile:
		# Muzzled: no acid. Its breath comes out of the nostrils as smoke.
		_build_boss_fog()
		_build_breath()
		_build_firelight()
	var rim := SpotLight3D.new()
	rim.name = "BackRim"
	rim.light_color = Color(0.78, 0.82, 0.84) if model_kind == "lizard" else Color(0.6, 0.72, 1.0)
	# The reptile fights in fire-light: only a ghost of an outline from behind.
	rim.light_energy = 1.4 if reptile else 6.0
	rim.spot_range = 40.0
	rim.spot_angle = 38.0
	rim.position = Vector3(0, 20.0, -12.0)
	rim.rotation_degrees = Vector3(-35.0, 180.0, 0.0)
	add_child(rim)
	if rig:
		rim.light_energy = 14.0
		rim.spot_range = 70.0
		rim.spot_angle = 50.0
		rim.position = Vector3(0, 30.0, -16.0)
		# Moonlight on its face and chest, from high over the platform: a
		# black dragon at night needs a key light the wet scales can catch.
		var key := SpotLight3D.new()
		key.name = "MoonKey"
		key.light_color = Color(0.62, 0.72, 1.0)
		key.light_energy = 7.0
		key.spot_range = 90.0
		key.spot_angle = 34.0
		key.spot_attenuation = 0.6
		add_child(key)
		key.position = Vector3(16.0, 34.0, 34.0)
		key.look_at(to_global(Vector3(0, 11.0, 2.0)), Vector3.UP)
		_build_dragon_fire()
	_build_chains()
	_rest_torso = _torso.transform
	_rest_head = _head.transform
	if _tail:
		_tail_rest = _tail.transform
	for i in 2:
		_wrist[i] = _idle_wrist(i)
		_hand_basis[i] = _grip_basis(i)
	_voice = AudioStreamPlayer3D.new()
	_voice.max_distance = 200.0
	_voice.unit_size = 30.0
	add_child(_voice)
	_start(Act.IDLE, 3.0)
	_place_on_anchor(true)


# ============================================================ public API ====

func hp_frac() -> float:
	return hp / MAX_HP


func is_dead() -> bool:
	return act == Act.DEAD


func act_name() -> String:
	return Act.keys()[act]


func core_open() -> bool:
	if reptile:
		return false
	return _core_open or (hp_frac() < 0.18 and act == Act.IDLE and phase >= 1)


func core_pos() -> Vector3:
	return _core.global_position


func head_open() -> bool:
	return _head_open or punch_open() or head_down()


## The skull lies on the stone after a head slam: the knight's best opening.
func head_down() -> bool:
	return reptile != null and act == Act.HEAD_SLAM and _struck \
			and act_t < HEAD_WINDUP + HEAD_STRIKE + HEAD_DOWN


func punch_open() -> bool:
	return reptile != null and act == Act.SLAM and _struck \
			and act_t < _punch_hold and _pinned_left[_hand_i] > 0.0


func head_pos() -> Vector3:
	if reptile:
		return _head.global_transform * reptile.head_center
	if rig:
		return _head.global_transform * rig.head_center
	return _head.global_position + _head.global_basis.y * 1.4


func eye_pos() -> Vector3:
	return _eye.global_position


func mouth_pos() -> Vector3:
	return reptile.mouth.global_position if reptile else eye_pos()


## The reptile's jaw is locked in an iron muzzle: there is no open mouth to
## shoot into any more.
func mouth_open() -> bool:
	return false


## Charging its gaze: the only moment an arrow in the eye does anything.
func eye_charging() -> bool:
	return act == Act.GAZE and act_t < GAZE_CHARGE


func grab_victim() -> Node3D:
	return _victim if act == Act.GRAB and act_t >= GRAB_WINDUP + GRAB_REACH \
			and act_t < GRAB_WINDUP + GRAB_REACH + _grab_hold() + _struggle else null


## The fist braced on the platform while the other one holds a victim.
func brace_hand_pos() -> Vector3:
	return fist_pos(1 - _hand_i) if grab_victim() != null else Vector3.INF


## Fists that are down on the platform with their embers bare.
func pinned_fists() -> Array[Vector3]:
	var out: Array[Vector3] = []
	for i in 2:
		if _pinned_left[i] > 0.0:
			out.append(fist_pos(i))
	return out


func fist_pos(i: int) -> Vector3:
	return _hand[i].to_global(_palm_offset(i))


func _palm_offset(i: int) -> Vector3:
	if reptile and reptile.spec.get("palms_inward", false):
		var p := _hand_body[i].position
		p.z = 0.0
		return p
	return Vector3(0, -FIST, 0)


func _palm_wrist(i: int, at: Vector3, basis: Basis) -> Vector3:
	#The visible palm lies beside the hand bone on the generated titans.
	return at - basis * _palm_offset(i) * sz


## The windup the AI (and a careful human) can read: what is coming, and when.
## {eta, kind, from} for `body`, eta = INF if nothing is aimed at it.
func strike_eta_for(body: Node3D) -> Dictionary:
	var none := {"eta": INF, "kind": "", "from": global_position}
	if body == null or not is_instance_valid(body):
		return none
	var p := body.global_position
	match act:
		Act.SLAM:
			var impact := _slam_windup + SLAM_STRIKE
			if act_t < impact and _flat_dist(p, _target) < (SLAM_RADIUS * sz) + 0.8 \
					and absf(p.y - (_target.y - (FIST_HALF_THICK * sz))) < 2.5:
				return {"eta": impact - act_t, "kind": "slam", "from": _target}
		Act.SWEEP:
			if not _sweep_high and p.y - _floor_y() > SWEEP_CLEAR_Y + 0.6:
				return none
			var phi := _boss_angle(p)
			var t0 := SWEEP_WINDUP
			var frac := (phi - _sweep_from) / (_sweep_to - _sweep_from)
			if frac < 0.0 or frac > 1.0:
				return none
			# The arm eases through the arc (smoothstep), so invert the ease.
			var hit_t := t0 + _unsmooth(frac) * SWEEP_TIME
			if act_t < hit_t:
				return {"eta": hit_t - act_t, "kind": "sweep_high" if _sweep_high else "sweep",
						"from": fist_pos(_hand_i)}
		Act.GRAB:
			var reach := GRAB_WINDUP + GRAB_REACH
			if act_t < reach and _flat_dist(p, _target) < (GRAB_RADIUS * sz) + 1.0:
				return {"eta": reach - act_t, "kind": "grab", "from": _target}
		Act.HEAD_SLAM:
			var land := HEAD_WINDUP + HEAD_STRIKE
			if act_t < land and _flat_dist(p, _target) < (HEAD_RADIUS * sz) + 0.8:
				return {"eta": land - act_t, "kind": "slam", "from": _target}
		Act.ROAR:
			if act_t < ROAR_WINDUP and p.y - _floor_y() < 2.0:
				return {"eta": ROAR_WINDUP - act_t, "kind": "roar", "from": global_position}
		Act.TAIL:
			if p.y - _floor_y() > SWEEP_CLEAR_Y + 0.6 or _flat_dist(p, global_position) < _tail_inner():
				return none
			var phi_t := _boss_angle(p)
			var frac_t := (phi_t - _sweep_from) / (_sweep_to - _sweep_from)
			if frac_t >= 0.0 and frac_t <= 1.0:
				var hit_t := TAIL_WINDUP + _unsmooth(frac_t) * TAIL_TIME
				if act_t < hit_t:
					return {"eta": hit_t - act_t, "kind": "sweep", "from": global_position}
		Act.SHAKE:
			if act_t < SHAKE_WINDUP and (on_pad(body) or is_climbing(body)):
				return {"eta": SHAKE_WINDUP - act_t, "kind": "shake", "from": global_position}
		Act.GAZE:
			if act_t < GAZE_CHARGE + GAZE_BEAM and body not in _swept:
				return {"eta": maxf(0.0, GAZE_CHARGE + 0.4 - act_t), "kind": "gaze",
						"from": eye_pos()}
	return none


## Telegraphed sweep, for the paladin's cover play: {eta, dir} or eta INF.
func sweep_incoming() -> Dictionary:
	if act != Act.SWEEP or act_t >= SWEEP_WINDUP + SWEEP_TIME:
		return {"eta": INF}
	return {"eta": maxf(0.0, SWEEP_WINDUP - act_t), "dir": _sweep_dir,
			"from_angle": _sweep_from, "high": _sweep_high}


## Which side a sweep reaches first: does `a` stand upstream of `b`?
func sweep_reaches_first(a: Vector3, b: Vector3) -> bool:
	return (_boss_angle(a) - _boss_angle(b)) * _sweep_dir < 0.0


## Ground point in the platform's frame at angle `phi` (radians, around the
## boss's axis) — the AI uses it to stand upstream of an ally.
func boss_angle_of(p: Vector3) -> float:
	return _boss_angle(p)


## A ground point at angle `phi` around the colossus's axis, `r` out.
func arc_point(phi: float, r: float, y: float) -> Vector3:
	return _arc_point(phi, r, y)


# ================================================================ loop ======

var _perf := OS.get_environment("LOB_BOSS_PROFILE") == "1"
var _perf_times := {}
var _perf_frames := 0


func _perf_mark(label: String, since: int) -> int:
	if not _perf:
		return 0
	var now := Time.get_ticks_usec()
	_perf_times[label] = int(_perf_times.get(label, 0)) + now - since
	return now


func _physics_process(delta: float) -> void:
	if arena == null:
		return
	var stamp := Time.get_ticks_usec() if _perf else 0
	act_t += delta
	_clock += delta
	_head_shy -= delta
	_grab_cd -= delta
	_gaze_cd -= delta
	for i in 2:
		_pinned_left[i] = maxf(0.0, _pinned_left[i] - delta)
	_poise_quiet += delta
	if act != Act.STAGGER and _poise_quiet > POISE_GRACE:
		poise = maxf(0.0, poise - POISE_DECAY * delta)
	match act:
		Act.IDLE:
			_tick_idle(delta)
		Act.SLAM:
			_tick_slam(delta)
		Act.SWEEP:
			_tick_sweep(delta)
		Act.GRAB:
			_tick_grab(delta)
		Act.ROAR:
			_tick_roar(delta)
		Act.GAZE:
			_tick_gaze(delta)
		Act.STAGGER:
			_tick_stagger(delta)
		Act.RELOCATE:
			_tick_relocate(delta)
		Act.DEAD:
			_tick_dead(delta)
		Act.SHIFT:
			_tick_shift(delta)
		Act.TAIL:
			_tick_tail(delta)
		Act.SHAKE:
			_tick_shake(delta)
		Act.HEAD_SLAM:
			_tick_head_slam(delta)
	_grace -= delta
	_head_cd -= delta
	_shift_cd -= delta
	_tick_riders(delta)
	_tick_plunges()
	_tick_burns(delta)
	_tick_marks(delta)
	_tick_jaw(delta)
	_tick_breath(delta)
	_tick_firelight(delta)
	var riders := _riders_by_pad()
	stamp = _perf_mark("state", stamp)
	_apply_pose(delta)
	stamp = _perf_mark("pose", stamp)
	if reptile:
		_tick_douse()
	if reptile:
		if _pending_slam >= 0 or _pending_head or not _pending_sweep.is_empty() \
				or not _climbing.is_empty() or not riders.is_empty():
			_skin_t = 0.0
		_skin_tick(delta)
	stamp = _perf_mark("skin", stamp)
	if _pending_slam >= 0:
		_slam_impact(_pending_slam)
		_pending_slam = -1
	if _pending_head:
		_pending_head = false
		_head_impact()
	if not _pending_sweep.is_empty():
		_sweep_hits(_pending_sweep[0], _pending_sweep[1])
		_pending_sweep.clear()
	_tick_climbing(delta)
	if reptile:
		_separate_party()
		_skin_separate()
	_carry_riders(riders)
	if reptile:
		_skin_riders()
	_left_pad.clear()
	# Holding someone, its chest gapes: the socket lip stops guarding the
	# core, so a rescue arrow works from the floor as well as a perch.
	if _lip:
		(_lip.get_child(0) as CollisionShape3D).disabled = grab_victim() != null
	_update_glow(delta)
	_update_chains()
	_perf_mark("contacts", stamp)
	if _perf:
		_perf_frames += 1
		if _perf_frames == 240:
			var result := {}
			for key in _perf_times:
				result[key] = snappedf(_perf_times[key] / 240000.0, 0.01)
			print("BOSS CPU ms/tick ", result)
			if _terrain:
				for key in _terrain.times:
					result[key] = snappedf(_terrain.times[key] / 240000.0, 0.01)
				print("BOSS TERRAIN ms/tick ", result)
				_terrain.times.clear()
			_perf_times.clear()
			_perf_frames = 0


func _start(next: int, length: float) -> void:
	if _grab_passer != null and next != Act.GRAB:
		_grab_pass_through(null, false)
	# Riders leave the boss before it withdraws into the abyss.
	if reptile:
		_party_pass_through(next in [Act.RELOCATE, Act.SHIFT, Act.DEAD])
	act_serial += 1
	act = next
	act_t = 0.0
	act_len = length
	_arm_stopped = [false, false]
	if next == Act.STAGGER:
		for i in 2:
			_stagger_from[i] = _hand[i].global_position
			_stagger_basis[i] = _hand[i].global_basis.orthonormalized()
			_stagger_palm[i] = _stagger_contact(i)
	_pending_slam = -1
	_pending_sweep.clear()
	_struck = false
	_strike_captured = false
	_swept.clear()
	_beam_covered.clear()
	_core_open = false
	_head_open = false
	_fx_ring.visible = false
	_fx_ring_fill.visible = false
	_fx_sweep.visible = false
	_fx_beam.visible = false
	if next != Act.IDLE:
		_last_acts.append(next)
		if _last_acts.size() > 4:
			_last_acts.pop_front()


# ---------------------------------------------------------------- idle -----

func _tick_idle(_delta: float) -> void:
	_lean_goal = deg_to_rad((4.0 if reptile else 18.0) + 2.0 * sin(act_t * 1.3))
	_sink_goal = 0.25 * sz * sin(act_t * 0.9)
	_track_party(0.6)
	for i in 2:
		if _pinned_left[i] <= 0.0:
			_rest_arm(i, 3.0)
	if act_t >= act_len:
		_choose_next()


func _choose_next() -> void:
	if not _climbing.is_empty():
		_start(Act.IDLE, 0.5)
		return
	if phase == 1 and hp_frac() <= PHASE2_FRAC:
		_begin_phase2()
		return
	var party := _targets()
	if party.is_empty():
		_start(Act.IDLE, 1.5)
		return
	# Someone just went down: a breath for the revive to begin.
	if _grace > 0.0:
		_start(Act.IDLE, _grace)
		return
	var floor_bodies: Array = party.filter(func(b: Node3D) -> bool: return _on_floor(b))
	var near: Array = party.filter(func(b: Node3D) -> bool: return _in_slam_reach(b.global_position))
	var far: Array = party.filter(func(b: Node3D) -> bool:
			return not _in_slam_reach(b.global_position) and not on_pad(b))
	var w := {}
	w[Act.SLAM] = (5.0 if not floor_bodies.is_empty() else 1.5) if not near.is_empty() else 0.0
	if not far.is_empty():
		w[Act.TAIL] = 2.0 if reptile == null else 0.0
	w[Act.SWEEP] = (3.0 if floor_bodies.size() >= 2 else 1.6) if not floor_bodies.is_empty() else 0.0
	# Never a grab while someone is down: with nobody to break it, it would
	# be a loss the survivor can do nothing about.
	var all_up: bool = _targets().size() == (arena.party().size() if arena else 2)
	w[Act.GRAB] = 2.5 if _grab_cd <= 0.0 and all_up else 0.0
	if _shift_cd <= 0.0:
		w[Act.SHIFT] = 2.5
	# The gaze from the start (rarer): the archer's own way to open the core.
	w[Act.GAZE] = (1.2 if phase == 1 else 3.0) if _gaze_cd <= 0.0 and reptile == null else 0.0
	var headable: Array = []
	if reptile:
		w[Act.SLAM] = 12.0 if not near.is_empty() else 0.0
		w[Act.SWEEP] *= 0.5
		w[Act.GRAB] *= 0.6
		headable = floor_bodies.filter(func(b: Node3D) -> bool:
				return _head_can_reach(b.global_position) and not on_pad(b))
		w[Act.HEAD_SLAM] = 5.0 if _head_cd <= 0.0 and not headable.is_empty() else 0.0
		# Nobody in reach of a claw: the muzzled boss has no ranged answer,
		# so it moves. Wading round the rim is how it brings the fight to them.
		if near.is_empty():
			w[Act.SHIFT] = 6.0 if _shift_cd <= SHIFT_COOLDOWN.x * 0.6 else 0.0
			# A sweep or grab at empty stone is a wasted turn.
			w[Act.SWEEP] = 0.0
			w[Act.GRAB] = 0.0
	if phase >= 2:
		w[Act.SWEEP] *= 1.25
		w[Act.ROAR] = 0.6
	# No act three times running — a pattern you can read, not a loop.
	if _last_acts.size() >= 2 and _last_acts[-1] == _last_acts[-2] and w.has(_last_acts[-1]):
		w[_last_acts[-1]] *= 0.15
	var pick: int = _weighted(w)
	if reptile and not near.is_empty() and not _last_acts.is_empty() \
			and _last_acts[-1] not in [Act.SLAM, Act.SHAKE, Act.HEAD_SLAM] and pick != Act.HEAD_SLAM:
		pick = Act.SLAM
	match pick:
		Act.SLAM:
			_begin_slam(near, floor_bodies.filter(func(b: Node3D) -> bool: return b in near))
		Act.SWEEP:
			_begin_sweep()
		Act.GRAB:
			_begin_grab(party)
		Act.GAZE:
			_begin_gaze(party)
		Act.ROAR:
			_begin_roar()
		Act.SHIFT:
			_begin_shift()
		Act.TAIL:
			_begin_tail()
		Act.HEAD_SLAM:
			_begin_head_slam(headable)
		_:
			if near.is_empty():
				_start(Act.IDLE, 0.6)
			else:
				_begin_slam(near, floor_bodies.filter(func(b: Node3D) -> bool: return b in near))


func _weighted(w: Dictionary) -> int:
	var total := 0.0
	for k in w:
		total += w[k]
	var r := randf() * total
	for k in w:
		r -= w[k]
		if r <= 0.0:
			return k
	return Act.SLAM


# ---------------------------------------------------------------- slam -----

func _begin_slam(party: Array, floor_bodies: Array, chained: bool = false,
		avoid: Node3D = null) -> void:
	# Riders answer to the shake and the grab, never a fist on the platform.
	party = party.filter(func(b: Node3D) -> bool: return not on_pad(b) and not _climbing.has(b))
	floor_bodies = floor_bodies.filter(func(b: Node3D) -> bool: return not on_pad(b))
	if party.is_empty():
		_start(Act.IDLE, 0.6)
		return
	var pool: Array = floor_bodies if not floor_bodies.is_empty() else party
	if avoid != null and pool.size() > 1:
		pool = pool.filter(func(b: Node3D) -> bool: return b != avoid)
	# Mercy: not the same body twice in a row while it is still reeling from
	# the last claw (a fresh ring on a just-flattened archer read as unfair).
	var fresh := pool.filter(func(b: Node3D) -> bool:
			return _clock - float(_last_slammed.get(b, -99.0)) > 3.5)
	if fresh.is_empty():
		_start(Act.IDLE, 0.8)   # let them get up; something else comes next
		return
	pool = fresh
	var who: Node3D = pool[randi() % pool.size()]
	_chained = chained
	_slam_windup = 1.0 if chained else SLAM_WINDUP
	_slam_victim = who
	var p := _slam_target(who)
	_target = p + Vector3.UP * FIST_HALF_THICK * sz
	_hand_i = 0 if _boss_angle(p) < 0.0 else 1
	if _pinned_left[_hand_i] > 0.0:
		_hand_i = 1 - _hand_i
	# A tower or ruin in one arm's way is cover from that arm only: swing
	# the other if its arc is clear.
	if reptile and _pinned_left[1 - _hand_i] <= 0.0 and not _slam_path_clear(_hand_i, p) \
			and _slam_path_clear(1 - _hand_i, p):
		_hand_i = 1 - _hand_i
	plan_slam_reach(p)
	_punch_hold = _slam_windup + SLAM_STRIKE + PUNCH_OPEN
	_start(Act.SLAM, _punch_hold + SLAM_RECOVER if reptile else _slam_windup + SLAM_STRIKE + 0.1)
	_show_ring(Vector3(p.x, p.y, p.z), (SLAM_RADIUS * sz), Color(1.0, 0.25, 0.08))
	_emit("slam", {"target": who.name, "hand": _hand_i})
	_rumble(-14.0, 0.75)


func _slam_target(who: Node3D) -> Vector3:
	var p := who.global_position
	if "velocity" in who:
		p += Vector3(who.velocity.x, 0, who.velocity.z) * 0.35
	p = _clamp_to_platform(p, 0.6)
	p.y = _floor_y() if _on_floor(who) else who.global_position.y
	return p


func _track_slam(delta: float) -> void:
	#Commit before the downswing so the last part of a dodge stays readable.
	if not _fx_ring.visible or act_t >= _slam_windup - 0.35 or not is_instance_valid(_slam_victim):
		return
	if on_pad(_slam_victim) or is_climbing(_slam_victim):
		return
	var p := _slam_target(_slam_victim)
	_target = _target.lerp(p + Vector3.UP * FIST_HALF_THICK * sz,
			1.0 - exp(-6.0 * delta))
	plan_slam_reach(_target)
	_fx_ring.global_position = _target - Vector3.UP * (FIST_HALF_THICK * sz - 0.05)
	_fx_ring_fill.global_position = _fx_ring.global_position + Vector3.UP * 0.01


func _tick_slam(delta: float) -> void:
	_track_slam(delta)
	var i := _hand_i
	var f := _flat_dir(global_position, _target)
	var down := _slam_basis(f)
	# How high the fist cocks before the blow. The titan's arms rest hanging
	# (an A-pose): cocked straight overhead, its shoulders tore; it draws back
	# lower and further instead.
	var lift := float(reptile.spec.get("windup_lift", 8.5)) if reptile else 8.5
	var raised := _target + Vector3(0, lift, 0) - f * (3.5 + (8.5 - lift) * 0.5)
	var impact := _slam_windup + SLAM_STRIKE
	_track_point(_target, 0.8)
	# Load the shoulder first, then bring the chest over the committed blow.
	_lean_goal = deg_to_rad(lerpf(12.0, lerpf(28.0, SLAM_LEAN_FAR, _slam_far),
			smoothstep(0.45, 1.0, act_t / _slam_windup)))
	if reptile and act_t < impact:
		_sink_goal = -SLAM_RISE * sz * _slam_far
		# Uncoil as it rears back, so the blow lands at full length. Measured
		# from where the shoulder actually is after the terrain guard.
		var land_at := _palm_wrist(i, _target, down)
		var rest := (_arm_len[i].x + _arm_len[i].y) * sz
		var want := 1.0
		if rest > 0.0:
			want = clampf(_ua[i].global_position.distance_to(land_at) / (rest * 0.97)
					* (1.0 + SLAM_ARCH * _slam_far), 1.0, ARM_STRETCH_MAX)
		arm_stretch[i] = move_toward(arm_stretch[i], want, get_physics_process_delta_time() * 0.9)
	var fill := clampf(act_t / impact, 0.0, 1.0)
	_ring_fill(fill)
	if act_t < _slam_windup:
		var k := smoothstep(0.0, 1.0, act_t / _slam_windup)
		_ease_arm(i, raised.lerp(raised + Vector3(0, 1.5, 0), k), _cocked_basis(f), 5.0 if not _chained else 8.0)
	elif act_t < impact:
		if not _strike_captured:
			_strike_from = _hand[i].global_position
			_strike_basis = _hand[i].global_basis.orthonormalized()
			_strike_captured = true
		var k := (act_t - _slam_windup) / SLAM_STRIKE
		k = k * k  # accelerates into the ground
		# Over and down, not along a ruler: the blow arcs forward then drops.
		var land := _palm_wrist(i, _target, down)
		var over := _strike_from.lerp(land, 0.5) + f * (2.0 * sz) + Vector3(0, 1.5 * sz, 0)
		# Far: high over the stone between, then down at the usual slope (a
		# vertical forearm drove the wrist's skin into the floor on landing).
		over = over.lerp(land + Vector3(0, 5.0 * sz, 0) - f * (3.0 * sz), _slam_far)
		_set_arm(i, _strike_from.bezier_interpolate(over, over, land, k), _strike_basis.slerp(down, k))
	else:
		if reptile == null or act_t < _punch_hold:
			if reptile and _struck and _pending_slam < 0:
				_set_arm(i, _punch_wrist, _punch_basis)
			else:
				_set_arm(i, _palm_wrist(i, _target, down), down)
		if not _struck:
			_struck = true
			_pending_slam = i
		if reptile:
			_tick_punch_recovery(i)
			return
		if act_t >= act_len:
			# A claw that found its mark lifts sooner: dodging or parrying it is
			# what earns the long window (bots and testers alike were eating
			# slams on purpose to climb the claw that hit them).
			_pinned_left[i] = maxf(_pinned_left[i], SLAM_PINNED if not _slam_landed else 1.8)
			# Phase 2: the other fist follows — two fists down, one punish window.
			if phase >= 2 and not _chained and randf() < 0.45 and _pinned_left[1 - i] <= 0.0:
				# The follow-up goes for the OTHER player, or not at all: two
				# fists on one body in a second was a knockdown nobody could read.
				var party := _targets().filter(func(b: Node3D) -> bool:
						return b != _slam_victim and _on_floor(b))
				if not party.is_empty():
					_begin_slam(party, party.filter(func(b: Node3D) -> bool: return _on_floor(b)),
							true, _slam_victim)
					_emit("combo", {})
					return
			_start(Act.IDLE, _idle_gap())


func _tick_punch_recovery(i: int) -> void:
	_lean_goal = deg_to_rad(10.0)
	_sink_goal = _punch_sink
	_rest_arm(1 - i, 2.0)
	if act_t >= _punch_hold:
		_pinned_left[i] = 0.0
		_lunge_goal = 0.0
		_slam_far = 0.0
		arm_stretch[i] = move_toward(arm_stretch[i], 1.0, get_physics_process_delta_time() * 0.6)
		_rest_arm(i, 3.0)
		_sink_goal = 0.0
		_lean_goal = deg_to_rad(4.0)
	if act_t >= act_len:
		_start(Act.IDLE, 0.45 if phase >= 2 else 0.65)


func _slam_impact(i: int) -> void:
	_fx_ring.visible = false
	_fx_ring_fill.visible = false
	_queue_reach_check(i, _target)
	var hits := 0
	for b in _targets():
		var p: Vector3 = b.global_position
		if on_pad(b) or _climbing.has(b):
			continue
		if _flat_dist(p, _target) > (SLAM_RADIUS * sz):
			continue
		if absf(p.y - (_target.y - (FIST_HALF_THICK * sz))) > 2.2:
			continue
		# Golden rule: the claw you SEE has to land on you. A hero inside the
		# ring but clear of the claw's hull is missed (the solid box used to
		# shove them out first; hit-only, the ring alone hit 4x a match).
		if reptile and _skin_solid and not _claw_touches(i, b):
			continue
		if reptile and _occluded(fist_pos(i), p + Vector3.UP):
			continue
		var away := _flat_dir(_target, p) if _flat_dist(_target, p) > 0.2 \
				else _flat_dir(global_position, p)
		if b.take_hit(SLAM_DAMAGE, away * SLAM_KNOCK + Vector3(0, 2.0, 0), false, _hand_body[i], false):
			hits += 1
			_last_slammed[b] = _clock
			_emit("slam_hit", {"victim": b.name, "blocked": _blocked(b)})
			_still_if_down(b)
	_slam_landed = hits > 0
	if reptile and act == Act.SLAM:
		# Hold the actual contact pose, including the terrain solver's floor lift.
		# Reapplying the nominal target drove the claw down and forced a retreat.
		_punch_wrist = _hand[i].global_position
		_punch_basis = _hand[i].global_basis.orthonormalized()
		_punch_sink = _sink
		var hold := PUNCH_PARRIED if _parried_this_slam else PUNCH_OPEN
		_pinned_left[i] = hold
		_punch_hold = act_t + hold
		act_len = _punch_hold + SLAM_RECOVER
		_emit("punch_open", {"hand": i, "seconds": hold})
	elif _parried_this_slam:
		_pinned_left[i] = SLAM_PINNED_PARRIED
	_parried_this_slam = false
	_shake(0.9)
	# The body rides the blow down: weight, not a puppet's arm.
	if reptile == null:
		_sink += 0.55 * sz
		_lean += deg_to_rad(4.0)
	var impact := fist_pos(i) if _arm_stopped[i] else _target
	_play("death_thud", impact, 6.0, 0.55)
	_dust(impact)
	if reptile:
		_douse_near(impact, DOUSE_SLAM, "slam")
		_snort(0.7)
	if hits == 0:
		_emit("slam_miss", {})


var _parried_this_slam := false
var _slam_landed := false
var _slam_victim: Node3D = null


func on_parried(part: ColossusPart, parrier: Node3D) -> void:
	if act != Act.SLAM or part != _hand_body[_hand_i]:
		return
	_parried_this_slam = true
	_add_poise(PARRY_POISE, parrier)
	_emit("parry", {"by": parrier.name})


# --------------------------------------------------------------- sweep -----

func _begin_sweep() -> void:
	# Sweep from the side its arm is on toward the other.
	_hand_i = randi() % 2
	if _pinned_left[_hand_i] > 0.0:
		_hand_i = 1 - _hand_i
	_sweep_dir = 1.0 if _hand_i == 0 else -1.0
	_sweep_from = -SWEEP_ARC * _sweep_dir
	_sweep_to = SWEEP_ARC * _sweep_dir
	_sweep_prev = _sweep_from
	_sweep_high = phase >= 2 and randf() < 0.5
	_sweep_lift_from = _hand[_hand_i].global_position
	_sweep_lift_basis = _hand[_hand_i].global_basis.orthonormalized()
	_start(Act.SWEEP, SWEEP_WINDUP + SWEEP_TIME + SWEEP_RECOVER)
	_show_sweep_band()
	_emit("sweep_high" if _sweep_high else "sweep", {"dir": _sweep_dir})
	_rumble(-10.0, 0.6)


func _tick_sweep(_delta: float) -> void:
	var i := _hand_i
	var r := _sweep_radius()
	var high_y := 3.2 if reptile else 2.6
	var y := _floor_y() + (high_y if _sweep_high else 0.7)
	_lean_goal = deg_to_rad(24.0)
	_fx_sweep_mat.albedo_color.a = (0.1 + 0.16 * absf(sin(act_t * 9.0))) \
			if act_t < SWEEP_WINDUP else 0.0
	if act_t < SWEEP_WINDUP:
		# Cock the arm out wide and back on its own side.
		var t := act_t / SWEEP_WINDUP
		var cocked := _arc_point(_sweep_from - 0.35 * _sweep_dir, r, y + 2.0)
		var launch := _arc_point(_sweep_from, r, y) - _sweep_tangent(_sweep_from) * (FIST * sz) * 0.2
		var lift := smoothstep(0.0, 0.65, t)
		var settle := smoothstep(0.65, 1.0, t)
		_set_arm(i, _sweep_lift_from.lerp(cocked, lift).lerp(launch, settle),
				_sweep_lift_basis.slerp(_sweep_basis(_sweep_from), lift))
		_track_point(_arc_point(0.0, r, y), 0.5)
	elif act_t < SWEEP_WINDUP + SWEEP_TIME:
		if not _strike_captured:
			_strike_from = _hand[i].global_position
			_strike_basis = _hand[i].global_basis.orthonormalized()
			_strike_captured = true
		var k := (act_t - SWEEP_WINDUP) / SWEEP_TIME
		k = smoothstep(0.0, 1.0, k)
		var phi := lerpf(_sweep_from, _sweep_to, k)
		var launch := smoothstep(0.0, 0.25, k)
		var wrist := _arc_point(phi, r, y) - _sweep_tangent(phi) * (FIST * sz) * 0.2
		_set_arm(i, _strike_from.lerp(wrist, launch), _strike_basis.slerp(_sweep_basis(phi), launch))
		_pending_sweep = [_sweep_prev, phi]
		_sweep_prev = phi
		if not _struck:
			_struck = true
			_play("punch_whoosh", _arc_point(0.0, r, y), 8.0, 0.45)
	else:
		# The arm drags to rest on the rim at the end of its arc — a moment
		# it cannot defend, and the punish a sweep owes the players.
		if act_t < SWEEP_WINDUP + SWEEP_TIME + 0.05 and _pinned_left[i] <= 0.0:
			_rest_point = _open_stone(_arc_point(_sweep_to * 0.85, r - 1.0, _floor_y()), 2.0) \
					+ Vector3(0, (FIST_HALF_THICK * sz), 0)
			_pinned_left[i] = SWEEP_REST
		if _pinned_left[i] > 0.0:
			var f := _flat_dir(global_position, _rest_point)
			_ease_arm(i, _palm_wrist(i, _rest_point, _slam_basis(f)), _slam_basis(f), 6.0)
		else:
			_rest_arm(i, 3.0)
		if act_t >= act_len:
			_start(Act.IDLE, _idle_gap())


var _rest_point := Vector3.ZERO


func _sweep_hits(phi_a: float, phi_b: float) -> void:
	var lo := minf(phi_a, phi_b)
	var hi := maxf(phi_a, phi_b)
	var party := _targets()
	for b in party:
		if b in _swept or on_pad(b) or _climbing.has(b):
			continue
		var p: Vector3 = b.global_position
		if reptile and (_occluded(fist_pos(_hand_i), p + Vector3.UP)
				or not _claw_touches(_hand_i, b)):
			continue
		var phi := _boss_angle(p)
		if phi < lo or phi > hi:
			continue
		# The arm reaches so far; the tail rakes the band beyond it.
		var rdist := _flat_dist(p, global_position)
		if act == Act.SWEEP and rdist > reach() + 1.5:
			continue
		if act == Act.TAIL and rdist < _tail_inner():
			continue
		_swept.append(b)
		if _sweep_high:
			if "is_crouching" in b and b.is_crouching:
				_emit("sweep_cleared", {"who": b.name, "how": "ducked"})
				continue
		elif p.y - _floor_y() > SWEEP_CLEAR_Y:
			_emit("sweep_cleared", {"who": b.name, "how": "high"})
			continue
		var cover := _shield_cover(b, party)
		if cover != null:
			_emit("covered", {"who": b.name, "by": cover.name})
			SlashTrail.spawn_hit_spark(self, p + Vector3(0, 1.0, 0), Color(0.6, 0.8, 1.0))
			continue
		var tangent := _sweep_tangent(phi)
		var outward := _flat_dir(_center(), p)
		var kb := tangent * SWEEP_KNOCK + outward * 1.0 + Vector3(0, 2.5, 0)
		if _sweep_high:
			kb = tangent * 4.0 + Vector3(0, 1.5, 0)   # a cuff, not a launch
		if b.take_hit(SWEEP_DAMAGE, kb, false, _hand_body[_hand_i], false):
			_emit("tail_hit" if act == Act.TAIL else "sweep_hit", {"victim": b.name, "blocked": _blocked(b)})
			_still_if_down(b)
		else:
			_emit("sweep_cleared", {"who": b.name, "how": "evaded"})


## A blocking paladin standing upstream of `b` (the sweep reaches him first)
## and close beside him takes the blow for both.
func _shield_cover(b: Node3D, party: Array) -> Node3D:
	for o in party:
		if o == b or not ("is_blocking" in o) or not o.is_blocking:
			continue
		if not o.has_method("is_paladin") or not o.is_paladin():
			continue
		if o.global_position.distance_to(b.global_position) > COVER_DIST:
			continue
		if not sweep_reaches_first(o.global_position, b.global_position):
			continue
		return o
	return null


# ---------------------------------------------------------------- grab -----

func _begin_grab(party: Array) -> void:
	# It plucks whoever has been out of reach longest — a perch is not a
	# fortress. Otherwise anyone.
	# Never a rider: the shudder is its answer to them (a knight seized off
	# its own shoulder had no way to read it coming).
	party = party.filter(func(b: Node3D) -> bool: return b is Player and _in_reach(b.global_position) and not on_pad(b) and not _climbing.has(b))
	if party.is_empty():
		_start(Act.IDLE, 0.5)
		return
	var who: Node3D = null
	for b in party:
		if not _on_floor(b):
			who = b
	if who == null:
		who = party[randi() % party.size()]
	_victim = who
	_target = who.global_position + Vector3(0, 1.0, 0)
	_hand_i = 0 if _boss_angle(_target) < 0.0 else 1
	if reptile:
		_prepare_brace(1 - _hand_i)
	_grab_pass_through(who, true)
	_grab_cd = GRAB_COOLDOWN
	_struggle = 0.0
	_rescue_dmg = 0.0
	_start(Act.GRAB, GRAB_WINDUP + GRAB_REACH + _grab_hold() + GRAB_THROW + 0.6)
	_show_ring(Vector3(_target.x, who.global_position.y, _target.z), (GRAB_RADIUS * sz),
			Color(0.65, 0.3, 1.0))
	_emit("grab", {"target": who.name})
	_rumble(-12.0, 0.9)


func _prepare_brace(i: int) -> void:
	var forward := _flat_dir(global_position, _center())
	var at := _idle_palm(i) + forward * 3.0 * sz
	at.y = _floor_y()
	_brace_point = _open_stone(at, 1.0) + Vector3.UP * FIST_HALF_THICK * sz
	_brace_from = _hand[i].global_position
	_brace_basis = _hand[i].global_basis.orthonormalized()
	var saved := [_ua[i].transform, _fa[i].transform, _hand[i].transform]
	var elbow := _elbow_n[i]
	var right := global_basis.x.normalized()
	var offsets := [Vector2.ZERO, Vector2(0, -2), Vector2(2, 0), Vector2(-2, 0),
			Vector2(0, -4), Vector2(2, -3), Vector2(-2, -3), Vector2(0, 2),
			Vector2(4, -2), Vector2(-4, -2)]
	var want := _brace_point
	#Find a place where the whole palm can sit on the floor, not just a
	#clear centre point beside a pillar. The partner must be able to cut it.
	for off: Vector2 in offsets:
		var p := want + right * off.x + forward * off.y
		_elbow_n[i] = Vector3.ZERO
		if _brace_fits(i, p):
			_brace_point = p
			break
	_ua[i].transform = saved[0]
	_fa[i].transform = saved[1]
	_hand[i].transform = saved[2]
	_elbow_n[i] = elbow
	reptile.drive(0.0)


func _brace_fits(i: int, p: Vector3) -> bool:
	var suffix := ".L" if i == 0 else ".R"
	var bones := ["upperarm" + suffix, "forearm" + suffix, "hand" + suffix]
	var f := _flat_dir(global_position, p)
	var wrist := _palm_wrist(i, p, _slam_basis(f))
	for step in 6:
		_solve_arm(i, wrist, _slam_basis(f), false)
		reptile.drive(0.0)
		var lift: float = _terrain.floor_lift(bones)
		if lift < 0.01:
			break
		wrist.y += lift
	return not _terrain.blocked(bones) and _terrain.lowest("hand" + suffix) < _floor_y() + 0.7


func _brace_windup(i: int, t: float) -> void:
	var f := _flat_dir(global_position, _brace_point)
	var wrist := _palm_wrist(i, _brace_point, _slam_basis(f))
	var travel := smoothstep(0.3, 0.85, t)
	var lift := smoothstep(0.0, 0.3, t) * (1.0 - smoothstep(0.75, 1.0, t))
	var basis := _brace_basis.slerp(_cocked_basis(f), smoothstep(0.0, 0.3, t))
	basis = basis.slerp(_slam_basis(f), smoothstep(0.55, 1.0, t))
	_set_arm(i, _brace_from.lerp(wrist, travel) + Vector3.UP * lift * 6.0 * sz, basis)


## The closing claw must be able to close ON its target: with solid hands,
## physics shoved every victim out of the grip before it shut (0 grabs in 30
## sims). Only the grabbing arm, only for this grab, only for that body.
var _grab_passer: PhysicsBody3D = null


func _grab_pass_through(b: Node3D, on: bool) -> void:
	if on and not (b is PhysicsBody3D):
		return
	var body: PhysicsBody3D = b as PhysicsBody3D if on else _grab_passer
	if body == null or not is_instance_valid(body):
		_grab_passer = null
		return
	for part in get_tree().get_nodes_in_group("colossus_parts"):
		if _is_under(part, _hand[_hand_i]) or _is_under(part, _fa[_hand_i]):
			if on:
				body.add_collision_exception_with(part)
			elif reptile != null and player_solid(part):
				body.remove_collision_exception_with(part)
	_grab_passer = body if on else null


var _party_passing := false


func _party_pass_through(on: bool) -> void:
	if on == _party_passing or arena == null:
		return
	_party_passing = on
	for b in arena.party():
		for part in get_tree().get_nodes_in_group("colossus_parts"):
			if not is_ancestor_of(part):
				continue
			if on:
				b.add_collision_exception_with(part)
			elif player_solid(part):
				b.remove_collision_exception_with(part)


func _grab_wrist(i: int, forward: Vector3) -> Vector3:
	return _palm_wrist(i, _target, _palm_basis(forward))


func _tick_grab(delta: float) -> void:
	var i := _hand_i
	var other := 1 - i
	var reach := GRAB_WINDUP + GRAB_REACH
	var hold_end := reach + _grab_hold() + _struggle
	var f := _flat_dir(global_position, _target)
	if act_t < GRAB_WINDUP:
		# Keep tracking the victim through the windup — a readable reach,
		# not a homing missile: it stops following 0.35 s before contact.
		if act_t < GRAB_WINDUP - 0.35 and is_instance_valid(_victim):
			_target = _target.lerp(_victim.global_position + Vector3(0, 1.0, 0), 4.0 * delta)
			_fx_ring.global_position = Vector3(_target.x, _victim.global_position.y + 0.05, _target.z)
			_fx_ring_fill.global_position = _fx_ring.global_position + Vector3(0, 0.01, 0)
		_ring_fill(act_t / reach)
		var k := smoothstep(0.0, 1.0, act_t / GRAB_WINDUP)
		var raised := _grab_wrist(i, f) - f * 2.0 + Vector3(0, 6.0 * k, 0)
		_ease_arm(i, raised, _cocked_basis(f) if reptile else _palm_basis(f), 5.0)
		if reptile:
			_brace_windup(other, act_t / GRAB_WINDUP)
		_track_point(_target, 0.9)
		return
	if act_t < reach:
		if not _strike_captured:
			_strike_from = _hand[i].global_position
			_strike_basis = _hand[i].global_basis.orthonormalized()
			_strike_captured = true
		var k := (act_t - GRAB_WINDUP) / GRAB_REACH
		_set_arm(i, _strike_from.lerp(_grab_wrist(i, f), k * k),
				_strike_basis.slerp(_palm_basis(f), k * k))
		return
	if not _struck:
		_struck = true
		_fx_ring.visible = false
		_fx_ring_fill.visible = false
		var caught := false
		if is_instance_valid(_victim) and not _victim.is_dead \
				and (not reptile or _claw_touches(i, _victim)) \
				and not _occluded(fist_pos(i), _victim.global_position + Vector3.UP) \
				and _victim.global_position.distance_to(_target) < (GRAB_RADIUS * sz) + 0.4 \
				and not _in_iframes(_victim) and not _climbing.has(_victim) and not on_pad(_victim):
			caught = true
		if not caught:
			# Missed: the open hand slaps the stone and stays there, bare.
			_victim = null
			_pinned_left[i] = GRAB_MISS_PINNED
			_emit("grab_missed", {})
			_play("death_thud", _target, 0.0, 0.7)
			act_len = act_t + 1.0
			_start_recover_after_miss()
			return
		_emit("grabbed", {"victim": _victim.name, "partner_dist": _partner_dist()})
		_play("hit_flesh", _target, 6.0, 0.6)
		_core_open = reptile == null
		# The other fist braces on the platform — and is bare while it does.
		_pinned_left[other] = _grab_hold() + 0.2
		# On the bracing claw's OWN side (it used to reach across the chest —
		# the colossus's long arms made it; the wyvern's hung in the air).
		_brace_check = true
		if not reptile:
			var brace := _arc_point(-0.45 if other == 0 else 0.45, _sweep_radius() - 1.5, _floor_y())
			_brace_point = _open_stone(brace, 1.0) + Vector3(0, FIST_HALF_THICK * sz, 0)
	if _victim == null:
		_rest_arm(i, 3.0)
		if act_t >= act_len:
			_start(Act.IDLE, _idle_gap())
		return
	var bf := _flat_dir(global_position, _brace_point)
	_set_arm(other, _palm_wrist(other, _brace_point, _slam_basis(bf)), _slam_basis(bf))
	if _brace_check and act_t > reach + 0.4:
		_brace_check = false
		_queue_reach_check(other, _brace_point)
	var hold := _hold_point()
	if act_t < hold_end:
		# Bare for the WHOLE hold: a struggle lengthens it by up to 3 s, and the
		# pin set at the catch ran out first — late cuts glanced off for 0 rescue.
		if act_t >= reach:
			_pinned_left[other] = maxf(_pinned_left[other], 0.3)
		_core_open = reptile == null
		_lean_goal = deg_to_rad(12.0)
		_ease_arm(i, hold - _torso.global_basis.z * (FIST * sz) * 0.0 + Vector3(0, 0, 0), _palm_basis(_flat_dir(global_position, _center())), 3.0)
		_pin_victim(fist_pos(i))
		if is_instance_valid(_victim) and not _victim.is_dead:
			# The grip hurts but never kills: the partner always gets the whole
			# window to break it (a low-health captive used to die in a second).
			if _victim.current_health - GRAB_SQUEEZE_DPS * delta > 1.0:
				_victim.take_damage_flat(GRAB_SQUEEZE_DPS * delta)
			# STRUGGLE: mashing attack/jump buys time (up to +3 s) for the
			# partner's rescue — the victim acts, but cannot win it alone.
			var mash: bool = (randf() < 4.0 * delta) if _victim.ai_driven else \
					(Input.is_action_just_pressed(&"attack") or Input.is_action_just_pressed(&"jump"))
			if mash and _struggle < 3.0:
				_struggle += 0.18
				act_len += 0.18
				if int(_struggle / 0.18) % 5 == 1:
					_emit("struggle", {"who": _victim.name})
		if _rescue_dmg >= RESCUE_DAMAGE or not is_instance_valid(_victim) or _victim.is_dead \
				or _victim.current_health <= 0.0:
			var freed := _victim
			if freed != null and is_instance_valid(freed) and (freed.is_dead or freed.current_health <= 0.0):
				_emit("dropped", {"victim": freed.name})
			_release_victim(true)
			if freed != null and is_instance_valid(freed) and not freed.is_dead:
				_emit("rescued", {"victim": freed.name})
				_flinch()
			return
		return
	# Out of time: hurl them into the abyss.
	_core_open = false
	var k := clampf((act_t - hold_end) / GRAB_THROW, 0.0, 1.0)
	var out := _flat_dir(_center(), _target)
	var fling := hold + out * 6.0 * k + Vector3(0, 3.0 * k, 0)
	_set_arm(i, fling - _flat_dir(global_position, fling) * (FIST * sz), _palm_basis(out))
	if k < 1.0:
		_pin_victim(fist_pos(i))
	else:
		var thrown := _victim
		_release_victim(false)
		if thrown != null and is_instance_valid(thrown):
			thrown.velocity = out * 14.0 + Vector3(0, 6.0, 0)
			_emit("thrown", {"victim": thrown.name})


var _brace_point := Vector3.ZERO
var _brace_check := false
var _struggle := 0.0


func _start_recover_after_miss() -> void:
	_core_open = false


func _pin_victim(at: Vector3) -> void:
	if _victim == null or not is_instance_valid(_victim):
		return
	var held := at - Vector3(0, 1.0, 0)
	# In the claw's grip, not swallowed by it: out to the palm's surface.
	if _skin != null and _skin_solid:
		# Feet, chest and head all clear of the palm, not just the chest.
		for _k in 3:
			var worst := {"depth": -INF}
			for h: float in [0.35, 0.95, 1.55]:
				var r := _skin.contact(held + Vector3(0, h, 0))
				if float(r.depth) > float(worst.depth):
					worst = r
			if float(worst.depth) <= -0.3 or worst.normal == Vector3.ZERO:
				break
			held += (worst.normal as Vector3) * (maxf(float(worst.depth), 0.0) + 0.3)
	_victim.global_position = held
	_victim.velocity = Vector3.ZERO
	if "_knockback_velocity" in _victim:
		_victim._knockback_velocity = Vector3.ZERO
	if "_is_stunned" in _victim:
		_victim._is_stunned = true
		_victim._stun_timer = 0.2


func _release_victim(gently: bool) -> void:
	if _victim and is_instance_valid(_victim) and gently:
		# Dropped back on the stone, well inside the rim.
		var drop := _clamp_to_platform(_center().lerp(_victim.global_position, 0.4), 1.5)
		_victim.global_position = Vector3(drop.x, _floor_y() + 0.6, drop.z)
		_victim.velocity = Vector3.ZERO
	_victim = null
	_core_open = false
	_pinned_left[1 - _hand_i] = minf(_pinned_left[1 - _hand_i], 1.2)
	act_len = act_t + 0.6


## A rescue is a dash on the small platform and a sprint on the big one.
## How far the captive's partner stands from the claw that frees them (logs).
func _partner_dist() -> float:
	for b in _targets(false):
		if b != _victim:
			return snappedf(_flat_dist(b.global_position, _brace_point) / sz, 0.1)
	return -1.0


func _grab_hold() -> float:
	return GRAB_HOLD + maxf(0.0, (arena.radius if arena else 6.0) - 6.0) * 0.15


func _hold_point() -> Vector3:
	# Out to the side of the chest, over the abyss — the open core stays in
	# clear view: the holding fist used to hang right in front of it and
	# soak the very arrows meant to break the grip.
	var side := -1.0 if _hand_i == 0 else 1.0
	return _torso.global_transform * Vector3(side * 3.6, 9.2, 4.8)


# ------------------------------------------------------------ head slam -----

var _pending_head := false


## Can the muzzled skull be brought down onto `p`? Measured from the anchor,
## so the reach does not shrink while the body is reared back or wading.
func _head_can_reach(p: Vector3) -> bool:
	if reptile == null or arena == null:
		return false
	var c := _center()
	var home := c + Vector3(sin(_anchor_angle), 0, -cos(_anchor_angle)) * float(arena.boss_distance)
	return _flat_dist(home, p) <= HEAD_REACH * sz


func _begin_head_slam(pool: Array) -> void:
	var fresh := pool.filter(func(b: Node3D) -> bool:
			return _clock - float(_last_slammed.get(b, -99.0)) > 3.5)
	if fresh.is_empty():
		_start(Act.IDLE, 0.6)
		return
	var who: Node3D = fresh[randi() % fresh.size()]
	var p: Vector3 = who.global_position
	if "velocity" in who:
		p += Vector3(who.velocity.x, 0, who.velocity.z) * 0.3
	p = _clamp_to_platform(p, 0.8)
	p.y = _floor_y()
	_target = p
	_head_victim = who
	_head_cd = HEAD_COOLDOWN
	# A spot past the skull's easy reach takes the body: it slides in a
	# little, as the far punch does (the terrain guard still has the last say).
	var short := _flat_dist(_head.global_position, p) - 7.0 * sz
	_lunge_goal = clampf(short / (5.0 * sz), 0.0, 1.0) * SLAM_LUNGE * sz
	_start(Act.HEAD_SLAM, HEAD_WINDUP + HEAD_STRIKE + HEAD_DOWN + HEAD_RECOVER)
	_show_ring(p, HEAD_RADIUS * sz, Color(1.0, 0.25, 0.08))
	_emit("head_slam", {"target": who.name})
	_rumble(-12.0, 0.7)


func _tick_head_slam(_delta: float) -> void:
	var impact := HEAD_WINDUP + HEAD_STRIKE
	_ring_fill(clampf(act_t / impact, 0.0, 1.0))
	if act_t < HEAD_WINDUP:
		# Rear back: chest up, skull high, the bands creaking.
		_lean_goal = deg_to_rad(lerpf(4.0, -6.0, smoothstep(0.0, 0.7, act_t / HEAD_WINDUP)))
		_sink_goal = 0.0
	elif act_t < impact + HEAD_DOWN:
		# The whole body follows the skull down.
		_lean_goal = deg_to_rad(HEAD_LEAN)
		_sink_goal = HEAD_SINK * sz
	else:
		_lean_goal = deg_to_rad(6.0)
		_sink_goal = 0.0
		_lunge_goal = 0.0
	for i in 2:
		# Thrown out and up to the sides, clear of the ramps in front of it.
		var side := -1.0 if i == 0 else 1.0
		_ease_arm(i, _torso.global_transform * Vector3(side * 8.5, 10.5, 0.5), _grip_basis(i), 3.0)
	if act_t >= impact and not _struck:
		_struck = true
		_pending_head = true
	if act_t >= act_len:
		_start(Act.IDLE, _idle_gap())


## A basis for the head: the rest pose turned to face `f` and pitched by
## `pitch` (positive lifts the snout), keeping the rest pose's size.
func _aim_head(rest: Transform3D, f: Vector3, pitch: float) -> Basis:
	var fwd := rest.basis.z
	fwd.y = 0.0
	var yaw := 0.0
	if fwd.length() > 0.01:
		yaw = fwd.normalized().signed_angle_to(f, Vector3.UP)
	var axis := f.cross(Vector3.UP).normalized()
	return Basis(axis, pitch) * Basis(Vector3.UP, yaw) * rest.basis


## Applied right after the torso, before the arms, rig and terrain guard: the
## guard then sees the real skull and lifts the snout off any stone it meets.
func _pose_head_slam() -> void:
	var rest: Transform3D = (_head.get_parent() as Node3D).global_transform * _rest_head
	var f := _flat_dir(global_position, _target)
	var impact := HEAD_WINDUP + HEAD_STRIKE
	var reared := Transform3D(_aim_head(rest, f, deg_to_rad(32.0)),
			rest.origin + Vector3.UP * (2.6 * sz) - f * (1.2 * sz))
	var down_basis := _aim_head(rest, f, deg_to_rad(-30.0))
	var down := Transform3D(down_basis,
			_target + Vector3.UP * (0.25 * sz) - down_basis * head_contact())
	var goal: Transform3D
	if act_t < HEAD_WINDUP:
		goal = rest.interpolate_with(reared, smoothstep(0.0, 1.0, act_t / HEAD_WINDUP))
	elif act_t < impact:
		var k := (act_t - HEAD_WINDUP) / HEAD_STRIKE
		goal = reared.interpolate_with(down, k * k)
	elif act_t < impact + HEAD_DOWN:
		goal = down
	else:
		goal = down.interpolate_with(rest, smoothstep(0.0, 1.0, (act_t - impact - HEAD_DOWN) / HEAD_RECOVER))
	_head.global_transform = goal


func _head_impact() -> void:
	_fx_ring.visible = false
	_fx_ring_fill.visible = false
	var hits := 0
	for b in _targets():
		if on_pad(b) or _climbing.has(b):
			continue
		var p: Vector3 = b.global_position
		if _flat_dist(p, _target) > HEAD_RADIUS * sz + 1.0 or absf(p.y - _floor_y()) > 2.2:
			continue
		# Golden rule: the skull you see has to land on you. What comes down
		# first is its underside (the lock, the chin bar, the shut jaw), not
		# the crown the head's hit hull is built from.
		if not _skull_lands_on(b):
			continue
		var away := _flat_dir(_target, p) if _flat_dist(_target, p) > 0.2 else _flat_dir(global_position, p)
		if b.take_hit(HEAD_DAMAGE, away * HEAD_KNOCK + Vector3(0, 2.5, 0), false, _head_body, false):
			hits += 1
			_last_slammed[b] = _clock
			_emit("head_hit", {"victim": b.name, "blocked": _blocked(b)})
			_still_if_down(b)
	if hits == 0:
		_emit("head_miss", {})
	_douse_near(_target, DOUSE_HEAD, "head")
	_shake(1.0)
	_play("death_thud", _target, 7.0, 0.45)
	_dust(_target)
	_snort(1.0)


## Head-local point that meets the stone: the bottom of the muzzle's lock.
func head_contact() -> Vector3:
	return reptile.spec.contact if reptile else Vector3.ZERO


func _skull_lands_on(b: Node3D) -> bool:
	var p: Vector3 = b.global_position
	# Head-local points along the underside: the lock, the chin bar, the shut jaw.
	for l: Vector3 in reptile.spec.underside:
		var at := _head.global_transform * l
		if _flat_dist(at, p) < 1.3 and at.y < p.y + 1.9:
			return true
	var chest := p + Vector3.UP
	return part_surface_point(_head_body, chest).distance_to(chest) < 1.3


# ------------------------------------------------------------- braziers -----

## Knock out every lit brazier near `at`: a blow on the stone, a claw raked
## through the bowl, the gust of a roar. The archer's arrows light them again.
func _douse_near(at: Vector3, radius: float, by: String) -> void:
	for b in get_tree().get_nodes_in_group("braziers"):
		if b.lit and _flat_dist(b.global_position, at) < radius:
			b.douse()
			_emit("brazier_out", {"by": by, "at": b.global_position})


func _tick_douse() -> void:
	if act == Act.SWEEP and not _sweep_high and act_t >= SWEEP_WINDUP \
			and act_t < SWEEP_WINDUP + SWEEP_TIME:
		_douse_near(fist_pos(_hand_i), DOUSE_CLAW, "sweep")
	elif act == Act.GRAB and act_t >= GRAB_WINDUP and act_t < GRAB_WINDUP + GRAB_REACH:
		_douse_near(fist_pos(_hand_i), DOUSE_CLAW, "grab")


# ----------------------------------------------------------- firelight -----

## The braziers stand on the platform; the titan leans in from beyond the
## rim, out of their reach, and read as a flat black shape. This is their
## glow thrown up onto it from the edge: as bright as the lit fires near the
## boss make it, gone when they are all out.
var _firelight: OmniLight3D
var _firelight_t := 0.0
var _firelight_goal := 0.0


func _build_firelight() -> void:
	_firelight = OmniLight3D.new()
	_firelight.name = "PlatformFireGlow"
	_firelight.light_color = Color(1.0, 0.5, 0.2)
	_firelight.omni_range = 26.0
	_firelight.omni_attenuation = 1.2
	_firelight.shadow_enabled = false
	_firelight.light_volumetric_fog_energy = 0.0
	_firelight.light_energy = 0.0
	add_child(_firelight)


func _tick_firelight(delta: float) -> void:
	if _firelight == null or arena == null:
		return
	# At the rim in front of the chest, a little above the stone.
	var rim := _center() + _flat_dir(_center(), global_position) * (float(arena.radius) - 1.0)
	_firelight.global_position = Vector3(rim.x, _floor_y() + 2.0, rim.z)
	_firelight_t -= delta
	if _firelight_t <= 0.0:
		_firelight_t = 0.4
		var glow := 0.0
		for b in get_tree().get_nodes_in_group("braziers"):
			if b.lit:
				var d := _flat_dist(b.global_position, rim)
				glow += clampf(1.0 - d / 20.0, 0.0, 1.0)
		_firelight_goal = minf(glow, 2.0) * 1.6
	var flicker := 1.0 + 0.08 * sin(_clock * 11.0) + 0.05 * sin(_clock * 23.0)
	_firelight.light_energy = lerpf(_firelight.light_energy, _firelight_goal * flicker, 1.0 - exp(-3.0 * delta))


# -------------------------------------------------------------- breath -----

## Smoke from both nostrils: a slow exhale while it waits, a hard snort after
## every blow, a steady jet while it strains against the muzzle. Lit like any
## smoke, so it shows in the braziers' glow and vanishes in the dark.
func _build_breath() -> void:
	if reptile == null:
		return
	for nostril: Vector3 in reptile.spec.nostrils:
		var side := signf(nostril.x)
		var p := GPUParticles3D.new()
		p.name = "NostrilSmoke"
		p.amount = 40
		p.lifetime = 2.4
		p.randomness = 0.5
		p.emitting = false
		p.position = nostril
		p.visibility_aabb = AABB(Vector3(-12, -12, -4), Vector3(24, 24, 28))
		var m := ParticleProcessMaterial.new()
		m.direction = Vector3(side * 0.25, -0.45, 1.0).normalized()
		m.spread = 14.0
		m.initial_velocity_min = 2.2
		m.initial_velocity_max = 3.4
		m.gravity = Vector3(0, 0.45, 0)
		m.damping_min = 1.2
		m.damping_max = 1.8
		m.scale_min = 0.6
		m.scale_max = 1.1
		var curve := Curve.new()
		curve.add_point(Vector2(0.0, 0.2))
		curve.add_point(Vector2(1.0, 1.7))
		var ctex := CurveTexture.new()
		ctex.curve = curve
		m.scale_curve = ctex
		m.turbulence_enabled = true
		m.turbulence_noise_strength = 0.7
		m.turbulence_noise_scale = 2.2
		var g := Gradient.new()
		g.offsets = PackedFloat32Array([0.0, 0.18, 1.0])
		# Warm grey and thin: in the fire-lit fog a pale smoke read as glowing
		# blue balls stuck to the muzzle.
		g.colors = PackedColorArray([Color(0.3, 0.27, 0.24, 0.0),
				Color(0.27, 0.25, 0.22, 0.18), Color(0.2, 0.19, 0.18, 0.0)])
		var ramp := GradientTexture1D.new()
		ramp.gradient = g
		m.color_ramp = ramp
		m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
		m.emission_sphere_radius = 0.15
		p.process_material = m
		var quad := QuadMesh.new()
		quad.size = Vector2(0.8, 0.8)
		var mat := StandardMaterial3D.new()
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		mat.vertex_color_use_as_albedo = true
		mat.albedo_texture = FireFX._soft_circle_tex()
		mat.roughness = 1.0
		mat.disable_receive_shadows = true
		quad.material = mat
		p.draw_pass_1 = quad
		reptile.head.add_child(p)
		_nostrils.append(p)


## A hard exhale through the nostrils, `strength` 0..1.
func _snort(strength: float) -> void:
	for p in _nostrils:
		p.amount_ratio = clampf(strength, 0.2, 1.0)
		p.restart()
		p.emitting = true
	_breath_t = 0.0


func _tick_breath(delta: float) -> void:
	if _nostrils.is_empty():
		return
	_breath_t += delta
	var straining := act == Act.ROAR or (act == Act.HEAD_SLAM and act_t < HEAD_WINDUP) \
			or act == Act.STAGGER
	# Exhale for a second out of every three and a bit; jet while straining.
	var exhale := straining or fmod(_breath_t, 3.3) < 1.0
	for p in _nostrils:
		if straining:
			p.amount_ratio = 1.0
		elif not exhale:
			p.amount_ratio = 0.45
		p.emitting = exhale


# ---------------------------------------------------------------- roar -----

func _begin_roar() -> void:
	_start(Act.ROAR, ROAR_WINDUP + ROAR_RECOVER)
	_emit("roar", {})


func _tick_roar(_delta: float) -> void:
	_lean_goal = deg_to_rad(-8.0) if act_t < ROAR_WINDUP else deg_to_rad(14.0)
	for i in 2:
		var side := -1.0 if i == 0 else 1.0
		# The dragon rears and throws its wings wide: wrists up and out,
		# not a man lifting his arms.
		var lift := Vector3(side * 11.5, 14.5, -1.5) if rig else Vector3(side * 7.5, 13.0, 1.5)
		_ease_arm(i, _torso.global_transform * lift, _grip_basis(i), 3.0)
	if act_t >= ROAR_WINDUP and not _struck:
		_struck = true
		_play("dragon_roar", head_pos(), 12.0, 0.5)
		if reptile:
			# Through the muzzle the roar is a blast of breath: it guts the
			# nearest fires.
			_douse_near(head_pos(), DOUSE_ROAR, "roar")
		_shake(1.0)
		for b in _targets():
			var p: Vector3 = b.global_position
			if p.y - _floor_y() > 2.0:
				continue
			if _occluded(head_pos(), p + Vector3(0, 1.0, 0)):
				_emit("roar_cover", {"who": b.name})
				continue
			if "is_crouching" in b and b.is_crouching:
				_emit("roar_braced", {"who": b.name})
				continue
			var kb := _flat_dir(global_position, p) * ROAR_KNOCK + Vector3(0, 2.0, 0)
			if b.take_hit(ROAR_DAMAGE, kb, false, _hand_body[0], false):
				_emit("roar_hit", {"victim": b.name})
				_still_if_down(b)
	if act_t >= act_len:
		if phase == 2 and _relocate_pending:
			_relocate_pending = false
			_start(Act.RELOCATE, 7.0)
			_anchor_goal = _anchor_angle + deg_to_rad(110.0) * (1.0 if randf() < 0.5 else -1.0)
			_relocate_from = _anchor_angle
			return
		_start(Act.IDLE, _idle_gap())


# ------------------------------------------------------------ relocate -----

var _relocate_pending := false
var _relocate_from := 0.0


func _begin_phase2() -> void:
	if phase >= 2:
		return
	phase = 2
	_snap_chains()
	_relocate_pending = true
	phase_changed.emit(2)
	_emit("phase2", {})
	_begin_roar()


func _tick_relocate(_delta: float) -> void:
	if reptile:
		# Its ledges go soft while it wades: a rider carried round the rim
		# was dropped behind it into the abyss (every fall in the TRELLIS
		# sims, 3 s after the phase-two roar).
		if act_t < 0.2:
			_fling_riders(true, "relocate")
		_wade(_relocate_from, _anchor_goal, act_len, 18.0 * sz)
		if act_t >= act_len:
			_start(Act.IDLE, 1.0)
		return
	# Sink into the abyss, circle beneath the rim, rise on another side.
	var t := act_t
	if t < 0.2:
		_fling_riders(true, "relocate")
	# Brisker than it was: testers sat through ~8 s of nothing after the chains broke.
	if t < 1.4:
		_sink_goal = 22.0 * sz * smoothstep(0.0, 1.0, t / 1.4)
	elif t < 2.6:
		_sink_goal = 22.0 * sz
		var k := smoothstep(0.0, 1.0, (t - 1.4) / 1.2)
		_anchor_angle = lerpf(_relocate_from, _anchor_goal, k)
		_place_on_anchor()
	else:
		_sink_goal = 22.0 * sz * (1.0 - smoothstep(0.0, 1.0, (t - 2.6) / 1.9))
	for i in 2:
		_rest_arm(i, 2.0)
	if t >= act_len:
		_sink_goal = 0.0
		_start(Act.IDLE, 1.0)


func _place_on_anchor(reset_pose: bool = false) -> void:
	if reset_pose:
		_withdraw = 0.0
		_terrain_back = 0.0
		_sink = 0.0
		_sink_goal = 0.0
		_head.transform = _rest_head
	var c := _center()
	var dist: float = arena.boss_distance + _withdraw + _terrain_back - _lunge
	global_position = Vector3(c.x + sin(_anchor_angle) * dist, arena.boss_base_y,
			c.z - cos(_anchor_angle) * dist)
	# Face the platform centre (local +Z toward it).
	var to_c := Vector3(c.x - global_position.x, 0, c.z - global_position.z).normalized()
	rotation.y = atan2(to_c.x, to_c.z)
	if reset_pose:
		_arm_pose = [{}, {}]
		_return_t = [-1.0, -1.0]
		for i in 2:
			_wrist[i] = _idle_wrist(i)
			_hand_basis[i] = _grip_basis(i)
			_elbow_n[i] = Vector3.ZERO
			_solve_arm(i, _wrist[i], _hand_basis[i], false)
		if reptile:
			reptile.drive(0.0)


# ---------------------------------------------------------------- gaze -----

func _begin_gaze(party: Array) -> void:
	_victim = party[randi() % party.size()]
	_gaze_cd = GAZE_COOLDOWN
	_eye_dmg = 0.0
	_start(Act.GAZE, GAZE_CHARGE + GAZE_BEAM + (1.6 if rig else GAZE_RECOVER))
	_emit("gaze", {"target": _victim.name})
	_play("spell_fire_start", eye_pos(), 8.0, 0.5)


func _tick_gaze(_delta: float) -> void:
	_lean_goal = deg_to_rad(10.0)
	for i in 2:
		if _pinned_left[i] <= 0.0:
			_rest_arm(i, 3.0)
	var aim: Vector3 = _victim.global_position if is_instance_valid(_victim) else _center()
	if act_t < GAZE_CHARGE:
		_track_point(aim, 1.0)
		# The beam's path: it opens beside the target and rakes across it.
		var side := _flat_dir(global_position, aim).cross(Vector3.UP)
		_beam_from = aim - side * 4.0
		_beam_to = aim + side * 4.0
		_show_beam(eye_pos(), _beam_from, 0.12, act_t / GAZE_CHARGE)
		if rig:
			# The throat fills with fire before it opens: the tell is the glow.
			_mouth_light.light_energy = 7.0 * act_t / GAZE_CHARGE
			_fx_beam.visible = act_t > GAZE_CHARGE * 0.5   # the aim line, late
		return
	if act_t < GAZE_CHARGE + GAZE_BEAM:
		var k := (act_t - GAZE_CHARGE) / GAZE_BEAM
		var at := _beam_from.lerp(_beam_to, k)
		_track_point(at, 1.0)
		if rig:
			_fx_beam.visible = false   # the aim line was the tell, not the fire
			_breathe(eye_pos(), at)
		else:
			_show_beam(eye_pos(), at, 0.55, 1.0)
		if not _struck:
			_struck = true
			_play("spell_fire_loop", eye_pos(), 10.0, 0.6)
		_beam_hits(eye_pos(), at)
		return
	_fx_beam.visible = false
	if rig:
		# Spent: after the fire it pants, chest heaving and open for a beat —
		# a guaranteed opening every breath, the archer's moment.
		_core_open = act_t < act_len - 0.2
		_breath.emitting = false
		_smoke.emitting = false
		_breath_glow.emitting = false
		_stream_light.light_energy = lerpf(_stream_light.light_energy, 0.0, 0.15)
		_mouth_light.light_energy = lerpf(_mouth_light.light_energy, 0.0, 0.1)
	if act_t >= act_len:
		_start(Act.IDLE, _idle_gap())


# ------------------------------------------------------- dragon fire -----

var _breath: GPUParticles3D
var _smoke: GPUParticles3D
var _breath_glow: GPUParticles3D
var _stream_light: OmniLight3D
var _fire_light: OmniLight3D
var _mouth_light: OmniLight3D
var _spot_t := 0.0
var _scorches := 0


## Throat fire (the chest glows from within, brighter when it gapes), a light
## in the mouth for the breath's tell, and the flame stream itself.
func _build_dragon_fire() -> void:
	_fire_light = OmniLight3D.new()
	_fire_light.light_color = Color(1.0, 0.42, 0.1)
	_fire_light.light_energy = 0.8
	_fire_light.omni_range = 9.0 * sz
	_fire_light.shadow_enabled = false
	_fire_light.position = Vector3(0, 0, 1.4)
	_core.add_child(_fire_light)
	_mouth_light = OmniLight3D.new()
	_mouth_light.light_color = Color(1.0, 0.5, 0.15)
	_mouth_light.light_energy = 0.0
	_mouth_light.omni_range = 14.0 * sz
	_mouth_light.position = Vector3(0, 0, 0.8)
	_eye.add_child(_mouth_light)
	_breath = GPUParticles3D.new()
	_breath.name = "Breath"
	_breath.top_level = true
	_breath.emitting = false
	_breath.amount = 260
	_breath.lifetime = 0.8
	_breath.local_coords = false
	_breath.visibility_aabb = AABB(Vector3(-60, -60, -60), Vector3(120, 120, 120))
	var m := ParticleProcessMaterial.new()
	m.direction = Vector3(0, 0, -1)
	m.spread = 7.0
	m.initial_velocity_min = 30.0
	m.initial_velocity_max = 38.0
	m.damping_min = 6.0
	m.damping_max = 12.0
	m.gravity = Vector3(0, 2.5, 0)
	m.scale_min = 2.2
	m.scale_max = 4.0
	var sc := Curve.new()
	sc.add_point(Vector2(0.0, 0.15))
	sc.add_point(Vector2(0.35, 0.7))
	sc.add_point(Vector2(1.0, 1.0))
	var sct := CurveTexture.new()
	sct.curve = sc
	m.scale_curve = sct
	# White-hot at the jaws, orange, then red and dying as it spreads.
	var g := Gradient.new()
	g.set_color(0, Color(1.0, 0.62, 0.22, 1.0))
	g.set_color(1, Color(0.35, 0.05, 0.02, 0.0))
	g.add_point(0.18, Color(1.0, 0.45, 0.1, 0.95))
	g.add_point(0.5, Color(1.0, 0.35, 0.06, 0.7))
	g.add_point(0.8, Color(0.6, 0.12, 0.03, 0.3))
	var gt := GradientTexture1D.new()
	gt.gradient = g
	m.color_ramp = FireFX.flame_gradient()
	m.angle_min = -180.0
	m.angle_max = 180.0
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	m.emission_sphere_radius = 0.35 * sz
	_breath.process_material = m
	var q := QuadMesh.new()
	q.size = Vector2(0.9, 1.1)
	var flame := ShaderMaterial.new()
	flame.shader = preload("res://combat/flame_sprite.gdshader")
	q.material = flame
	_breath.draw_pass_1 = q
	add_child(_breath)
	# A heat glow around the stream: big soft additive blooms, orange, so the
	# breath reads as a mass of fire and not a string of candle flames.
	_breath_glow = GPUParticles3D.new()
	_breath_glow.top_level = true
	_breath_glow.emitting = false
	_breath_glow.amount = 70
	_breath_glow.lifetime = 0.7
	_breath_glow.local_coords = false
	_breath_glow.visibility_aabb = _breath.visibility_aabb
	var gm := m.duplicate() as ParticleProcessMaterial
	gm.scale_min = 4.5
	gm.scale_max = 7.0
	var gg := Gradient.new()
	gg.set_color(0, Color(1.0, 0.5, 0.12, 0.0))
	gg.set_color(1, Color(0.6, 0.1, 0.02, 0.0))
	gg.add_point(0.15, Color(1.0, 0.45, 0.1, 0.32))
	gg.add_point(0.6, Color(0.9, 0.22, 0.04, 0.18))
	var ggt := GradientTexture1D.new()
	ggt.gradient = gg
	gm.color_ramp = ggt
	_breath_glow.process_material = gm
	var gq := QuadMesh.new()
	gq.size = Vector2(1.0, 1.0)
	var gmat := StandardMaterial3D.new()
	gmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	gmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	gmat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	gmat.vertex_color_use_as_albedo = true
	gmat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	gmat.albedo_texture = FireFX._soft_circle_tex()
	gq.material = gmat
	_breath_glow.draw_pass_1 = gq
	add_child(_breath_glow)
	# Smoke rolling off the stream: dark, slower, rising.
	_smoke = GPUParticles3D.new()
	_smoke.top_level = true
	_smoke.emitting = false
	_smoke.amount = 40
	_smoke.lifetime = 2.2
	_smoke.local_coords = false
	_smoke.visibility_aabb = _breath.visibility_aabb
	var sm := ParticleProcessMaterial.new()
	sm.direction = Vector3(0, 0, -1)
	sm.spread = 14.0
	sm.initial_velocity_min = 14.0
	sm.initial_velocity_max = 20.0
	sm.damping_min = 8.0
	sm.damping_max = 12.0
	sm.gravity = Vector3(0, 3.0, 0)
	sm.scale_min = 4.0
	sm.scale_max = 7.0
	var sg := Gradient.new()
	sg.set_color(0, Color(0.1, 0.08, 0.07, 0.0))
	sg.set_color(1, Color(0.06, 0.06, 0.07, 0.0))
	sg.add_point(0.35, Color(0.05, 0.045, 0.04, 0.28))
	var sgt := GradientTexture1D.new()
	sgt.gradient = sg
	sm.color_ramp = sgt
	_smoke.process_material = sm
	var sq := QuadMesh.new()
	sq.size = Vector2(1.0, 1.0)
	var smat := StandardMaterial3D.new()
	smat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	smat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	smat.vertex_color_use_as_albedo = true
	smat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	smat.albedo_texture = FireFX._soft_circle_tex()
	sq.material = smat
	_smoke.draw_pass_1 = sq
	add_child(_smoke)
	# The fire lights what it touches.
	_stream_light = OmniLight3D.new()
	_stream_light.light_color = Color(1.0, 0.5, 0.15)
	_stream_light.light_energy = 0.0
	_stream_light.omni_range = 12.0
	_stream_light.top_level = true
	add_child(_stream_light)


func _breathe(from: Vector3, at: Vector3) -> void:
	_breath.global_transform = Transform3D(Basis.looking_at(at - from, Vector3.UP), from)
	_breath.emitting = true
	_smoke.global_transform = _breath.global_transform
	_smoke.emitting = true
	_breath_glow.global_transform = _breath.global_transform
	_breath_glow.emitting = true
	_stream_light.global_position = at + Vector3(0, 1.5, 0)
	_stream_light.light_energy = 7.0 + 2.0 * sin(act_t * 33.0)
	_mouth_light.light_energy = 9.0 + 2.0 * sin(act_t * 40.0)
	_spot_t -= get_physics_process_delta_time()
	if _spot_t <= 0.0:
		_spot_t = 0.12
		var spot := Vector3(at.x, _floor_y() + 0.05, at.z)
		if _flat_dist(spot, _center()) < (arena.radius if arena else 6.0):
			_fire_spot(spot)


## Scorched stone where the breath passed: looks, not damage (the breath's
## own sweep is the hit).
func _fire_spot(at: Vector3) -> void:
	var n := Node3D.new()
	n.top_level = true
	add_child(n)
	n.global_position = at
	FireFX.add_flames(n, Vector3.ZERO, 1.6, 24)
	var l := OmniLight3D.new()
	l.light_color = Color(1.0, 0.45, 0.12)
	l.light_energy = 2.5
	l.omni_range = 5.0
	l.position = Vector3(0, 1.0, 0)
	n.add_child(l)
	var tw := n.create_tween()
	tw.tween_interval(1.2)
	tw.tween_property(l, "light_energy", 0.0, 1.0)
	tw.tween_callback(n.queue_free)
	# The stone stays blackened a while after the flames die.
	if _scorches < 24:
		_scorches += 1
		var sc := Node3D.new()
		sc.top_level = true
		add_child(sc)
		sc.global_position = at
		FireFX.add_scorch_decal(sc, 1.6)
		var st := sc.create_tween()
		st.tween_interval(9.0)
		st.tween_callback(func() -> void:
			_scorches -= 1
			sc.queue_free())


func _beam_hits(from: Vector3, to: Vector3) -> void:
	var dir := (to - from).normalized()
	for b in _targets():
		# Once a pillar has hidden someone from this breath, it hides them
		# for all of it (cover that held, then failed a frame later, read as
		# a bug).
		if b in _swept or b in _beam_covered or on_pad(b) or _climbing.has(b):
			continue
		var p: Vector3 = b.global_position + Vector3(0, 1.0, 0)
		var along := (p - from).dot(dir)
		if along < 0.0:
			continue
		var closest := from + dir * along
		if closest.distance_to(p) > 1.0:
			continue
		if _occluded(from, p):
			if b not in _beam_covered:
				_beam_covered.append(b)
				_emit("beam_cover", {"who": b.name})
			continue
		_swept.append(b)
		if b.take_hit(GAZE_DAMAGE, dir * 1.2 + Vector3(0, 0.5, 0), false, _hand_body[0], false):
			_emit("beam_hit", {"victim": b.name})
			_still_if_down(b)


# ------------------------------------------------------- stagger/flinch -----

func _stagger(length: float, why: String) -> void:
	if act == Act.DEAD:
		return
	_stagger_plunges = 0
	if _victim != null:
		_release_victim(true)
	if phase >= 2 and why == "poise":
		length = minf(length, 5.0)
	_rise_roar = phase >= 2 and randf() < 0.5
	_start(Act.STAGGER, length + RISE_TIME)
	poise = 0.0
	for i in 2:
		_pinned_left[i] = length   # braced on the rim, bare — the knight's share
	_emit("stagger", {"why": why, "length": length})
	_play("dragon_roar", head_pos(), 4.0, 0.35)
	_shake(0.7)


func _flinch() -> void:
	_stagger(FLINCH_TIME, "flinch")


## Phase 2 staggers are shorter and it sometimes comes out of one roaring:
## the same window, eight seconds, every time, was a loop players named.
var _rise_roar := false
var _stagger_from: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var _stagger_basis: Array[Basis] = [Basis.IDENTITY, Basis.IDENTITY]
var _stagger_palm: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]


func _stagger_contact(i: int) -> Vector3:
	var side := -1.0 if i == 0 else 1.0
	var span := 6.5 if reptile and reptile.spec.get("palms_inward", false) else (6.0 if rig else 3.6)
	var rim := _center() + global_basis.x * side * span - global_basis.z * 4.4
	rim = _clamp_to_platform(rim, 0.5)
	rim.y = _floor_y() + FIST_HALF_THICK * sz
	if reptile == null or not reptile.spec.get("palms_inward", false):
		return rim
	var saved := [_ua[i].transform, _fa[i].transform, _hand[i].transform]
	var elbow := _elbow_n[i]
	var stretch: float = arm_stretch[i]
	var found := false
	for z: float in [-10.0, -7.0, -4.4, 0.0, 4.0]:
		for x: float in [13.0, 12.0, 11.0, 6.5]:
			var p := _clamp_to_platform(_center() + global_basis.x * side * x + global_basis.z * z, 0.5)
			p.y = rim.y
			var wrist := _palm_wrist(i, p, _slam_basis(_flat_dir(global_position, p)))
			var rest := (_arm_len[i].x + _arm_len[i].y) * sz
			arm_stretch[i] = clampf(_ua[i].global_position.distance_to(wrist) / (rest * 0.97), 1.0, ARM_STRETCH_MAX)
			_elbow_n[i] = Vector3.ZERO
			if _brace_fits(i, p):
				rim = p
				found = true
				break
		if found:
			break
	_ua[i].transform = saved[0]
	_fa[i].transform = saved[1]
	_hand[i].transform = saved[2]
	_elbow_n[i] = elbow
	arm_stretch[i] = stretch
	reptile.drive(0.0)
	return rim


func _tick_stagger(_delta: float) -> void:
	var down := act_len - RISE_TIME
	if act_t < down:
		# Reeling back, chest thrown open, both fists braced on the rim to
		# keep from going over: the core high and level with the perches
		# (its lip turns shots from the floor), the head far out of reach.
		_core_open = act_t > 0.5 and reptile == null
		_head_open = act_t > 0.5 and reptile != null
		_lean_goal = deg_to_rad(26.0 if reptile else -6.0)
		_sink_goal = (0.6 if reptile else -0.6) * sz
		if reptile:
			_track_point(_center() + Vector3.UP * 2.5, 0.3)
			for i in 2:
				_pinned_left[i] = maxf(_pinned_left[i], down - act_t)
		for i in 2:
			var rim := _stagger_palm[i]
			var f := _flat_dir(global_position, rim)
			var wrist := _palm_wrist(i, rim, _slam_basis(f))
			if reptile:
				var t := clampf(act_t / minf(1.4, down * 0.5), 0.0, 1.0)
				var travel := smoothstep(0.25, 0.8, t)
				var lift := smoothstep(0.0, 0.25, t) * (1.0 - smoothstep(0.75, 1.0, t))
				wrist = _stagger_from[i].lerp(wrist, travel) + Vector3.UP * lift * 10.0 * sz
				var rest := (_arm_len[i].x + _arm_len[i].y) * sz
				var want := clampf(_ua[i].global_position.distance_to(wrist) / (rest * 0.97), 1.0, ARM_STRETCH_MAX)
				arm_stretch[i] = move_toward(arm_stretch[i], want, _delta * 0.9)
				_set_arm(i, wrist, _stagger_basis[i].slerp(_slam_basis(f), travel))
			else:
				_ease_arm(i, wrist, _slam_basis(f), 4.0)
	else:
		_core_open = false
		_head_open = false
		_sink_goal = 0.0
		_lean_goal = deg_to_rad(18.0)
		for i in 2:
			_rest_arm(i, 2.5)
		if act_t >= act_len:
			if _rise_roar:
				_begin_roar()
			else:
				_start(Act.IDLE, _idle_gap())


# ---------------------------------------------------------------- death ----

func _die() -> void:
	if act == Act.DEAD:
		return
	if _victim != null:
		_release_victim(true)
	_start(Act.DEAD, 8.0)
	_emit("died", {})
	_play("dragon_roar", head_pos(), 14.0, 0.3)
	died.emit()


func _tick_dead(_delta: float) -> void:
	if reptile:
		_withdraw = 14.0 * sz * smoothstep(0.5, 3.0, act_t)
		_place_on_anchor()
		_lean_goal = deg_to_rad(-12.0)
		_sink_goal = 40.0 * sz * smoothstep(3.0, 8.0, act_t)
		_travel_arms()
		return
	if rig:
		_tick_dead_dragon()
		return
	_lean_goal = deg_to_rad(10.0 + 30.0 * minf(act_t / 3.0, 1.0))
	_sink_goal = 40.0 * sz * smoothstep(0.0, 1.0, act_t / 8.0)
	for i in 2:
		_ease_arm(i, _idle_wrist(i) + Vector3(0, -6.0 * minf(act_t / 3.0, 1.0), 0), _grip_basis(i), 1.5)


## The dragon's death, in three beats: it rears back with its wings flared
## and screams at the sky; its claws slip off the rim; it topples backward
## into the mist, wings trailing, the fire inside it guttering out.
func _tick_dead_dragon() -> void:
	var up := to_global(Vector3(0, 40.0, -6.0))
	if act_t < 1.0:
		# A last scream at the sky, wings half flared.
		_lean_goal = deg_to_rad(-10.0)
		_look_at = up
		_look_w = 1.0
		_jaw_goal = 0.6
		for i in 2:
			_rest_arm(i, 3.0)
	elif act_t < 2.0:
		# Talons scrape back across the stone to the edge; the head sags.
		_lean_goal = deg_to_rad(6.0)
		_jaw_goal = 0.25
		_look_at = _center() + Vector3(0, -6.0 * sz, 0)
		_look_w = 0.9
		var k := (act_t - 1.0) / 1.0
		for i in 2:
			var edge := _idle_wrist(i).lerp(_idle_wrist(i) - _flat_dir(global_position, _center()) * (3.0 * sz), k)
			_ease_arm(i, edge, _grip_basis(i), 3.0)
	else:
		# It loses the rim and slides backward into the mist, limp: claws
		# dragging last over the edge, head lolling, wings trailing.
		var k := smoothstep(2.0, 6.5, act_t)
		_lean_goal = deg_to_rad(6.0 - 30.0 * k)
		_sink_goal = 48.0 * sz * k
		_jaw_goal = 0.15
		_look_at = _center() + Vector3(0, -20.0 * sz, 0)
		_look_w = 0.7
		for i in 2:
			var hang := _idle_wrist(i) - _flat_dir(global_position, _center()) * (3.5 * sz) + Vector3(0, -8.0 * sz * k, 0)
			_ease_arm(i, hang, _grip_basis(i), 2.0)


# ============================================================== damage ======

## Every hit on every part lands here. Returns whether it counted as a hit
## (false only when the boss is dead — a glance still "lands", it just does
## next to nothing, and says so with a spark and a clink).
func on_part_hit(part: ColossusPart, damage: float, attacker: Node3D, is_arrow: bool,
		at: Vector3) -> bool:
	if act == Act.DEAD or act == Act.RELOCATE:
		return false
	var mult := HIDE_MULT if reptile else ARMOR_MULT
	var poise_gain := 0.0
	var weak := false
	var what := "armor"
	match part.kind:
		ColossusPart.Kind.HAND_L, ColossusPart.Kind.HAND_R:
			var i := 0 if part.kind == ColossusPart.Kind.HAND_L else 1
			if _pinned_left[i] > 0.0:
				weak = true
				what = "hand"
				mult = HAND_ARROW_MULT if is_arrow else HAND_MELEE_MULT
				if reptile:
					mult = CLAW_ARROW_MULT if is_arrow else CLAW_MELEE_MULT
				poise_gain = damage * (HAND_ARROW_POISE if is_arrow else 1.0)
				if punch_open() and i == _hand_i:
					mult = 0.65 if is_arrow else 1.25
					poise_gain *= 1.3
				if grab_victim() != null and i != _hand_i:
					# The bracing wrist is THE rescue target, for both classes:
					# an archer's arrow there counts as much as a sword cut.
					_rescue_dmg += damage * (1.5 if is_arrow else 1.0)
			elif grab_victim() != null and i == _hand_i and not is_arrow:
				# A sword in the fist that holds him pries it open as well: a
				# knight at the brace whose swing met the gripping claw first
				# used to spend the cut on a clink.
				what = "hand"
				_rescue_dmg += damage
		ColossusPart.Kind.CORE:
			if core_open():
				weak = true
				what = "core"
				mult = CORE_ARROW_MULT if is_arrow else CORE_MELEE_MULT
				if grab_victim() != null:
					_rescue_dmg += damage
		ColossusPart.Kind.HEAD:
			if reptile:
				weak = true
				what = "head"
				mult = _skull_mult(is_arrow)
				poise_gain = damage * (0.2 if is_arrow else 0.7)
			elif _head_open:
				weak = true
				what = "head"
				mult = HEAD_ARROW_MULT if is_arrow else HEAD_MELEE_MULT
			elif attacker != null and on_pad(attacker):
				weak = true
				what = "head"
				mult = HEAD_MOUNT_MULT
				if not is_arrow:
					poise_gain = damage * HEAD_MOUNT_POISE
		ColossusPart.Kind.MARK:
			weak = true
			what = "mark"
			mult = MARK_MULT
			poise_gain = damage * MARK_POISE
			_consume_mark(part)
		ColossusPart.Kind.EYE:
			if eye_charging():
				weak = true
				what = "eye"
				mult = 1.0
				_eye_dmg += damage
		ColossusPart.Kind.MOUTH:
			weak = true
			what = "head"
			mult = _skull_mult(is_arrow)
			poise_gain = damage * (0.2 if is_arrow else 0.7)
	# Holding someone, its whole chest gapes: an arrow anywhere in it counts
	# toward breaking the grip (a full-strength hit, not a glance).
	if reptile == null and not weak and is_arrow and grab_victim() != null and (part.get_parent() == _torso
			or (rig != null and not _is_under(part, _ua[_hand_i]))):
		weak = true
		what = "core"
		mult = 1.0
		_rescue_dmg += damage
	var dealt := damage * mult
	hp = maxf(0.0, hp - dealt)
	# The chains break at the threshold, even mid-stagger: a burst through
	# 60% used to carry the whole fight past its second act.
	if phase == 1 and hp > 0.0 and hp_frac() <= PHASE2_FRAC and act == Act.STAGGER:
		_begin_phase2.call_deferred()
	# Incendiary arrows (an archer spell) set the hide alight where they land.
	if is_arrow and attacker != null and int(attacker.get_meta("incendiary", 0)) > 0:
		attacker.set_meta("incendiary", int(attacker.get_meta("incendiary")) - 1)
		ignite(part, attacker, 4.0, 18.0 if weak else 9.0)
	var who: String = String(attacker.name) if attacker != null else "?"
	_emit("hit", {"part": what, "weak": weak, "by": who, "arrow": is_arrow,
			"dealt": dealt, "raw": damage,
			"on": String(part.get_parent().name) if not weak else what})
	_float_number(at, dealt, weak)
	if weak:
		SlashTrail.spawn_hit_spark(self, at, Color(1.0, 0.55, 0.15))
		_play("hit_flesh", at, 2.0, 0.6)
		_pulse_core(1.0 if what == "core" else 0.5)
	else:
		SlashTrail.spawn_hit_spark(self, at, Color(0.75, 0.75, 0.7))
		_play("hit_flesh" if reptile else ("arrow_impact_stone" if is_arrow else "hit_metal"), at, -2.0, 0.9)
	if poise_gain > 0.0:
		_add_poise(poise_gain, attacker)
	# One rule, every time: an arrow (or blade) into the open, glowing mouth
	# chokes the breath. (A damage threshold made identical shots differ.)
	if what == "eye" and act == Act.GAZE:
		_emit("eye_interrupt", {"by": who})
		if rig:
			# It chokes on its own fire: the breath dies, the head jerks back
			# — no free opening (one sure shot that ALSO bared the chest made
			# the fight a shooting gallery).
			_breath.emitting = false
			_smoke.emitting = false
			_breath_glow.emitting = false
			_fx_beam.visible = false
			_start(Act.IDLE, 1.2)
		else:
			_flinch()
	if hp <= 0.0:
		_die()
	return true


## Arrows into the skull are a poke between openings (0.8x), a real wound only
## once it reels (1.6x); a blade that reaches the head always cuts deep.
## Ranged plinking at 1.8x anytime made the knight optional.
func _skull_mult(is_arrow: bool) -> float:
	if punch_open() or head_down():
		return 1.8 if is_arrow else 3.2
	if is_arrow:
		return 1.6 if _head_open else 0.8
	return SKULL_OPEN_MULT if _head_open else SKULL_MULT


func _add_poise(amount: float, by: Node3D) -> void:
	if act == Act.STAGGER or act == Act.DEAD:
		return
	poise += amount
	_poise_quiet = 0.0
	# The last stretch: its fire is failing and it buckles sooner (testers sat
	# 50-85 s at 10% with no opening).
	var need := POISE_MAX * (0.55 if hp_frac() < 0.18 else 1.0)
	if poise >= need:
		_emit("poise_break", {"by": by.name if by else "?"})
		_stagger(STAGGER_TIME, "poise")


## t such that smoothstep(0, 1, t) == y (bisection; y in 0..1).
func _unsmooth(y: float) -> float:
	var lo := 0.0
	var hi := 1.0
	for _i in 14:
		var mid := (lo + hi) * 0.5
		if mid * mid * (3.0 - 2.0 * mid) < y:
			lo = mid
		else:
			hi = mid
	return (lo + hi) * 0.5


## A blow that drops someone does not also fling the body: a downed ally
## stays on the stone for the partner to raise.
func _still_if_down(b: Node3D) -> void:
	if ("is_dead" in b and b.is_dead) or ("current_health" in b and b.current_health <= 0.0):
		_grace = 2.5
		b._knockback_velocity = Vector3.ZERO
		b.velocity = Vector3.ZERO
		_emit("downed", {"victim": b.name})


## Did the game actually count that hit as blocked (a shield, facing it)?
## Holding guard is not blocking: the archer has no shield.
func _blocked(b: Node3D) -> bool:
	if b.has_method("is_paladin") and not b.is_paladin():
		return false   # no shield, no block (the log said otherwise)
	return "_guard_recoil" in b and bool(b._guard_recoil)


func _in_iframes(b: Node3D) -> bool:
	if not ("is_rolling" in b) or not b.is_rolling:
		return false
	var elapsed: float = b.ROLL_DURATION - b._roll_timer
	return elapsed >= b.ROLL_IFRAME_START and elapsed <= b.ROLL_IFRAME_END


# ================================================================ pose ======

func _apply_pose(delta: float) -> void:
	if act not in [Act.SHIFT, Act.RELOCATE, Act.DEAD]:
		_withdraw = move_toward(_withdraw, 0.0, delta * 4.0 * sz)
	if act != Act.SLAM:
		_slam_far = 0.0
		if act != Act.HEAD_SLAM:
			_lunge_goal = 0.0
		if act not in [Act.STAGGER, Act.IDLE, Act.SHAKE]:
			for a in 2:
				arm_stretch[a] = move_toward(arm_stretch[a], 1.0, delta * 0.6)
	# In fast for the blow, back at the arm's pace.
	_lunge = lerpf(_lunge, _lunge_goal, 1.0 - exp(-(4.5 if _lunge_goal > _lunge else 1.6) * delta))
	var k := 1.0 - exp(-3.0 * delta)
	var lean_goal := _lean_goal
	# The supplied biped's chest is much deeper than the old stone rig: it
	# leans past the cap only to carry a far punch.
	if reptile:
		var cap := HEAD_LEAN if act == Act.HEAD_SLAM else lerpf(REPTILE_LEAN_CAP, SLAM_LEAN_FAR, _slam_far)
		lean_goal = minf(lean_goal, deg_to_rad(cap))
	_lean = lerpf(_lean, lean_goal, k)
	_sink = lerpf(_sink, _sink_goal, 1.0 - exp(-2.2 * delta))
	var t := _rest_torso
	# Full lean for the wyvern too: its shoulders must come over the rim or
	# the wing-claws fall short of the stone the fight promises they reach
	# (the head's own floor clamp keeps its chin up).
	var lean := _lean
	var twist := 0.0
	var roll := 0.0
	if act == Act.SHAKE:
		var shake_t := maxf(0.0, act_t - SHAKE_WINDUP)
		var strength := 3.0 if act_t < SHAKE_WINDUP else 12.0
		roll = deg_to_rad(strength * sin(act_t * 12.0))
		twist = deg_to_rad(8.0 * sin(shake_t * 10.0))
	_roll = lerpf(_roll, roll, 1.0 - exp(-18.0 * delta))
	if model_kind in ["lizard", "reptilian"]:
		if act == Act.SWEEP:
			var through := smoothstep(0.0, 1.0, (act_t - SWEEP_WINDUP) / SWEEP_TIME)
			twist = deg_to_rad(lerpf(-12.0, 12.0, through) * _sweep_dir)
		elif act == Act.SLAM:
			var through := smoothstep(0.0, 1.0, act_t / (_slam_windup + SLAM_STRIKE))
			twist = deg_to_rad(lerpf(-7.0, 4.0, through) * (-1.0 if _hand_i == 0 else 1.0))
	_twist = lerpf(_twist, twist, 1.0 - exp(-5.0 * delta))
	# _sink is in world metres; the torso lives in the (scaled) root's space.
	t = Transform3D(Basis(Vector3.UP, _twist) * Basis(Vector3.FORWARD, _roll) * Basis(Vector3.RIGHT, lean), Vector3(0, -_sink / sz, 0)) * t
	_torso.transform = t
	if act == Act.HEAD_SLAM and reptile:
		_pose_head_slam()
	for i in _legs.size():
		_legs[i].rotation.x = -lean * 0.18
		_legs[i].rotation.y = _twist * 0.15
		_shins[i].rotation.x = lean * 0.30
	for i in 2:
		_solve_arm(i, _wrist[i], _hand_basis[i])
	if rig:
		if _look_w >= 0.0:
			_pose_dragon_head(delta)
		rig.drive(delta, lean, _sink, [_wing_fold(0), _wing_fold(1)])
	if reptile:
		reptile.drive(delta)
		_constrain_terrain(delta)
	# Check this frame's solved hand, not the previous frame's windup pose.
	for check in _reach_checks:
		var hand: int = check.hand
		if _arm_stopped[hand]:
			continue
		var gap := _flat_dist(fist_pos(hand), check.want) if reptile else fist_pos(hand).distance_to(check.want)
		if gap > 1.2 * sz:
			_emit("reach_short", {"gap": snappedf(gap / sz, 0.1), "hand": check.hand})
	_reach_checks.clear()


func _constrain_terrain(delta: float) -> void:
	if _terrain == null:
		return
	_terrain_back = maxf(0.0, _terrain_back - delta * 1.5)
	_place_on_anchor()
	reptile.drive(0.0)
	#Keep the long jaw above the stone by lifting the snout, before moving
	#the whole body back. Otherwise looking down made the boss retreat.
	for step in 32:
		#A head slam's skull is placed on its mark: rotating it about the
		#pivot swung the muzzle's lock metres off the ring (the titan's jaw
		#touches stone at impact). It is raised straight up further down.
		if act == Act.HEAD_SLAM or not _terrain.blocked(["head", "jaw"]):
			break
		if _head.rotation.x <= -0.85:
			break
		_head.rotate_object_local(Vector3.RIGHT, -0.025)
		reptile.drive(0.0)
	var body := ["pelvis", "spine", "chest", "neck", "head", "jaw"]
	if act == Act.HEAD_SLAM:
		# The skull is placed on its mark, not carried by the body: moving
		# the body back never frees it (the boss once retreated 1.8 km).
		# Raise it off whatever it met, so it comes to rest on the stone.
		body = ["pelvis", "spine", "chest", "neck"]
		for step in 40:
			if not _terrain.blocked(["head", "jaw"]):
				break
			_head.global_position += Vector3.UP * (0.15 * sz)
			reptile.drive(0.0)
	for step in 80:
		if not _terrain.blocked(body):
			break
		_terrain_back += 0.15
		_place_on_anchor()
		reptile.drive(0.0)
	for i in 2:
		_constrain_arm(i, delta)
	#Some supplied skin weights span the shoulder and the opposite arm.
	#Recheck the finished pose after both IK chains have changed those joints.
	for i in [0, 1, 0]:
		var suffix := ".L" if i == 0 else ".R"
		var bones := ["upperarm" + suffix, "forearm" + suffix, "hand" + suffix]
		if _terrain.blocked(bones):
			_retract_arm(i, bones, 0.0)
			_remember_arm(i, bones)


func _constrain_arm(i: int, delta: float) -> void:
	var suffix := ".L" if i == 0 else ".R"
	var bones := ["upperarm" + suffix, "forearm" + suffix, "hand" + suffix]
	var striking := i == _hand_i and (
			(act == Act.SWEEP and act_t >= SWEEP_WINDUP and act_t < SWEEP_WINDUP + SWEEP_TIME)
			or (act == Act.SLAM and act_t >= _slam_windup and (reptile == null or act_t < _punch_hold))
			or (act == Act.GRAB and act_t >= GRAB_WINDUP and not _struck))
	if _arm_stopped[i] and striking:
		_wrist[i] = _safe_wrist[i]
		_hand_basis[i] = _safe_basis[i]
	elif not striking and not _arm_pose[i].is_empty():
		_wrist[i] = _safe_wrist[i].move_toward(_wrist[i], delta * 18.0)
	_solve_arm(i, _wrist[i], _hand_basis[i], false)
	reptile.drive(0.0)
	#The claw's thickness changes when it rolls into a sweep or opens to grab.
	for step in 8:
		var lift: float = _terrain.floor_lift(bones)
		if lift < 0.01:
			break
		_wrist[i].y += minf(lift, 0.75)
		_solve_arm(i, _wrist[i], _hand_basis[i], false)
		reptile.drive(0.0)
	var blocked: bool = _terrain.blocked(bones)
	if not blocked and not _arm_pose[i].is_empty():
		for bn: String in bones:
			if not _terrain.motion_clear(bn, _arm_pose[i][bn], _terrain.pose(bn)):
				blocked = true
				break
	if blocked:
		if striking and not _arm_stopped[i]:
			_arm_stopped[i] = true
			_emit("terrain_block", {"hand": i, "attack": act_name(), "obstacle": _terrain.last_hit})
			_play("hit_metal", fist_pos(i), 1.0, 0.55)
			_dust(fist_pos(i))
		_retract_arm(i, bones, 0.0 if striking else delta * 8.0)
	_remember_arm(i, bones)


func _remember_arm(i: int, bones: Array) -> void:
	_safe_wrist[i] = _hand[i].global_position
	_safe_basis[i] = _hand[i].global_basis.orthonormalized()
	for bn: String in bones:
		_arm_pose[i][bn] = _terrain.pose(bn)


func _retract_arm(i: int, bones: Array, lift: float) -> void:
	if not _arm_pose[i].is_empty():
		_wrist[i] = _safe_wrist[i]
		_hand_basis[i] = _safe_basis[i]
		_wrist[i].y += lift
	#Recover vertically before trying to pass the obstacle again.
	for step in 40:
		_solve_arm(i, _wrist[i], _hand_basis[i], false)
		reptile.drive(0.0)
		if not _terrain.blocked(bones):
			return
		_wrist[i].y += 0.2


## Move an arm's goal smoothly toward a pose (idle, windups).
func _ease_arm(i: int, wrist: Vector3, hand_basis: Basis, rate: float) -> void:
	_return_t[i] = -1.0
	var k := 1.0 - exp(-rate * get_physics_process_delta_time())
	# Step, don't slide: a wrist going somewhere lifts on the way and sets
	# down at the end (the lift fades as it arrives). Straight-line easing
	# dragged the fists across the stone like a mouse cursor.
	var far := Vector2(wrist.x - _wrist[i].x, wrist.z - _wrist[i].z).length()
	if wrist.y <= _wrist[i].y + 0.5 * sz:
		wrist += Vector3.UP * minf(far * 0.45, 3.5 * sz)
	_wrist[i] = _wrist[i].lerp(wrist, k)
	_hand_basis[i] = _hand_basis[i].slerp(hand_basis.orthonormalized(), k)


## Put an arm exactly there (strikes: the timing must be the promised one).
func _set_arm(i: int, wrist: Vector3, hand_basis: Basis) -> void:
	_return_t[i] = -1.0
	_wrist[i] = wrist
	_hand_basis[i] = hand_basis.orthonormalized()


func _rest_arm(i: int, rate: float) -> void:
	var target := _idle_wrist(i)
	if reptile and _arm_len[i] != Vector2.ZERO:
		var rest := (_arm_len[i].x + _arm_len[i].y) * sz
		var want := clampf(_ua[i].global_position.distance_to(target) / (rest * 0.97), 1.0, ARM_STRETCH_MAX)
		arm_stretch[i] = move_toward(arm_stretch[i], want, get_physics_process_delta_time())
	if reptile == null or (_return_t[i] < 0.0 and _flat_dist(_wrist[i], target) < 1.0):
		_ease_arm(i, target, _grip_basis(i), rate)
		return
	if _return_t[i] < 0.0:
		_return_t[i] = 0.0
		_return_from[i] = _wrist[i]
		_return_basis[i] = _hand_basis[i]
	_return_t[i] = minf(1.0, _return_t[i] + get_physics_process_delta_time())
	var t: float = _return_t[i]
	var travel := smoothstep(0.3, 0.8, t)
	var lift := smoothstep(0.0, 0.3, t) * (1.0 - smoothstep(0.8, 1.0, t))
	# Clear a standing player before withdrawing the solid forearm.
	_wrist[i] = _return_from[i].lerp(target, travel) + Vector3.UP * lift * (3.0 + sz)
	_hand_basis[i] = _return_basis[i].slerp(_grip_basis(i), travel)
	if t >= 1.0:
		_return_t[i] = -1.0


## Analytic two-bone IK. Segments hang along their local -Y; the elbow bends
## out to the side and back, like a giant bracing on a ledge.
func _solve_arm(i: int, wrist: Vector3, hand_basis: Basis, smooth: bool = true) -> void:
	var ua := _ua[i]
	var fa := _fa[i]
	var s := ua.global_position
	var to := wrist - s
	if _arm_len[i] == Vector2.ZERO:
		_arm_len[i] = Vector2(fa.position.length(), _hand[i].position.length())
	if reptile:
		var seg := segment_stretch(i)
		fa.position = fa.position.normalized() * _arm_len[i].x * seg.x
		_hand[i].position = _hand[i].position.normalized() * _arm_len[i].y * seg.y
	var upper := fa.position.length() * sz
	var fore := _hand[i].position.length() * sz
	var d := clampf(to.length(), absf(upper - fore) + 0.2, upper + fore - 0.02)
	var dir := to.normalized() if to.length_squared() > 1e-6 else Vector3.DOWN
	var pole := _arm_pole(i, _torso.global_basis.orthonormalized())
	var n := dir.cross(pole)
	if n.length_squared() < 1e-6:
		n = dir.cross(Vector3.UP)
	n = n.normalized()
	# The elbow plane turns, it never flips: a wrist sweeping across the body
	# (or rising overhead, past the pole) used to snap the elbow to the other
	# side in one frame — the arm "popped". Ease the plane instead.
	# The pole stays the authority; the plane only rotates toward it around
	# the shoulder->wrist axis, a little each frame (smooth even when the
	# wanted side is 180 degrees away).
	var prev := _elbow_n[i] - dir * _elbow_n[i].dot(dir)
	if prev.length_squared() > 1e-6:
		prev = prev.normalized()
		var turn := atan2(dir.dot(prev.cross(n)), prev.dot(n))
		var k := 1.0 - exp(-10.0 * get_physics_process_delta_time()) if smooth else 0.0
		n = prev.rotated(dir, turn * k).normalized()
	_elbow_n[i] = n
	var cos_a := (upper * upper + d * d - fore * fore) / (2.0 * upper * d)
	var a := acos(clampf(cos_a, -1.0, 1.0))
	var upper_dir := dir.rotated(n, a)
	var elbow := s + upper_dir * upper
	var fore_dir := ((s + dir * d) - elbow).normalized()
	# Bases carry the colossus's size: an orthonormal basis here would shrink
	# every limb (and its children) back to 1x.
	ua.global_basis = _along(upper_dir, pole).scaled(Vector3.ONE * sz)
	fa.global_basis = _along(fore_dir, pole).scaled(Vector3.ONE * sz)
	_hand[i].global_basis = hand_basis.scaled(Vector3.ONE * sz)


var _elbow_n: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]


## Where the elbow wants to go, in the frame of the torso. The colossus braced
## like a man on a ledge (elbows out and back); the dragon walks on its
## wing-wrists like a bat, elbows high above its back.
func _arm_pole(i: int, frame: Basis) -> Vector3:
	var side := frame.x * (-1.0 if i == 0 else 1.0)
	if model_kind == "dragon":
		return (side * 0.75 + frame.y * 1.0 - frame.z * 0.55).normalized()
	var pole := (side * 1.0 + Vector3.UP * 0.35 - frame.z * 0.5).normalized()
	if reptile and reptile.spec.get("palms_inward", false) and act in [Act.IDLE, Act.STAGGER, Act.SHAKE]:
		#Keep the elbow above the wide brace and outside the perch columns.
		pole = (side * 1.5 + Vector3.UP - frame.z * 0.3).normalized()
	if reptile and act == Act.SLAM and i == _hand_i and _slam_far > 0.0:
		# Elbow straight up, not out to the side: a wide elbow swung the
		# forearm into the towers flanking the line to the centre.
		pole = pole.lerp(Vector3.UP - frame.z * 0.3, _slam_far).normalized()
	return pole


## The golden rule's tripwire: a fist the logic says is on the stone must be
## on the stone. An arm that cannot reach its target hangs short in the IK
## while hits and braces still count at the target — log it for the sims.
func _queue_reach_check(i: int, want: Vector3) -> void:
	_reach_checks.append({"hand": i, "want": want})


## arm_stretch split into (upper arm, forearm) factors with the same total.
func segment_stretch(i: int) -> Vector2:
	var k := arm_stretch[i]
	var rest := _arm_len[i]
	if k <= 1.0 or rest.x <= 0.0:
		return Vector2.ONE
	var fore := minf(k, FOREARM_STRETCH_MAX)
	return Vector2((k * (rest.x + rest.y) - fore * rest.y) / rest.x, fore)


## A basis whose local -Y points along `dir`, rolled so +X leans to `hint`.
func _along(dir: Vector3, hint: Vector3) -> Basis:
	var y := -dir.normalized()
	var x := hint - y * hint.dot(y)
	if x.length_squared() < 1e-6:
		x = Vector3.RIGHT - y * y.x
	x = x.normalized()
	var z := x.cross(y)
	return Basis(x, y, z)


## Fist down on the stone, knuckle-embers (local -Z) facing the sky.
func _slam_basis(f: Vector3) -> Basis:
	var y := -f
	var z := Vector3.DOWN
	var x := y.cross(z).normalized()
	return Basis(x, y, x.cross(y).normalized()).orthonormalized()


## Raised overhead, back of the fist toward the target.
func _cocked_basis(f: Vector3) -> Basis:
	if reptile:
		var up := (Vector3.UP - f * 0.25).normalized()
		var x := (-up).cross(f).normalized()
		return Basis(x, -up, x.cross(-up)).orthonormalized()
	var y := Vector3.DOWN.lerp(f, 0.3).normalized() * -1.0
	var z := f
	var x := y.cross(z).normalized()
	return Basis(x, y, x.cross(y).normalized()).orthonormalized()


## Open hand reaching: fingers (local -Y) toward the target.
func _palm_basis(f: Vector3) -> Basis:
	if reptile:
		return _slam_basis(f)
	var y := -(f + Vector3.DOWN * 0.4).normalized()
	var z := Vector3.UP
	var x := y.cross(z).normalized()
	return Basis(x, y, x.cross(y).normalized()).orthonormalized()


## Knuckles leading through the sweep.
func _sweep_basis(phi: float) -> Basis:
	if reptile:
		#Keep the broad palm flat. Rolling this claw onto its side made both
		#sweep heights intersect the floor by several metres.
		return _slam_basis(_flat_dir(global_position, _arc_point(phi, 1.0, 0.0)))
	var t := _sweep_tangent(phi)
	var y := -_flat_dir(global_position, _arc_point(phi, 1.0, 0.0))
	var z := -t
	var x := y.cross(z).normalized()
	return Basis(x, y, x.cross(y).normalized()).orthonormalized()


## Idle spreads the arms; attacks bring the palms back to the near rim.
func _grip_basis(i: int) -> Basis:
	var f := _flat_dir(global_position, _idle_palm(i))
	return _slam_basis(f)


func _idle_wrist(i: int) -> Vector3:
	var p := _idle_palm(i)
	return _palm_wrist(i, p, _slam_basis(_flat_dir(global_position, p)))


func _idle_palm(i: int) -> Vector3:
	var side := -1.0 if i == 0 else 1.0
	var c := _center()
	var toward := _flat_dir(global_position, c)
	var right := toward.cross(Vector3.UP) * -1.0
	var r: float = arena.radius if arena else 6.0
	var span := 7.0 if reptile and reptile.spec.get("palms_inward", false) else (5.6 if rig else 4.2)
	var p := c - toward * (r - 0.4) + right * side * span * sz
	if reptile and reptile.spec.get("palms_inward", false) and act in [Act.IDLE, Act.SHAKE]:
		p = global_position + global_basis.x * side * 24.0 + global_basis.z * 4.0
		p.y = _ua[i].global_position.y + sz
		return p
	p = _clamp_to_platform(p, 0.3)
	return Vector3(p.x, _floor_y() + (FIST_HALF_THICK * sz) + 0.1, p.z)


func _track_party(weight: float) -> void:
	var party := _targets()
	if party.is_empty():
		return
	var mid := Vector3.ZERO
	for b in party:
		mid += b.global_position
	_track_point(mid / party.size(), weight)


func _track_point(p: Vector3, weight: float) -> void:
	if reptile:
		var dir := global_basis.orthonormalized().inverse() * (p + Vector3.UP - _head.global_position)
		var limit := 0.6
		var yaw := clampf(atan2(dir.x, dir.z), -limit, limit) * weight
		var pitch := clampf(-atan2(dir.y, Vector2(dir.x, dir.z).length()), -0.25, 0.4)
		if _head_shy > 0.0:
			# Its skull came down on someone with nowhere to step (a tower
			# top): lift and turn away rather than swallow them.
			yaw *= 0.3
			pitch = -0.25
		var world := global_basis.orthonormalized() * Basis.from_euler(Vector3(pitch, yaw, 0))
		var goal := _torso.global_basis.orthonormalized().inverse() * world
		_head.basis = _head.basis.slerp(goal, 1.0 - exp(-4.0 * get_physics_process_delta_time()))
		return
	if rig:
		_look_at = p
		_look_w = weight
		return
	# The head follows; the body only leans. Looking is cheap and readable.
	var local: Vector3 = (_head.get_parent() as Node3D).to_local(p) - _rest_head.origin
	var yaw := clampf(atan2(local.x, local.z), -0.7, 0.7) * weight
	var pitch := clampf(-atan2(local.y, Vector2(local.x, local.z).length()), -0.6, 0.9) * weight
	var goal := Transform3D(Basis.from_euler(Vector3(pitch, yaw, 0.0)), Vector3.ZERO) * _rest_head
	goal.origin = _rest_head.origin
	_head.transform = _head.transform.interpolate_with(goal, 1.0 - exp(-4.0 * get_physics_process_delta_time()))


# ============================================================== helpers =====

func _targets(lures: bool = true) -> Array:
	var out: Array = []
	if arena == null:
		return out
	var pool: Array = arena.party()
	if lures and arena.has_method("lures"):
		pool = pool + arena.lures()
	for b in pool:
		if is_instance_valid(b) and not b.is_dead and b.current_health > 0.0:
			out.append(b)
	return out


## Fists reach this far from the shoulders (world metres).
func reach() -> float:
	return (UPPER + FORE + FIST * 0.6) * sz * 0.95


## How much body and arm a punch at `p` needs from the acting hand.
## 0 within the arm's own reach, 1 a full SLAM_FAR_SPAN past it (the big
## field's centre). Absolute, not "fraction of the way to the centre": on
## the small field the centre is barely past the arm, and a full overhead
## arc there overshot into the far perches.
func plan_slam_reach(p: Vector3) -> void:
	_slam_far = 0.0
	if reptile:
		var short := _flat_dist(_ua[_hand_i].global_position, p) - reach() * 0.9
		_slam_far = clampf(short / (SLAM_FAR_SPAN * sz), 0.0, 1.0)
	_lunge_goal = SLAM_LUNGE * sz * _slam_far


## Where a downward punch can land: the arm's reach, and for the reptile
## everything from its own rim to the platform's centre.
func _in_slam_reach(p: Vector3) -> bool:
	if _in_reach(p):
		return true
	if reptile == null or arena == null:
		return false
	var c := _center()
	var home := c + Vector3(sin(_anchor_angle), 0, -cos(_anchor_angle)) * float(arena.boss_distance)
	return _flat_dist(home, p) <= float(arena.boss_distance) + 0.5 * sz


func _in_reach(p: Vector3) -> bool:
	for i in 2:
		if _ua[i].global_position.distance_to(p) < reach():
			return true
	return false


func _center() -> Vector3:
	return arena.center if arena else Vector3.ZERO


func _floor_y() -> float:
	return arena.floor_y if arena else 0.0


func _on_floor(b: Node3D) -> bool:
	return b.global_position.y - _floor_y() < 1.0


func _flat_dist(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


## Never zero: a degenerate direction (two points on one vertical) falls
## back to the way the colossus faces, so no basis built from it collapses.
func _flat_dir(from: Vector3, to: Vector3) -> Vector3:
	var d := Vector3(to.x - from.x, 0.0, to.z - from.z)
	if d.length_squared() > 1e-6:
		return d.normalized()
	var f := Vector3(global_basis.z.x, 0.0, global_basis.z.z)
	return f.normalized() if f.length_squared() > 1e-6 else Vector3.FORWARD


## A spot on the platform where a fist can lie in the open: clear of the
## perch columns and their ramps. A fist braced under a ramp could not be
## struck — the stone blocked every swing, and the rescue never came.
func _open_stone(want: Vector3, margin: float) -> Vector3:
	var best := _clamp_to_platform(want, margin)
	if arena == null or _clear_of_perches(best):
		return best
	for k in range(1, 9):
		for sgn in [1.0, -1.0]:
			var c := _center()
			var off := want - c
			off.y = 0.0
			var p := c + off.rotated(Vector3.UP, sgn * 0.18 * k)
			p = _clamp_to_platform(Vector3(p.x, want.y, p.z), margin + 0.1 * k)
			if _clear_of_perches(p):
				return p
	return best


func _clear_of_perches(p: Vector3) -> bool:
	for perch in arena.perches:
		var top: Vector3 = perch.top
		if _flat_dist(p, top) < 2.6:
			return false
		var a: Vector3 = perch.ramp_base
		var b: Vector3 = perch.ramp_top
		var ab := Vector2(b.x - a.x, b.z - a.z)
		var ap := Vector2(p.x - a.x, p.z - a.z)
		var t := clampf(ap.dot(ab) / maxf(ab.length_squared(), 0.001), 0.0, 1.0)
		if (ap - ab * t).length() < 2.0:
			return false
	return true


func _clamp_to_platform(p: Vector3, margin: float) -> Vector3:
	var c := _center()
	var r: float = (arena.radius if arena else 6.0) - margin
	var off := Vector3(p.x - c.x, 0.0, p.z - c.z)
	if off.length() > r:
		off = off.normalized() * r
	return Vector3(c.x + off.x, p.y, c.z + off.z)


## Angle around the boss's own vertical axis, 0 = straight ahead, + = its left.
func _boss_angle(p: Vector3) -> float:
	var local := to_local(p)
	return atan2(local.x, local.z)


func _sweep_radius() -> float:
	return global_position.distance_to(Vector3(_center().x, global_position.y, _center().z))


func _arc_point(phi: float, r: float, y: float) -> Vector3:
	var p := to_global(Vector3(sin(phi) * r, 0.0, cos(phi) * r) / sz)
	return Vector3(p.x, y, p.z)


func _sweep_tangent(phi: float) -> Vector3:
	var a := _arc_point(phi, 10.0, 0.0)
	var b := _arc_point(phi + 0.01 * _sweep_dir, 10.0, 0.0)
	return _flat_dir(a, b)


## The punch's arc, shoulder to apex to just above the mark, clear of the
## arena's stone (the terrain guard would stop the claw on anything in it).
func _slam_path_clear(i: int, p: Vector3) -> bool:
	var f := _flat_dir(global_position, p)
	var apex := p + Vector3(0, 5.0 * sz, 0) - f * (3.0 * sz)
	var near := p + Vector3(0, 1.5 * sz, 0)
	var space := get_world_3d().direct_space_state
	var exclude: Array[RID] = _terrain.query.exclude if _terrain != null else _party_rids()
	for seg: Array in [[_ua[i].global_position, apex], [apex, near]]:
		var q := PhysicsRayQueryParameters3D.create(seg[0], seg[1], 1)
		q.exclude = exclude
		if not space.intersect_ray(q).is_empty():
			return false
	return true


func _occluded(from: Vector3, to: Vector3) -> bool:
	var q := PhysicsRayQueryParameters3D.create(from, to, 1)
	q.exclude = _party_rids()
	return not get_world_3d().direct_space_state.intersect_ray(q).is_empty()


func _party_rids() -> Array[RID]:
	var out: Array[RID] = []
	for b in _targets():
		out.append(b.get_rid())
	return out


func _idle_gap() -> float:
	return randf_range(0.7, 1.4) if phase == 1 else randf_range(0.45, 1.0)


func _emit(kind: String, data: Dictionary) -> void:
	data["t"] = Time.get_ticks_msec() / 1000.0
	data["hp"] = hp
	combat_event.emit(kind, data)


# ================================================================ body ======

func _build_body() -> void:
	if model_kind == "reptilian":
		reptile = ReptilianRig.new()
		if reptile.build(self):
			_torso = reptile.torso
			_head = reptile.head
			_jaw = reptile.jaw
			_eye = reptile.mouth
			_core = reptile.focus
			_tail = reptile.tail
			_ua = reptile.ua
			_fa = reptile.fa
			_hand = reptile.hand
			FIST = 3.0
			_build_reptilian_hitboxes()
			_build_pads()
			_skin = SkinProbe.new()
			var hide := reptile.model.find_child("Reptilian_Hide", true, false) as MeshInstance3D
			# Retain claw sampling detail with the denser replacement skull.
			if hide == null or not _skin.build(hide, reptile.skel, 6000, reptile.spec.get("palms_inward", false)):
				_skin = null
			else:
				_hull_hitboxes_from_skin()
				_terrain = preload("res://enemies/colossus/terrain_guard.gd").new()
				_terrain.build(reptile)
			return
		reptile = null
		model_kind = "lizard"
	if model_kind == "dragon":
		rig = DragonRig.new()
		if rig.build(self):
			_torso = rig.torso
			_head = rig.head
			_jaw = rig.jaw
			_eye = rig.eye
			_core = rig.core
			_tail = rig.tail
			_ua = rig.ua
			_fa = rig.fa
			_hand = rig.hand
			_eye_mat = rig.eye_mat
			_core_mat = rig.core_mat
			_ember_mats = rig.ember_mats
			if _eye_mat == null:
				_eye_mat = _mat(Color(1, 0.6, 0.2), 0.0, 0.3, 2.0)
			if _core_mat == null:
				_core_mat = _mat(Color(1, 0.42, 0.1), 0.0, 0.4, 2.0)
			_build_dragon_hitboxes()
			_build_pads()
			return
		rig = null
		model_kind = "lizard"
	var model: Node3D = null
	var path := LIZARD_PATH if model_kind == "lizard" else COLOSSUS_PATH
	if ResourceLoader.exists(path):
		var scene := load(path) as PackedScene
		if scene:
			model = scene.instantiate()
	if model:
		add_child(model)
		_torso = model.find_child("Colossus_Torso", true, false)
	if _torso == null:
		if model:
			model.queue_free()
		_build_placeholder()
	else:
		_head = model.find_child("Colossus_Head", true, false)
		_tail = model.find_child("Colossus_Tail", true, false) as Node3D
		_jaw = model.find_child("Colossus_Jaw", true, false) as Node3D
		_eye = model.find_child("Colossus_Eye", true, false)
		_core = model.find_child("Colossus_Core", true, false)
		for side in ["L", "R"]:
			var i := 0 if side == "L" else 1
			_ua[i] = model.find_child("Colossus_UpperArm_" + side, true, false)
			_fa[i] = model.find_child("Colossus_Forearm_" + side, true, false)
			_hand[i] = model.find_child("Colossus_Hand_" + side, true, false)
		for n in ["Colossus_ShutterL", "Colossus_ShutterR"]:
			var sh := model.find_child(n, true, false) as Node3D
			if sh:
				_shutters.append(sh)
				_shutter_bare.append(0.0)
				_shutter_shut.append(deg_to_rad(90.0) if n.ends_with("L") else deg_to_rad(-90.0))
		_adopt_materials(model)
		for side in ["L", "R"]:
			var leg := model.find_child("Lizard_Thigh_" + side, true, false) as Node3D
			var shin := model.find_child("Lizard_Shin_" + side, true, false) as Node3D
			if leg and shin:
				_legs.append(leg)
				_shins.append(shin)
	_build_hitboxes()
	_build_pads()


## Grey-box stand-in with the same pivots as the Blender model, so the fight
## is fully playable before (or without) the art.
func _build_placeholder() -> void:
	var stone := _mat(Color(0.2, 0.2, 0.22), 0.0, 0.9)
	var bronze := _mat(Color(0.25, 0.38, 0.3), 0.7, 0.45)
	_torso = _pivot(self, "Colossus_Torso", Vector3.ZERO)
	_box(_torso, Vector3(9.0, 12.5, 5.0), Vector3(0, 6.25, 0), stone)
	_head = _pivot(_torso, "Colossus_Head", Vector3(0, 13.2, 0.3))
	_box(_head, Vector3(3.0, 3.2, 3.0), Vector3(0, 1.6, 0), bronze)
	_eye = _pivot(_head, "Colossus_Eye", Vector3(0, 1.6, 1.25))
	_core = _pivot(_torso, "Colossus_Core", Vector3(0, 9.5, 2.3))
	for i in 2:
		var side := -1.0 if i == 0 else 1.0
		var sfx := "L" if i == 0 else "R"
		_ua[i] = _pivot(_torso, "Colossus_UpperArm_" + sfx, Vector3(side * 5.5, 12.0, 0))
		_capsule(_ua[i], 1.4, UPPER + 1.0, Vector3(0, -UPPER * 0.5, 0), stone)
		_fa[i] = _pivot(_ua[i], "Colossus_Forearm_" + sfx, Vector3(0, -UPPER, 0))
		_capsule(_fa[i], 1.15, FORE + 0.8, Vector3(0, -FORE * 0.5, 0), bronze)
		_hand[i] = _pivot(_fa[i], "Colossus_Hand_" + sfx, Vector3(0, -FORE, 0))
		_box(_hand[i], Vector3(2.2, 2.6, 1.8), Vector3(0, -FIST, 0), stone)
		var knuckles := _box(_hand[i], Vector3(1.9, 1.6, 0.2), Vector3(0, -FIST - 0.2, -0.95),
				_mat(Color(1.0, 0.42, 0.1), 0.0, 0.5, 1.0))
		_ember_mats.append(knuckles.material_override)
	var eye_mesh := MeshInstance3D.new()
	var es := SphereMesh.new()
	es.radius = 0.45
	es.height = 0.9
	eye_mesh.mesh = es
	_eye_mat = _mat(Color(1.0, 0.92, 0.7), 0.0, 0.3, 2.0)
	eye_mesh.material_override = _eye_mat
	_eye.add_child(eye_mesh)
	var core_mesh := MeshInstance3D.new()
	var cs := SphereMesh.new()
	cs.radius = 0.85
	cs.height = 1.7
	core_mesh.mesh = cs
	_core_mat = _mat(Color(1.0, 0.42, 0.1), 0.0, 0.4, 2.0)
	core_mesh.material_override = _core_mat
	_core.add_child(core_mesh)
	# The socket's lower lip, so the core reads as set INTO the chest.
	_box(_torso, Vector3(2.6, 0.5, 0.6), Vector3(0, 8.4, 2.7), bronze)
	for i in 2:
		var side := -1.0 if i == 0 else 1.0
		var hinge := _pivot(_torso, "Colossus_Shutter" + ("L" if i == 0 else "R"),
				Vector3(side * 1.1, 9.5, 2.5))
		_box(hinge, Vector3(1.1, 2.1, 0.25), Vector3(-side * 0.55, 0, 0), bronze)
		_shutters.append(hinge)
		_shutter_shut.append(0.0)
		_shutter_bare.append(side * deg_to_rad(-100.0))


func _adopt_materials(model: Node) -> void:
	for mi in model.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		for s in m.mesh.get_surface_count():
			var mat := m.mesh.surface_get_material(s)
			if mat == null:
				continue
			var name := String(mat.resource_name)
			if model_kind == "lizard" and not name.begins_with("Colossus_Ember") and not name.begins_with("Colossus_Eye"):
				var skin := mat.duplicate() as StandardMaterial3D
				if skin:
					skin.vertex_color_use_as_albedo = true
					# Keep the sculpt's scale/crease roughness map.
					if name == "Lizard_EyeBall":
						skin.roughness = 0.22
					skin.normal_scale = 0.72
					m.set_surface_override_material(s, skin)
			if name.begins_with("Colossus_Ember") or name.begins_with("Colossus_Eye"):
				var dup := mat.duplicate() as StandardMaterial3D
				if dup == null:
					continue
				# Blender's strengths blow out to white under the game's ACES
				# tonemap: an ember has to stay ORANGE to read as an ember.
				if name.begins_with("Colossus_Ember"):
					# Ember orange for the colossus; the lizard-king's venom green.
					dup.emission = Color(1.0, 0.36, 0.06) if model_kind == "colossus" \
							else Color(0.48, 0.39, 0.12)
					dup.emission_energy_multiplier = 1.2
					dup.emission_texture = null
				else:
					dup.emission_energy_multiplier = 0.05 if model_kind == "lizard" else 2.5
					if model_kind == "lizard":
						dup.emission = Color(0.58, 0.43, 0.18)
				m.set_surface_override_material(s, dup)
				if name.begins_with("Colossus_Eye"):
					_eye_mat = dup
				elif m.get_parent() == _core or m == _core or m.get_parent() == null:
					_core_mat = dup
				elif _is_under(m, _core):
					_core_mat = dup
				elif _is_under(m, _hand[0]) or _is_under(m, _hand[1]):
					_ember_mats.append(dup)
	if _eye_mat == null:
		_eye_mat = _mat(Color(1, 0.9, 0.7), 0.0, 0.3, 2.0)
	if _core_mat == null:
		_core_mat = _mat(Color(1, 0.42, 0.1), 0.0, 0.4, 2.0)


func _is_under(n: Node, parent: Node) -> bool:
	return parent != null and (n == parent or parent.is_ancestor_of(n))


## Same parts and kinds as the colossus, shaped to the wyvern: a chest and a
## belly of armour, the chest-fire weak point with its scute lip below it,
## the skull, the throat (the breath interrupt), and the wing-arms. Riders on
## the shoulders strike the base of the skull-ridge on the neck.
func _build_dragon_hitboxes() -> void:
	var chest := _part(_torso, ColossusPart.Kind.ARMOR, _capsule_shape(2.5, 7.5), rig.rest_pos("spine2").lerp(rig.rest_pos("chest"), 0.75))
	chest.rotation.x = deg_to_rad(25.0)
	var belly := _part(_torso, ColossusPart.Kind.ARMOR, _capsule_shape(2.2, 6.0), rig.rest_pos("spine1").lerp(rig.rest_pos("spine2"), 0.5))
	belly.rotation.x = deg_to_rad(35.0)
	var core_at := rig.rest_pos("core")
	_lip = _part(_torso, ColossusPart.Kind.ARMOR, _box_shape(Vector3(2.6, 0.7, 0.9)), core_at + Vector3(0, -1.15, 0.45))
	_part(_core, ColossusPart.Kind.CORE, _sphere_shape(0.95), Vector3(0, 0, 0.15))
	# The cranium only: the snout is left to the mouth target (an arrow into
	# the open jaws chokes the breath), which a whole-skull box used to swallow.
	var skull_len := rig.head_center.length() * 2.0
	_part(_head, ColossusPart.Kind.HEAD, _box_shape(Vector3(2.0, 1.7, skull_len * 0.42)), Vector3(0, 0.25, skull_len * 0.2))
	_head_body = _part(rig.neck, ColossusPart.Kind.HEAD, _sphere_shape(1.5), Vector3.ZERO)
	_part(_eye, ColossusPart.Kind.EYE, _sphere_shape(0.75), Vector3(0, 0, 0.2))
	for i in 2:
		# Inside the visible wing-arm, not around it: the bones are lean and
		# arrows meant for the chest must not die on air beside them.
		_part(_ua[i], ColossusPart.Kind.ARMOR, _capsule_shape(0.75, UPPER), Vector3(0, -UPPER * 0.5, 0))
		_part(_fa[i], ColossusPart.Kind.ARMOR, _capsule_shape(0.55, FORE), Vector3(0, -FORE * 0.5, 0))
		_hand_body[i] = _part(_hand[i], ColossusPart.Kind.HAND_L if i == 0 else ColossusPart.Kind.HAND_R,
				_box_shape(Vector3(2.0, 2.7, 1.7)), Vector3(0, -FIST, 0))


## The head reaches for what it watches: the skull turns toward the point
## (limited), and the whole head travels a little toward it along the neck.
var _look_at := Vector3.ZERO
var _look_w := -1.0


func _pose_dragon_head(delta: float) -> void:
	var parent := _head.get_parent() as Node3D
	var rest := _rest_head
	# Holding someone or reeling: the head rears up and away, the chest in
	# full view (a low head soaked the rescue arrows meant for its chest).
	if (act == Act.GRAB and grab_victim() != null) or (act == Act.STAGGER and _core_open):
		_look_at = to_global(Vector3(0, 26.0, 10.0))
		_look_w = 0.8
	var want := parent.to_local(_look_at) - rest.origin
	if want.length_squared() < 1e-4:
		return
	var z0 := rest.basis.z.normalized()
	var q := Quaternion(z0, want.normalized())
	var ang := q.get_angle()
	var lim := deg_to_rad(55.0)
	if ang > lim:
		q = Quaternion.IDENTITY.slerp(q, lim / ang)
	q = Quaternion.IDENTITY.slerp(q, clampf(_look_w, 0.0, 1.0))
	var goal := Transform3D(Basis(q) * rest.basis, rest.origin)
	# Keep the skull level: no corkscrew from the arc rotation.
	var gz := goal.basis.z.normalized()
	var gx := Vector3.UP.cross(gz).normalized()
	if gx.length_squared() > 1e-4:
		goal.basis = Basis(gx, gz.cross(gx).normalized(), gz)
	# A small reach: a head that lunged at everything it watched hung in
	# every arrow's path to the chest, the claws and the runes.
	var reach := want.normalized() * 0.9 * _look_w
	reach.y = clampf(reach.y, -0.3, 0.4)
	goal.origin = rest.origin + reach
	# Never lay the chin on the stone: a head down in the slam ring read as a
	# bite the hitboxes never made.
	var g := parent.to_global(goal.origin)
	var low := _floor_y() + 6.0 * sz
	if g.y < low:
		goal.origin = parent.to_local(Vector3(g.x, low, g.z))
	var k := 1.0 - exp(-3.2 * delta)
	_head.transform = _head.transform.interpolate_with(goal, k)


## How folded each wing is (1 = along the forearm, 0 = flared).
func _wing_fold(i: int) -> float:
	match act:
		Act.ROAR:
			return 0.05 if act_t > ROAR_WINDUP * 0.4 else 0.6
		Act.STAGGER:
			return 0.35
		Act.SHIFT, Act.RELOCATE:
			return 0.45
		Act.DEAD:
			return 0.35 if act_t < 1.0 else 0.75
		Act.SWEEP:
			return 0.55 if i == _hand_i else 0.85
		Act.SLAM:
			return 0.7 if i == _hand_i else 0.9
		Act.SHAKE:
			return 0.3
		Act.GAZE:
			return 0.5
	return 0.92


func _build_hitboxes() -> void:
	_part(_torso, ColossusPart.Kind.ARMOR, _box_shape(Vector3(8.6, 12.0, 4.6)), Vector3(0, 6.0, -0.2))
	# The socket lip is armour in FRONT of the core: low shots hit it.
	_lip = _part(_torso, ColossusPart.Kind.ARMOR, _box_shape(Vector3(2.6, 0.7, 0.9)), Vector3(0, 8.35, 2.75))
	_part(_core, ColossusPart.Kind.CORE, _sphere_shape(0.95), Vector3(0, 0, 0.15))
	# The helm's box stops short of the face so the eye sits PROUD of it: an
	# eye inside the head's armour could never be hit, and the gaze could
	# never be interrupted (testers saw it happen ~0.1 times a fight).
	_head_body = _part(_head, ColossusPart.Kind.HEAD, _box_shape(Vector3(3.0, 3.2, 2.2)), Vector3(0, 1.6, -0.4))
	if model_kind == "lizard":
		# The broad muzzle stops short of the exposed eye at the temple.
		_part(_head, ColossusPart.Kind.HEAD, _box_shape(Vector3(2.6, 1.5, 2.5)), Vector3(0, 1.7, 2.4))
		_part(_eye, ColossusPart.Kind.EYE, _sphere_shape(0.46), Vector3(-0.10, 0, 0.16))
	else:
		_part(_eye, ColossusPart.Kind.EYE, _sphere_shape(0.7), Vector3(0, 0, 0.3))
	for i in 2:
		_part(_ua[i], ColossusPart.Kind.ARMOR, _capsule_shape(1.3, UPPER), Vector3(0, -UPPER * 0.5, 0))
		_part(_fa[i], ColossusPart.Kind.ARMOR, _capsule_shape(1.1, FORE), Vector3(0, -FORE * 0.5, 0))
		_hand_body[i] = _part(_hand[i], ColossusPart.Kind.HAND_L if i == 0 else ColossusPart.Kind.HAND_R,
				_box_shape(Vector3(2.3, 2.7, 1.9)), Vector3(0, -FIST, 0))


func _build_reptilian_hitboxes() -> void:
	_part(_torso, ColossusPart.Kind.ARMOR, _capsule_shape(3.2, 10.0), Vector3(0, 5.3, -1.5))
	_segment_part(_torso, reptile.rest_pos("chest"), reptile.rest_pos("neck"), 3.2)
	_segment_part(_torso, reptile.rest_pos("neck"), reptile.rest_pos("head"), 2.0)
	# Sized toward the skull and claw you SEE (skin probe: ~8.5 x 6.6 x 10 m
	# skull, ~6 x 10 x 5 m claw), still inside them: with the hide now solid,
	# the old small boxes sat out of a sword's reach behind the scales.
	_head_body = _part(_head, ColossusPart.Kind.HEAD,
			_box_shape(Vector3(6.0, 5.0, 7.6)), Vector3(-0.3, 0.0, 2.4))
	_part(_eye, ColossusPart.Kind.MOUTH, _sphere_shape(1.35), Vector3.ZERO)
	for i in 2:
		var upper := _fa[i].position.length()
		var fore := _hand[i].position.length()
		_part(_ua[i], ColossusPart.Kind.ARMOR, _capsule_shape(1.4, upper), Vector3(0, -upper * 0.5, 0))
		_part(_fa[i], ColossusPart.Kind.ARMOR, _capsule_shape(1.05, fore), Vector3(0, -fore * 0.5, 0))
		_hand_body[i] = _part(_hand[i], ColossusPart.Kind.HAND_L if i == 0 else ColossusPart.Kind.HAND_R,
				_box_shape(Vector3(4.6, 7.6, 3.2)), Vector3(-0.2, -FIST - 0.6, 0))


func _segment_part(parent: Node3D, a: Vector3, b: Vector3, radius: float) -> void:
	var d := b - a
	var part := _part(parent, ColossusPart.Kind.ARMOR,
			_capsule_shape(radius, d.length() + radius * 2.0), (a + b) * 0.5)
	part.basis = Basis(Quaternion(Vector3.UP, d.normalized()))


func _part(parent: Node3D, kind: int, shape: Shape3D, at: Vector3) -> ColossusPart:
	var body := ColossusPart.new()
	body.boss = self
	body.kind = kind
	body.name = "Hit_%s" % ColossusPart.Kind.keys()[kind]
	var cs := CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)
	body.position = at
	parent.add_child(body)
	return body


## The skull and claws take the SHAPE you see. Hand-sized boxes were 46-86%
## outside the visible mesh (animation_review's fit check): heroes were
## shoved by air under the jaw, and a blade on a visible claw met no box. A
## box cannot sit inside a claw (its palm is ~0.8 m thick, fingers spread), so
## each becomes the convex hull of its bone's skin samples, set 0.2 m in
## along their normals: inside the scales, spanning only the finger gaps.
const HULL_INSET := 0.2


func _hull_hitboxes_from_skin() -> void:
	_skin.update()
	for f in [[_head_body, "head"], [_hand_body[0], "hand.L"], [_hand_body[1], "hand.R"]]:
		var part: ColossusPart = f[0]
		var pivot := part.get_parent() as Node3D
		var inv := pivot.global_transform.affine_inverse()
		var pts := PackedVector3Array()
		var centre := Vector3.ZERO
		# The titan's skin splits its skull between head, jaw and neck: too few
		# samples were the head's alone, and the hull fell back to a box.
		var skull_r := float(reptile.spec.get("head_hull_radius", 0.0))
		var names: Array = ["head", "jaw"] if f[1] == "head" and skull_r > 0.0 else [f[1]]
		var min_weight := float(reptile.spec.get("hand_hull_weight", 0.85)) if f[1] != "head" else 0.85
		for i in _skin.pos.size():
			# Mostly this bone's: a sample half on the forearm bends with the wrist.
			if not (_skin.bone_names[_skin.dominant[i]] in names) or _skin_weight_of(i, names) < min_weight:
				continue
			var l: Vector3 = inv * (_skin.pos[i] - _skin.nrm[i] * HULL_INSET)
			# The skull's hull is the skull: horn tips and the crest of spines
			# behind it would stretch a convex hull over empty air. Bodies
			# that need it give a radius.
			if f[1] == "head" and skull_r > 0.0 and l.distance_to(reptile.head_center) > skull_r:
				continue
			pts.append(l)
			centre += l
		# Long, spread claws (the titan's): a hull over the fingertips spans the
		# gaps between them. Bodies that need it keep only the samples nearest
		# the wrist; hitboxes stay small (golden rule).
		var keep := float(reptile.spec.get("hand_hull_keep", 1.0))
		if f[1] != "head" and keep < 1.0 and pts.size() > 40:
			var by_reach := Array(pts)
			by_reach.sort_custom(func(a: Vector3, b: Vector3) -> bool: return a.length() < b.length())
			pts = PackedVector3Array(by_reach.slice(0, int(by_reach.size() * keep)))
			centre = Vector3.ZERO
			for q in pts:
				centre += q
		if pts.size() < 8:
			push_warning("hitbox hull: too few skin samples for %s" % part.name)
			continue
		centre /= pts.size()
		for k in pts.size():
			pts[k] -= centre
		var hull := ConvexPolygonShape3D.new()
		hull.points = pts
		(part.get_child(0) as CollisionShape3D).shape = hull
		part.position = centre


## Total weight sample `i` takes from the bones named.
func _skin_weight_of(i: int, names: Array) -> float:
	var w := 0.0
	for k in 4:
		if _skin.bone_names[_skin.bones[i * 4 + k]] in names:
			w += _skin.weights[i * 4 + k]
	return w


func _skin_weight(i: int) -> float:
	var w := 0.0
	for k in 4:
		if _skin.bones[i * 4 + k] == _skin.dominant[i]:
			w += _skin.weights[i * 4 + k]
	return w


func _claw_touches(i: int, b: Node3D) -> bool:
	#Grab contact runs before the regular skin tick; query the solved pose.
	if _skin_pose != reptile.pose_serial:
		_skin.update()
		_skin_pose = reptile.pose_serial
	for h: float in [0.3, 1.0, 1.6]:
		var q := b.global_position + Vector3.UP * h
		if part_surface_point(_hand_body[i], q).distance_to(q) < 1.1:
			return true
		var c := _skin.contact(q)
		if float(c.depth) > -0.45 and String(c.bone) == ("hand.L" if i == 0 else "hand.R"):
			return true
	return false


## A point of a part's hitbox nearest `from` (pivot-frame hull vertices or
## box clamp), in world space.
func part_surface_point(part: ColossusPart, from: Vector3) -> Vector3:
	var cs := part.get_child(0) as CollisionShape3D
	var l := cs.global_transform.affine_inverse() * from
	if cs.shape is BoxShape3D:
		var half := (cs.shape as BoxShape3D).size * 0.5
		return cs.global_transform * l.clamp(-half, half)
	if cs.shape is ConvexPolygonShape3D:
		if not cs.shape.has_meta("surface_faces"):
			cs.shape.set_meta("surface_faces", cs.shape.get_debug_mesh().get_faces())
		var faces: PackedVector3Array = cs.shape.get_meta("surface_faces")
		var best := INF
		var bp := Vector3.ZERO
		for i in range(0, faces.size(), 3):
			var p := _triangle_point(l, faces[i], faces[i + 1], faces[i + 2])
			var d := p.distance_squared_to(l)
			if d < best:
				best = d
				bp = p
		return cs.global_transform * bp
	return cs.global_position


func _triangle_point(p: Vector3, a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	var n := (b - a).cross(c - a)
	if n.length_squared() > 0.000001:
		var q := p - n * (p - a).dot(n) / n.length_squared()
		if (b - a).cross(q - a).dot(n) >= 0.0 and (c - b).cross(q - b).dot(n) >= 0.0 \
				and (a - c).cross(q - c).dot(n) >= 0.0:
			return q
	var best := Geometry3D.get_closest_point_to_segment(p, a, b)
	for edge in [[b, c], [c, a]]:
		var q := Geometry3D.get_closest_point_to_segment(p, edge[0], edge[1])
		if p.distance_squared_to(q) < p.distance_squared_to(best):
			best = q
	return best


# ================================================================ skin =====
# The visible hide is the boss's real outline. The hitbox capsules are thin
# stand-ins for weapons; sims with the skin probe found heroes standing up
# to 1.3 m inside the head, chest and arms (5.6% of all player-time).
const SKIN_CLEAR := 0.34          # capsule radius + a hair
var _skin: SkinProbe
var _pad_rest: Array[Vector3] = []
var _head_shy := 0.0
var _skin_t := 0.0
var _skin_fresh := false
var _skin_pose := -1


## LOB_SKIN_SOLID=0 turns the skin back into scenery (A/B for the sims).
var _skin_solid := OS.get_environment("LOB_SKIN_SOLID") != "0"


func _skin_tick(delta: float) -> void:
	_skin_fresh = false
	if _skin == null or not _skin_solid:
		return
	_skin_t -= delta
	if _skin_t > 0.0:
		return
	_skin_t = 1.0 / 40.0
	_skin.update()
	_skin_pose = reptile.pose_serial
	_skin_fresh = true
	_seat_pads_on_skin()


## Ledges ride ON the shoulders: the top of the hide under each ledge's
## standing area, not a fixed offset that sank riders into the chest.
func _seat_pads_on_skin() -> void:
	for i in _pads.size():
		var pad := _pads[i]
		var rest_y: float = _pad_rest[i].y
		#The supplied shoulder offsets sit above the hide in a low brace.
		#Allow the ledge to settle there, but never follow a claw to the floor.
		var rest_g := (pad.get_parent() as Node3D).to_global(_pad_rest[i])
		var gb := pad.global_basis
		var top := _skin.top_in(rest_g, gb.x * 1.4, gb.z * 1.1, maxf(_floor_y() + 3.0 * sz, rest_g.y - 6.0 * sz), rest_g.y + 1.5 * sz)
		var want := rest_g.y
		if top != -INF:
			want = top + 0.08 - 0.2 * gb.y.length()
		var c := pad.global_position
		pad.global_position = Vector3(rest_g.x, lerpf(c.y, want, 0.6), rest_g.z)
		pad.position.y = clampf(pad.position.y, rest_y - 6.0, rest_y + 1.5)
		# Solid only where riders can be: never while it sinks, wades or
		# dies, and never down at the level of the platform.
		var low := pad.global_position.y < _floor_y() + 2.5
		(pad.get_child(0) as CollisionShape3D).disabled = low or act in [Act.RELOCATE, Act.SHIFT, Act.DEAD]


## Sample the capsule axis from feet to head. Depth includes its radius.
func _skin_contact(b: Node3D) -> Dictionary:
	return _skin_contact_at(b.global_position)


func _skin_contact_at(at: Vector3) -> Dictionary:
	var best := {"depth": -INF, "normal": Vector3.ZERO}
	for h: float in [0.3, 0.6, 0.9, 1.2, 1.5]:
		var r := _skin.contact(at + Vector3(0, h, 0))
		var d := float(r.depth) + SKIN_CLEAR
		if d > float(best.depth):
			best = {"depth": d, "normal": r.normal, "bone": r.bone}
	return best


func _skin_free(at: Vector3) -> bool:
	for h: float in [0.3, 0.6, 0.9, 1.2, 1.5]:
		if float(_skin.contact(at + Vector3(0, h, 0)).depth) > -SKIN_CLEAR:
			return false
	return true


## Heroes on the floor (or a perch) are never inside the hide: step them out
## along the surface onto clear stone, never over the rim.
func _skin_separate() -> void:
	if _skin == null or not _skin_fresh:
		return
	var space := get_world_3d().direct_space_state
	for p: Player in arena.party():
		# The fallen too: a skull swinging over a downed archer left them lying
		# inside it (37 s of 57 in the C8 sims), out of their partner's reach.
		if p == _victim or _climbing.has(p) or on_pad(p):
			continue
		var c := _skin_contact(p)
		if float(c.depth) <= 0.0:
			continue
		var out: Vector3 = c.normal
		out.y = 0.0
		if out.length() < 0.3:
			out = _flat_dir(_torso.global_position, p.global_position)
		out = out.normalized()
		var dest := Vector3.INF
		# Straight out first, then fanning toward open stone.
		for step in range(0, 10):
			var dist := float(c.depth) + 0.05 + step * 0.35
			for ang: float in [0.0, 0.6, -0.6, 1.2, -1.2, 1.9, -1.9]:
				var at := p.global_position + out.rotated(Vector3.UP, ang) * dist
				if _flat_dist(at, _center()) > float(arena.radius) - 0.6:
					continue
				if not _skin_free(at) or not _footing(space, p, at):
					continue
				dest = at
				break
			if dest != Vector3.INF:
				break
		if dest == Vector3.INF:
			# Nothing clear up here (a tower top under its head): step down
			# off the stone rather than stay inside the hide.
			for ang: float in [0.0, 0.8, -0.8, 1.6, -1.6, PI]:
				var at := p.global_position + out.rotated(Vector3.UP, ang) * (float(c.depth) + 1.6)
				if _flat_dist(at, _center()) > float(arena.radius) - 0.8:
					continue
				if _skin_free(at) and _footing(space, p, at, 7.0):
					dest = at
					break
		if dest == Vector3.INF:
			if String(c.get("bone", "")) in ["head", "jaw", "neck"]:
				_head_shy = 0.6
			continue
		p.global_position = dest
		# No walking straight back in.
		var v_in := p.velocity.dot(-out)
		if v_in > 0.0:
			p.velocity += out * v_in


## A rider the neck or head has come down over: shuffle along the ledge out
## of the hide, or, with no room left on it, slide off onto the platform.
func _skin_riders() -> void:
	if _skin == null or not _skin_fresh:
		return
	for i in _pads.size():
		var pad := _pads[i]
		for b in _targets(false):
			if not (b is Player) or not _on_this_pad(pad, b) or _left_pad.has(b) or is_climbing(b):
				continue
			var c := _skin_contact(b)
			if float(c.depth) <= 0.15:
				continue
			var out: Vector3 = c.normal
			out = (out - pad.global_basis.y.normalized() * out.dot(pad.global_basis.y.normalized()))
			if out.length() < 0.2:
				out = pad.global_basis.x.normalized() * (-1.0 if i == 0 else 1.0)
			var moved := false
			for step in range(1, 6):
				var at: Vector3 = b.global_position + out.normalized() * (float(c.depth) + 0.1 * step)
				var l := pad.to_local(at)
				if absf(l.x) > 1.9 or absf(l.z) > 1.5:
					break
				if _skin_free(at):
					b.global_position = at
					moved = true
					break
			if not moved:
				dismount(b, _center())


## Stone to stand on at `at` (within a step of the body's height) and no wall
## or pillar in the capsule's way there.
func _footing(space: PhysicsDirectSpaceState3D, p: Player, at: Vector3, max_drop: float = 0.8) -> bool:
	var down := PhysicsRayQueryParameters3D.create(at + Vector3(0, 1.0, 0), at + Vector3(0, -max_drop, 0), 1)
	down.exclude = [p.get_rid()]
	var hit := space.intersect_ray(down)
	if hit.is_empty():
		return false
	var cs := p.get_node_or_null("CollisionCapsule") as CollisionShape3D
	if cs == null:
		return true
	var q := PhysicsShapeQueryParameters3D.new()
	var sh := (cs.shape as CapsuleShape3D).duplicate() as CapsuleShape3D
	sh.radius -= 0.03
	sh.height -= 0.08
	q.shape = sh
	q.transform = Transform3D(cs.global_basis, cs.global_position + (at - p.global_position) + Vector3(0, 0.05, 0))
	q.collision_mask = 1 | 2 | 8
	var ex: Array[RID] = [p.get_rid()]
	for o in p.get_collision_exceptions():
		ex.append(o.get_rid())
	q.exclude = ex
	return space.intersect_shape(q, 1).is_empty()


var _climb_query: PhysicsShapeQueryParameters3D


func _climb_stone_free(at: Vector3) -> bool:
	if _climb_query == null:
		_climb_query = PhysicsShapeQueryParameters3D.new()
		var shape := CapsuleShape3D.new()
		shape.radius = SKIN_CLEAR
		shape.height = 1.8
		_climb_query.shape = shape
		_climb_query.collision_mask = 1
		_climb_query.exclude = _terrain.query.exclude if _terrain else _party_rids()
	_climb_query.transform.origin = at + Vector3.UP * 0.94
	return get_world_3d().direct_space_state.intersect_shape(_climb_query, 1).is_empty()


func _climb_stone_clear(a: Vector3, b: Vector3) -> bool:
	_climb_query.transform.origin = a + Vector3.UP * 0.94
	_climb_query.motion = b - a
	var clear := get_world_3d().direct_space_state.cast_motion(_climb_query)[0] >= 0.999
	_climb_query.motion = Vector3.ZERO
	return clear


## Mouth and spell targets overlay the solid skin. They catch weapons,
## but must not make an invisible step outside the creature's silhouette.
func configure_player_collision(b: PhysicsBody3D) -> void:
	for part in get_tree().get_nodes_in_group("colossus_parts"):
		if is_ancestor_of(part) and not player_solid(part):
			b.add_collision_exception_with(part)


## Whether a part's collider stops a hero's body. The skull and claws are
## hit-only when the hide is solid: their hull spans the gaps between the
## fingers (a claw is concave, no convex shape fits inside it), so as a
## collider it shoved heroes with air. The hide itself (_skin_separate) is
## what a hero bumps into there.
func player_solid(part: ColossusPart) -> bool:
	if reptile == null:
		return false
	match part.kind:
		ColossusPart.Kind.CORE, ColossusPart.Kind.EYE, ColossusPart.Kind.MARK, ColossusPart.Kind.MOUTH:
			return false
		ColossusPart.Kind.HEAD, ColossusPart.Kind.HAND_L, ColossusPart.Kind.HAND_R:
			return _skin == null or not _skin_solid
	return true


# A descending limb must separate bodies along the floor. Letting the
# physics solver choose the shortest exit can push a capsule below it.
func _separate_party() -> void:
	for part in get_tree().get_nodes_in_group("colossus_parts"):
		if is_ancestor_of(part):
			part.force_update_transform()
	for p: Player in arena.party():
		if p == _victim or _climbing.has(p) or on_pad(p):
			continue
		var cs := p.get_node("CollisionCapsule") as CollisionShape3D
		var q := PhysicsShapeQueryParameters3D.new()
		q.shape = cs.shape
		q.transform = cs.global_transform
		q.collision_mask = 2
		var excluded: Array[RID] = [p.get_rid()]
		for other in p.get_collision_exceptions():
			excluded.append(other.get_rid())
		q.exclude = excluded
		if get_world_3d().direct_space_state.intersect_shape(q, 1).is_empty():
			continue
		_clear_body_contact(p, q)


func _clear_body_contact(p: Player, q: PhysicsShapeQueryParameters3D) -> void:
	var space := get_world_3d().direct_space_state
	var start := q.transform
	var toward := _flat_dir(p.global_position, _center())
	# A small inset ignores the floor contact while checking the free space.
	var shape := (q.shape as CapsuleShape3D).duplicate() as CapsuleShape3D
	shape.radius -= 0.02
	shape.height -= 0.04
	q.shape = shape
	for step in range(1, 25):
		for angle in [0.0, 0.7854, -0.7854, 1.5708, -1.5708, 2.3562, -2.3562, PI]:
			var offset := toward.rotated(Vector3.UP, angle) * (step * 0.2)
			var at := p.global_position + offset
			if _flat_dist(at, _center()) > float(arena.radius) - 0.5:
				continue
			q.transform = start.translated(offset)
			q.collision_mask = 1 | 2 | 8
			if not space.intersect_shape(q, 1).is_empty():
				continue
			q.transform = start
			q.collision_mask = 1 | 8
			q.motion = offset
			var path := space.cast_motion(q)
			q.motion = Vector3.ZERO
			if path[0] < 0.99:
				continue
			p.global_position = at
			return


## Where a blade can actually meet a claw near `point`: the nearest point of
## that hand's hitbox to the swordsman (the claw's centre sits metres behind
## its solid scales, and a bot waiting to reach the centre never swung).
func claw_melee_pos(point: Vector3, from: Vector3) -> Vector3:
	if reptile == null or point == Vector3.INF:
		return point
	for i in 2:
		if fist_pos(i).distance_to(point) < 1.5:
			return part_surface_point(_hand_body[i], from + Vector3.UP * 1.0)
	return point


func head_melee_pos(from: Vector3) -> Vector3:
	if reptile == null:
		return head_pos() - Vector3.UP * 1.4
	return part_surface_point(_head_body, from + Vector3.UP * 1.3)


func _pivot(parent: Node3D, n: String, at: Vector3) -> Node3D:
	var p := Node3D.new()
	p.name = n
	p.position = at
	parent.add_child(p)
	return p


func _box(parent: Node3D, size: Vector3, at: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var m := BoxMesh.new()
	m.size = size
	mi.mesh = m
	mi.position = at
	mi.material_override = mat
	parent.add_child(mi)
	return mi


func _capsule(parent: Node3D, r: float, h: float, at: Vector3, mat: Material) -> void:
	var mi := MeshInstance3D.new()
	var m := CapsuleMesh.new()
	m.radius = r
	m.height = h
	mi.mesh = m
	mi.position = at
	mi.material_override = mat
	parent.add_child(mi)


func _mat(c: Color, metal: float, rough: float, emit: float = 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.metallic = metal
	m.roughness = rough
	if emit > 0.0:
		m.emission_enabled = true
		m.emission = c
		m.emission_energy_multiplier = emit
	return m


func _box_shape(size: Vector3) -> BoxShape3D:
	var s := BoxShape3D.new()
	s.size = size
	return s


func _sphere_shape(r: float) -> SphereShape3D:
	var s := SphereShape3D.new()
	s.radius = r
	return s


func _capsule_shape(r: float, h: float) -> CapsuleShape3D:
	var s := CapsuleShape3D.new()
	s.radius = r
	s.height = h + r * 2.0
	return s


# ============================================================ telegraphs ====

# ================================================================ chains ====
# Two iron chains from the wrist manacles back to the crags behind it: they
# strain as it swings, and snap when phase 2 begins.

var _chains: Array[MeshInstance3D] = []


func _build_chains() -> void:
	var iron := StandardMaterial3D.new()
	iron.albedo_color = Color(0.13, 0.12, 0.12)
	iron.metallic = 0.8
	iron.roughness = 0.45
	for i in 2:
		var side := -1.0 if i == 0 else 1.0
		var mi := MeshInstance3D.new()
		var m := CylinderMesh.new()
		m.top_radius = 0.16
		m.bottom_radius = 0.16
		m.height = 1.0
		m.radial_segments = 6
		mi.mesh = m
		mi.material_override = iron
		mi.top_level = true
		add_child(mi)
		_chains.append(mi)


func _update_chains() -> void:
	for i in _chains.size():
		var c := _chains[i]
		if not c.visible:
			continue
		var a := _fa[i].global_position - _fa[i].global_basis.y * (FORE - 0.8)
		# Anchored behind it, wherever it wades: it drags its chains along.
		var b := to_global(Vector3((-1.0 if i == 0 else 1.0) * 24.0, 6.0, -26.0))
		var mid := (a + b) * 0.5
		var y := (b - a)
		var len := y.length()
		y = y / maxf(len, 0.001)
		var x := y.cross(Vector3.UP)
		if x.length_squared() < 1e-4:
			x = Vector3.RIGHT
		x = x.normalized()
		c.global_transform = Transform3D(Basis(x, y * len, x.cross(y)), mid)


func _snap_chains() -> void:
	for i in _chains.size():
		var c := _chains[i]
		if not c.visible:
			continue
		var at := _fa[i].global_position - _fa[i].global_basis.y * (FORE - 0.8)
		SlashTrail.spawn_hit_spark(self, at, Color(1.0, 0.7, 0.3))
		_play("hit_metal", at, 10.0, 0.5)
		c.visible = false


func _build_fx() -> void:
	var root := Node3D.new()
	root.name = "ColossusFX"
	root.top_level = true
	add_child(root)
	_fx_ring_mat = _fx_mat(Color(1, 0.25, 0.08, 0.85))
	_fx_fill_mat = _fx_mat(Color(1, 0.25, 0.08, 0.35))
	_fx_sweep_mat = _fx_mat(Color(1, 0.3, 0.1, 0.3))
	_fx_sweep_mat.vertex_color_use_as_albedo = true
	_fx_sweep_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_fx_beam_mat = _fx_mat(Color(1.0, 0.9, 0.6, 0.9))
	_fx_beam_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD   # a beam of light, not a plank
	_fx_ring = MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.92
	torus.outer_radius = 1.0
	torus.rings = 48
	_fx_ring.mesh = torus
	_fx_ring.material_override = _fx_ring_mat
	_fx_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(_fx_ring)
	_fx_ring_fill = MeshInstance3D.new()
	var disc := CylinderMesh.new()
	disc.top_radius = 1.0
	disc.bottom_radius = 1.0
	disc.height = 0.02
	_fx_ring_fill.mesh = disc
	_fx_ring_fill.material_override = _fx_fill_mat
	_fx_ring_fill.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(_fx_ring_fill)
	_fx_sweep = MeshInstance3D.new()
	_fx_sweep.material_override = _fx_sweep_mat
	_fx_sweep.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(_fx_sweep)
	_fx_beam = MeshInstance3D.new()
	var beam := CylinderMesh.new()
	beam.top_radius = 1.0
	beam.bottom_radius = 1.0
	beam.height = 1.0
	_fx_beam.mesh = beam
	_fx_beam.material_override = _fx_beam_mat
	_fx_beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(_fx_beam)
	for n in [_fx_ring, _fx_ring_fill, _fx_sweep, _fx_beam]:
		n.visible = false


func _fx_mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = c
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.no_depth_test = false
	return m


func _show_ring(at: Vector3, radius: float, c: Color) -> void:
	_fx_ring_mat.albedo_color = Color(c.r, c.g, c.b, 0.9)
	_fx_fill_mat.albedo_color = Color(c.r, c.g, c.b, 0.3)
	_fx_ring.global_transform = Transform3D(Basis.from_scale(Vector3(radius, 1.0, radius)),
			at + Vector3(0, 0.06, 0))
	_fx_ring_fill.global_position = at + Vector3(0, 0.05, 0)
	_fx_ring.visible = true
	_fx_ring_fill.visible = true
	_ring_radius = radius
	_ring_fill(0.0)


var _ring_radius := 1.0


func _ring_fill(k: float) -> void:
	var r := maxf(0.05, _ring_radius * clampf(k, 0.0, 1.0))
	_fx_ring_fill.global_transform = Transform3D(Basis.from_scale(Vector3(r, 1.0, r)),
			_fx_ring_fill.global_position)


## The band the sweep will rake: an annular sector drawn on the platform.
func _show_sweep_band() -> void:
	var r := _sweep_radius()
	var y := _floor_y() + (1.6 if _sweep_high else 0.07)
	if _sweep_high:
		# A curtain of light at chest height along the arc, not a flat
		# yellow plane hanging in the air: duck under the glow.
		_fx_sweep.mesh = _curtain_mesh(-SWEEP_ARC, SWEEP_ARC, maxf(1.0, r - 8.0 * sz), minf(reach() + 1.5, r + 8.0 * sz), y)
		_fx_sweep.global_transform = Transform3D.IDENTITY
		_fx_sweep_mat.albedo_color = Color(1.0, 0.7, 0.2, 0.3)
		_fx_sweep.visible = true
		return
	_fx_sweep.mesh = _band_mesh(-SWEEP_ARC, SWEEP_ARC, maxf(1.0, r - 8.0 * sz), minf(reach() + 1.5, r + 8.0 * sz), y)
	_fx_sweep_mat.albedo_color = Color(1.0, 0.75, 0.15, 0.2) if _sweep_high else Color(1, 0.3, 0.1, 0.2)
	_fx_sweep.global_transform = Transform3D.IDENTITY
	_fx_sweep.visible = true


## A warning band on the platform: only the cells that lie ON the stone
## (it used to spill into the void and through pillars), brightest at its
## leading edges and fading toward the middle — light on the ground, not paint.
func _band_mesh(a_from: float, a_to: float, inner: float, outer: float, y: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var steps := 40
	var rings := 8
	var c := _center()
	var lim: float = (arena.radius if arena else 6.0) - 0.2
	for s in steps:
		for k in rings:
			var a0 := lerpf(a_from, a_to, float(s) / steps)
			var a1 := lerpf(a_from, a_to, float(s + 1) / steps)
			var r0 := lerpf(inner, outer, float(k) / rings)
			var r1 := lerpf(inner, outer, float(k + 1) / rings)
			var mid := _arc_point((a0 + a1) * 0.5, (r0 + r1) * 0.5, y)
			if Vector2(mid.x - c.x, mid.z - c.z).length() > lim:
				continue
			var p := [_arc_point(a0, r0, y), _arc_point(a0, r1, y), _arc_point(a1, r1, y), _arc_point(a1, r0, y)]
			var e0 := absf(float(k) / rings - 0.5) * 2.0
			var e1 := absf(float(k + 1) / rings - 0.5) * 2.0
			var al := [0.35 + 0.65 * e0, 0.35 + 0.65 * e1, 0.35 + 0.65 * e1, 0.35 + 0.65 * e0]
			for idx in [0, 1, 2, 0, 2, 3]:
				st.set_color(Color(1, 1, 1, al[idx]))
				st.add_vertex(p[idx])
	return st.commit()


## Vertical light ribbons across the swept arc at chest height, brightest at
## the height the arm will pass, fading above and below.
func _curtain_mesh(a_from: float, a_to: float, inner: float, outer: float, y: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var c := _center()
	var lim: float = (arena.radius if arena else 6.0) - 0.2
	var rings := 7
	var steps := 36
	for k in rings:
		var rr := lerpf(inner, outer, (k + 0.5) / rings)
		for i in steps:
			var a0 := lerpf(a_from, a_to, float(i) / steps)
			var a1 := lerpf(a_from, a_to, float(i + 1) / steps)
			var m := _arc_point((a0 + a1) * 0.5, rr, y)
			if Vector2(m.x - c.x, m.z - c.z).length() > lim:
				continue
			var p0 := _arc_point(a0, rr, y)
			var p1 := _arc_point(a1, rr, y)
			var h := 0.7
			var quad := [p0 + Vector3(0, -h, 0), p1 + Vector3(0, -h, 0), p1, p0,
					p0 + Vector3(0, h, 0), p1 + Vector3(0, h, 0)]
			# two stacked quads: transparent edge -> bright middle -> edge
			var alpha := [0.0, 0.0, 1.0, 1.0, 0.0, 0.0]
			for tri in [[0, 1, 2], [0, 2, 3], [3, 2, 5], [3, 5, 4]]:
				for idx in tri:
					st.set_color(Color(1, 1, 1, alpha[idx]))
					st.add_vertex(quad[idx])
	return st.commit()


func _show_beam(from: Vector3, to: Vector3, width: float, intensity: float) -> void:
	var mid := (from + to) * 0.5
	var len := from.distance_to(to)
	var y := (to - from).normalized()
	var x := y.cross(Vector3.UP)
	if x.length_squared() < 1e-6:
		x = Vector3.RIGHT
	x = x.normalized()
	var z := x.cross(y)
	_fx_beam.global_transform = Transform3D(Basis(x * width, y * len, z * width), mid)
	_fx_beam_mat.albedo_color = (Color(0.55, 1.0, 0.3, 0.15 + 0.6 * intensity) if model_kind == "lizard"
			else Color(1.0, 0.85, 0.5, 0.15 + 0.6 * intensity))
	_fx_beam.visible = true


var _glow_core := 0.6
var _glow_throat := 0.0
var _glow_ember: Array[float] = [0.3, 0.3]


func _update_glow(delta: float) -> void:
	if rig:
		var breathe := 0.3 + 0.18 * sin(Time.get_ticks_msec() * 0.0021)
		var want_core := 4.5 if _core_open else breathe
		if hp_frac() < 0.18 and act == Act.IDLE:
			want_core = 2.6 + 0.8 * sin(Time.get_ticks_msec() * 0.006)   # the fire gutters, exposed
		if act == Act.DEAD:
			want_core = 6.0 * (1.0 - smoothstep(0.5, 6.0, act_t))
		var want_throat := 0.0
		if act == Act.GAZE:
			want_throat = 5.0 * clampf(act_t / GAZE_CHARGE, 0.0, 1.0) if act_t < GAZE_CHARGE + GAZE_BEAM else 1.0
		_glow_core = lerpf(_glow_core, want_core, 6.0 * delta)
		_glow_throat = lerpf(_glow_throat, want_throat, 8.0 * delta)
		for i in 2:
			var w := 3.0 + 1.5 * sin(Time.get_ticks_msec() * 0.012) if _pinned_left[i] > 0.0 else 0.25
			_glow_ember[i] = lerpf(_glow_ember[i], w, 8.0 * delta)
		rig.set_glow(_glow_core, _glow_throat, _glow_ember[0], _glow_ember[1])
	for i in 2:
		var m: StandardMaterial3D = _ember_mats[i] if i < _ember_mats.size() else null
		if m:
			var want := 3.0 + 1.5 * sin(Time.get_ticks_msec() * 0.012) if _pinned_left[i] > 0.0 else 0.5
			m.emission_energy_multiplier = lerpf(m.emission_energy_multiplier, want, 8.0 * delta)
	if _fire_light:
		# Embers breathing in the chest; a furnace when it gapes or inhales.
		var fl := 0.7 + 0.35 * sin(Time.get_ticks_msec() * 0.0021)
		if _core_open:
			fl = 6.0
		elif act == Act.GAZE and act_t < GAZE_CHARGE:
			fl = 1.0 + 4.0 * act_t / GAZE_CHARGE
		_fire_light.light_energy = lerpf(_fire_light.light_energy, fl, 5.0 * delta)
	if _core_mat:
		var want := 4.0 if _core_open else 0.7
		_core_mat.emission_energy_multiplier = lerpf(_core_mat.emission_energy_multiplier, want, 6.0 * delta)
	if _eye_mat:
		var want := 0.05 if model_kind == "lizard" else (0.8 if rig else 1.5)
		if act == Act.GAZE:
			want = (1.0 + 3.0 * clampf(act_t / GAZE_CHARGE, 0.0, 1.0)) if rig \
					else 2.0 + 7.0 * clampf(act_t / GAZE_CHARGE, 0.0, 1.0)
		elif act == Act.STAGGER:
			want = 0.4
		_eye_mat.emission_energy_multiplier = lerpf(_eye_mat.emission_energy_multiplier, want, 6.0 * delta)
	for idx in _shutters.size():
		var want_rot: float = _shutter_bare[idx] if _core_open else _shutter_shut[idx]
		_shutters[idx].rotation.y = lerpf(_shutters[idx].rotation.y, want_rot, 5.0 * delta)


var _core_pulse := 0.0


func _pulse_core(k: float) -> void:
	if _core_mat:
		_core_mat.emission_energy_multiplier += 6.0 * k


# ================================================================= sound ====

func _play(event: String, at: Vector3, volume: float, pitch: float) -> void:
	if Sfx.muted:
		return
	var stream: AudioStream = Sfx._get_stream(event)
	if stream == null:
		return
	var p := AudioStreamPlayer3D.new()
	p.stream = stream
	p.pitch_scale = pitch
	p.volume_db = volume
	p.unit_size = 25.0
	p.max_distance = 220.0
	p.bus = Sfx._bus(event)
	get_tree().current_scene.add_child(p)
	p.global_position = at
	p.play()
	p.finished.connect(p.queue_free)


## Souls-style damage numbers: a big ember-orange figure when a weak point
## is struck, a small grey one when stone shrugs the hit off — the plainest
## possible "this works / this doesn't" a player can learn from.
func _float_number(at: Vector3, amount: float, weak: bool) -> void:
	var l := Label3D.new()
	l.text = str(maxi(1, int(round(amount))))
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = true
	l.fixed_size = true
	l.pixel_size = 0.0011 if weak else 0.0007
	l.font_size = 64
	l.outline_size = 12
	l.modulate = Color(1.0, 0.62, 0.2) if weak else Color(0.7, 0.7, 0.7, 0.85)
	l.outline_modulate = Color(0.1, 0.03, 0.0) if weak else Color(0, 0, 0, 0.7)
	get_tree().current_scene.add_child(l)
	# Beside the hit, not on it: numbers stacked over the gem hid the gem.
	var side_off := global_basis.x.normalized() * (1.6 * sz) * (1.0 if randf() < 0.5 else -1.0)
	l.global_position = at + side_off + Vector3(0, 0.8, 0)
	var tw := l.create_tween()
	tw.set_parallel(true)
	tw.tween_property(l, "global_position", l.global_position + Vector3(0, 1.4, 0), 0.9)
	tw.tween_property(l, "modulate:a", 0.0, 0.9).set_delay(0.3)
	tw.chain().tween_callback(l.queue_free)


func _rumble(volume: float, pitch: float) -> void:
	_play("dragon_roar", head_pos(), volume, pitch)


func _shake(weight: float) -> void:
	if has_node("/root/CombatFX"):
		CombatFX.on_hit(weight)


func _dust(at: Vector3) -> void:
	SlashTrail.spawn_hit_spark(self, at + Vector3(0, 0.3, 0), Color(0.7, 0.65, 0.55))


# =============================================================== climbing ====

## Shoulder ledges carry riders explicitly through every lean and slam.
func _build_pads() -> void:
	for i in 2:
		var side := -1.0 if i == 0 else 1.0
		var pad := AnimatableBody3D.new()
		pad.name = "ShoulderLedge" + ("L" if i == 0 else "R")
		# Not sync_to_physics: that only syncs the body's OWN transform, and
		# this one moves with its parent — riders fell straight through.
		pad.sync_to_physics = false
		pad.collision_layer = 1
		pad.collision_mask = 0
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(4.2, 0.4, 3.4)   # inner edge against the neck: helm in sword reach
		cs.shape = box
		pad.add_child(cs)
		pad.position = Vector3(side * 3.7, 13.3, 0.4)
		if reptile:
			# On top of the shoulder: the titan's joint sits deep under a spiked
			# plate, and a ledge 1 m over it was buried in the hide.
			var off: Vector3 = reptile.spec.get("pad_offset", Vector3(0.8, 1.0, 0.0))
			pad.position = reptile.rest_pos("upperarm." + ("L" if i == 0 else "R")) + Vector3(-side * off.x, off.y, off.z)
		if rig:
			# On the wing-roots, either side of the neck.
			var root := rig.rest_pos("upperarm." + ("L" if i == 0 else "R"))
			pad.position = Vector3(side * 2.9, root.y + 1.35, root.z - 0.5)
		_torso.add_child(pad)
		_pads.append(pad)
		_pad_rest.append(pad.position)


## Who stands on which ledge, judged BEFORE the colossus moves this frame.
func _riders_by_pad() -> Array:
	var out: Array = []
	for pad in _pads:
		var on: Array = []
		for b in _targets():
			if not _climbing.has(b) and _on_this_pad(pad, b):
				on.append([b, pad.to_local(b.global_position)])
		out.append(on)
	return out


## The ledge moved: move its riders with it, keeping where they stood on it.
var _left_pad := {}
var _rider_swinging := {}
var _rider_hit_due := {}
var _head_body: ColossusPart   # bodies that left a ledge this frame: never carry them back


func _carry_riders(riders: Array) -> void:
	for i in mini(riders.size(), _pads.size()):
		for pair in riders[i]:
			var b: Node3D = pair[0]
			if _left_pad.has(b):
				continue
			var l: Vector3 = pair[1]
			l.y = maxf(l.y, 0.2)
			# Bots stay on the ledge; a human may step or jump off on purpose.
			if b.ai_driven:
				l.x = clampf(l.x, -1.9, 1.9)
				l.z = clampf(l.z, -1.5, 1.5)
			b.global_position = _pads[i].to_global(l)


## Is this body standing on (or just above) a shoulder ledge?
func on_pad(b: Node3D) -> bool:
	if b == null or not is_instance_valid(b):
		return false
	for pad in _pads:
		if _on_this_pad(pad, b):
			return true
	return false


func _on_this_pad(pad: Node3D, b: Node3D) -> bool:
	if _clock < float(_dropped_until.get(b, 0.0)):
		return false
	var l := pad.to_local(b.global_position)
	return absf(l.x) < 2.4 and absf(l.z) < 2.0 and l.y > -0.3 and l.y < 2.2


func pad_pos(i: int) -> Vector3:
	return _pads[i].global_position


func is_climbing(b: Node3D) -> bool:
	return _climbing.has(b)


## A fist a body could climb from right now (Vector3.INF if none).
func climbable_fist(b: Node3D) -> Vector3:
	if act in [Act.RELOCATE, Act.DEAD, Act.SHIFT] or _climbing.has(b):
		return Vector3.INF
	if act == Act.GRAB and _victim == b:
		return Vector3.INF   # the claw is closing on you: no scrambling up the other one
	for i in 2:
		if _pinned_left[i] <= 0.4:
			continue
		var edge := _climb_edge(i, b.global_position)
		if edge != Vector3.INF and _flat_dist(b.global_position, edge) < maxf(2.5, CLIMB_REACH * sz) \
				and edge.y - b.global_position.y < 2.5 \
				and b.global_position.y - _floor_y() < 1.0 \
				and _clock - float(_last_slammed.get(b, -99.0)) > 1.5:
			return fist_pos(i)
	return Vector3.INF


func _climb_edge(i: int, from: Vector3) -> Vector3:
	if _skin == null:
		return fist_pos(i)
	#The weapon hull omits the fingertips. Climbing starts on the visible
	#low claw, even when the centre of its palm is above a standing player.
	var bone := "hand.L" if i == 0 else "hand.R"
	var best := Vector3.INF
	var dist := INF
	for k in _skin.pos.size():
		var p := _skin.pos[k]
		if p.y > from.y + 2.0 or _skin.bone_names[_skin.dominant[k]] != bone:
			continue
		var d := p.distance_squared_to(from + Vector3.UP)
		if d < dist:
			dist = d
			best = p
	return best


## Leap down from a shoulder onto the platform near `toward` (a bot's way
## off; a human simply jumps). No damage — it is a choice, not a fling.
func dismount(b: Node3D, toward: Vector3) -> void:
	if not on_pad(b):
		return
	_left_pad[b] = true
	var land := _clamp_to_platform(_center().lerp(toward, 0.6), 1.2)
	b.global_position = Vector3(land.x, _floor_y() + 1.2, land.z)
	b.velocity = Vector3.ZERO
	_emit("dismount", {"who": b.name})


## Begin the scramble: fist -> forearm -> elbow -> onto that arm's shoulder.
func try_climb(b: Node3D) -> bool:
	var fist := climbable_fist(b)
	if fist == Vector3.INF or b.is_dead:
		return false
	var i := 0 if fist.distance_to(fist_pos(0)) < fist.distance_to(fist_pos(1)) else 1
	var seat := -0.65
	for other in _climbing.values():
		if other.hand == i and other.get("seat", 0.0) < 0.0:
			seat = 0.65
	for other in _targets(false):
		if other != b and on_pad(other) and _pads[i].to_local(other.global_position).x < 0.0:
			seat = 0.65
	var landing := _climb_seat(i, seat)
	if landing == Vector3.INF:
		return false
	_climbing[b] = {"t": 0.0, "hand": i, "leg": 0, "from": b.global_position, "distance": 0.0,
			"normal": _flat_dir(fist, b.global_position),
			"seat": seat, "landing": landing}
	b.begin_climb()
	_emit("climb", {"who": b.name})
	return true


func _climb_frame(bone: String) -> Transform3D:
	if bone.begins_with("pad."):
		return _pads[0 if bone == "pad.L" else 1].global_transform
	var index := _skin.skel.find_bone(bone)
	return _skin.mi.global_transform * _skin.skel.get_bone_global_pose(index)


func _climb_goal(c: Dictionary) -> Vector3:
	var i: int = c.hand
	var goals := [_hand[i].global_position + Vector3.UP * 3.0 * sz,
			_fa[i].global_position + Vector3.UP * 2.5 * sz,
			_pads[i].to_global(c.landing),
			_pads[i].to_global(c.landing)]
	return goals[mini(c.leg, 3)]


func _climb_seat(i: int, lane: float) -> Vector3:
	if _skin == null:
		return Vector3(0, 0.3, lane)
	_climb_surface.update()
	var best := Vector3.INF
	var score := INF
	for z in range(-7, 8):
		var local := Vector3(lane, 0.3, z * 0.2)
		var foot := _pads[i].to_global(local)
		var hit: Dictionary = _climb_surface.capsule(foot)
		if float(hit.depth) > -0.03:
			continue
		var gap := absf(float(hit.depth) + 0.1)
		if gap < score:
			score = gap
			best = local
	return best


func _tick_climbing(delta: float) -> void:
	if _skin and not _climbing.is_empty():
		if _climb_surface == null:
			_climb_surface = preload("res://enemies/colossus/climb_surface.gd").new(_skin)
		_climb_surface.update()
	for b in _climbing.keys():
		if not is_instance_valid(b):
			_climbing.erase(b)
			continue
		if b.is_dead or b.current_health <= 0.0 or act in [Act.DEAD, Act.SHIFT, Act.RELOCATE]:
			_cancel_climb(b)
			continue
		var c: Dictionary = _climbing[b]
		c.t += delta
		if not b.ai_driven and c.t > 0.3 and Input.is_action_just_pressed("jump"):
			_release_climber(b, Vector3(c.normal) * 3.0 + Vector3.UP * 4.0)
			continue
		if _skin == null:
			_tick_legacy_climb(b, c, delta)
			continue
		_tick_surface_climb(b, c, delta)

	if _climb_surface and _climb_surface.body:
		var planning := false
		for c in _climbing.values():
			planning = planning or not c.has("anchors_local")
		if not planning:
			_climb_surface.body.collision_layer = 0
			_climb_surface.discard()


func _climb_path(c: Dictionary) -> PackedVector3Array:
	if not c.has("search") and not _climb_search(c):
		return PackedVector3Array()
	var q: Dictionary = c.search
	#Bound route work so two climbers leave time for combat and skinning.
	var until := Time.get_ticks_usec() + 6000
	while not q.open.is_empty() and Time.get_ticks_usec() < until:
		var key: Vector3i = _climb_pop(q.open)
		if q.closed.has(key):
			continue
		q.closed[key] = true
		var at: Vector3 = q.origin + Vector3(key) * 0.4
		if at.distance_to(q.goal) < 0.85 and _climb_segment(at, q.goal):
			return _climb_result(c, key)
		_climb_expand(c, key, at)
	if q.open.is_empty() or q.closed.size() > 12000:
		if q.margin > 0.5:
			return PackedVector3Array([Vector3.INF])
		#A stretched wrist can leave a wider recess between its knuckles.
		q.margin = 0.9
		q.open = [[Vector3(q.origin).distance_to(q.goal), Vector3i.ZERO]]
		q.cost = {Vector3i.ZERO: 0.0}
		q.parent.clear()
		q.closed.clear()
		q.free.clear()
	return PackedVector3Array()


func _climb_search(c: Dictionary) -> bool:
	#The second route can see the first and leave space to pass.
	for other in _climbing.values():
		if other == c:
			break
		if other.hand == c.hand and not other.has("route"):
			return false
	if not _climb_surface.prepare(self):
		return false
	var goal := _pads[int(c.hand)].to_global(c.landing)
	for k in 10:
		if _climb_surface.is_free(goal):
			break
		goal.y += 0.15
	c.landing = _pads[int(c.hand)].to_local(goal)
	var bounds := AABB(c.from, Vector3.ZERO).expand(goal)
	var suffix := ".L" if c.hand == 0 else ".R"
	for k in _skin.pos.size():
		if _skin.bone_names[_skin.dominant[k]] in ["hand" + suffix,
				"forearm" + suffix, "upperarm" + suffix]:
			bounds = bounds.expand(_skin.pos[k])
	c.search = {"origin": c.from, "goal": goal, "bounds": bounds.grow(1.5),
			"open": [[Vector3(c.from).distance_to(goal), Vector3i.ZERO]],
			"cost": {Vector3i.ZERO: 0.0}, "parent": {}, "closed": {}, "free": {}, "margin": 0.48}
	return true


func _climb_expand(c: Dictionary, key: Vector3i, at: Vector3) -> void:
	var q: Dictionary = c.search
	for offset in [Vector3i.RIGHT, Vector3i.LEFT, Vector3i.UP,
			Vector3i.DOWN, Vector3i.BACK, Vector3i.FORWARD]:
		var next: Vector3i = key + offset
		var pt: Vector3 = q.origin + Vector3(next) * 0.4
		if q.closed.has(next) or pt.y < _floor_y() - 0.01 or not q.bounds.has_point(pt):
			continue
		if not q.free.has(next):
			var near: bool = pt.y < _floor_y() + 0.1 or not _climb_surface.is_free(pt, q.margin)
			q.free[next] = near and _climb_surface.is_free(pt) and _climb_stone_free(pt)
		if not q.free[next] or not _climb_segment(at, pt):
			continue
		var cost: float = q.cost[key] + 0.4 + _climb_lane_cost(c, pt)
		if cost >= float(q.cost.get(next, INF)):
			continue
		q.cost[next] = cost
		q.parent[next] = key
		_climb_push(q.open, [cost + pt.distance_to(q.goal) * 1.5, next])


func _climb_result(c: Dictionary, key: Vector3i) -> PackedVector3Array:
	var q: Dictionary = c.search
	var path := PackedVector3Array([q.goal, q.origin + Vector3(key) * 0.4])
	while q.parent.has(key):
		key = q.parent[key]
		path.append(q.origin + Vector3(key) * 0.4)
	path.reverse()
	c.route = _climb_smooth(path)
	c.erase("search")
	return c.route


func _climb_smooth(path: PackedVector3Array) -> PackedVector3Array:
	for pass_i in 2:
		for k in range(1, path.size() - 1):
			var p := (path[k - 1] + path[k] * 2.0 + path[k + 1]) * 0.25
			if _climb_surface.is_free(p) and not _climb_surface.is_free(p, 0.48) \
					and _climb_stone_free(p) and _climb_segment(path[k - 1], p) \
					and _climb_segment(p, path[k + 1]):
				path[k] = p
	return path


func _climb_lane_cost(c: Dictionary, at: Vector3) -> float:
	var distance := INF
	for other in _climbing.values():
		if other == c or other.hand != c.hand or not other.has("route"):
			continue
		for p: Vector3 in other.route:
			distance = minf(distance, at.distance_to(p))
	return maxf(0.0, 1.2 - distance) * 2.0


func _climb_segment(a: Vector3, b: Vector3) -> bool:
	return _climb_surface.clear(a, b) and _climb_stone_clear(a, b)


func _climb_push(heap: Array, item: Array) -> void:
	heap.append(item)
	var k := heap.size() - 1
	while k > 0:
		var parent := (k - 1) / 2
		if heap[parent][0] <= item[0]:
			break
		heap[k] = heap[parent]
		k = parent
	heap[k] = item


func _climb_pop(heap: Array) -> Vector3i:
	var key: Vector3i = heap[0][1]
	var last: Array = heap.pop_back()
	if heap.is_empty():
		return key
	var k := 0
	while k * 2 + 1 < heap.size():
		var child := k * 2 + 1
		if child + 1 < heap.size() and heap[child + 1][0] < heap[child][0]:
			child += 1
		if last[0] <= heap[child][0]:
			break
		heap[k] = heap[child]
		k = child
	heap[k] = last
	return key


func _tick_surface_climb(b: Player, c: Dictionary, delta: float) -> void:
	if not c.has("anchors_local"):
		var path := _climb_path(c)
		if path.is_empty():
			return
		if Vector3.INF in path:
			_cancel_climb(b)
			return
		_store_climb_path(c, path)
	var input := Vector2(0, -1) if b.ai_driven else Input.get_vector(
			"move_left", "move_right", "move_forward", "move_back", 0.15)
	if b.is_crouching:
		input = Vector2.ZERO
	var before: float = c.distance
	c.distance = clampf(before - input.y * CLIMB_SPEED * delta, 0.0, c.length)
	var point := _climb_path_point(c)
	var at: Vector3 = point.position
	var forward: Vector3 = point.forward
	if absf(input.x) > 0.1:
		c.side = clampf(float(c.get("side", 0.0)) + input.x * delta, -0.5, 0.5)
	at += forward.cross(Vector3.UP).normalized() * float(c.get("side", 0.0))
	if c.distance < c.length - 1.0:
		at = _climb_footing(at)
	var carried := b.global_position
	if c.has("body_bone"):
		carried = _climb_frame(c.body_bone) * Vector3(c.body_anchor)
	if not _climb_stone_free(carried):
		carried = b.global_position
	if at.distance_to(carried) > CLIMB_SPEED * delta + 0.15:
		c.distance = before
	at = carried.move_toward(at, CLIMB_SPEED * delta)
	var hit: Dictionary = _climb_surface.capsule(at)
	for k in 4:
		if float(hit.depth) <= 0.0:
			break
		var out: Vector3 = hit.normal
		out.y = maxf(out.y, 0.3)
		at += out.normalized() * minf(float(hit.depth) + 0.02, 0.12)
		hit = _climb_surface.capsule(at)
	if float(hit.depth) > 0.04 or at.distance_to(carried) > 0.3 \
			or not _climb_stone_free(at) or not _climb_stone_clear(carried, at):
		at = carried
		c.distance = before
	for other in _targets():
		if other != b and at.distance_to(other.global_position) < 0.68:
			c.distance = before
			at = carried
	c.body_bone = hit.bone
	c.body_anchor = _climb_frame(hit.bone).affine_inverse() * at
	b.global_position = at
	b.velocity = Vector3.ZERO
	c.normal = hit.normal
	b.climb_pose(forward, hit.normal, at.distance_to(carried) / delta, delta)
	if c.distance >= c.length and on_pad(b):
		_finish_climb(b)


func _climb_footing(at: Vector3) -> Vector3:
	if at.y <= _floor_y() + 0.3:
		return at
	var hit: Dictionary = _climb_surface.capsule(at)
	if float(hit.depth) >= -0.4:
		return at
	var close := at + Vector3(hit.normal) * maxf(float(hit.depth) + 0.2, -0.6)
	if _climb_surface.capsule(close).depth <= 0.0 and _climb_stone_free(close) \
			and _climb_stone_clear(at, close):
		return close
	return at


func _store_climb_path(c: Dictionary, path: PackedVector3Array) -> void:
	c.anchors_local = []
	c.lengths = [0.0]
	c.length = 0.0
	for k in path.size():
		var sample: int = _skin.nearest(path[k] + Vector3.UP * 0.6)[0]
		var bone := _skin.bone_names[_skin.dominant[sample]]
		if k == path.size() - 1:
			bone = "pad.L" if c.hand == 0 else "pad.R"
		c.anchors_local.append([bone, _climb_frame(bone).affine_inverse() * path[k]])
		if k > 0:
			c.length += path[k - 1].distance_to(path[k])
			c.lengths.append(c.length)


func _climb_path_point(c: Dictionary) -> Dictionary:
	for k in range(1, c.anchors_local.size()):
		if c.distance > c.lengths[k] and k < c.anchors_local.size() - 1:
			continue
		var a: Array = c.anchors_local[k - 1]
		var b: Array = c.anchors_local[k]
		var start := _climb_frame(a[0]) * Vector3(a[1])
		var end := _climb_frame(b[0]) * Vector3(b[1])
		var t: float = (c.distance - c.lengths[k - 1]) / maxf(c.lengths[k] - c.lengths[k - 1], 0.001)
		return {"position": start.lerp(end, t), "forward": (end - start).normalized()}
	return {"position": c.from, "forward": Vector3.UP}


func _tick_legacy_climb(b: Player, c: Dictionary, delta: float) -> void:
	var goal := _climb_goal(c)
	var at := b.global_position.move_toward(goal, CLIMB_SPEED * delta)
	b.global_position = at
	b.climb_pose(goal - at, Vector3.UP, CLIMB_SPEED, delta)
	if at.distance_to(goal) < 0.2:
		c.leg += 1
		if c.leg > 3:
			_finish_climb(b)


func _finish_climb(b: Player) -> void:
	_climbing.erase(b)
	b.end_climb()
	_emit("mounted", {"who": b.name})


func _release_climber(b: Player, impulse: Vector3) -> void:
	_climbing.erase(b)
	_left_pad[b] = true
	_dropped_until[b] = _clock + 1.2
	b.end_climb()
	b.velocity = impulse
	b._knockback_velocity = impulse
	b._is_stunned = true
	b._stun_timer = 0.35


func _cancel_climb(b: Player) -> void:
	_emit("climb_blocked", {"who": b.name})
	var normal: Vector3 = _climbing[b].normal
	_release_climber(b, normal * 2.0 + Vector3.UP)


## While anyone rides it, it means to be rid of them: a SHAKE comes a few
## seconds in, telegraphed by a shudder through its shoulders.
func _tick_riders(delta: float) -> void:
	# Someone downed up here slides down onto the stone, within reach of a revive.
	if arena:
		for b in arena.party():
			if is_instance_valid(b) and (b.is_dead or b.current_health <= 0.0) and on_pad(b):
				_left_pad[b] = true
				var land := _clamp_to_platform(_center().lerp(b.global_position, 0.4), 1.5)
				b.global_position = Vector3(land.x, _floor_y() + 0.8, land.z)
				b.velocity = Vector3.ZERO
				_emit("rider_down", {"who": b.name})
	var riding := false
	for b in _targets():
		if on_pad(b) or is_climbing(b):
			riding = true
	if not riding:
		_ride_total = 0.0
		_ride_t = 0.0
		_shake_due = randf_range(SHAKE_AFTER.x, SHAKE_AFTER.y)
		return
	_ride_t += delta
	_ride_total += delta
	# Legacy bodies used a timed head hit. The reptilian uses blade contact,
	# so a rider cannot score a second hit or hit while facing away.
	for b in _targets(false):
		if reptile or not on_pad(b) or not (b is Player):
			continue
		var was: bool = _rider_swinging.get(b, false)
		if b.is_attacking and not was:
			_rider_hit_due[b] = 0.3
		_rider_swinging[b] = b.is_attacking
	for b in _rider_hit_due.keys():
		_rider_hit_due[b] -= delta
		if _rider_hit_due[b] <= 0.0:
			_rider_hit_due.erase(b)
			if is_instance_valid(b) and on_pad(b) and _head_body:
				var dmg: float = b.get_knight_sword_damage() if b.is_paladin() else 45.0
				on_part_hit(_head_body, dmg, b, false, _head_body.global_position if rig else head_pos())
	var free_now := act in [Act.IDLE, Act.GAZE] \
			or (act == Act.SLAM and (act_t < 0.3 or act_t > _punch_hold)) \
			or (act == Act.STAGGER and act_t > 2.0)
	if _ride_t >= _shake_due and free_now:
		_ride_t = 0.0
		_shake_due = randf_range(SHAKE_AFTER.x, SHAKE_AFTER.y)
		_start(Act.SHAKE, SHAKE_WINDUP + SHAKE_TIME)
		_emit("shake", {})
		_rumble(-6.0, 0.6)


func _tick_shake(_delta: float) -> void:
	# A shudder, then a violent roll of the shoulders.
	if act_t < SHAKE_WINDUP:
		_lean_goal = deg_to_rad(18.0 + 3.0 * sin(act_t * 40.0))
	else:
		_lean_goal = deg_to_rad(18.0 + 14.0 * sin(act_t * 14.0))
	if act_t >= SHAKE_WINDUP and not _struck:
		_struck = true
		_shake(0.8)
		#Clinging buys time, but a long uninterrupted ride ends in a hard buck.
		_fling_riders(_ride_total > 18.0, "shake")
	if act_t >= act_len:
		_start(Act.IDLE, _idle_gap())


## Throw riders back onto the platform. A crouching rider clings on —
## unless `all` (it is about to sink: nobody rides it into the abyss).
func _fling_riders(all: bool, why: String) -> void:
	for b in _targets():
		if not on_pad(b) and not is_climbing(b):
			continue
		if not all and "is_crouching" in b and b.is_crouching:
			_emit("clung", {"who": b.name})
			continue
		var away := _flat_dir(b.global_position, _center())
		_release_climber(b, away * 5.0 + Vector3.UP * 3.0)
		if not all or why == "shake":
			b.take_hit(SHAKE_DAMAGE, away * 5.0, false, _hand_body[0], false)
			b.velocity.y = 3.0
		_emit("flung", {"who": b.name, "why": why})


# ================================================================== wade =====

func _begin_shift() -> void:
	_shift_cd = randf_range(SHIFT_COOLDOWN.x, SHIFT_COOLDOWN.y)
	_shift_from = _anchor_angle
	var turn := 1.0 if randf() < 0.5 else -1.0
	if reptile:
		# Toward whoever stands out of every claw's reach: no ranged attack
		# any more, so it goes to them.
		for b in _targets():
			if not _in_slam_reach(b.global_position):
				var c := _center()
				var at := atan2(b.global_position.x - c.x, -(b.global_position.z - c.z))
				turn = signf(wrapf(at - _anchor_angle, -PI, PI))
				if turn == 0.0:
					turn = 1.0
				break
	_shift_to = _anchor_angle + deg_to_rad(randf_range(70.0, 130.0)) * turn
	for i in 2:
		_pinned_left[i] = 0.0
	# Nobody rides it through the mist.
	_fling_riders(true, "wade")
	_start(Act.SHIFT, SHIFT_TIME)
	_emit("shift", {})
	_rumble(-8.0, 0.5)


func _tick_shift(_delta: float) -> void:
	if reptile:
		_wade(_shift_from, _shift_to, SHIFT_TIME, SHIFT_SINK * sz)
		if act_t >= act_len:
			_start(Act.IDLE, 0.8)
		return
	# Chest-deep, it pushes through the mist around the platform — whoever is
	# on its shoulders rides along.
	var t := act_t
	_sink_goal = SHIFT_SINK * sz if t < SHIFT_TIME - 1.1 else 0.0
	_lean_goal = deg_to_rad(10.0)
	var k := smoothstep(0.0, 1.0, clampf((t - 0.9) / (SHIFT_TIME - 2.0), 0.0, 1.0))
	_anchor_angle = lerpf(_shift_from, _shift_to, k)
	_place_on_anchor()
	for i in 2:
		_ease_arm(i, _idle_wrist(i) + Vector3(0, 1.5, 0), _grip_basis(i), 3.0)
	if t >= act_len:
		_start(Act.IDLE, 0.8)


func _wade(from: float, to: float, duration: float, depth: float) -> void:
	var t := act_t / duration
	#Withdraw first, circle outside the stone, rise, then reach for the rim.
	_withdraw = 13.0 * sz * smoothstep(0.0, 0.22, t) * (1.0 - smoothstep(0.80, 1.0, t))
	_sink_goal = depth * smoothstep(0.24, 0.40, t) * (1.0 - smoothstep(0.58, 0.76, t))
	_lean_goal = 0.0
	_anchor_angle = lerpf(from, to, smoothstep(0.26, 0.70, t))
	_place_on_anchor()
	_travel_arms()


func _travel_arms() -> void:
	var outward := _flat_dir(_center(), global_position)
	for i in 2:
		var wrist := _idle_wrist(i) + outward * _withdraw
		wrist.y += 2.5 * sz - _sink
		_ease_arm(i, wrist, _grip_basis(i), 4.0)



# ================================================================== fog ======

func _build_boss_fog() -> void:
	var fog := FogVolume.new()
	fog.name = "BossFog"
	fog.shape = RenderingServer.FOG_VOLUME_SHAPE_ELLIPSOID
	fog.size = Vector3(34, 20, 29)
	fog.position = Vector3(0, 1.0, -2.5)
	var mat := ShaderMaterial.new()
	mat.shader = preload("res://enemies/colossus/boss_fog.gdshader")
	fog.material = mat
	add_child(fog)


# ================================================================== tail =====

func _tail_inner() -> float:
	return reach() + 0.5


func _begin_tail() -> void:
	_sweep_dir = 1.0 if randf() < 0.5 else -1.0
	_sweep_from = -SWEEP_ARC * 0.8 * _sweep_dir
	_sweep_to = SWEEP_ARC * 0.8 * _sweep_dir
	_sweep_prev = _sweep_from
	_sweep_high = false
	_start(Act.TAIL, TAIL_WINDUP + TAIL_TIME + TAIL_RECOVER)
	_show_tail_band()
	_emit("tail", {})
	_rumble(-8.0, 0.55)


func _tick_tail(_delta: float) -> void:
	_lean_goal = deg_to_rad(14.0)
	for i in 2:
		if _pinned_left[i] <= 0.0:
			_rest_arm(i, 3.0)
	var phi := _sweep_from
	if act_t < TAIL_WINDUP:
		_fx_sweep_mat.albedo_color.a = 0.1 + 0.16 * absf(sin(act_t * 9.0))
		phi = _sweep_from - 0.4 * _sweep_dir
	elif act_t < TAIL_WINDUP + TAIL_TIME:
		_fx_sweep_mat.albedo_color.a = 0.0
		var k := smoothstep(0.0, 1.0, (act_t - TAIL_WINDUP) / TAIL_TIME)
		phi = lerpf(_sweep_from, _sweep_to, k)
		_sweep_hits(_sweep_prev, phi)
		_sweep_prev = phi
		if not _struck:
			_struck = true
			_play("punch_whoosh", _center(), 10.0, 0.35)
	else:
		_fx_sweep.visible = false
		phi = _sweep_to
		if act_t >= act_len:
			if _tail:
				_tail.transform = _tail_rest
			_start(Act.IDLE, _idle_gap())
			return
	_pose_tail(phi, act_t >= TAIL_WINDUP and act_t < TAIL_WINDUP + TAIL_TIME)


## Swing the rigid tail so it points at the band it rakes.
func _pose_tail(phi: float, lashing: bool) -> void:
	if _tail == null:
		return
	var far := _arc_point(phi, _tail_inner() + 6.0, _floor_y() + (0.8 if lashing else 6.0))
	var dir := (far - _tail.global_position).normalized()
	var b := _along(dir, Vector3.UP.cross(dir) if absf(dir.y) < 0.95 else Vector3.RIGHT)
	_tail.global_basis = _tail.global_basis.orthonormalized().slerp(b, 0.35).scaled(Vector3.ONE * sz)


func _show_tail_band() -> void:
	var inner := _tail_inner()
	var outer: float = _flat_dist(global_position, _center()) + (arena.radius if arena else 6.0)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_fx_sweep.mesh = _band_mesh(_sweep_from, _sweep_to, inner, outer, _floor_y() + 0.08)
	st = null
	_fx_sweep.global_transform = Transform3D.IDENTITY
	_fx_sweep_mat.albedo_color = Color(0.85, 0.22, 0.08, 0.2)
	_fx_sweep.visible = true


# =================================================================== jaw =====

func _tick_jaw(delta: float) -> void:
	# The dragon breathes its fire through open jaws (the colossus's beam came
	# from the eye, its mouth shut while it fired).
	var gaze_open := GAZE_CHARGE + (GAZE_BEAM if rig else 0.0)
	if act == Act.ROAR or (act == Act.GAZE and act_t < gaze_open):
		_jaw_goal = 0.5 if not (rig and act == Act.GAZE and act_t >= GAZE_CHARGE) else 0.75
	elif act != Act.DEAD:
		_jaw_goal = 0.48 if reptile and _head_open else 0.0
	_jaw_open = lerpf(_jaw_open, _jaw_goal, 8.0 * delta)
	if _jaw:
		var angle := 62.0 if model_kind == "lizard" else 35.0
		_jaw.rotation.x = _jaw_open * deg_to_rad(angle) / 0.6   # + opens (hinge behind the snout)
		if reptile:
			# The muzzle holds it shut. A roar strains against the bands: the
			# jaw shudders a degree or two and no further.
			var strain := 1.0 if act == Act.ROAR or (act == Act.HEAD_SLAM and act_t < HEAD_WINDUP) else 0.0
			_jaw.rotation.x = deg_to_rad(float(reptile.spec.jaw_closed) + strain * (0.8 + 0.8 * sin(_clock * 47.0)))


# ================================================================ plunge =====
# Drop onto it from height with the blade out: off a perch, a tower, a Leap,
# or down from its own shoulder onto a fist. Big damage and big poise.

var _air := {}


func _tick_plunges() -> void:
	for b in _targets(false):
		if not (b is Player) or on_pad(b) or _climbing.has(b):
			_air.erase(b)
			continue
		var st: Dictionary = _air.get(b, {})
		if not b.is_on_floor():
			if st.is_empty():
				st = {"peak": b.global_position.y, "armed": false}
				_air[b] = st
			st.peak = maxf(st.peak, b.global_position.y)
			var wants: bool = b._ai_plunge if b.ai_driven else Input.is_action_pressed(&"attack")
			if wants:
				st.armed = true
		elif not st.is_empty():
			_air.erase(b)
			b._ai_plunge = false
			var drop: float = float(st.peak) - b.global_position.y
			if drop >= PLUNGE_MIN_DROP and st.armed:
				plunge(b, drop)


## The plunging blow itself (also used when a rider leaps down onto a fist).
func plunge(b: Node3D, drop: float) -> bool:
	var best := -1
	var best_d := INF
	for i in 2:
		var d := _flat_dist(b.global_position, fist_pos(i))
		if d < 2.9 * sz and d < best_d:
			best_d = d
			best = i
	if best < 0 or b == _victim:
		return false
	# One heavy drop per climb, not a pogo: a leap-boosted knight used to
	# land eight plunges in five seconds and erase half the bar in one stagger.
	var now := _clock
	if now - float(_last_plunge.get(b, -99.0)) < PLUNGE_COOLDOWN:
		return false
	_last_plunge[b] = now
	var pinned := _pinned_left[best] > 0.0
	var dmg := (PLUNGE_DAMAGE + 25.0 * minf(drop, 8.0)) * (1.0 if pinned else 0.35)
	if reptile:
		dmg *= CLAW_MELEE_MULT if pinned else HIDE_MULT
	if act == Act.STAGGER:
		_stagger_plunges += 1
		dmg *= 1.0 / (1.0 + 0.6 * maxf(0.0, _stagger_plunges - 1.0))
	hp = maxf(0.0, hp - dmg)
	_emit("plunge", {"by": b.name, "pinned": pinned})
	_emit("hit", {"part": "plunge", "weak": pinned, "by": b.name, "arrow": false,
			"dealt": dmg, "raw": dmg})
	var at := fist_pos(best) + Vector3(0, 1.0 * sz, 0)
	_float_number(at, dmg, true)
	SlashTrail.spawn_hit_spark(self, at, Color(1.0, 0.8, 0.3))
	_play("hit_metal", at, 8.0, 0.6)
	_shake(1.0)
	_add_poise(PLUNGE_POISE if pinned else PLUNGE_POISE * 0.4, b)
	if hp <= 0.0:
		_die()
	return true


const PLUNGE_COOLDOWN := 2.5
var _last_plunge := {}
var _clock := 0.0
var _last_slammed := {}
var _stagger_plunges := 0


## A rider leaps down from the shoulder onto a pinned fist below.
func plunge_from_shoulder(b: Node3D) -> bool:
	if not on_pad(b):
		return false
	for i in 2:
		if _pinned_left[i] > 0.4:
			var f := fist_pos(i)
			var land := _clamp_to_platform(f + _flat_dir(f, _center()) * 1.6 * sz, 1.0)
			var drop := b.global_position.y - _floor_y()
			_left_pad[b] = true
			b.global_position = Vector3(land.x, _floor_y() + 0.8, land.z)
			b.velocity = Vector3.ZERO
			_emit("dismount", {"who": b.name})
			return plunge(b, drop)
	return false


# ================================================================== burn =====
# Incendiary arrows set the hide alight: damage over time that ignores armour.

var _burns: Array = []          # [{t, dps, by, fx}]


func ignite(part: Node3D, by: Node3D, seconds: float, dps: float) -> void:
	if _burns.size() >= 4:
		return
	var fx := FireFX.add_flames(part, Vector3.ZERO, 1.0 * sz, 18)
	_burns.append({"t": seconds, "dps": dps, "by": by, "fx": fx})
	_emit("ignite", {"by": by.name if by else "?"})


func _tick_burns(delta: float) -> void:
	for b in _burns.duplicate():
		b.t -= delta
		var dmg: float = b.dps * delta
		hp = maxf(0.0, hp - dmg)
		b["acc"] = float(b.get("acc", 0.0)) + dmg
		if float(b.acc) >= 10.0:
			_emit("hit", {"part": "burn", "weak": false, "by": b.by.name if is_instance_valid(b.by) else "?",
					"arrow": true, "dealt": b.acc, "raw": b.acc})
			b.acc = 0.0
		if b.t <= 0.0:
			if is_instance_valid(b.fx):
				(b.fx as Node).queue_free()
			_burns.erase(b)
	if hp <= 0.0 and act != Act.DEAD:
		_die()


# ================================================================= marks =====
# Hunter's Mark: glowing runes appear on its joints; an arrow (or a blade)
# on one is a critical hit that also cracks poise — the archer's opener.

var _marks: Array = []          # [{part, t}]


func add_marks(count: int, seconds: float) -> void:
	var spots: Array = []
	for i in 2:
		spots.append([_ua[i], Vector3(0, -0.6, 1.2)])           # shoulder joint, front
		spots.append([_fa[i], Vector3(0, -FORE * 0.5, 1.15)])   # mid forearm
	spots.append([_head, Vector3(0, 0.4, 1.6)])                  # throat
	spots.shuffle()
	for k in mini(count, spots.size()):
		var host: Node3D = spots[k][0]
		var part := _part(host, ColossusPart.Kind.MARK, _sphere_shape(0.55), spots[k][1])
		var mi := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = 0.45
		sm.height = 0.9
		mi.mesh = sm
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.albedo_color = Color(0.4, 0.9, 1.0)
		m.emission_enabled = true
		m.emission = Color(0.4, 0.9, 1.0)
		m.emission_energy_multiplier = 4.0
		mi.material_override = m
		part.add_child(mi)
		for p in arena.party():
			p.add_collision_exception_with(part)
		_marks.append({"part": part, "t": seconds})
	_emit("marks", {"n": count})


func marks() -> Array[Vector3]:
	var out: Array[Vector3] = []
	for m in _marks:
		if is_instance_valid(m.part):
			out.append((m.part as Node3D).global_position)
	return out


func _tick_marks(delta: float) -> void:
	for m in _marks.duplicate():
		m.t -= delta
		if m.t <= 0.0 or not is_instance_valid(m.part):
			if is_instance_valid(m.part):
				(m.part as Node).queue_free()
			_marks.erase(m)


func _consume_mark(part: ColossusPart) -> void:
	for m in _marks.duplicate():
		if m.part == part:
			part.queue_free()
			_marks.erase(m)
