class_name DragonWingFlap
extends RefCounted

## Procedural flight animation for the ancient dragon.
##
## EVERY key is composed ON TOP of the bone's rest rotation:
##   local_pose = rest_parent_global⁻¹ · R_skeleton · rest_global
## where R_skeleton is a small delta expressed in SKELETON space. At delta
## zero the pose equals the rest pose exactly, so the animation can never
## fight the model-level flight-pose correction in dragon.gd (the bug that
## previously forced body/neck/tail tracks to be disabled — raw rotation
## tracks REPLACE the rest rotation, and this rig's rests are far from
## identity, e.g. LHand rest ≈ (-65°, 62°, -74°)).
##
## Skeleton-space axes (measured from the rig's global rests):
##   +X lateral (right wing), -X left wing
##   +Y body axis toward the head, -Y toward the tail
##   +Z dorsal (back), -Z ventral (belly, standing legs)
## So: nose-up pitch = +rx on head-ward chains, tail lift = -rx,
## left wing up = +ry / right wing up = -ry, left wing sweep-back = +rz.
## Mirror rule L→R: (rx, ry, rz) → (rx, -ry, -rz).
##
## Motion design (bird/bat flight + creature-animation references):
## - Asymmetric stroke: fast loaded downstroke (~42% of cycle), slower
##   recovery; distal segments lag the shoulder (wingtip follow-through).
## - Wings fold back slightly during the upstroke to shed drag.
## - Distal washout twist during the power stroke.
## - Chest/spine pitch subtly with the wing impulse.
## - Neck bobs as a delayed wave; the HEAD counter-rotates so it stays
##   stabilized (guides the flight) instead of nodding with the body.
## - Tail streams behind with a vertical wave synced to the flap plus a
##   slow lateral rudder sway — amplitude and delay grow toward the tip.
## - Legs hold a flight tuck with a trailing swing (rest pose legs stand
##   ventrally, which is what made them dangle in flight).

const SKELETON_PATH := "Sketchfab_model/Dragon_Ancient_Skeleton_fbx/Object_2/RootNode/Dragon_Ancient_Skeleton/NPC /NPC Root [Root]/Object_9/Skeleton3D"

const SAMPLES := 16          # keys per loop (cubic-interpolated)
const DOWNSTROKE_FRAC := 0.42

# Wing chains, shoulder → tip: [bone, stroke_amp, lag, fold_amp, twist_amp]
# stroke_amp: total ry excursion share (deg); lag: cycle fraction the segment
# trails the shoulder; fold_amp: upstroke sweep-back (rz); twist_amp: washout (rx).
const WING_CHAIN := [
	["Collarbone_0%s4", 6.0, 0.00, 0.0, 0.0],
	["UpArm1_0%s5", 15.0, 0.01, 0.0, 0.0],
	["UpArm2_0%s6", 10.0, 0.025, 2.0, 0.0],
	["Forearm1_0%s8", 12.0, 0.05, 10.0, 2.0],
	["Forearm2_0%s9", 6.0, 0.065, 4.0, 2.0],
	["Hand_0%s0", 10.0, 0.085, 14.0, 5.0],
]
# Finger rows: [bone_suffixes, stroke_amp, lag, fold_amp, twist_amp]
const WING_FINGERS_1 := [["Finger11", "Finger21", "Finger31", "Finger41"], 8.0, 0.115, 16.0, 7.0]
const WING_FINGERS_2 := [["Finger12", "Finger22", "Finger32", "Finger42"], 7.0, 0.145, 12.0, 8.0]

const NECK_BONES := ["NPC Neck1_040", "NPC Neck2_041", "NPC Neck3_042", "NPC Neck4_043", "NPC Neck5_044"]
const HEAD_BONE := "NPC Head_046"
const TAIL_BONES := ["NPC Tail1_074", "NPC Tail2_075", "NPC Tail3_076", "NPC Tail4_077",
		"NPC Tail5_078", "NPC Tail6_079", "NPC Tail7_080", "NPC Tail8_081"]
