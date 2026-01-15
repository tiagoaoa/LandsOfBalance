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
	"L_Finger12": "NPC LFinger12_032",
	"L_Finger2": "NPC LFinger21_033",
	"L_Finger22": "NPC LFinger22_034",
	"L_Finger3": "NPC LFinger31_035",
	"L_Finger32": "NPC LFinger32_036",
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
	"R_Finger22": "NPC RFinger22_068",
	"R_Finger3": "NPC RFinger31_069",
	"R_Finger32": "NPC RFinger32_070",
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

	# === PHYSICS-BASED ANIMATION ===
	# Wings push air DOWN → reaction force pushes body UP at chest (Hub)
	# Force propagates as a wave from Hub outward to head and tail
	# Delay = distance from Hub / wave_speed
	# Amplitude decreases with distance (damping)

	# Wing flapping - the source of all motion
	_add_vertical_wing_flap(anim, duration, downstroke_end, flap_intensity)

	# Body response - DISABLED until wings are correct
	# _add_physics_body_response(anim, duration, downstroke_end, flap_intensity)

	return anim


static func _add_physics_body_response(anim: Animation, duration: float, downstroke_end: float, intensity: float) -> void:
	## Physics-based body motion in response to wing forces during forward flight
	##
	## Key principles from bat flight research:
	## 1. DOWNSTROKE: Wings sweep forward-down, body pitches UP (reaction force)
	## 2. UPSTROKE: Wings retract backward-up, body pitches DOWN more dramatically
	## 3. HEAD stays STILL (head tracking - essential for vision during flight)
	## 4. HIPS/TAIL move A LOT (counterbalance and rudder)
	## 5. LEGS trail behind, tucked
	##
	## The motion propagates as a wave from the chest (Hub) outward

	var t0 := 0.0
	var t1 := downstroke_end  # End of downstroke
	var t2 := duration

	# Wave delay per segment
	var wave_delay := duration * 0.03

	# === CHEST/HUB - Primary response to wing forces ===
	# Body pitches UP on downstroke (wings push air down)
	# Body pitches DOWN on upstroke (wings retract, less lift)
	_add_rotation_track(anim, "Hub",
		[t0, t1, t2],
		[
			# Start of downstroke: neutral/slightly down from previous upstroke
			Quaternion.from_euler(Vector3(deg_to_rad(2 * intensity), 0, 0)),
			# End of downstroke: pitched UP from lift force
			Quaternion.from_euler(Vector3(deg_to_rad(-4 * intensity), 0, 0)),
			# End of upstroke: pitched DOWN (more dramatic)
			Quaternion.from_euler(Vector3(deg_to_rad(2 * intensity), 0, 0)),
		])

	# === SPINE - Wave propagates backward ===
	_add_rotation_track(anim, "Spine3",
		[t0, t1 + wave_delay, t2],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(1.5 * intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(-3 * intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(1.5 * intensity), 0, 0)),
		])

	_add_rotation_track(anim, "Spine2",
		[t0, t1 + wave_delay * 2, t2],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(1 * intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(-2 * intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(1 * intensity), 0, 0)),
		])

	_add_rotation_track(anim, "Spine1",
		[t0, t1 + wave_delay * 3, t2],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(0.5 * intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(-1.5 * intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(0.5 * intensity), 0, 0)),
		])

	# === NECK - Absorbs motion to keep head stable (head tracking) ===
	# Neck COMPENSATES for body pitch to keep head level
	# When body pitches up, neck pitches down (and vice versa)
	_add_rotation_track(anim, "Neck1",
		[t0, t1, t2],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(-1 * intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(2 * intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(-1 * intensity), 0, 0)),
		])

	_add_rotation_track(anim, "Neck2",
		[t0, t1 + wave_delay * 0.3, t2],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(-0.8 * intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(1.5 * intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(-0.8 * intensity), 0, 0)),
		])

	_add_rotation_track(anim, "Neck3",
		[t0, t1 + wave_delay * 0.6, t2],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(-0.5 * intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(1 * intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(-0.5 * intensity), 0, 0)),
		])

	_add_rotation_track(anim, "Neck4",
		[t0, t1 + wave_delay * 0.9, t2],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(-0.3 * intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(0.6 * intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(-0.3 * intensity), 0, 0)),
		])

	_add_rotation_track(anim, "Neck5",
		[t0, t1 + wave_delay * 1.2, t2],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(-0.2 * intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(0.3 * intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(-0.2 * intensity), 0, 0)),
		])

	# === HEAD - Nearly stationary (head tracking for vision) ===
	# Minimal movement - dragons need to see where they're flying!
	_add_rotation_track(anim, "Head",
		[t0, t1 + wave_delay * 1.5, t2],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(-0.1 * intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(0.1 * intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(-0.1 * intensity), 0, 0)),
		])

	# === TAIL - Major counterbalance, moves A LOT ===
	# Tail moves OPPOSITE to body pitch (counterbalance)
	# Whip effect: amplitude increases toward tip, then decreases
	var tail_delay := wave_delay * 4  # Starts after spine wave reaches pelvis

	_add_rotation_track(anim, "Tail1",
		[t0, t1 + tail_delay, t2],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(-3 * intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(5 * intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(-3 * intensity), 0, 0)),
		])

	_add_rotation_track(anim, "Tail2",
		[t0, t1 + tail_delay + wave_delay, t2],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(-4 * intensity), deg_to_rad(-1 * intensity), 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(6 * intensity), deg_to_rad(1 * intensity), 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(-4 * intensity), deg_to_rad(-1 * intensity), 0)),
		])

	_add_rotation_track(anim, "Tail3",
		[t0, t1 + tail_delay + wave_delay * 2, t2],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(-5 * intensity), deg_to_rad(-2 * intensity), 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(7 * intensity), deg_to_rad(2 * intensity), 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(-5 * intensity), deg_to_rad(-2 * intensity), 0)),
		])

	_add_rotation_track(anim, "Tail4",
		[t0, t1 + tail_delay + wave_delay * 3, t2],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(-6 * intensity), deg_to_rad(-2 * intensity), 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(8 * intensity), deg_to_rad(2 * intensity), 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(-6 * intensity), deg_to_rad(-2 * intensity), 0)),
		])

	_add_rotation_track(anim, "Tail5",
		[t0, t1 + tail_delay + wave_delay * 4, t2],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(-5 * intensity), deg_to_rad(-2 * intensity), 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(7 * intensity), deg_to_rad(2 * intensity), 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(-5 * intensity), deg_to_rad(-2 * intensity), 0)),
		])

	_add_rotation_track(anim, "Tail6",
		[t0, t1 + tail_delay + wave_delay * 5, t2],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(-4 * intensity), deg_to_rad(-1 * intensity), 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(5 * intensity), deg_to_rad(1 * intensity), 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(-4 * intensity), deg_to_rad(-1 * intensity), 0)),
		])

	_add_rotation_track(anim, "Tail7",
		[t0, t1 + tail_delay + wave_delay * 6, t2],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(-3 * intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(4 * intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(-3 * intensity), 0, 0)),
		])

	# === LEGS - Tucked and trailing behind ===
	_add_rotation_track(anim, "L_Thigh",
		[t0, t1, t2],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(25 * intensity), 0, deg_to_rad(-5 * intensity))),
			Quaternion.from_euler(Vector3(deg_to_rad(30 * intensity), 0, deg_to_rad(-8 * intensity))),
			Quaternion.from_euler(Vector3(deg_to_rad(25 * intensity), 0, deg_to_rad(-5 * intensity))),
		])

	_add_rotation_track(anim, "L_Calf",
		[t0, t1, t2],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(-40 * intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(-45 * intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(-40 * intensity), 0, 0)),
		])

	_add_rotation_track(anim, "R_Thigh",
		[t0, t1, t2],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(25 * intensity), 0, deg_to_rad(5 * intensity))),
			Quaternion.from_euler(Vector3(deg_to_rad(30 * intensity), 0, deg_to_rad(8 * intensity))),
			Quaternion.from_euler(Vector3(deg_to_rad(25 * intensity), 0, deg_to_rad(5 * intensity))),
		])

	_add_rotation_track(anim, "R_Calf",
		[t0, t1, t2],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(-40 * intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(-45 * intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(-40 * intensity), 0, 0)),
		])


