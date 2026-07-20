class_name SkeletonAnim
extends RefCounted

## Procedural animation set for the draugr-style axe skeleton
## (assets/skeleton/skeleton_axe.fbx — Skyrim-style NPC rig, 79 bones,
## battleaxe on the WEAPON bone in the right hand). Same technique as the
## dragon's flight rig: every key composes a SKELETON-SPACE delta on top
## of the bone's rest rotation (rest_parent_global⁻¹ · R · rest_global),
## so zero delta = rest pose and clip authoring is sign-stable regardless
## of the rig's local axes.
##
## Rig facts (measured from the imported FBX):
##   character faces -Z, up +Y, right side +X; ~3.4 units tall (scaled in
##   skeleton.gd). Sign conventions for deltas:
##   - DOWN-pointing bones (thighs, calves, upper arms, forearms):
##     +X rotation swings the limb FORWARD (toward -Z), -X backward.
##   - UP-pointing bones (spine chain, neck, head): -X leans FORWARD.
##   - +Z tips a hanging limb out to the character's right (+X side).
##   - Y rotations twist around the vertical (torso wind-up).
##
## Clips: Idle (heavy axe-bearer sway + jaw chatter), Walk/Run (arms AND
## legs swing in opposition — the axe arm pumps, the free arm counters),
## AttackOverhead (two-handed 170° axe chop), AttackSlash (torso-loaded
## horizontal sweep). Blade contact for both attacks is at t=0.5 of the
## 1.0 s clip — skeleton.gd deals damage exactly then.

const SKELETON_PATH := "Skeleton3D"
const SAMPLES := 16

# Rig bone names (Skyrim NPC naming).
const B_SPINE0 := "NPC_Spine__Spn0_"
const B_SPINE1 := "NPC_Spine1__Spn1_"
const B_SPINE2 := "NPC_Spine2__Spn2_"
const B_NECK := "NPC_Neck__Neck_"
const B_HEAD := "NPC_Head__Head_"
const B_JAW := "NPC_Head__Jaw_"
const B_R_THIGH := "NPC_R_Thigh__RThg_"
const B_L_THIGH := "NPC_L_Thigh__LThg_"
const B_R_CALF := "NPC_R_Calf__RClf_"
const B_L_CALF := "NPC_L_Calf__LClf_"
const B_R_ARM := "NPC_R_UpperArm__RUar_"
const B_L_ARM := "NPC_L_UpperArm__LUar_"
const B_R_FORE := "NPC_R_Forearm__RLar_"
const B_L_FORE := "NPC_L_Forearm__LLar_"
const B_R_HAND := "NPC_R_Hand__RHnd_"


static func add_all(anim_player: AnimationPlayer, skel: Skeleton3D) -> void:
	var lib := AnimationLibrary.new()
	lib.add_animation(&"Idle", create_idle(skel))
	lib.add_animation(&"Walk", create_walk(skel))
	lib.add_animation(&"Run", create_run(skel))
	lib.add_animation(&"AttackOverhead", create_attack_overhead(skel))
	lib.add_animation(&"AttackSlash", create_attack_slash(skel))
	anim_player.add_animation_library(&"", lib)


static func create_idle(skel: Skeleton3D) -> Animation:
	var anim := _new_anim(2.8, true)
	# The dead thing breathes anyway: slow sway, axe drifting, jaw working.
	_track(anim, skel, B_SPINE0, func(t: float) -> Vector3:
		return Vector3(-3.0 + 1.5 * sin(TAU * t), 2.5 * sin(TAU * t + 1.2), 0.0))
	_track(anim, skel, B_SPINE2, func(t: float) -> Vector3:
		return Vector3(-2.0 + 1.5 * sin(TAU * t + 0.5), 0.0, 2.0 * sin(TAU * t)))
	_track(anim, skel, B_HEAD, func(t: float) -> Vector3:
		return Vector3(2.0 * sin(TAU * t + 0.8), 6.0 * sin(TAU * t), 0.0))
	_track(anim, skel, B_JAW, func(t: float) -> Vector3:
		return Vector3(-8.0 * maxf(0.0, sin(TAU * t * 3.0)), 0.0, 0.0))
	_track(anim, skel, B_R_ARM, func(t: float) -> Vector3:
		return Vector3(2.5 * sin(TAU * t), 0.0, 2.0 * sin(TAU * t + 2.0)))
	_track(anim, skel, B_L_ARM, func(t: float) -> Vector3:
		return Vector3(2.0 * sin(TAU * t + 1.0), 0.0, -1.5 * sin(TAU * t)))
	return anim


static func create_walk(skel: Skeleton3D) -> Animation:
	return _locomotion(skel, 1.15, 24.0, 16.0, 5.0)


static func create_run(skel: Skeleton3D) -> Animation:
	return _locomotion(skel, 0.64, 38.0, 26.0, 10.0)