const SPINE_BONES := ["NPC Spine1_020", "NPC Spine2_021", "NPC Spine3_022", "NPC Hub01_023"]

# Flight tuck for the standing-pose legs plus per-bone swing motion:
# bone → [tuck delta, swing amp (deg about lateral X), swing lag].
# The legs trail the wing impulse — they get dragged slightly on each
# power stroke and settle back during recovery, with the distal segments
# lagging (same follow-through logic as the tail).
const LEG_MOTION := {
	"NPC LLegThigh_02": [Vector3(-30.0, 6.0, 4.0), 3.0, 0.14],
	"NPC LLegCalf_03": [Vector3(-58.0, 0.0, 0.0), 4.5, 0.22],
	"NPC LLegFoot_04": [Vector3(-26.0, 0.0, 0.0), 4.0, 0.30],
	"NPC RLegThigh_011": [Vector3(-30.0, -6.0, -4.0), 3.0, 0.14],
	"NPC RLegCalf_012": [Vector3(-58.0, 0.0, 0.0), 4.5, 0.22],
	"NPC RLegFoot_013": [Vector3(-26.0, 0.0, 0.0), 4.0, 0.30],
}


## Warped cycle phase: s ∈ [0,1], with the downstroke compressed into
## DOWNSTROKE_FRAC of real time. cos(TAU·s) = +1 wings at top, -1 at bottom.
static func _stroke_phase(t: float) -> float:
	t = fposmod(t, 1.0)
	if t < DOWNSTROKE_FRAC:
		return t / DOWNSTROKE_FRAC * 0.5
	return 0.5 + (t - DOWNSTROKE_FRAC) / (1.0 - DOWNSTROKE_FRAC) * 0.5


## Vertical wing angle for one segment: +0.4·amp raised at the top,
## -0.6·amp driven past horizontal at the bottom (ventral-biased power).
static func _stroke_angle(t: float, amp: float, lag: float) -> float:
	var s := _stroke_phase(t - lag)
	return amp * (cos(TAU * s) * 0.5 - 0.1)


## Upstroke fold factor 0..1: zero through the downstroke, peaks mid-recovery.
static func _fold_factor(t: float, lag: float) -> float:
	var s := _stroke_phase(t - lag)
	if s < 0.5:
		return 0.0
	return sin((s - 0.5) / 0.5 * PI)


## Washout twist: strongest mid-downstroke, reversed mid-upstroke.
static func _twist_factor(t: float, lag: float) -> float:
	return sin(TAU * _stroke_phase(t - lag))


static func create_wing_flap_animation(skel: Skeleton3D, duration: float = 2.5,
		intensity: float = 1.0) -> Animation:
	return _build_flight_animation(skel, duration, intensity, "flap")


static func create_glide_animation(skel: Skeleton3D, duration: float = 3.5,
		intensity: float = 1.0) -> Animation:
	return _build_flight_animation(skel, duration, intensity, "glide")


## Hummingbird-style hover for the fire-blowing pause: the body is tipped
## upright at the MODEL level (dragon.gd's hover pitch), while this clip keeps
## the wings beating fast and shallow, EXTENDS the neck forward (cancelling
## the body pitch so the head aims at the target), lets the tail hang and
## sway harder, and relaxes the leg tuck so the legs hang hummingbird-like.
static func create_hover_animation(skel: Skeleton3D, duration: float = 2.5,
		intensity: float = 1.0) -> Animation:
	return _build_flight_animation(skel, duration, intensity, "hover")


