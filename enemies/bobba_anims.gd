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
		# He carries the axe one-handed, so the swing has to START by
		# committing to it: the left hand crosses the body and takes the haft
		# below the right, THEN both arms haul it overhead, hold at the apex,
		# and drive it down the centre line. That grab is what makes the
		# attack expensive — it is why this one is slow and readable where a
		# punch is not.
		#
		# The damage window in AXE_ATTACK sits over the downswing only, so the
		# blade has to be travelling through the middle of the arc there.
		{
			"name": "AxeAttack", "base": "Idle", "length": 1.60,
			"keys": [
				{"t": 0.00, "pose": carry},
				# Left hand crosses and grips the haft; knees settle.
				{"t": 0.26, "pose": {
					"Spine": Vector3(6, -8, 0), "Spine1": Vector3(4, -10, 0),
					"Head": Vector3(4, -10, 0),
					"RightShoulder": Vector3(0, 4, 0),
					"RightArm": Vector3(-16, 8, -22), "RightForeArm": Vector3(0, 30, 0),
					"LeftShoulder": Vector3(0, 16, 0),
					"LeftArm": Vector3(-6, 54, 30), "LeftForeArm": Vector3(0, -24, 0),
					"LeftHand": Vector3(0, 0, -10),
					"LeftUpLeg": Vector3(6, 0, 0), "RightUpLeg": Vector3(6, 0, 0),
				}},
				# Both arms haul it up and back over the head.
				{"t": 0.55, "twist": {"RightForeArm": 45.0, "RightHand": 30.0,
						"LeftForeArm": -45.0, "LeftHand": -30.0}, "pose": {
					"Spine": Vector3(12, 0, 0), "Spine1": Vector3(9, 0, 0),
					"Spine2": Vector3(6, 0, 0), "Head": Vector3(-4, 0, 0),
					"RightShoulder": Vector3(0, -6, 0), "LeftShoulder": Vector3(0, 6, 0),
					# Three quarters of the way into the solved coil.
					"RightArm": Vector3(-9, -5, -84),
					"LeftArm": Vector3(-11, 6, 90),
					"RightForeArm": Vector3(0, 12, 0), "LeftForeArm": Vector3(0, -12, 0),
					"LeftUpLeg": Vector3(-4, 0, 0), "RightUpLeg": Vector3(-4, 0, 0),
				}},
				# Apex hold — the readable moment before it comes down.
				# The coil, matching the reference: both fists together high
				# on the haft above the head, arms back over the shoulder, and
				# the head of the axe hanging BEHIND and BELOW them. The wrist
				# is left near its carry angle on purpose — rolling the blade
				# upright is what made him look like he was presenting the axe
				# rather than cocking it.
				# Palms rolled INWARD onto the shaft — counterclockwise on the
				# right, clockwise on the left — as a twist about each bone's
				# own axis, which is what a wrist actually does.
				{"t": 0.66, "twist": {"RightForeArm": 70.0, "RightHand": 45.0,
						"LeftForeArm": -70.0, "LeftHand": -45.0}, "pose": {
					# Matches the reference: stood up out of the mutant idle's
					# hunch (which is why the spine offset is large and
					# negative), fists together high on the haft above the
					# head, arms back over the shoulder, blade trailing behind
					# and below. The wrist stays near its carry angle — rolling
					# the blade upright made him present the axe rather than
					# cock it.
					"Spine": Vector3(16, 0, 0), "Spine1": Vector3(12, 0, 0),
					"Spine2": Vector3(7, 0, 0), "Head": Vector3(-6, 0, 0),
					# SOLVED, not guessed: the rotation that takes each arm from
					# its rest direction (shoulder->hand) to the direction of
					# the fists meeting above the head. Verified to land the
					# right hand within a centimetre of the target. The signs
					# are opposite to what the isolation test suggested, which
					# is why every hand-tuned attempt spread the arms instead
					# of closing them.
					"RightArm": Vector3(-12, -7, -111),
					"LeftArm": Vector3(-15, 8, 120),
					"RightForeArm": Vector3(0, 16, 0), "LeftForeArm": Vector3(0, -16, 0),
				}},
				# The strike, straight down the centre line.
				{"t": 0.82, "pose": {
					"Spine": Vector3(-26, 0, 0), "Spine1": Vector3(-19, 0, 0),
					"Spine2": Vector3(-13, 0, 0), "Head": Vector3(-14, 0, 0),
					"RightShoulder": Vector3(0, 6, 0), "LeftShoulder": Vector3(0, -6, 0),
					"RightArm": Vector3(6, 0, -34), "LeftArm": Vector3(6, 26, 30),
					"RightForeArm": Vector3(0, 10, 0), "LeftForeArm": Vector3(0, 12, 0),
					"LeftUpLeg": Vector3(14, 0, 0), "RightUpLeg": Vector3(14, 0, 0),
				}},
				# Blade low, weight forward — the recovery he is punishable in.
				{"t": 1.05, "pose": {
					"Spine": Vector3(24, 0, 0), "Spine1": Vector3(18, 0, 0),
					"Head": Vector3(14, 0, 0),
					"RightArm": Vector3(2, 2, -30), "LeftArm": Vector3(2, 30, 24),
					"RightForeArm": Vector3(0, 20, 0), "LeftForeArm": Vector3(0, 24, 0),
				}},
				# Left hand releases, back to the one-handed carry.
				{"t": 1.60, "pose": carry},
			],
		},
	]


static func _scaled(pose: Dictionary, k: float) -> Dictionary:
	var out := {}
	for bone in pose:
		out[bone] = (pose[bone] as Vector3) * k
	return out
