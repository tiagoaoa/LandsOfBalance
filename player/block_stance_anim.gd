class_name BlockStanceAnim
extends RefCounted
## Builds "guard up while still moving" locomotion clips.
##
## The character packs ship a single full-body `Block` clip (a planted
## guard idle), so holding the defense button used to overwrite the whole
## body — legs included — and the character slid around frozen mid-stride.
## There is no authored block-walk animation for any of the three rigs, so
## we compose one at load time: the stride (hips, legs, feet) is kept from
## the locomotion clip and the guard (shoulders/arms/hands/weapon joints)
## is baked in from the Block clip, with the spine chain blended between
## the two so the torso still breathes with the steps.
##
## Result: `<prefix>/BlockWalk`, `/BlockRun`, `/BlockSprint`,
## `/BlockStrafeLeft`, `/BlockStrafeRight` — ordinary Animation resources
## the AnimationPlayer plays like any other clip (no AnimationTree, no
## per-frame bone poking).

## Locomotion clips that get a guard-up twin (when the library has them).
## Retreats and run-strafes are in here too: backing away or circling with
## the guard up is the whole point of a shield.
const LOCOMOTION: Array[String] = ["Walk", "Run", "Sprint", "StrafeLeft", "StrafeRight",
		"WalkBack", "RunBack", "RunStrafeLeft", "RunStrafeRight"]

## Only ONE of the three rigs ships a real guard IDLE: armed/Block holds
## the shield (about 5 degrees of drift over the whole clip). archer/Block
## and unarmed/Block are block REACTIONS — raise, block, lower, back to
## neutral, 210-275 degrees of arm travel — so looping them pumps the
## guard up and down forever. Everything below therefore works off the
## clip's GUARD APEX (the frame furthest from its neutral start pose)
## instead of the clip's timeline: `BlockHold` holds that apex with a
## slow sway for standing, and the locomotion twins freeze the guard
## there while the legs stride.

## Bones whose deviation from neutral identifies the apex.
const APEX_BONES: Array[String] = ["LeftArm", "LeftForeArm", "RightArm", "RightForeArm"]

## Sway window: grown outward from the apex while the pose stays within
## APEX_WINDOW_TOL of it, capped here. Motion is slowest at an extremum,
## so this stays subtle and loops seamlessly.
const APEX_WINDOW_MAX: float = 0.25
const APEX_WINDOW_TOL: float = 6.0   # degrees
const HOLD_LENGTH: float = 1.6       # one slow breath

## Resampling rate of the composed tracks. The source clips key at roughly
## this density, so nothing visible is lost.
const SAMPLE_FPS: float = 30.0

## How much the guard pose wins over the stride on the spine chain. Full
## guard on the torso reads stiff; none of it and the shield swings away
## with the arm swing baked into the walk.
const SPINE_WEIGHT: float = 0.7

## Bones that get the guard pose verbatim (matched as substrings of the
## bone name — "Arm" also catches "ForeArm", none of the leg bones contain
## any of these).
const GUARD_TOKENS: Array[String] = ["Shoulder", "Arm", "Hand", "Shield", "Sword",
		"arch", "arrow"]

## Bones blended between guard and stride.
const SPINE_BONES: Array[String] = ["Spine", "Spine1", "Spine2", "Neck", "Head"]


## Adds the composed guard-up clips to `anim_player`'s `<prefix>` library.
## Safe to call more than once and on libraries missing Block or Walk.
static func compose(anim_player: AnimationPlayer, prefix: String) -> void:
	if anim_player == null:
		return
	var lib_name := StringName(prefix)
	if not anim_player.has_animation_library(lib_name):
		return
	var lib: AnimationLibrary = anim_player.get_animation_library(lib_name)
	if lib == null or not lib.has_animation(&"Block"):
		return
	var block: Animation = lib.get_animation(&"Block")
	if block == null or block.length <= 0.0:
		return

	var guard_t: float = _guard_apex_time(block)
	var built: Array[String] = []

	# Standing guard: hold the apex instead of looping the reaction.
	if not lib.has_animation(&"BlockHold"):
		var hold: Animation = _compose_hold(block, guard_t)
		if hold != null:
			lib.add_animation(&"BlockHold", hold)
			built.append("BlockHold")

	for loco_name in LOCOMOTION:
		var src_name := StringName(loco_name)
		var out_name := StringName("Block" + loco_name)
		if not lib.has_animation(src_name) or lib.has_animation(out_name):
			continue
		var composed: Animation = _compose_one(lib.get_animation(src_name), block, guard_t)
		if composed != null:
			lib.add_animation(out_name, composed)
			built.append(String(out_name))
	if not built.is_empty():
		print("  Composed guard-up locomotion for %s (apex %.2fs): %s" % [
				prefix, guard_t, ", ".join(built)])