static func _build_flight_animation(skel: Skeleton3D, duration: float,
		intensity: float, mode: String) -> Animation:
	var glide := mode == "glide"
	var hover := mode == "hover"
	var anim := Animation.new()
	anim.length = duration
	anim.loop_mode = Animation.LOOP_LINEAR

	# --- Wings ---------------------------------------------------------
	# Glide: wings held with a slight dihedral + a slow ±2° breathing sway.
	var rows: Array = []
	for seg in WING_CHAIN:
		rows.append([[String(seg[0])], seg[1], seg[2], seg[3], seg[4]])
	rows.append([WING_FINGERS_1[0], WING_FINGERS_1[1], WING_FINGERS_1[2], WING_FINGERS_1[3], WING_FINGERS_1[4]])
	rows.append([WING_FINGERS_2[0], WING_FINGERS_2[1], WING_FINGERS_2[2], WING_FINGERS_2[3], WING_FINGERS_2[4]])

	for row in rows:
		var names: Array = row[0]
		var amp: float = row[1] * intensity * (0.75 if hover else 1.0)
		var lag: float = row[2]
		var fold_amp: float = row[3] * intensity * (0.6 if hover else 1.0)
		var twist_amp: float = row[4] * intensity
		for raw_name in names:
			for side in ["L", "R"]:
				var bone := _wing_bone_name(String(raw_name), side)
				if bone == "":
					continue
				var mirror: float = 1.0 if side == "L" else -1.0
				var sampler: Callable
				if glide:
					sampler = func(t: float) -> Vector3:
						var breathe := sin(TAU * t)
						return Vector3(
							twist_amp * 0.6,
							mirror * (amp * 0.35 + amp * 0.16 * breathe),
							mirror * fold_amp * 0.25)
				else:
					sampler = func(t: float) -> Vector3:
						return Vector3(
							twist_amp * _twist_factor(t, lag),
							mirror * _stroke_angle(t, amp, lag),
							mirror * fold_amp * _fold_factor(t, lag))
				_add_sampled_track(anim, skel, bone, duration, sampler)

	# --- Spine / chest: subtle pitch response to the wing impulse ------
	var spine_scale := 0.35 if glide else 1.0
	for i in SPINE_BONES.size():
		var amp_s: float = lerpf(1.0, 2.0, float(i) / (SPINE_BONES.size() - 1)) * intensity * spine_scale
		var lag_s := 0.45 + 0.02 * i
		var spine_sampler := func(t: float) -> Vector3:
			return Vector3(amp_s * cos(TAU * (_stroke_phase(t) - lag_s)), 0.0, 0.0)
		_add_sampled_track(anim, skel, SPINE_BONES[i], duration, spine_sampler)

	# --- Neck: delayed bob wave + slow lateral sway --------------------
	# Hover: each segment also pitches DOWN (-rx extends the chain forward),
	# cancelling the upright body pitch so the head thrusts toward the
	# target for the flame blow.
	var neck_scale := 0.5 if glide else 1.0
	var neck_extend := -8.5 if hover else 0.0
	for i in NECK_BONES.size():
		var bob_amp: float = lerpf(1.2, 2.4, float(i) / (NECK_BONES.size() - 1)) * intensity * neck_scale
		var sway_amp: float = lerpf(0.8, 1.8, float(i) / (NECK_BONES.size() - 1)) * intensity
		var bob_lag := 0.12 + 0.05 * i
		var sway_lag := 0.06 * i
		var neck_sampler := func(t: float) -> Vector3:
			return Vector3(
				neck_extend + bob_amp * cos(TAU * (_stroke_phase(t) - bob_lag)),
				0.0,
				sway_amp * sin(TAU * (t - sway_lag)))
		_add_sampled_track(anim, skel, NECK_BONES[i], duration, neck_sampler)

	# Head: counter-rotates the accumulated neck bob (stabilized gaze,
	# slight proud pitch-up) and counters part of the sway.
	var head_bob := 4.0 * intensity * neck_scale
	var head_bias := -4.0 if hover else 3.0
	var head_sampler := func(t: float) -> Vector3:
		return Vector3(
			head_bias - head_bob * cos(TAU * (_stroke_phase(t) - 0.3)),
			0.0,
			-2.5 * intensity * sin(TAU * (t - 0.2)))
	_add_sampled_track(anim, skel, HEAD_BONE, duration, head_sampler)

	# --- Tail: streaming wave, amplitude and delay grow to the tip -----
	var tail_scale := 0.6 if glide else (1.3 if hover else 1.0)
	for i in TAIL_BONES.size():
		var f := float(i) / (TAIL_BONES.size() - 1)
		var vert_amp: float = lerpf(1.2, 5.0, f) * intensity * tail_scale
		var side_amp: float = lerpf(0.8, 4.0, f) * intensity * (1.4 if hover else 1.0)
		var vert_lag := 0.5 + 0.06 * i
		var side_lag := 0.09 * i
		var tail_sampler := func(t: float) -> Vector3:
			return Vector3(
				-1.2 - vert_amp * cos(TAU * (_stroke_phase(t) - vert_lag)),
				0.0,
				side_amp * sin(TAU * (t - side_lag)))
		_add_sampled_track(anim, skel, TAIL_BONES[i], duration, tail_sampler)

	# --- Legs: flight tuck + trailing swing ----------------------------
	# Hover: the tuck relaxes to ~half — the legs hang under the upright
	# body the way a hovering bird's do.
	var leg_scale := 0.45 if glide else (1.3 if hover else 1.0)
	for bone in LEG_MOTION:
		var tuck: Vector3 = LEG_MOTION[bone][0] * (0.5 if hover else 1.0)
		var swing_amp: float = LEG_MOTION[bone][1] * intensity * leg_scale
		var swing_lag: float = LEG_MOTION[bone][2]
		var leg_sampler: Callable
		if glide:
			leg_sampler = func(t: float) -> Vector3:
				return tuck + Vector3(swing_amp * sin(TAU * (t - swing_lag)), 0.0, 0.0)
		else:
			leg_sampler = func(t: float) -> Vector3:
				return tuck + Vector3(
					swing_amp * cos(TAU * (_stroke_phase(t) - swing_lag)), 0.0, 0.0)
		_add_sampled_track(anim, skel, bone, duration, leg_sampler)

	return anim