static func _add_wave_response(anim: Animation, bone_key: String, duration: float,
		downstroke_end: float, delay: float, amplitude: float, invert: bool = false) -> void:
	## Add a single bone's response to the wing force wave
	##
	## Physics: Wing downstroke creates upward force at chest
	## This force propagates as a wave through the skeleton
	## Each segment responds with a time delay proportional to its distance
	##
	## delay: phase offset in seconds (wave propagation time from Hub)
	## amplitude: maximum rotation in degrees
	## invert: if true, motion is opposite phase (for counterbalance like tail)

	# Direction of pitch (negative X = pitch up in Godot)
	# Body pitches UP when wings push down (Newton's 3rd law)
	var sign := -1.0 if not invert else 1.0

	# Phase shift from delay - convert to fraction of cycle
	var phase_shift := delay / duration

	# Create sinusoidal motion with phase shift
	# Peak UP occurs at downstroke_end (when wing force is maximum)
	# Phase-shifted peak time for this segment
	var peak_time := fmod(downstroke_end + delay, duration)
	var trough_time := fmod(peak_time + duration * 0.5, duration)

	# Build keyframes for smooth sinusoidal motion
	# We need 4 keyframes for a clean loop: start, peak, trough, end
	var times: Array = []
	var rotations: Array = []

	# Calculate rotation values
	var rot_peak := Quaternion.from_euler(Vector3(deg_to_rad(sign * amplitude), 0, 0))
	var rot_trough := Quaternion.from_euler(Vector3(deg_to_rad(-sign * amplitude * 0.4), 0, 0))
	var rot_mid := Quaternion.from_euler(Vector3(deg_to_rad(sign * amplitude * 0.3), 0, 0))

	# Simple approach: 4 evenly-spaced keyframes with phase offset
	var t0 := 0.0
	var t1 := duration * 0.25
	var t2 := duration * 0.5
	var t3 := duration * 0.75
	var t4 := duration

	# Calculate rotation at each time point based on sine wave with phase shift
	# sin(0) = 0, sin(π/2) = 1, sin(π) = 0, sin(3π/2) = -1
	var phase := phase_shift * TAU  # Convert to radians

	var r0 := _wave_rotation(0.0 * TAU + phase, amplitude, sign)
	var r1 := _wave_rotation(0.25 * TAU + phase, amplitude, sign)
	var r2 := _wave_rotation(0.5 * TAU + phase, amplitude, sign)
	var r3 := _wave_rotation(0.75 * TAU + phase, amplitude, sign)
	var r4 := r0  # Loop back to start

	_add_rotation_track(anim, bone_key,
		[t0, t1, t2, t3, t4],
		[r0, r1, r2, r3, r4])


