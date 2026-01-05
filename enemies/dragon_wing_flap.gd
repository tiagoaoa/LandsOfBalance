class_name DragonWingFlap
extends RefCounted

## Creates a procedural wing flapping animation for the dragon
##
## Dragon Flight Animation Reference:
## - Wings flap vertically (up and down) while the body remains relatively horizontal
## - The downstroke is more powerful and faster than the upstroke
## - Wing tips lag behind the wing base, creating a wave-like motion
## - Head and neck bob slightly - rising on the downstroke (power stroke) and
##   dipping on the upstroke as the body responds to the lift generated
## - Tail acts as a counterbalance and rudder, moving opposite to head motion
## - Legs are tucked and trail behind during flight

const SKELETON_PATH := "Sketchfab_model/Dragon_Ancient_Skeleton_fbx/Object_2/RootNode/Dragon_Ancient_Skeleton/NPC /NPC Root [Root]/Object_9/Skeleton3D"

# Wing bone names
const WING_BONES := {
	# Left wing (spreads to the dragon's left)
	"L_Collarbone": "NPC LCollarbone_024",
	"L_UpArm1": "NPC LUpArm1_025",
	"L_UpArm2": "NPC LUpArm2_026",
	"L_Forearm1": "NPC LForearm1_028",
	"L_Forearm2": "NPC LForearm2_029",
	"L_Hand": "NPC LHand_030",
	"L_Finger1": "NPC LFinger11_031",
	"L_Finger2": "NPC LFinger21_033",
	"L_Finger3": "NPC LFinger31_035",
	"L_Finger4": "NPC LFinger41_037",
	# Right wing (spreads to the dragon's right)
	"R_Collarbone": "NPC RCollarbone_058",
	"R_UpArm1": "NPC RUpArm1_059",
	"R_UpArm2": "NPC RUpArm2_060",
	"R_Forearm1": "NPC RForearm1_062",
	"R_Forearm2": "NPC RForearm2_063",
	"R_Hand": "NPC RHand_064",
	"R_Finger1": "NPC RFinger11_065",
	"R_Finger2": "NPC RFinger21_067",
	"R_Finger3": "NPC RFinger31_069",
	"R_Finger4": "NPC RFinger41_071",
}

# Neck and head bones for natural movement
const NECK_BONES := {
	"Neck1": "NPC Neck1_040",
	"Neck2": "NPC Neck2_041",
	"Neck3": "NPC Neck3_042",
	"Neck4": "NPC Neck4_043",
	"Neck5": "NPC Neck5_044",
	"NeckHub": "NPC NeckHub_045",
	"Head": "NPC Head_046",
}

# Body and tail bones
const BODY_BONES := {
	"COM": "NPC COM_00",
	"Pelvis": "NPC Pelvis_01",
	"Spine1": "NPC Spine1_020",
	"Spine2": "NPC Spine2_021",
	"Spine3": "NPC Spine3_022",
	"Hub": "NPC Hub01_023",
	"Tail1": "NPC Tail1_074",
	"Tail2": "NPC Tail2_075",
	"Tail3": "NPC Tail3_076",
	"Tail4": "NPC Tail4_077",
	"Tail5": "NPC Tail5_078",
	"Tail6": "NPC Tail6_079",
	"Tail7": "NPC Tail7_080",
	"Tail8": "NPC Tail8_081",
}

# Leg bones (tucked during flight)
const LEG_BONES := {
	"L_Thigh": "NPC LLegThigh_02",
	"L_Calf": "NPC LLegCalf_03",
	"L_Foot": "NPC LLegFoot_04",
	"R_Thigh": "NPC RLegThigh_011",
	"R_Calf": "NPC RLegCalf_012",
	"R_Foot": "NPC RLegFoot_013",
}


static func create_wing_flap_animation(duration: float = 1.0, flap_intensity: float = 1.0) -> Animation:
	var anim := Animation.new()
	anim.length = duration
	anim.loop_mode = Animation.LOOP_LINEAR

	# Downstroke is faster (40% of cycle), upstroke is slower (60% of cycle)
	var downstroke_end := duration * 0.4
	var upstroke_end := duration

	# Create all animation tracks
	_add_vertical_wing_flap(anim, duration, downstroke_end, flap_intensity)
	_add_neck_head_bob(anim, duration, downstroke_end, flap_intensity)
	_add_body_motion(anim, duration, downstroke_end, flap_intensity)
	_add_tail_motion(anim, duration, downstroke_end, flap_intensity)
	_add_tucked_legs(anim, duration, flap_intensity)

	return anim


