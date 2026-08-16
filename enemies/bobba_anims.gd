class_name BobbaAnims
extends RefCounted
## Clips the mutant pack never shipped: a hit reaction, and carrying/swinging
## the axe.
##
## Bobba's FBX set is Attack, Dying, Idle, JumpAttack, Punch, Roar, Run and
## Walk. There is nothing for being struck, so a blow that connected looked
## exactly like one that missed, and nothing for the axe he now carries — he
## held it like a stick while throwing punches.
##
## Everything here is composed onto an existing clip via PoseAnim, so each
## output is a full body and the AnimationPlayer can play it like any other.
## Poses are character-space degrees. Verified against the rig with an
## isolation clip: +x arches BACK / opens the chest, -x folds FORWARD.

const LIB := "bobba"


static func compose(anim_player: AnimationPlayer, skeleton: Skeleton3D) -> void:
	if anim_player == null or skeleton == null:
		return
	if not anim_player.has_animation_library(LIB):
		return
	var lib: AnimationLibrary = anim_player.get_animation_library(LIB)
	if lib == null:
		return
	var idle: Animation = lib.get_animation(&"Idle") if lib.has_animation(&"Idle") else null
	if idle == null:
		return

	var built: Array[String] = []
	for spec in _specs():
		var name: StringName = StringName(spec["name"])
		if lib.has_animation(name):
			continue
		var base_name: StringName = StringName(spec.get("base", "Idle"))
		var base: Animation = lib.get_animation(base_name) if lib.has_animation(base_name) else idle
		# length 0 means "as long as the base" — the carry poses are a constant
		# offset over a walk or run cycle and must keep its exact timing.
		var length: float = float(spec["length"])
		if length <= 0.0:
			length = base.length
		var clip: Animation = PoseAnim.compose(base, skeleton, spec["keys"],
				length, bool(spec.get("loop", false)))
		if clip != null:
			lib.add_animation(name, clip)
			built.append(String(name))
	if not built.is_empty():
		print("Bobba: composed clips: %s" % ", ".join(built))


## The clip specs, exposed so the animation lab can edit them live.
static func specs() -> Array:
	return _specs()


