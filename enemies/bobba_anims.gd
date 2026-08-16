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
	for spec in specs():
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


## Where the animation lab saves. A clip saved there OVERRIDES the keys
## written below, so posing in the lab reaches the game without anyone
## pasting GDScript around.
const POSE_DIR := "res://tests/anim_lab/poses"


## The clip specs, exposed so the animation lab can edit them live.
##
## Specs below are the DEFAULT — they always work, with no files present. A
## saved .json replaces that clip's keys, and says so in the log, because a
## silent override would make the source read as the truth when it is not.
static func specs() -> Array:
	var all := _specs()
	for sp in all:
		_apply_override(sp)
	return all


static func _apply_override(spec: Dictionary) -> void:
	var path := "%s/%s.json" % [POSE_DIR, String(spec["name"])]
	if not FileAccess.file_exists(path):
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(parsed) != TYPE_DICTIONARY or not (parsed as Dictionary).has("keys"):
		push_warning("Bobba: %s is not a pose file, ignoring" % path)
		return
	var keys := []
	for k in (parsed["keys"] as Array):
		var pose := {}
		for b in (k.get("pose", {}) as Dictionary):
			var a: Array = k["pose"][b]
			pose[b] = Vector3(float(a[0]), float(a[1]), float(a[2]))
		var twist := {}
		for b in (k.get("twist", {}) as Dictionary):
			twist[b] = float(k["twist"][b])
		keys.append({"t": float(k["t"]), "pose": pose, "twist": twist})
	if keys.is_empty():
		return
	spec["keys"] = keys
	if parsed.has("length"):
		spec["length"] = float(parsed["length"])
	print("Bobba: %s OVERRIDDEN from %s (%d keys) — the values in " % [
			spec["name"], path.get_file(), keys.size()]
			+ "bobba_anims.gd are NOT what is running")


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
		# HAND-KEYED IN THE ANIMATION LAB, not written by hand here. Edit it there
		# (tools/run_anim_lab.sh), save, and paste the export back — do not nudge
		# these numbers blind, which is what the lab exists to stop.
		#
		# Key times are SECONDS along the 1.60 s clip; AXE_ATTACK's damage window
		# is a FRACTION of it. Coil is HELD across 0.62-0.74 s (0.39-0.46) and the
		# strike lands at 0.89 s (0.56).
		{
			"name": "AxeAttack", "base": "Idle", "length": 1.60,
			"keys": [
				{"t": 0.00, "pose": {"RightArm": Vector3(-12, 6, -28), "RightForeArm": Vector3(0, 26, 0), "RightHand": Vector3(0, 0, 12), "RightShoulder": Vector3(0, 8, 0), "Spine1": Vector3(0, -6, 0)}},
				{"t": 0.26, "twist": {"LeftArm": -1.2, "LeftForeArm": -20.8, "LeftHand": -13.8, "RightForeArm": -33.5, "RightHand": 13.8, "Spine": 6.1}, "pose": {"Head": Vector3(-2, 0, 0), "LeftArm": Vector3(-5, 3, 42), "LeftForeArm": Vector3(0, -6, 0), "LeftHand": Vector3(0, 0, 0), "LeftShoulder": Vector3(0, 3, 0), "LeftUpLeg": Vector3(-2, 0, 0), "RightArm": Vector3(-11, 1, -54), "RightForeArm": Vector3(12, 20, -1), "RightHand": Vector3(2, -6, 11), "RightShoulder": Vector3(0, 2, 0), "RightUpLeg": Vector3(-2, 0, 0), "Spine": Vector3(6, 0, 0), "Spine1": Vector3(4, -3, 0), "Spine2": Vector3(3, 0, 0)}},
				{"t": 0.62, "twist": {"LeftArm": -0.2, "LeftForeArm": -33.2, "LeftHand": -21.4, "RightForeArm": -31.8, "RightHand": 14.2, "Spine": 1.0}, "pose": {"Head": Vector3(-9, 0, 0), "LeftArm": Vector3(-5, 15, 71), "LeftForeArm": Vector3(0, -3, 0), "LeftHand": Vector3(0, 0, 0), "LeftShoulder": Vector3(0, -2, 0), "LeftUpLeg": Vector3(6, 0, 0), "RightArm": Vector3(-4, -3, -70), "RightForeArm": Vector3(2, 14, 0), "RightHand": Vector3(19, -35, -12), "RightShoulder": Vector3(0, 3, 0), "RightUpLeg": Vector3(6, 0, 0), "Spine": Vector3(-3, 0, 0), "Spine1": Vector3(-2, -1, 0), "Spine2": Vector3(-2, 0, 0)}},
				{"t": 0.74, "twist": {"LeftForeArm": -35.5, "LeftHand": -22.8, "RightForeArm": -31.5, "RightHand": 22.8}, "pose": {"Head": Vector3(-10, 0, 0), "LeftArm": Vector3(-5, 17, 76), "LeftForeArm": Vector3(0, -2, 0), "LeftHand": Vector3(0, 0, 0), "LeftShoulder": Vector3(0, -3, 0), "LeftUpLeg": Vector3(7, 0, 0), "RightArm": Vector3(-3, -4, -73), "RightForeArm": Vector3(0, 13, 0), "RightHand": Vector3(4, -12, -4), "RightShoulder": Vector3(0, 3, 0), "RightUpLeg": Vector3(7, 0, 0), "Spine": Vector3(-5, 0, 0), "Spine1": Vector3(-3, 0, 0), "Spine2": Vector3(-3, 0, 0)}},
				{"t": 0.89, "twist": {"LeftArm": -19.5, "RightArm": 49.0, "RightForeArm": -101.0, "RightHand": 8.5}, "pose": {"Head": Vector3(-8, 0, 0), "LeftArm": Vector3(5, 27, 29), "LeftForeArm": Vector3(0, 15, 0), "LeftShoulder": Vector3(0, -5, 0), "LeftUpLeg": Vector3(11, 0, 0), "RightArm": Vector3(13, 12, -44), "RightForeArm": Vector3(3, 21, -2), "RightHand": Vector3(0, 0, 0), "RightShoulder": Vector3(0, 5, 0), "RightUpLeg": Vector3(11, 0, 0), "Spine": Vector3(-15, 0, 0), "Spine1": Vector3(-11, 0, 0), "Spine2": Vector3(-10, 0, 0)}},
				{"t": 0.99, "twist": {"LeftArm": -18.4, "LeftHand": -9.9, "LeftShoulder": -41.6, "RightArm": 46.3, "RightForeArm": -95.5, "RightHand": 8.0, "RightShoulder": -2.3, "RightUpLeg": -3.2, "Spine": -0.0, "Spine1": 3.2, "Spine2": 0.0}, "pose": {"Head": Vector3(-8, 0, 0), "LeftArm": Vector3(5, 26, 27), "LeftForeArm": Vector3(10, 5, 4), "LeftHand": Vector3(0, 0, 0), "LeftShoulder": Vector3(-1, -52, 24), "LeftUpLeg": Vector3(10, 0, 0), "RightArm": Vector3(12, 12, -43), "RightForeArm": Vector3(3, 21, -2), "RightHand": Vector3(0, 0, 1), "RightShoulder": Vector3(0, 5, 0), "RightUpLeg": Vector3(10, 0, 0), "Spine": Vector3(-14, 0, 0), "Spine1": Vector3(-48, -1, -3), "Spine2": Vector3(-9, 0, 0)}},
				{"t": 1.49, "twist": {"LeftArm": -1.6, "LeftHand": -0.8, "LeftShoulder": -3.5, "RightArm": 3.9, "RightForeArm": -8.0, "RightHand": 0.7, "RightShoulder": -0.2, "RightUpLeg": -0.3, "Spine": -2.3, "Spine1": 0.3, "Spine2": 11.3}, "pose": {"Head": Vector3(-1, 0, 0), "LeftArm": Vector3(0, 2, 2), "LeftForeArm": Vector3(1, 0, 0), "LeftHand": Vector3(0, 0, 0), "LeftShoulder": Vector3(0, -4, 2), "LeftUpLeg": Vector3(1, 0, 0), "RightArm": Vector3(-11, 13, -29), "RightForeArm": Vector3(0, 26, 0), "RightHand": Vector3(0, 0, 11), "RightShoulder": Vector3(0, 8, 0), "RightUpLeg": Vector3(1, 0, 0), "Spine": Vector3(-1, 0, 0), "Spine1": Vector3(26, -4, 7), "Spine2": Vector3(-1, 0, 0)}},
				{"t": 1.60, "pose": {"RightArm": Vector3(-12, 6, -28), "RightForeArm": Vector3(0, 26, 0), "RightHand": Vector3(0, 0, 12), "RightShoulder": Vector3(0, 8, 0), "Spine1": Vector3(0, -6, 0)}},
			],
		},
	]


static func _scaled(pose: Dictionary, k: float) -> Dictionary:
	var out := {}
	for bone in pose:
		out[bone] = (pose[bone] as Vector3) * k
	return out