static func _add_vertical_wing_flap(anim: Animation, duration: float, downstroke_end: float, intensity: float) -> void:
	## Wings flap vertically - rotating around the X axis (pitch) for up/down motion
	## The wing folds slightly on upstroke and extends on downstroke

	# Keyframe times: start (wings up) -> downstroke end (wings down) -> end (wings up)
	var t0 := 0.0           # Wings at top
	var t1 := downstroke_end  # Wings at bottom (end of powerful downstroke)
	var t2 := duration       # Wings back at top

	# Wing tip delay for wave effect
	var tip_delay := duration * 0.08

	# === LEFT WING ===
	# Collarbone - slight lift to support wing
	_add_rotation_track(anim, "L_Collarbone",
		[t0, t1, t2],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(10 * intensity), 0, deg_to_rad(-5 * intensity))),
			Quaternion.from_euler(Vector3(deg_to_rad(-15 * intensity), 0, deg_to_rad(5 * intensity))),
			Quaternion.from_euler(Vector3(deg_to_rad(10 * intensity), 0, deg_to_rad(-5 * intensity))),
		])

	# Upper arm - main vertical flap (X rotation = pitch up/down)
	_add_rotation_track(anim, "L_UpArm1",
		[t0, t1, t2],
		[
			# Wings UP position - rotated up (positive X)
			Quaternion.from_euler(Vector3(deg_to_rad(45 * intensity), 0, deg_to_rad(-10 * intensity))),
			# Wings DOWN position - rotated down (negative X)
			Quaternion.from_euler(Vector3(deg_to_rad(-35 * intensity), 0, deg_to_rad(15 * intensity))),
			# Back to UP
			Quaternion.from_euler(Vector3(deg_to_rad(45 * intensity), 0, deg_to_rad(-10 * intensity))),
		])

	_add_rotation_track(anim, "L_UpArm2",
		[t0, t1, t2],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(15 * intensity), deg_to_rad(-5 * intensity), 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(-10 * intensity), deg_to_rad(8 * intensity), 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(15 * intensity), deg_to_rad(-5 * intensity), 0)),
		])

	# Forearm - follows with slight delay, extends on downstroke
	_add_rotation_track(anim, "L_Forearm1",
		[t0, t1 + tip_delay * 0.5, t2],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(25 * intensity), 0, deg_to_rad(-8 * intensity))),
			Quaternion.from_euler(Vector3(deg_to_rad(-20 * intensity), 0, deg_to_rad(12 * intensity))),
			Quaternion.from_euler(Vector3(deg_to_rad(25 * intensity), 0, deg_to_rad(-8 * intensity))),
		])

	_add_rotation_track(anim, "L_Forearm2",
		[t0, t1 + tip_delay, t2],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(20 * intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(-15 * intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(20 * intensity), 0, 0)),
		])

	# Hand/wing tip - most delayed, creates the wave effect
	_add_rotation_track(anim, "L_Hand",
		[t0, t1 + tip_delay * 1.5, t2],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(30 * intensity), 0, deg_to_rad(-5 * intensity))),
			Quaternion.from_euler(Vector3(deg_to_rad(-25 * intensity), 0, deg_to_rad(8 * intensity))),
			Quaternion.from_euler(Vector3(deg_to_rad(30 * intensity), 0, deg_to_rad(-5 * intensity))),
		])

	# Wing membrane fingers - spread on downstroke, fold slightly on upstroke
	_add_rotation_track(anim, "L_Finger1",
		[t0, t1 + tip_delay * 1.8, t2],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(20 * intensity), deg_to_rad(-10 * intensity), 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(-15 * intensity), deg_to_rad(5 * intensity), 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(20 * intensity), deg_to_rad(-10 * intensity), 0)),
		])

	_add_rotation_track(anim, "L_Finger2",
		[t0, t1 + tip_delay * 2.0, t2],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(25 * intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(-20 * intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(25 * intensity), 0, 0)),
		])

	# === RIGHT WING (mirrored) ===
	_add_rotation_track(anim, "R_Collarbone",
		[t0, t1, t2],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(10 * intensity), 0, deg_to_rad(5 * intensity))),
			Quaternion.from_euler(Vector3(deg_to_rad(-15 * intensity), 0, deg_to_rad(-5 * intensity))),
			Quaternion.from_euler(Vector3(deg_to_rad(10 * intensity), 0, deg_to_rad(5 * intensity))),
		])

	_add_rotation_track(anim, "R_UpArm1",
		[t0, t1, t2],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(45 * intensity), 0, deg_to_rad(10 * intensity))),
			Quaternion.from_euler(Vector3(deg_to_rad(-35 * intensity), 0, deg_to_rad(-15 * intensity))),
			Quaternion.from_euler(Vector3(deg_to_rad(45 * intensity), 0, deg_to_rad(10 * intensity))),
		])

	_add_rotation_track(anim, "R_UpArm2",
		[t0, t1, t2],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(15 * intensity), deg_to_rad(5 * intensity), 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(-10 * intensity), deg_to_rad(-8 * intensity), 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(15 * intensity), deg_to_rad(5 * intensity), 0)),
		])

	_add_rotation_track(anim, "R_Forearm1",
		[t0, t1 + tip_delay * 0.5, t2],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(25 * intensity), 0, deg_to_rad(8 * intensity))),
			Quaternion.from_euler(Vector3(deg_to_rad(-20 * intensity), 0, deg_to_rad(-12 * intensity))),
			Quaternion.from_euler(Vector3(deg_to_rad(25 * intensity), 0, deg_to_rad(8 * intensity))),
		])

	_add_rotation_track(anim, "R_Forearm2",
		[t0, t1 + tip_delay, t2],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(20 * intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(-15 * intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(20 * intensity), 0, 0)),
		])

	_add_rotation_track(anim, "R_Hand",
		[t0, t1 + tip_delay * 1.5, t2],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(30 * intensity), 0, deg_to_rad(5 * intensity))),
			Quaternion.from_euler(Vector3(deg_to_rad(-25 * intensity), 0, deg_to_rad(-8 * intensity))),
			Quaternion.from_euler(Vector3(deg_to_rad(30 * intensity), 0, deg_to_rad(5 * intensity))),
		])

	_add_rotation_track(anim, "R_Finger1",
		[t0, t1 + tip_delay * 1.8, t2],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(20 * intensity), deg_to_rad(10 * intensity), 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(-15 * intensity), deg_to_rad(-5 * intensity), 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(20 * intensity), deg_to_rad(10 * intensity), 0)),
		])

	_add_rotation_track(anim, "R_Finger2",
		[t0, t1 + tip_delay * 2.0, t2],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(25 * intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(-20 * intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(25 * intensity), 0, 0)),
		])