static func _specs() -> Array:
	# Arms thrown open and torso driven back — the "took one square in the
	# chest" read. Snap out fast, recover slower, so it lands as an impact
	# rather than a sway.
	var hit_open := {
		"Spine": Vector3(28, 0, 0), "Spine1": Vector3(21, 0, 0),
		"Spine2": Vector3(16, 0, 0), "Neck": Vector3(12, 0, 0),
		"Head": Vector3(24, 0, 0),
		"LeftShoulder": Vector3(0, -20, 0), "RightShoulder": Vector3(0, 20, 0),
		"LeftArm": Vector3(-16, -42, 28), "RightArm": Vector3(-16, 42, -28),
		"LeftForeArm": Vector3(0, -28, 0), "RightForeArm": Vector3(0, 28, 0),
		"LeftUpLeg": Vector3(12, 0, 0), "RightUpLeg": Vector3(12, 0, 0),
	}
	var hit_settle := {
		"Spine": Vector3(9, 0, 0), "Spine1": Vector3(7, 0, 0),
		"Head": Vector3(8, 0, 0),
		"LeftArm": Vector3(0, -14, 9), "RightArm": Vector3(0, 14, -9),
	}

	# Carry: the axe hangs off the right hand, so the right arm has to hold a
	# haft rather than swing free — shoulder back, elbow bent, wrist steady.
	var carry := {
		"RightShoulder": Vector3(0, 8, 0),
		"RightArm": Vector3(-12, 6, -28),
		"RightForeArm": Vector3(0, 26, 0),
		"RightHand": Vector3(0, 0, 12),
		"Spine1": Vector3(0, -6, 0),
	}

	return [
		{
			"name": "HitReact", "base": "Idle", "length": 0.55,
			"keys": [
				{"t": 0.00, "pose": {}},
				{"t": 0.09, "pose": hit_open},
				{"t": 0.30, "pose": hit_settle},
				{"t": 0.55, "pose": {}},
			],
		},
		# Same shape, shallower: he shrugged most of it off behind the guard.
		{
			"name": "HitReactLight", "base": "Idle", "length": 0.38,
			"keys": [
				{"t": 0.00, "pose": {}},
				{"t": 0.08, "pose": _scaled(hit_open, 0.45)},
				{"t": 0.38, "pose": {}},
			],
		},
		{
			"name": "AxeIdle", "base": "Idle", "length": 0.0, "loop": true,
			"keys": [{"t": 0.0, "pose": carry}],
		},
		{
			"name": "AxeWalk", "base": "Walk", "length": 0.0, "loop": true,
			"keys": [{"t": 0.0, "pose": carry}],
		},
		{
			"name": "AxeRun", "base": "Run", "length": 0.0, "loop": true,
			"keys": [{"t": 0.0, "pose": carry}],
		},
		# Two-handed overhead chop, frontal.
		#
		# HAND-KEYED IN THE ANIMATION LAB, not written by hand here. Twelve keys,
		# with the downswing broken into 0.74 / 0.79 / 0.82 / 0.89 so the blade
		# accelerates through the strike instead of sliding linearly into it.
		# Edit it there (tools/run_anim_lab.sh) and paste the export back, rather
		# than nudging these numbers blind — that is what they are for.
		#
		# Key times are SECONDS along the 1.60 s clip; AXE_ATTACK's damage window
		# is a FRACTION of it. Apex 0.66 s = 0.41, strike 0.82 s = 0.51.
		{
			"name": "AxeAttack", "base": "Idle", "length": 1.60,
			"keys": [
				{"t": 0.00, "pose": {"RightArm": Vector3(-12, 6, -28), "RightForeArm": Vector3(0, 26, 0), "RightHand": Vector3(0, 0, 12), "RightShoulder": Vector3(0, 8, 0), "Spine1": Vector3(0, -6, 0)}},
				{"t": 0.26, "pose": {"Head": Vector3(4, -10, 0), "LeftArm": Vector3(-6, 54, 30), "LeftForeArm": Vector3(0, -24, 0), "LeftHand": Vector3(0, 0, -10), "LeftShoulder": Vector3(0, 16, 0), "LeftUpLeg": Vector3(6, 0, 0), "RightArm": Vector3(-16, 8, -22), "RightForeArm": Vector3(0, 30, 0), "RightShoulder": Vector3(0, 4, 0), "RightUpLeg": Vector3(6, 0, 0), "Spine": Vector3(6, -8, 0), "Spine1": Vector3(4, -10, 0)}},
				{"t": 0.55, "twist": {"LeftForeArm": -45.0, "LeftHand": -30.0, "RightForeArm": 45.0, "RightHand": 30.0}, "pose": {"Head": Vector3(-4, 0, 0), "LeftArm": Vector3(-11, 6, 90), "LeftForeArm": Vector3(0, -12, 0), "LeftShoulder": Vector3(0, 6, 0), "LeftUpLeg": Vector3(-4, 0, 0), "RightArm": Vector3(-9, -5, -84), "RightForeArm": Vector3(0, 12, 0), "RightShoulder": Vector3(0, -6, 0), "RightUpLeg": Vector3(-4, 0, 0), "Spine": Vector3(12, 0, 0), "Spine1": Vector3(9, 0, 0), "Spine2": Vector3(6, 0, 0)}},
				{"t": 0.59, "twist": {"LeftForeArm": -53.7, "LeftHand": -35.2, "RightForeArm": 53.7, "RightHand": 35.2}, "pose": {"Head": Vector3(-5, 0, 0), "LeftArm": Vector3(-12, 7, 100), "LeftForeArm": Vector3(0, -13, 0), "LeftHand": Vector3(0, 0, 0), "LeftShoulder": Vector3(0, 4, 0), "LeftUpLeg": Vector3(6, -5, -6), "RightArm": Vector3(-10, -6, -93), "RightForeArm": Vector3(5, -53, 26), "RightHand": Vector3(29, 151, 66), "RightShoulder": Vector3(0, -4, 0), "RightUpLeg": Vector3(-3, 0, 0), "Spine": Vector3(13, 0, 0), "Spine1": Vector3(10, 0, 0), "Spine2": Vector3(6, 0, 0)}},
				{"t": 0.62, "twist": {"LeftForeArm": -59.1, "LeftHand": -38.4, "RightForeArm": 59.1, "RightHand": -15.1}, "pose": {"Head": Vector3(-5, 0, 0), "LeftArm": Vector3(-13, 7, 107), "LeftForeArm": Vector3(0, -14, 0), "LeftHand": Vector3(0, 0, 0), "LeftShoulder": Vector3(0, 3, 0), "LeftUpLeg": Vector3(4, -3, -4), "RightArm": Vector3(-11, -6, -99), "RightForeArm": Vector3(3, -30, 17), "RightHand": Vector3(19, 101, 44), "RightShoulder": Vector3(0, -3, 0), "RightUpLeg": Vector3(-2, 0, 0), "Spine": Vector3(14, 0, 0), "Spine1": Vector3(11, 0, 0), "Spine2": Vector3(7, 0, 0)}},
				{"t": 0.66, "twist": {"LeftForeArm": -70.0, "LeftHand": -45.0, "RightForeArm": 70.0, "RightHand": 45.0}, "pose": {"Head": Vector3(-6, 0, 0), "LeftArm": Vector3(-15, 8, 120), "LeftForeArm": Vector3(0, -16, 0), "RightArm": Vector3(-12, -7, -111), "RightForeArm": Vector3(0, 16, 0), "Spine": Vector3(16, 0, 0), "Spine1": Vector3(12, 0, 0), "Spine2": Vector3(7, 0, 0)}},
				{"t": 0.74, "twist": {"LeftForeArm": -35.5, "LeftHand": -22.8, "RightForeArm": -31.5, "RightHand": 22.8}, "pose": {"Head": Vector3(-10, 0, 0), "LeftArm": Vector3(-5, 17, 76), "LeftForeArm": Vector3(0, -2, 0), "LeftHand": Vector3(0, 0, 0), "LeftShoulder": Vector3(0, -3, 0), "LeftUpLeg": Vector3(7, 0, 0), "RightArm": Vector3(-3, -4, -73), "RightForeArm": Vector3(0, 13, 0), "RightHand": Vector3(4, -12, -4), "RightShoulder": Vector3(0, 3, 0), "RightUpLeg": Vector3(7, 0, 0), "Spine": Vector3(-5, 0, 0), "Spine1": Vector3(-3, 0, 0), "Spine2": Vector3(-3, 0, 0)}},
				{"t": 0.79, "twist": {"LeftForeArm": -8.9, "LeftHand": -5.7, "RightForeArm": -33.9, "RightHand": 5.7}, "pose": {"Head": Vector3(-13, 0, 0), "LeftArm": Vector3(3, 24, 41), "LeftForeArm": Vector3(0, 8, 0), "LeftHand": Vector3(0, 0, 0), "LeftShoulder": Vector3(0, -5, 0), "LeftUpLeg": Vector3(12, 0, 0), "RightArm": Vector3(4, -1, -44), "RightForeArm": Vector3(-12, 47, 4), "RightHand": Vector3(-1, -3, 3), "RightShoulder": Vector3(0, 5, 0), "RightUpLeg": Vector3(12, 0, 0), "Spine": Vector3(-21, 0, 0), "Spine1": Vector3(-15, 0, 0), "Spine2": Vector3(-10, 0, 0)}},
				{"t": 0.82, "pose": {"Head": Vector3(-14, 0, 0), "LeftArm": Vector3(6, 26, 30), "LeftForeArm": Vector3(0, 12, 0), "LeftShoulder": Vector3(0, -6, 0), "LeftUpLeg": Vector3(14, 0, 0), "RightArm": Vector3(6, 0, -34), "RightForeArm": Vector3(0, 10, 0), "RightShoulder": Vector3(0, 6, 0), "RightUpLeg": Vector3(14, 0, 0), "Spine": Vector3(-26, 0, 0), "Spine1": Vector3(-19, 0, 0), "Spine2": Vector3(-13, 0, 0)}},
				{"t": 0.89, "twist": {"LeftArm": -19.5, "RightArm": 49.0, "RightForeArm": -101.0, "RightHand": 8.5}, "pose": {"Head": Vector3(-8, 0, 0), "LeftArm": Vector3(5, 27, 29), "LeftForeArm": Vector3(0, 15, 0), "LeftShoulder": Vector3(0, -5, 0), "LeftUpLeg": Vector3(11, 0, 0), "RightArm": Vector3(13, 12, -44), "RightForeArm": Vector3(3, 21, -2), "RightHand": Vector3(0, 0, 0), "RightShoulder": Vector3(0, 5, 0), "RightUpLeg": Vector3(11, 0, 0), "Spine": Vector3(-15, 0, 0), "Spine1": Vector3(-11, 0, 0), "Spine2": Vector3(-10, 0, 0)}},
				{"t": 1.05, "pose": {"Head": Vector3(14, 0, 0), "LeftArm": Vector3(2, 30, 24), "LeftForeArm": Vector3(0, 24, 0), "RightArm": Vector3(2, 2, -30), "RightForeArm": Vector3(0, 20, 0), "Spine": Vector3(24, 0, 0), "Spine1": Vector3(18, 0, 0)}},
				{"t": 1.60, "pose": {"RightArm": Vector3(-12, 6, -28), "RightForeArm": Vector3(0, 26, 0), "RightHand": Vector3(0, 0, 12), "RightShoulder": Vector3(0, 8, 0), "Spine1": Vector3(0, -6, 0)}},
			],
		},
	]


static func _scaled(pose: Dictionary, k: float) -> Dictionary:
	var out := {}
	for bone in pose:
		out[bone] = (pose[bone] as Vector3) * k
	return out