static func _wave_rotation(phase: float, amplitude: float, sign: float) -> Quaternion:
	## Calculate rotation quaternion for a point on the wave
	## phase: position in wave cycle (radians)
	## amplitude: maximum rotation (degrees)
	## sign: direction multiplier
	var wave_value := sin(phase)
	var rotation_deg := sign * amplitude * wave_value
	return Quaternion.from_euler(Vector3(deg_to_rad(rotation_deg), 0, 0))


static func _add_vertical_wing_flap(anim: Animation, duration: float, downstroke_end: float, intensity: float) -> void:
	## Dragon Wing Flap Animation
	##
	## Coordinate system:
	## - DOWN: Negative Y axis (gravity direction)
	## - FORWARD: Positive Z axis (dragon's flight direction)
	## - LEFT/RIGHT: X axis
	##
	## Wing stroke plane: 30° from vertical (gravity vector)
	## - Downstroke: Wings push air DOWN and BACK → generates LIFT + FORWARD THRUST
	## - Upstroke: Wings recover UP and FORWARD with minimal resistance
	##
	## The main lifting surface is the forearm/hand/fingers (membrane area)
	## These must move through the 30° stroke plane to generate thrust

	var t0 := 0.0             # Start: wings at TOP of stroke
	var t1 := downstroke_end  # End of downstroke: wings at BOTTOM
	var t2 := duration        # End: wings back at TOP

	# 30 degrees from vertical = the stroke plane angle
	# This creates both lift (vertical component) and thrust (horizontal component)
	var stroke_angle := 30.0 * intensity

	# === LEFT WING ===
	# Wing extends to the dragon's LEFT (negative X in local space)
	#
	# Bone hierarchy: Collarbone (shoulder) → UpArm1 → UpArm2 → Forearm → Hand → Fingers
	#
	# Bone local axes (typical for left arm bones):
	# - Positive X rotation: rotates bone "down" relative to parent
	# - Positive Z rotation: rotates bone "forward"
	#
	# For downstroke: rotate positive X (down) + positive Z (forward tilt for 30° plane)
	# For upstroke: rotate negative X (up) + negative Z (back)

	# Wing bones - up and down motion (Y rotation - gravity axis)
	var amp := 35.0 * intensity
	var elbow_amp := 30.0 * intensity
	var uparm_amp := 25.0 * intensity
	var head_offset := 10.0  # 10° clockwise toward head

	# R_UpArm2 (upper arm) - with 10° offset toward head
	_add_rotation_track(anim, "R_UpArm2", [t0, t1, t2], [
		Quaternion.from_euler(Vector3(0, deg_to_rad(uparm_amp + head_offset), 0)),   # DOWN
		Quaternion.from_euler(Vector3(0, deg_to_rad(-uparm_amp + head_offset), 0)),  # UP
		Quaternion.from_euler(Vector3(0, deg_to_rad(uparm_amp + head_offset), 0)),   # DOWN
	])

	# R_Forearm1 (elbow) - 30 degrees, synched
	_add_rotation_track(anim, "R_Forearm1", [t0, t1, t2], [
		Quaternion.from_euler(Vector3(0, deg_to_rad(elbow_amp), 0)),   # DOWN
		Quaternion.from_euler(Vector3(0, deg_to_rad(-elbow_amp), 0)),  # UP
		Quaternion.from_euler(Vector3(0, deg_to_rad(elbow_amp), 0)),   # DOWN
	])

	# Base finger bones (R_Finger1-4)
	_add_rotation_track(anim, "R_Finger1", [t0, t1, t2], [
		Quaternion.from_euler(Vector3(0, deg_to_rad(amp), 0)),   # DOWN
		Quaternion.from_euler(Vector3(0, deg_to_rad(-amp), 0)),  # UP
		Quaternion.from_euler(Vector3(0, deg_to_rad(amp), 0)),   # DOWN
	])

	_add_rotation_track(anim, "R_Finger2", [t0, t1, t2], [
		Quaternion.from_euler(Vector3(0, deg_to_rad(amp), 0)),   # DOWN
		Quaternion.from_euler(Vector3(0, deg_to_rad(-amp), 0)),  # UP
		Quaternion.from_euler(Vector3(0, deg_to_rad(amp), 0)),   # DOWN
	])

	_add_rotation_track(anim, "R_Finger3", [t0, t1, t2], [
		Quaternion.from_euler(Vector3(0, deg_to_rad(amp), 0)),   # DOWN
		Quaternion.from_euler(Vector3(0, deg_to_rad(-amp), 0)),  # UP
		Quaternion.from_euler(Vector3(0, deg_to_rad(amp), 0)),   # DOWN
	])

	_add_rotation_track(anim, "R_Finger4", [t0, t1, t2], [
		Quaternion.from_euler(Vector3(0, deg_to_rad(amp), 0)),   # DOWN
		Quaternion.from_euler(Vector3(0, deg_to_rad(-amp), 0)),  # UP
		Quaternion.from_euler(Vector3(0, deg_to_rad(amp), 0)),   # DOWN
	])

	# Second finger segments
	_add_rotation_track(anim, "R_Finger22", [t0, t1, t2], [
		Quaternion.from_euler(Vector3(0, deg_to_rad(amp), 0)),   # DOWN
		Quaternion.from_euler(Vector3(0, deg_to_rad(-amp), 0)),  # UP
		Quaternion.from_euler(Vector3(0, deg_to_rad(amp), 0)),   # DOWN
	])

	_add_rotation_track(anim, "R_Finger32", [t0, t1, t2], [
		Quaternion.from_euler(Vector3(0, deg_to_rad(amp), 0)),   # DOWN
		Quaternion.from_euler(Vector3(0, deg_to_rad(-amp), 0)),  # UP
		Quaternion.from_euler(Vector3(0, deg_to_rad(amp), 0)),   # DOWN
	])

	# === LEFT WING (mirrored) ===
	# L_UpArm2 (upper arm) - mirrored head offset
	_add_rotation_track(anim, "L_UpArm2", [t0, t1, t2], [
		Quaternion.from_euler(Vector3(0, deg_to_rad(-uparm_amp - head_offset), 0)),   # DOWN
		Quaternion.from_euler(Vector3(0, deg_to_rad(uparm_amp - head_offset), 0)),    # UP
		Quaternion.from_euler(Vector3(0, deg_to_rad(-uparm_amp - head_offset), 0)),   # DOWN
	])

	# L_Forearm1 (elbow)
	_add_rotation_track(anim, "L_Forearm1", [t0, t1, t2], [
		Quaternion.from_euler(Vector3(0, deg_to_rad(-elbow_amp), 0)),   # DOWN
		Quaternion.from_euler(Vector3(0, deg_to_rad(elbow_amp), 0)),    # UP
		Quaternion.from_euler(Vector3(0, deg_to_rad(-elbow_amp), 0)),   # DOWN
	])

	# Left base finger bones
	_add_rotation_track(anim, "L_Finger1", [t0, t1, t2], [
		Quaternion.from_euler(Vector3(0, deg_to_rad(-amp), 0)),   # DOWN
		Quaternion.from_euler(Vector3(0, deg_to_rad(amp), 0)),    # UP
		Quaternion.from_euler(Vector3(0, deg_to_rad(-amp), 0)),   # DOWN
	])

	_add_rotation_track(anim, "L_Finger2", [t0, t1, t2], [
		Quaternion.from_euler(Vector3(0, deg_to_rad(-amp), 0)),   # DOWN
		Quaternion.from_euler(Vector3(0, deg_to_rad(amp), 0)),    # UP
		Quaternion.from_euler(Vector3(0, deg_to_rad(-amp), 0)),   # DOWN
	])

	_add_rotation_track(anim, "L_Finger3", [t0, t1, t2], [
		Quaternion.from_euler(Vector3(0, deg_to_rad(-amp), 0)),   # DOWN
		Quaternion.from_euler(Vector3(0, deg_to_rad(amp), 0)),    # UP
		Quaternion.from_euler(Vector3(0, deg_to_rad(-amp), 0)),   # DOWN
	])

	_add_rotation_track(anim, "L_Finger4", [t0, t1, t2], [
		Quaternion.from_euler(Vector3(0, deg_to_rad(-amp), 0)),   # DOWN
		Quaternion.from_euler(Vector3(0, deg_to_rad(amp), 0)),    # UP
		Quaternion.from_euler(Vector3(0, deg_to_rad(-amp), 0)),   # DOWN
	])

	# Left second finger segments
	_add_rotation_track(anim, "L_Finger22", [t0, t1, t2], [
		Quaternion.from_euler(Vector3(0, deg_to_rad(-amp), 0)),   # DOWN
		Quaternion.from_euler(Vector3(0, deg_to_rad(amp), 0)),    # UP
		Quaternion.from_euler(Vector3(0, deg_to_rad(-amp), 0)),   # DOWN
	])

	_add_rotation_track(anim, "L_Finger32", [t0, t1, t2], [
		Quaternion.from_euler(Vector3(0, deg_to_rad(-amp), 0)),   # DOWN
		Quaternion.from_euler(Vector3(0, deg_to_rad(amp), 0)),    # UP
		Quaternion.from_euler(Vector3(0, deg_to_rad(-amp), 0)),   # DOWN
	])

	# === NECK BONES - Z rotation wave ===
	# Custom ranges from animation editor
	_add_rotation_track(anim, "Neck1", [t0, t1, t2], [
		Quaternion.from_euler(Vector3(0, 0, deg_to_rad(10.0 * intensity))),
		Quaternion.from_euler(Vector3(0, 0, deg_to_rad(-10.0 * intensity))),
		Quaternion.from_euler(Vector3(0, 0, deg_to_rad(10.0 * intensity))),
	])
	_add_rotation_track(anim, "Neck2", [t0, t1, t2], [
		Quaternion.from_euler(Vector3(0, 0, deg_to_rad(10.0 * intensity))),
		Quaternion.from_euler(Vector3(0, 0, deg_to_rad(-10.0 * intensity))),
		Quaternion.from_euler(Vector3(0, 0, deg_to_rad(10.0 * intensity))),
	])
	_add_rotation_track(anim, "Neck3", [t0, t1, t2], [
		Quaternion.from_euler(Vector3(0, 0, deg_to_rad(80.0 * intensity))),
		Quaternion.from_euler(Vector3(0, 0, deg_to_rad(68.0 * intensity))),
		Quaternion.from_euler(Vector3(0, 0, deg_to_rad(80.0 * intensity))),
	])
	_add_rotation_track(anim, "Neck4", [t0, t1, t2], [
		Quaternion.from_euler(Vector3(0, 0, deg_to_rad(28.0 * intensity))),
		Quaternion.from_euler(Vector3(0, 0, deg_to_rad(17.0 * intensity))),
		Quaternion.from_euler(Vector3(0, 0, deg_to_rad(28.0 * intensity))),
	])
	_add_rotation_track(anim, "Neck5", [t0, t1, t2], [
		Quaternion.from_euler(Vector3(0, 0, deg_to_rad(-21.0 * intensity))),
		Quaternion.from_euler(Vector3(0, 0, deg_to_rad(60.0 * intensity))),
		Quaternion.from_euler(Vector3(0, 0, deg_to_rad(-21.0 * intensity))),
	])

	# === TAIL BONES - Z rotation (custom values from animation editor) ===
	# Tail1: min=-14, max=-62
	_add_rotation_track(anim, "Tail1", [t0, t1, t2], [
		Quaternion.from_euler(Vector3(0, 0, deg_to_rad(-62.0 * intensity))),
		Quaternion.from_euler(Vector3(0, 0, deg_to_rad(-14.0 * intensity))),
		Quaternion.from_euler(Vector3(0, 0, deg_to_rad(-62.0 * intensity))),
	])
	# Tail2: min=-65, max=-33
	_add_rotation_track(anim, "Tail2", [t0, t1, t2], [
		Quaternion.from_euler(Vector3(0, 0, deg_to_rad(-33.0 * intensity))),
		Quaternion.from_euler(Vector3(0, 0, deg_to_rad(-65.0 * intensity))),
		Quaternion.from_euler(Vector3(0, 0, deg_to_rad(-33.0 * intensity))),
	])
	# Tail3: min=47, max=-40
	_add_rotation_track(anim, "Tail3", [t0, t1, t2], [
		Quaternion.from_euler(Vector3(0, 0, deg_to_rad(-40.0 * intensity))),
		Quaternion.from_euler(Vector3(0, 0, deg_to_rad(47.0 * intensity))),
		Quaternion.from_euler(Vector3(0, 0, deg_to_rad(-40.0 * intensity))),
	])
	# Tail4: min=56, max=-29
	_add_rotation_track(anim, "Tail4", [t0, t1, t2], [
		Quaternion.from_euler(Vector3(0, 0, deg_to_rad(-29.0 * intensity))),
		Quaternion.from_euler(Vector3(0, 0, deg_to_rad(56.0 * intensity))),
		Quaternion.from_euler(Vector3(0, 0, deg_to_rad(-29.0 * intensity))),
	])
	# Tail5: min=-76, max=-38
	_add_rotation_track(anim, "Tail5", [t0, t1, t2], [
		Quaternion.from_euler(Vector3(0, 0, deg_to_rad(-38.0 * intensity))),
		Quaternion.from_euler(Vector3(0, 0, deg_to_rad(-76.0 * intensity))),
		Quaternion.from_euler(Vector3(0, 0, deg_to_rad(-38.0 * intensity))),
	])
	# Tail6: min=14, max=61
	_add_rotation_track(anim, "Tail6", [t0, t1, t2], [
		Quaternion.from_euler(Vector3(0, 0, deg_to_rad(61.0 * intensity))),
		Quaternion.from_euler(Vector3(0, 0, deg_to_rad(14.0 * intensity))),
		Quaternion.from_euler(Vector3(0, 0, deg_to_rad(61.0 * intensity))),
	])
	# Tail7: min=6, max=81
	_add_rotation_track(anim, "Tail7", [t0, t1, t2], [
		Quaternion.from_euler(Vector3(0, 0, deg_to_rad(81.0 * intensity))),
		Quaternion.from_euler(Vector3(0, 0, deg_to_rad(6.0 * intensity))),
		Quaternion.from_euler(Vector3(0, 0, deg_to_rad(81.0 * intensity))),
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
	var neck_intensity := intensity * 0.15  # Reduced from 0.25

	# Base pitch offset to keep head looking forward (negative X = pitch up)
	# Keep corrections minimal - the model may not need as much correction as assumed
	# Small adjustments for natural flight pose
	var neck_pitch_per_segment := -3.0  # Reduced from -12° to -3° per segment
	var head_pitch := -5.0  # Reduced from -8° (total: 5*3 + 5 = 20°)

	# Slight upward bias for majestic flight pose
	var upward_bias := 0.0  # Removed extra tilt to prevent folding

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
	## - Very subtle pitch changes - keep body mostly straight
	## - Spine extended for stretched flight pose

	var t0 := 0.0
	var t1 := downstroke_end
	var t2 := duration

	var body_intensity := intensity * 0.1  # Reduced from 0.2 for subtler motion

	# Spine stays mostly straight with very subtle motion
	_add_rotation_track(anim, "Spine1",
		[t0, t1, t2],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(-1 * body_intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(1 * body_intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(-1 * body_intensity), 0, 0)),
		])

	_add_rotation_track(anim, "Spine2",
		[t0, t1, t2],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(-0.5 * body_intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(0.5 * body_intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(-0.5 * body_intensity), 0, 0)),
		])

	# Hub (chest) - minimal movement to keep body straight
	_add_rotation_track(anim, "Hub",
		[t0, t1, t2],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(-1 * body_intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(1 * body_intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(-1 * body_intensity), 0, 0)),
		])


