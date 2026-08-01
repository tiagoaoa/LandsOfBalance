class_name DerivedAnims
extends RefCounted
## Fixes up borrowed locomotion clips so they still carry the character's
## own weapon.
##
## The retreat clips (`WalkBack`, `RunBack`) are generic Mixamo walks: the
## arms swing loosely at the sides. That is fine for the legs — which is
## all we borrowed them for — but on the Paladin the sword and shield hang
## off the hand bones, so a borrowed stride made him back away with his
## guard flapping, while walking FORWARD held it ready. Backing away from
## something is exactly when a souls character should have their weapon up.
##
## So: keep the borrowed footwork, graft the character's OWN idle upper
## body over it. The idle is sampled across the retreat (not frozen) so it
## keeps breathing, and it is phase-matched to the retreat's length so the
## result still loops seamlessly.
##
## Runs before BlockStanceAnim, which then builds the guard-up retreat
## twins on top of the corrected clips.

## Clips that get the treatment, in the order they are built.
const RETREATS: Array[String] = ["WalkBack", "RunBack"]

## Resampling rate — matches BlockStanceAnim and the source key density.
const SAMPLE_FPS: float = 30.0


## Grafts the idle upper body onto `<prefix>`'s retreat clips in place.
static func compose(anim_player: AnimationPlayer, prefix: String) -> void:
	if anim_player == null:
		return
	var lib_name := StringName(prefix)
	if not anim_player.has_animation_library(lib_name):
		return
	var lib: AnimationLibrary = anim_player.get_animation_library(lib_name)
	if lib == null or not lib.has_animation(&"Idle"):
		return
	var idle: Animation = lib.get_animation(&"Idle")
	if idle == null or idle.length <= 0.0:
		return

	var built: Array[String] = []
	for clip in RETREATS:
		var clip_name := StringName(clip)
		if not lib.has_animation(clip_name):
			continue
		var grafted: Animation = _graft_upper_body(lib.get_animation(clip_name), idle)
		if grafted != null:
			lib.remove_animation(clip_name)
			lib.add_animation(clip_name, grafted)
			built.append(clip)
	if not built.is_empty():
		print("  Grafted idle upper body onto %s retreats: %s" % [prefix, ", ".join(built)])


## Footwork from `base`, arms/shoulders/hands/weapon joints from `pose`,
## spine blended between the two (same split BlockStanceAnim uses).
static func _graft_upper_body(base: Animation, pose: Animation) -> Animation:
	if base == null or base.length <= 0.0:
		return null
	var out: Animation = base.duplicate(true)
	var length: float = out.length
	var steps: int = maxi(int(ceil(length * SAMPLE_FPS)), 4)
	# Whole idle cycles per retreat cycle, so both ends meet: at least one,
	# and the closest whole number to playing the idle at its own speed.
	var cycles: float = maxf(round(length / pose.length), 1.0)

	for track in range(out.get_track_count()):
		var track_type: int = out.track_get_type(track)
		if track_type != Animation.TYPE_POSITION_3D \
				and track_type != Animation.TYPE_ROTATION_3D \
				and track_type != Animation.TYPE_SCALE_3D:
			continue
		var weight: float = BlockStanceAnim.guard_weight(
				BlockStanceAnim.bone_of(out.track_get_path(track)))
		if weight <= 0.0:
			continue
		var src: int = pose.find_track(out.track_get_path(track), track_type)
		if src < 0:
			continue

		# Sample before clearing — the stride values feed the spine blend.
		var samples: Array = []
		for s in range(steps + 1):
			var t: float = length * float(s) / float(steps)
			var pt: float = fmod(t * cycles, pose.length)
			samples.append(BlockStanceAnim.mix_pose(
					track_type, out, track, t, pose, src, pt, weight))

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