static func _add_neck_head_bob(anim: Animation, duration: float, downstroke_end: float, intensity: float) -> void:
	## Head and neck naturally bob during flight:
	## - On downstroke: body gets lift, head rises slightly
	## - On upstroke: body dips slightly, head follows
	## - The neck creates a wave motion, with each segment slightly delayed
	## - Head stays oriented forward (looking in flight direction)
	##
	## Elder Scrolls Blades dragon has head severely pitched down in default pose
	## Total correction needed: ~60-70 degrees distributed across neck chain

	var t0 := 0.0
	var t1 := downstroke_end
	var t2 := duration

	# Reduce intensity for neck/head - subtle movement
	var neck_intensity := intensity * 0.25

	# Base pitch offset to keep head looking forward (negative X = pitch up)
	# The dragon model's default pose has the head looking ~60-70° down
	# Distribute correction across 5 neck segments + head for natural curve
	var neck_pitch_per_segment := -12.0  # Each neck segment pitches up 12°
	var head_pitch := -8.0  # Head adds final 8° (total: 5*12 + 8 = 68°)

	# Slight upward bias for majestic flight pose
	var upward_bias := -3.0  # Extra upward tilt for heroic look

	# Neck segments create a wave - each delayed slightly from the previous
	var neck_delay := duration * 0.025

	# Neck1 (base of neck, connected to body) - pitch up to raise head
	_add_rotation_track(anim, "Neck1",
		[t0, t1, t2],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(neck_pitch_per_segment + upward_bias + -3 * neck_intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(neck_pitch_per_segment + upward_bias + 4 * neck_intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(neck_pitch_per_segment + upward_bias + -3 * neck_intensity), 0, 0)),
		])

	# Neck2
	_add_rotation_track(anim, "Neck2",
		[t0, t1 + neck_delay, t2],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(neck_pitch_per_segment + -2 * neck_intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(neck_pitch_per_segment + 3 * neck_intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(neck_pitch_per_segment + -2 * neck_intensity), 0, 0)),
		])

	# Neck3
	_add_rotation_track(anim, "Neck3",
		[t0, t1 + neck_delay * 2, t2],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(neck_pitch_per_segment + -2 * neck_intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(neck_pitch_per_segment + 3 * neck_intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(neck_pitch_per_segment + -2 * neck_intensity), 0, 0)),
		])

	# Neck4
	_add_rotation_track(anim, "Neck4",
		[t0, t1 + neck_delay * 3, t2],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(neck_pitch_per_segment + -1.5 * neck_intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(neck_pitch_per_segment + 2 * neck_intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(neck_pitch_per_segment + -1.5 * neck_intensity), 0, 0)),
		])

	# Neck5
	_add_rotation_track(anim, "Neck5",
		[t0, t1 + neck_delay * 4, t2],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(neck_pitch_per_segment + -1 * neck_intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(neck_pitch_per_segment + 1.5 * neck_intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(neck_pitch_per_segment + -1 * neck_intensity), 0, 0)),
		])

	# Head - final pitch correction plus slight bobbing
	# Head compensates to look forward/slightly up during flight
	_add_rotation_track(anim, "Head",
		[t0, t1 + neck_delay * 5, t2],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(head_pitch + 2 * neck_intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(head_pitch + -1.5 * neck_intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(head_pitch + 2 * neck_intensity), 0, 0)),
		])