static func _add_tail_motion(anim: Animation, duration: float, downstroke_end: float, intensity: float) -> void:
	## Tail acts as counterbalance and rudder:
	## - Waves opposite to head motion
	## - Creates a traveling wave down the tail
	## - Helps stabilize flight
	## - Base extension keeps tail stretched out behind

	var t0 := 0.0
	var t1 := downstroke_end
	var t2 := duration

	var tail_intensity := intensity * 0.2  # Reduced from 0.4 for subtler motion
	var tail_delay := duration * 0.04  # Wave travels down tail

	# Base extension to keep tail stretched out (positive X = pitch down/back)
	var tail_extend := 3.0  # Extends tail backward

	# Tail segments - gentle wave motion with extension bias
	_add_rotation_track(anim, "Tail1",
		[t0, t1, t2],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(tail_extend + 2 * tail_intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(tail_extend - 2 * tail_intensity), 0, 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(tail_extend + 2 * tail_intensity), 0, 0)),
		])

	_add_rotation_track(anim, "Tail2",
		[t0, t1 + tail_delay, t2],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(tail_extend + 2 * tail_intensity), deg_to_rad(-1 * tail_intensity), 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(tail_extend - 2 * tail_intensity), deg_to_rad(1 * tail_intensity), 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(tail_extend + 2 * tail_intensity), deg_to_rad(-1 * tail_intensity), 0)),
		])

	_add_rotation_track(anim, "Tail3",
		[t0, t1 + tail_delay * 2, t2],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(tail_extend + 3 * tail_intensity), deg_to_rad(-2 * tail_intensity), 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(tail_extend - 3 * tail_intensity), deg_to_rad(2 * tail_intensity), 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(tail_extend + 3 * tail_intensity), deg_to_rad(-2 * tail_intensity), 0)),
		])

	_add_rotation_track(anim, "Tail4",
		[t0, t1 + tail_delay * 3, t2],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(tail_extend + 3 * tail_intensity), deg_to_rad(-2 * tail_intensity), 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(tail_extend - 3 * tail_intensity), deg_to_rad(2 * tail_intensity), 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(tail_extend + 3 * tail_intensity), deg_to_rad(-2 * tail_intensity), 0)),
		])

	_add_rotation_track(anim, "Tail5",
		[t0, t1 + tail_delay * 4, t2],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(tail_extend + 2 * tail_intensity), deg_to_rad(-3 * tail_intensity), 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(tail_extend - 2 * tail_intensity), deg_to_rad(3 * tail_intensity), 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(tail_extend + 2 * tail_intensity), deg_to_rad(-3 * tail_intensity), 0)),
		])

	_add_rotation_track(anim, "Tail6",
		[t0, t1 + tail_delay * 5, t2],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(tail_extend + 2 * tail_intensity), deg_to_rad(-3 * tail_intensity), 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(tail_extend - 2 * tail_intensity), deg_to_rad(3 * tail_intensity), 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(tail_extend + 2 * tail_intensity), deg_to_rad(-3 * tail_intensity), 0)),
		])

	_add_rotation_track(anim, "Tail7",
		[t0, t1 + tail_delay * 6, t2],
		[
			Quaternion.from_euler(Vector3(deg_to_rad(tail_extend + 1 * tail_intensity), deg_to_rad(-2 * tail_intensity), 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(tail_extend - 1 * tail_intensity), deg_to_rad(2 * tail_intensity), 0)),
			Quaternion.from_euler(Vector3(deg_to_rad(tail_extend + 1 * tail_intensity), deg_to_rad(-2 * tail_intensity), 0)),
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

	# Create animation: 1.2 second per flap cycle (20% slower), full intensity
	var anim := create_wing_flap_animation(1.2, 1.0)

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
