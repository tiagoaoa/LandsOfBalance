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
const LOCOMOTION: Array[String] = ["Walk", "Run", "Sprint", "StrafeLeft", "StrafeRight"]

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

	var built: Array[String] = []
	for loco_name in LOCOMOTION:
		var src_name := StringName(loco_name)
		var out_name := StringName("Block" + loco_name)
		if not lib.has_animation(src_name) or lib.has_animation(out_name):
			continue
		var composed: Animation = _compose_one(lib.get_animation(src_name), block)
		if composed != null:
			lib.add_animation(out_name, composed)
			built.append(String(out_name))
	if not built.is_empty():
		print("  Composed guard-up locomotion for %s: %s" % [prefix, ", ".join(built)])


## Stride clip + guard pose -> one clip. The locomotion clip is the base,
## so its length, loop mode and untouched tracks (hips, legs, feet) carry
## over exactly as authored.
static func _compose_one(loco: Animation, block: Animation) -> Animation:
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
		var weight: float = _guard_weight(_bone_of(out.track_get_path(track)))
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
			# The guard idle is compressed onto the stride's period so the
			# composed clip loops seamlessly (t=0 and t=length agree).
			var bt: float = fposmod(t / length * block.length, block.length)
			samples.append(_mix(track_type, out, track, t, block, src, bt, weight))

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


static func _mix(track_type: int, loco: Animation, loco_track: int, t: float,
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
static func _guard_weight(bone: String) -> float:
	if bone == "":
		return 0.0
	var short: String = bone.replace("mixamorig:", "").replace("mixamorig_", "")
	if short in SPINE_BONES:
		return SPINE_WEIGHT
	for token in GUARD_TOKENS:
		if short.contains(token):
			return 1.0
	return 0.0


static func _bone_of(path: NodePath) -> String:
	if path.get_subname_count() == 0:
		return ""
	return String(path.get_subname(0))