static func _add_body_motion(anim: Animation, duration: float, downstroke_end: float, intensity: float) -> void:
	## Body responds to wing forces:
	## - Rises slightly on downstroke (lift)
	## - Slight pitch changes as center of gravity shifts

	var t0 := 0.0
	var t1 := downstroke_end
	var t2 := duration

	var body_intensity := intensity * 0.2

	# Spine responds to wing motion
	_add_rotation_track(anim, "Spine1",
		[t0, t1, t2],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(-2 * body_intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(3 * body_intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(-2 * body_intensity), 0, 0)),
		])

	_add_rotation_track(anim, "Spine2",
		[t0, t1, t2],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(-1 * body_intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(2 * body_intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(-1 * body_intensity), 0, 0)),
		])

	# Hub (chest) - main body response
	_add_rotation_track(anim, "Hub",
		[t0, t1, t2],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(-3 * body_intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(4 * body_intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(-3 * body_intensity), 0, 0)),
		])


static func _add_tail_motion(anim: Animation, duration: float, downstroke_end: float, intensity: float) -> void:
	## Tail acts as counterbalance and rudder:
	## - Waves opposite to head motion
	## - Creates a traveling wave down the tail
	## - Helps stabilize flight

	var t0 := 0.0
	var t1 := downstroke_end
	var t2 := duration

	var tail_intensity := intensity * 0.4
	var tail_delay := duration * 0.04  # Wave travels down tail

	# Tail segments - wave motion, opposite phase to head
	_add_rotation_track(anim, "Tail1",
		[t0, t1, t2],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(3 * tail_intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(-4 * tail_intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(3 * tail_intensity), 0, 0)),
		])

	_add_rotation_track(anim, "Tail2",
		[t0, t1 + tail_delay, t2],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(4 * tail_intensity), deg_to_rad(-2 * tail_intensity), 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(-5 * tail_intensity), deg_to_rad(2 * tail_intensity), 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(4 * tail_intensity), deg_to_rad(-2 * tail_intensity), 0)),
		])

	_add_rotation_track(anim, "Tail3",
		[t0, t1 + tail_delay * 2, t2],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(5 * tail_intensity), deg_to_rad(-3 * tail_intensity), 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(-6 * tail_intensity), deg_to_rad(3 * tail_intensity), 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(5 * tail_intensity), deg_to_rad(-3 * tail_intensity), 0)),
		])

	_add_rotation_track(anim, "Tail4",
		[t0, t1 + tail_delay * 3, t2],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(5 * tail_intensity), deg_to_rad(-4 * tail_intensity), 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(-6 * tail_intensity), deg_to_rad(4 * tail_intensity), 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(5 * tail_intensity), deg_to_rad(-4 * tail_intensity), 0)),
		])

	_add_rotation_track(anim, "Tail5",
		[t0, t1 + tail_delay * 4, t2],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(4 * tail_intensity), deg_to_rad(-5 * tail_intensity), 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(-5 * tail_intensity), deg_to_rad(5 * tail_intensity), 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(4 * tail_intensity), deg_to_rad(-5 * tail_intensity), 0)),
		])

	_add_rotation_track(anim, "Tail6",
		[t0, t1 + tail_delay * 5, t2],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(3 * tail_intensity), deg_to_rad(-5 * tail_intensity), 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(-4 * tail_intensity), deg_to_rad(5 * tail_intensity), 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(3 * tail_intensity), deg_to_rad(-5 * tail_intensity), 0)),
		])

	_add_rotation_track(anim, "Tail7",
		[t0, t1 + tail_delay * 6, t2],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(2 * tail_intensity), deg_to_rad(-4 * tail_intensity), 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(-3 * tail_intensity), deg_to_rad(4 * tail_intensity), 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(2 * tail_intensity), deg_to_rad(-4 * tail_intensity), 0)),
		])