## The frame where the guard is actually UP: furthest from the clip's own
## neutral (its first frame — these clips start and end at rest, seam ~0).
static func _guard_apex_time(block: Animation) -> float:
	var tracks: Array[int] = []
	for track in range(block.get_track_count()):
		if block.track_get_type(track) != Animation.TYPE_ROTATION_3D:
			continue
		var short: String = bone_of(block.track_get_path(track)) \
				.replace("mixamorig:", "").replace("mixamorig_", "")
		if short in APEX_BONES:
			tracks.append(track)
	if tracks.is_empty():
		return block.length * 0.5

	var steps: int = maxi(int(ceil(block.length * SAMPLE_FPS)), 8)
	var neutral: Array[Quaternion] = []
	for track in tracks:
		neutral.append(block.rotation_track_interpolate(track, 0.0))

	var best_t: float = block.length * 0.5
	var best_dev: float = -1.0
	for s in range(steps + 1):
		var t: float = block.length * float(s) / float(steps)
		var dev: float = 0.0
		for i in range(tracks.size()):
			dev += neutral[i].angle_to(block.rotation_track_interpolate(tracks[i], t))
		if dev > best_dev:
			best_dev = dev
			best_t = t
	return best_t


## Whole-body guard hold: the apex pose, swayed gently back and forth
## across the window where the clip is still essentially at that pose.
## The sway follows a sine so the loop closes with matching velocity.
static func _compose_hold(block: Animation, guard_t: float) -> Animation:
	var window: float = _apex_window(block, guard_t)
	var out := Animation.new()
	out.length = HOLD_LENGTH
	out.loop_mode = Animation.LOOP_LINEAR
	var steps: int = maxi(int(ceil(HOLD_LENGTH * SAMPLE_FPS)), 8)

	for src in range(block.get_track_count()):
		var track_type: int = block.track_get_type(src)
		if track_type != Animation.TYPE_POSITION_3D \
				and track_type != Animation.TYPE_ROTATION_3D \
				and track_type != Animation.TYPE_SCALE_3D:
			continue
		var track: int = out.add_track(track_type)
		out.track_set_path(track, block.track_get_path(src))
		for s in range(steps + 1):
			var t: float = HOLD_LENGTH * float(s) / float(steps)
			var bt: float = clampf(guard_t + window * sin(TAU * t / HOLD_LENGTH),
					0.0, block.length)
			match track_type:
				Animation.TYPE_POSITION_3D:
					out.position_track_insert_key(track, t,
							block.position_track_interpolate(src, bt))
				Animation.TYPE_ROTATION_3D:
					out.rotation_track_insert_key(track, t,
							block.rotation_track_interpolate(src, bt))
				Animation.TYPE_SCALE_3D:
					out.scale_track_insert_key(track, t,
							block.scale_track_interpolate(src, bt))
	return out