## "Collarbone_0%s4" + side L → "NPC LCollarbone_024"; bare finger names
## ("Finger11") map through the rig's L/R numbering (L 031.., R 065..).
static func _wing_bone_name(raw: String, side: String) -> String:
	if "%s" in raw:
		# Chain bones share digits between sides except the middle digit:
		# L collarbone is _024, R is _058 etc. Encode via lookup instead.
		var l_map := {
			"Collarbone_0%s4": "NPC LCollarbone_024", "UpArm1_0%s5": "NPC LUpArm1_025",
			"UpArm2_0%s6": "NPC LUpArm2_026", "Forearm1_0%s8": "NPC LForearm1_028",
			"Forearm2_0%s9": "NPC LForearm2_029", "Hand_0%s0": "NPC LHand_030",
		}
		var r_map := {
			"Collarbone_0%s4": "NPC RCollarbone_058", "UpArm1_0%s5": "NPC RUpArm1_059",
			"UpArm2_0%s6": "NPC RUpArm2_060", "Forearm1_0%s8": "NPC RForearm1_062",
			"Forearm2_0%s9": "NPC RForearm2_063", "Hand_0%s0": "NPC RHand_064",
		}
		return l_map.get(raw, "") if side == "L" else r_map.get(raw, "")
	var finger_l := {
		"Finger11": "NPC LFinger11_031", "Finger21": "NPC LFinger21_033",
		"Finger31": "NPC LFinger31_035", "Finger41": "NPC LFinger41_037",
		"Finger12": "NPC LFinger12_032", "Finger22": "NPC LFinger22_034",
		"Finger32": "NPC LFinger32_036", "Finger42": "NPC LFinger42_038",
	}
	var finger_r := {
		"Finger11": "NPC RFinger11_065", "Finger21": "NPC RFinger21_067",
		"Finger31": "NPC RFinger31_069", "Finger41": "NPC RFinger41_071",
		"Finger12": "NPC RFinger12_066", "Finger22": "NPC RFinger22_068",
		"Finger32": "NPC RFinger32_070", "Finger42": "NPC RFinger42_072",
	}
	return finger_l.get(raw, "") if side == "L" else finger_r.get(raw, "")


