class_name PoseAnim
extends RefCounted
## Authors a full-body clip by layering timed bone rotations over a base clip.
##
## The packs simply do not contain some motions we need — Bobba ships no hit
## reaction at all, and nothing anywhere swings an axe. Rather than hand-author
## FBX for each, describe the motion as a few timed POSES and compose it onto
## an existing clip, the same way BlockStanceAnim builds the guard-up walks.
##
## Composing onto a base matters because there is no AnimationTree here: the
## AnimationPlayer runs one clip at a time, so any bone a clip does not key
## snaps to rest. Every output is therefore a complete body — the base clip
## carries everything the pose does not mention.
##
## Offsets are given in CHARACTER space, not bone space:
##   x = pitch (lean back positive), y = yaw (twist), z = roll (side bend)
## Mixamo bone axes point down each limb and differ joint to joint, so a raw
## bone-local euler is unreadable and unmaintainable. Each offset is converted
## through the bone's rest basis, so "lean the spine back 20 degrees" means
## exactly that on every bone and every rig.

## Resampling rate. The source clips key at about this density.
const SAMPLE_FPS: float = 30.0


## `keys` is an Array of {"t": seconds, "pose": {"<ShortBone>": Vector3(deg)}}.
## Bones absent from a key are held at zero offset there, so a pose only has to
## name what it moves. Returns null if the base is unusable.
static func compose(base: Animation, skeleton: Skeleton3D, keys: Array,
		length: float, loop: bool = false) -> Animation:
	if base == null or base.length <= 0.0 or skeleton == null or keys.is_empty():
		return null

	var targeted := {}
	for k in keys:
		for bone in (k.get("pose", {}) as Dictionary):
			targeted[bone] = true

	var out := Animation.new()
	out.length = length
	out.loop_mode = Animation.LOOP_LINEAR if loop else Animation.LOOP_NONE
	var steps: int = maxi(int(ceil(length * SAMPLE_FPS)), 4)

	for src in range(base.get_track_count()):
		var track_type: int = base.track_get_type(src)
		if track_type != Animation.TYPE_POSITION_3D \
				and track_type != Animation.TYPE_ROTATION_3D \
				and track_type != Animation.TYPE_SCALE_3D:
			continue
		var path: NodePath = base.track_get_path(src)
		var track: int = out.add_track(track_type)
		out.track_set_path(track, path)

		var short: String = _short_bone(path)
		var conv: Basis = Basis.IDENTITY
		var has_offset: bool = track_type == Animation.TYPE_ROTATION_3D \
				and targeted.has(short)
		if has_offset:
			conv = _rest_basis(skeleton, path)

		for s in range(steps + 1):
			var t: float = length * float(s) / float(steps)
			# Base clips are short loops; wrap so a long reaction still has a
			# living body under it instead of freezing on the last frame.
			var bt: float = fposmod(t, base.length)
			match track_type:
				Animation.TYPE_POSITION_3D:
					out.position_track_insert_key(track, t,
							base.position_track_interpolate(src, bt))
				Animation.TYPE_SCALE_3D:
					out.scale_track_insert_key(track, t,
							base.scale_track_interpolate(src, bt))
				Animation.TYPE_ROTATION_3D:
					var q: Quaternion = base.rotation_track_interpolate(src, bt)
					if has_offset:
						q = _local_offset(conv, _pose_at(keys, short, t)) * q
					out.rotation_track_insert_key(track, t, q)
	return out


## Character-space euler (degrees) for `bone` at time `t`, smoothstepped
## between the surrounding keys so the motion eases instead of snapping.
static func _pose_at(keys: Array, bone: String, t: float) -> Vector3:
	var prev_t: float = -INF
	var next_t: float = INF
	var prev := Vector3.ZERO
	var next := Vector3.ZERO
	for k in keys:
		var kt: float = float(k["t"])
		var v: Vector3 = (k.get("pose", {}) as Dictionary).get(bone, Vector3.ZERO)
		if kt <= t and kt > prev_t:
			prev_t = kt
			prev = v
		if kt >= t and kt < next_t:
			next_t = kt
			next = v
	if prev_t == -INF:
		return next
	if next_t == INF or is_equal_approx(prev_t, next_t):
		return prev
	var u: float = (t - prev_t) / (next_t - prev_t)
	return prev.lerp(next, u * u * (3.0 - 2.0 * u))


## Turn a character-space rotation into the equivalent bone-local one.
##
## A rotation track holds a bone's rotation relative to its PARENT, and the
## bone's orientation in skeleton space is G = G_parent * L. To rotate the
## bone by R expressed in character space:
##
##     G_new = R * G_old
##     G_parent * L_new = R * G_parent * L_old
##     L_new = (G_parent⁻¹ * R * G_parent) * L_old
##
## So the conversion basis is the PARENT's rest basis, and the result
## PRE-multiplies the animated rotation. Using the bone's own basis and
## post-multiplying — which is the easy mistake — happens to be nearly right
## on a spine, where each bone points the same way as its parent, but is
## nonsense on an arm, where the shoulder-to-arm rest rotation is about 90
## degrees. That is why "raise the arm" produced a diagonal shrug.
static func _local_offset(parent_rest: Basis, euler_deg: Vector3) -> Quaternion:
	if euler_deg == Vector3.ZERO:
		return Quaternion.IDENTITY
	var r := Basis.from_euler(euler_deg * (PI / 180.0))
	return (parent_rest.inverse() * r * parent_rest) \
			.orthonormalized().get_rotation_quaternion()


## The parent bone's global rest basis, in skeleton space. Root bones have no
## parent, so the skeleton's own frame stands in.
static func _rest_basis(skeleton: Skeleton3D, path: NodePath) -> Basis:
	var idx: int = skeleton.find_bone(_bone_name(path))
	if idx == -1:
		return Basis.IDENTITY
	var parent: int = skeleton.get_bone_parent(idx)
	if parent == -1:
		return Basis.IDENTITY
	return skeleton.get_bone_global_rest(parent).basis.orthonormalized()


static func _bone_name(path: NodePath) -> String:
	return String(path.get_subname(0)) if path.get_subname_count() > 0 else ""


static func _short_bone(path: NodePath) -> String:
	return _bone_name(path).replace("mixamorig:", "").replace("mixamorig_", "")