## Legs AND arms swing in opposition, knees fold on the swing-through,
## the torso counter-twists — a full-body gait, not a glide.
static func _locomotion(skel: Skeleton3D, duration: float, leg_amp: float,
		arm_amp: float, hunch: float) -> Animation:
	var anim := _new_anim(duration, true)
	# Legs: +X swings forward. Right leg leads at t=0.
	_track(anim, skel, B_R_THIGH, func(t: float) -> Vector3:
		return Vector3(leg_amp * sin(TAU * t), 0.0, 0.0))
	_track(anim, skel, B_L_THIGH, func(t: float) -> Vector3:
		return Vector3(-leg_amp * sin(TAU * t), 0.0, 0.0))
	# Knees fold BACKWARD (heel toward the pelvis) while that leg swings
	# through — peak flexion mid swing-through (right leg swings through
	# around phase 0.9, left half a cycle later), never on the planted leg.
	_track(anim, skel, B_R_CALF, func(t: float) -> Vector3:
		return Vector3(-leg_amp * 0.9 * maxf(0.0, sin(TAU * t + 2.2)), 0.0, 0.0))
	_track(anim, skel, B_L_CALF, func(t: float) -> Vector3:
		return Vector3(-leg_amp * 0.9 * maxf(0.0, sin(TAU * t + 2.2 + PI)), 0.0, 0.0))
	# Arms counter-swing the legs: right arm forward when LEFT leg leads.
	# The axe arm keeps a bent elbow (weapon carried), the free arm swings.
	_track(anim, skel, B_R_ARM, func(t: float) -> Vector3:
		return Vector3(-arm_amp * sin(TAU * t), 0.0, 3.0))
	_track(anim, skel, B_L_ARM, func(t: float) -> Vector3:
		return Vector3(arm_amp * sin(TAU * t), 0.0, -3.0))
	_track(anim, skel, B_R_FORE, func(t: float) -> Vector3:
		return Vector3(14.0 + arm_amp * 0.4 * maxf(0.0, -sin(TAU * t)), 0.0, 0.0))
	_track(anim, skel, B_L_FORE, func(t: float) -> Vector3:
		return Vector3(10.0 + arm_amp * 0.4 * maxf(0.0, sin(TAU * t)), 0.0, 0.0))
	# Hungry hunch; torso counter-twists the hips; head locked on the prey.
	_track(anim, skel, B_SPINE0, func(t: float) -> Vector3:
		return Vector3(-hunch, 6.0 * sin(TAU * t), 0.0))
	_track(anim, skel, B_SPINE2, func(t: float) -> Vector3:
		return Vector3(-hunch * 0.6 - 2.0 * sin(TAU * t * 2.0), -4.0 * sin(TAU * t), 0.0))
	_track(anim, skel, B_HEAD, func(t: float) -> Vector3:
		return Vector3(hunch * 0.9, -2.0 * sin(TAU * t), 0.0))
	_track(anim, skel, B_JAW, func(t: float) -> Vector3:
		return Vector3(-6.0 * maxf(0.0, sin(TAU * t * 2.0)), 0.0, 0.0))
	return anim


static func create_attack_overhead(skel: Skeleton3D) -> Animation:
	## TWO-HANDED overhead chop: both arms haul the axe high behind the
	## skull (windup 0-0.35), then slam it down-forward through the target
	## line (contact ~0.5) with the whole spine committing to the blow.
	var anim := _new_anim(1.0, false)
	# Arms: -X hauls them up-back, then the strike whips them far forward.
	_track(anim, skel, B_R_ARM, func(t: float) -> Vector3:
		var w := _phase(t)
		return Vector3(-150.0 * w.x + 55.0 * w.y, 0.0, 8.0 * w.x))
	_track(anim, skel, B_L_ARM, func(t: float) -> Vector3:
		var w := _phase(t)
		return Vector3(-145.0 * w.x + 50.0 * w.y, 0.0, -8.0 * w.x))
	# Elbows cock in the windup, snap straight through the fall.
	_track(anim, skel, B_R_FORE, func(t: float) -> Vector3:
		var w := _phase(t)
		return Vector3(45.0 * w.x - 8.0 * w.y, 0.0, 0.0))
	_track(anim, skel, B_L_FORE, func(t: float) -> Vector3:
		var w := _phase(t)
		return Vector3(42.0 * w.x - 6.0 * w.y, 0.0, 0.0))
	# Spine: rear back (+X), then slam forward (-X) through the chop.
	_track(anim, skel, B_SPINE0, func(t: float) -> Vector3:
		var w := _phase(t)
		return Vector3(14.0 * w.x - 22.0 * w.y, 0.0, 0.0))
	_track(anim, skel, B_SPINE2, func(t: float) -> Vector3:
		var w := _phase(t)
		return Vector3(12.0 * w.x - 20.0 * w.y, 0.0, 0.0))
	_track(anim, skel, B_NECK, func(t: float) -> Vector3:
		var w := _phase(t)
		return Vector3(-10.0 * w.x + 6.0 * w.y, 0.0, 0.0))
	_track(anim, skel, B_JAW, func(t: float) -> Vector3:
		return Vector3(-18.0 * clampf(sin(TAU * t), 0.0, 1.0), 0.0, 0.0))
	return anim