static func _add_tucked_legs(anim: Animation, duration: float, intensity: float) -> void:
	## Legs are tucked during flight - static pose
	## Just a slight bend to look natural

	var leg_intensity := intensity * 0.5

	# Left leg - tucked back
	_add_rotation_track(anim, "L_Thigh",
		[0.0, duration],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(30 * leg_intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(30 * leg_intensity), 0, 0)),
		])

	_add_rotation_track(anim, "L_Calf",
		[0.0, duration],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(-45 * leg_intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(-45 * leg_intensity), 0, 0)),
		])

	# Right leg - tucked back
	_add_rotation_track(anim, "R_Thigh",
		[0.0, duration],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(30 * leg_intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(30 * leg_intensity), 0, 0)),
		])

	_add_rotation_track(anim, "R_Calf",
		[0.0, duration],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(-45 * leg_intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(-45 * leg_intensity), 0, 0)),
		])


static func _add_rotation_track(anim: Animation, bone_key: String, times: Array, rotations: Array) -> void:
	var bone_name: String = ""

	if WING_BONES.has(bone_key):
		bone_name = WING_BONES[bone_key]
	elif NECK_BONES.has(bone_key):
		bone_name = NECK_BONES[bone_key]
	elif BODY_BONES.has(bone_key):
		bone_name = BODY_BONES[bone_key]
	elif LEG_BONES.has(bone_key):
		bone_name = LEG_BONES[bone_key]
	else:
		push_warning("DragonWingFlap: Unknown bone key: " + bone_key)
		return

	var track_path := SKELETON_PATH + ":" + bone_name
	var track_idx := anim.add_track(Animation.TYPE_ROTATION_3D)
	anim.track_set_path(track_idx, track_path)
	anim.track_set_interpolation_type(track_idx, Animation.INTERPOLATION_CUBIC)

	for i in times.size():
		anim.rotation_track_insert_key(track_idx, times[i], rotations[i])


static func add_to_animation_player(anim_player: AnimationPlayer, anim_name: StringName = &"WingFlap") -> void:
	if not anim_player:
		push_warning("DragonWingFlap: No AnimationPlayer provided")
		return

	# Create animation: 1.0 second per flap cycle, full intensity
	var anim := create_wing_flap_animation(1.0, 1.0)

	# Get or create the default animation library
	var lib_name := &""
	var lib: AnimationLibrary
	if anim_player.has_animation_library(lib_name):
		lib = anim_player.get_animation_library(lib_name)
	else:
		lib = AnimationLibrary.new()
		anim_player.add_animation_library(lib_name, lib)

	# Add the animation
	if lib.has_animation(anim_name):
		lib.remove_animation(anim_name)
	lib.add_animation(anim_name, anim)

	print("DragonWingFlap: Added '%s' animation (%.2fs, %d tracks)" % [anim_name, anim.length, anim.get_track_count()])