## How far either side of the apex the pose is still "the same guard".
static func _apex_window(block: Animation, guard_t: float) -> float:
	var tracks: Array[int] = []
	for track in range(block.get_track_count()):
		if block.track_get_type(track) != Animation.TYPE_ROTATION_3D:
			continue
		var short: String = bone_of(block.track_get_path(track)) \
				.replace("mixamorig:", "").replace("mixamorig_", "")
		if short in APEX_BONES:
			tracks.append(track)
	if tracks.is_empty():
		return 0.0
	var apex: Array[Quaternion] = []
	for track in tracks:
		apex.append(block.rotation_track_interpolate(track, guard_t))

	var window: float = 0.0
	var step: float = 1.0 / SAMPLE_FPS
	while window + step <= APEX_WINDOW_MAX:
		var probe: float = window + step
		var worst: float = 0.0
		for side in [-1.0, 1.0]:
			var t: float = clampf(guard_t + side * probe, 0.0, block.length)
			for i in range(tracks.size()):
				worst = maxf(worst, rad_to_deg(apex[i].angle_to(
						block.rotation_track_interpolate(tracks[i], t))))
		if worst > APEX_WINDOW_TOL:
			break
		window = probe
	return window


## Stride clip + guard pose -> one clip. The locomotion clip is the base,
## so its length, loop mode and untouched tracks (hips, legs, feet) carry
## over exactly as authored.
static func _compose_one(loco: Animation, block: Animation, guard_t: float) -> Animation:
	if loco == null or loco.length <= 0.0:
		return null
	var out: Animation = loco.duplicate(true)
	var length: float = out.length
	var steps: int = maxi(int(ceil(length * SAMPLE_FPS)), 4)

	for track in range(out.get_track_count()):
		var track_type: int = out.track_get_type(track)
		if track_type != Animation.TYPE_POSITION_3D \
				and track_type != Animation.TYPE_ROTATION_3D \
				and track_type != Animation.TYPE_SCALE_3D:
			continue
		var weight: float = guard_weight(bone_of(out.track_get_path(track)))
		if weight <= 0.0:
			continue
		var src: int = block.find_track(out.track_get_path(track), track_type)
		if src < 0:
			continue

		# Sample everything BEFORE clearing — the stride values are needed
		# for the spine blend and vanish with the keys.
		var samples: Array = []
		for s in range(steps + 1):
			var t: float = length * float(s) / float(steps)
			# The guard is FROZEN at its apex: replaying the block clip
			# across the stride made the arms pump every step (and every
			# archer/unarmed clip is a raise-lower reaction, not a hold).
			samples.append(mix_pose(track_type, out, track, t, block, src, guard_t, weight))

		for k in range(out.track_get_key_count(track) - 1, -1, -1):
			out.track_remove_key(track, k)
		for s in range(steps + 1):
			var t: float = length * float(s) / float(steps)
			match track_type:
				Animation.TYPE_POSITION_3D:
					out.position_track_insert_key(track, t, samples[s])
				Animation.TYPE_ROTATION_3D:
					out.rotation_track_insert_key(track, t, samples[s])
				Animation.TYPE_SCALE_3D:
					out.scale_track_insert_key(track, t, samples[s])
	return out


static func mix_pose(track_type: int, loco: Animation, loco_track: int, t: float,
		block: Animation, block_track: int, bt: float, weight: float) -> Variant:
	match track_type:
		Animation.TYPE_ROTATION_3D:
			var loco_q: Quaternion = loco.rotation_track_interpolate(loco_track, t)
			var block_q: Quaternion = block.rotation_track_interpolate(block_track, bt)
			return loco_q.slerp(block_q, weight) if weight < 1.0 else block_q
		Animation.TYPE_POSITION_3D:
			var loco_p: Vector3 = loco.position_track_interpolate(loco_track, t)
			var block_p: Vector3 = block.position_track_interpolate(block_track, bt)
			return loco_p.lerp(block_p, weight)
		_:
			var loco_s: Vector3 = loco.scale_track_interpolate(loco_track, t)
			var block_s: Vector3 = block.scale_track_interpolate(block_track, bt)
			return loco_s.lerp(block_s, weight)


## 1.0 = pure guard, 0.0 = pure stride.
static func guard_weight(bone: String) -> float:
	if bone == "":
		return 0.0
	var short: String = bone.replace("mixamorig:", "").replace("mixamorig_", "")
	if short in SPINE_BONES:
		return SPINE_WEIGHT
	for token in GUARD_TOKENS:
		if short.contains(token):
			return 1.0
	return 0.0


static func bone_of(path: NodePath) -> String:
	if path.get_subname_count() == 0:
		return ""
	return String(path.get_subname(0))