## Add a rotation track whose keys are skeleton-space deltas (euler degrees
## from `sampler`) composed onto the bone's rest rotation.
static func _add_sampled_track(anim: Animation, skel: Skeleton3D, bone_name: String,
		duration: float, sampler: Callable, sample_count: int = SAMPLES) -> void:
	var bi := skel.find_bone(bone_name)
	if bi < 0:
		push_warning("DragonWingFlap: bone not found: " + bone_name)
		return
	var parent := skel.get_bone_parent(bi)
	var pg_inv: Basis = Basis.IDENTITY
	if parent >= 0:
		pg_inv = skel.get_bone_global_rest(parent).basis.inverse()
	var g: Basis = skel.get_bone_global_rest(bi).basis

	var track_idx := anim.add_track(Animation.TYPE_ROTATION_3D)
	anim.track_set_path(track_idx, SKELETON_PATH + ":" + bone_name)
	anim.track_set_interpolation_type(track_idx, Animation.INTERPOLATION_CUBIC)
	for i in range(sample_count + 1):
		var t := float(i) / sample_count
		var e: Vector3 = sampler.call(t)
		var r := Basis.from_euler(Vector3(deg_to_rad(e.x), deg_to_rad(e.y), deg_to_rad(e.z)))
		var q := (pg_inv * (r * g)).get_rotation_quaternion()
		anim.rotation_track_insert_key(track_idx, duration * t, q)


static func _add_static_track(anim: Animation, skel: Skeleton3D, bone_name: String,
		duration: float, sampler: Callable) -> void:
	_add_sampled_track(anim, skel, bone_name, duration, sampler, 1)


static func add_to_animation_player(anim_player: AnimationPlayer, skel: Skeleton3D,
		anim_name: StringName = &"WingFlap") -> void:
	if not anim_player or not skel:
		push_warning("DragonWingFlap: AnimationPlayer or Skeleton3D missing")
		return

	# Ancient heavy dragon cycle: ~0.4 Hz wingbeat (scaling laws for large
	# soarers — heavier body, slower and bigger strokes).
	var anim := create_wing_flap_animation(skel, 2.5, 1.0)
	# Long slow glide cycle — wings held out, secondary motion only.
	var glide_anim := create_glide_animation(skel, 3.5, 1.0)

	var lib_name := &""
	var lib: AnimationLibrary
	if anim_player.has_animation_library(lib_name):
		lib = anim_player.get_animation_library(lib_name)
	else:
		lib = AnimationLibrary.new()
		anim_player.add_animation_library(lib_name, lib)

	if lib.has_animation(anim_name):
		lib.remove_animation(anim_name)
	lib.add_animation(anim_name, anim)

	var glide_name := &"WingGlide"
	if lib.has_animation(glide_name):
		lib.remove_animation(glide_name)
	lib.add_animation(glide_name, glide_anim)

	# Hover clip for the mid-air fire-blowing pause (played at a raised
	# speed_scale for the fast hummingbird wingbeat).
	var hover_anim := create_hover_animation(skel, 2.5, 1.0)
	var hover_name := &"WingHover"
	if lib.has_animation(hover_name):
		lib.remove_animation(hover_name)
	lib.add_animation(hover_name, hover_anim)

	print("DragonWingFlap: Added '%s' (%d tracks), '%s' (%d tracks), '%s' (%d tracks)" % [
		anim_name, anim.get_track_count(),
		glide_name, glide_anim.get_track_count(),
		hover_name, hover_anim.get_track_count()])