static func create_attack_slash(skel: Skeleton3D) -> Animation:
	## Torso-loaded horizontal sweep: wind the shoulders hard to the right
	## with the axe drawn out wide, then rip the whole upper body around,
	## the axe arm sweeping flat across the frontal arc.
	var anim := _new_anim(1.0, false)
	# Torso does the work: big Y wind-up then the counter-whip.
	_track(anim, skel, B_SPINE0, func(t: float) -> Vector3:
		var w := _phase(t)
		return Vector3(-4.0 * w.y, -30.0 * w.x + 34.0 * w.y, 0.0))
	_track(anim, skel, B_SPINE2, func(t: float) -> Vector3:
		var w := _phase(t)
		return Vector3(-6.0 * w.y, -26.0 * w.x + 30.0 * w.y, 0.0))
	# Axe arm: raised out to the right side in the windup, then swept
	# forward-across as the torso whips.
	_track(anim, skel, B_R_ARM, func(t: float) -> Vector3:
		var w := _phase(t)
		return Vector3(-25.0 * w.x + 70.0 * w.y, 0.0, 55.0 * w.x - 20.0 * w.y))
	_track(anim, skel, B_R_FORE, func(t: float) -> Vector3:
		var w := _phase(t)
		return Vector3(30.0 * w.x - 5.0 * w.y, 0.0, 0.0))
	# Free arm counters for balance.
	_track(anim, skel, B_L_ARM, func(t: float) -> Vector3:
		var w := _phase(t)
		return Vector3(15.0 * w.x - 20.0 * w.y, 0.0, -12.0 * w.x))
	_track(anim, skel, B_NECK, func(t: float) -> Vector3:
		var w := _phase(t)
		return Vector3(0.0, 22.0 * w.x - 18.0 * w.y, 0.0))
	_track(anim, skel, B_JAW, func(t: float) -> Vector3:
		return Vector3(-14.0 * clampf(sin(TAU * t + 0.5), 0.0, 1.0), 0.0, 0.0))
	return anim


## Attack phase envelope: x = windup weight (rises 0-0.35, dies by 0.65),
## y = strike weight (whips in at 0.35-0.5, decays through recovery).
static func _phase(t: float) -> Vector2:
	var windup := clampf(t / 0.35, 0.0, 1.0) * clampf((0.65 - t) / 0.15, 0.0, 1.0)
	var strike := clampf((t - 0.35) / 0.15, 0.0, 1.0) * clampf((1.0 - t) / 0.35, 0.0, 1.0)
	return Vector2(clampf(windup, 0.0, 1.0), clampf(strike, 0.0, 1.0))


static func _new_anim(duration: float, looped: bool) -> Animation:
	var anim := Animation.new()
	anim.length = duration
	anim.loop_mode = Animation.LOOP_LINEAR if looped else Animation.LOOP_NONE
	return anim


static func _track(anim: Animation, skel: Skeleton3D, bone_name: String,
		sampler: Callable) -> void:
	var bi := skel.find_bone(bone_name)
	if bi < 0:
		push_warning("SkeletonAnim: bone not found: " + bone_name)
		return
	# Compose on the imported POSE baseline, not the rest: this FBX imports
	# with 40 of its 79 bones POSED away from their rests (the natural
	# axe-bearing stance — knees flexed, hands on the haft — lives in the
	# poses; the rests are a T-pose). Composing on rests snapped animated
	# bones toward straight-leg T-pose geometry while unanimated bones kept
	# the stance — which is exactly what made the shins hinge FORWARD.
	# Clips are generated at spawn, before anything plays, so the current
	# pose IS the imported stance.
	var parent := skel.get_bone_parent(bi)
	var pg_inv: Basis = Basis.IDENTITY
	if parent >= 0:
		pg_inv = skel.get_bone_global_pose(parent).basis.inverse()
	var g: Basis = skel.get_bone_global_pose(bi).basis
	var idx := anim.add_track(Animation.TYPE_ROTATION_3D)
	anim.track_set_path(idx, SKELETON_PATH + ":" + bone_name)
	anim.track_set_interpolation_type(idx, Animation.INTERPOLATION_CUBIC)
	for i in range(SAMPLES + 1):
		var t := float(i) / SAMPLES
		var e: Vector3 = sampler.call(t)
		var r := Basis.from_euler(Vector3(deg_to_rad(e.x), deg_to_rad(e.y), deg_to_rad(e.z)))
		anim.rotation_track_insert_key(idx, anim.length * t,
				(pg_inv * (r * g)).get_rotation_quaternion())
