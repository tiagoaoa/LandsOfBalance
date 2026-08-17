class_name ClipTrim
extends RefCounted
## Cut a sub-range out of an animation as a clip in its own right.
##
## Mixamo sells motions, not game actions: "Stand To Roll" is 2.4 seconds of
## stand, crouch, dive, tumble, stand up. A dodge-roll is the tumble. Playing
## the whole thing fast enough to fit a dodge blurs the part that matters
## along with the parts that don't, so take the range that IS the action and
## let the caller pick its playback rate.
##
## Every track is resampled rather than copied, because a source key rarely
## falls on the cut and the first frame of a game action has to be exactly the
## pose the action starts from.

const SAMPLE_FPS: float = 30.0


## The range [from, to] of `src`, re-based to start at zero.
static func sub(src: Animation, from: float, to: float,
		fps: float = SAMPLE_FPS) -> Animation:
	if src == null:
		return null
	from = clampf(from, 0.0, src.length)
	to = clampf(to, from, src.length)
	var length: float = to - from
	if length <= 0.0:
		return src

	var out := Animation.new()
	out.length = length
	out.loop_mode = src.loop_mode
	var steps: int = maxi(int(ceil(length * fps)), 2)

	for i in range(src.get_track_count()):
		var type: int = src.track_get_type(i)
		if type != Animation.TYPE_POSITION_3D \
				and type != Animation.TYPE_ROTATION_3D \
				and type != Animation.TYPE_SCALE_3D:
			continue
		var track: int = out.add_track(type)
		out.track_set_path(track, src.track_get_path(i))
		for s in range(steps + 1):
			var t: float = length * float(s) / float(steps)
			match type:
				Animation.TYPE_POSITION_3D:
					out.position_track_insert_key(track, t,
							src.position_track_interpolate(i, from + t))
				Animation.TYPE_ROTATION_3D:
					out.rotation_track_insert_key(track, t,
							src.rotation_track_interpolate(i, from + t))
				Animation.TYPE_SCALE_3D:
					out.scale_track_insert_key(track, t,
							src.scale_track_interpolate(i, from + t))
	return out
