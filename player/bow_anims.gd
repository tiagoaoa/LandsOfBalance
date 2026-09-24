extends RefCounted

const HOLD_TIME := .9
const RECOVERY_TIME := .8


static func compose(player: AnimationPlayer, prefix: String) -> void:
	if prefix != "archer":
		return
	var lib := player.get_animation_library(prefix)
	var drawn := lib.get_animation("Attack")
	var idle := lib.get_animation("Idle")
	var loose := Animation.new()
	loose.length = RECOVERY_TIME
	for i in range(drawn.get_track_count()):
		var type := drawn.track_get_type(i)
		var path := drawn.track_get_path(i)
		var dst := idle.find_track(path, type)
		if dst < 0 or type not in [Animation.TYPE_ROTATION_3D,
				Animation.TYPE_POSITION_3D, Animation.TYPE_SCALE_3D]:
			continue
		var track := loose.add_track(type)
		loose.track_set_path(track, path)
		for frame in range(25):
			var t := RECOVERY_TIME * frame / 24.0
			#Let the string go, then lower the arms with zero-speed endpoints.
			var blend := smoothstep(.10, RECOVERY_TIME, t)
			match type:
				Animation.TYPE_ROTATION_3D:
					var a := drawn.rotation_track_interpolate(i, HOLD_TIME)
					var b := idle.rotation_track_interpolate(dst, 0.0)
					loose.rotation_track_insert_key(track, t, a.slerp(b, blend))
				Animation.TYPE_POSITION_3D:
					var a := drawn.position_track_interpolate(i, HOLD_TIME)
					var b := idle.position_track_interpolate(dst, 0.0)
					loose.position_track_insert_key(track, t, a.lerp(b, blend))
				Animation.TYPE_SCALE_3D:
					var a := drawn.scale_track_interpolate(i, HOLD_TIME)
					var b := idle.scale_track_interpolate(dst, 0.0)
					loose.scale_track_insert_key(track, t, a.lerp(b, blend))
	lib.add_animation("Loose", loose)
