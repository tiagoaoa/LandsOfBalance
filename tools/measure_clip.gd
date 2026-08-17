extends SceneTree
## Find when a swing actually lands, by measuring it rather than eyeballing it.
##
##   godot --path . --headless --script tools/measure_clip.gd -- <res://clip.fbx> [Bone]
##
## Reports the tracked bone's height, forward reach and vertical speed across
## the clip. The impact frame is the one with the most downward speed near the
## bottom of the arc, and that is what the damage window has to be built
## around. Guessing it from screenshots has been wrong here more than once.
##
## The forward kinematics are done by hand — sample the tracks, compose parent
## to child — rather than by seeking an AnimationPlayer. A harness that only
## LOOKS like it is driving the skeleton reports a flat line and reads as a
## finding; this version cannot, because nothing but the tracks feeds it.

const FPS := 60.0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var path: String = args[0] if args.size() > 0 else "res://assets/bobba/axe_attack_downward.fbx"
	var bone_name: String = args[1] if args.size() > 1 else "mixamorig_RightHand"

	var scene: PackedScene = load(path) as PackedScene
	if scene == null:
		print("FAILED to load ", path)
		quit(1)
		return
	var inst: Node3D = scene.instantiate()
	var skel: Skeleton3D = _find(inst, "Skeleton3D") as Skeleton3D
	var ap: AnimationPlayer = _find(inst, "AnimationPlayer") as AnimationPlayer
	if skel == null or ap == null:
		print("no skeleton/animationplayer")
		quit(1)
		return
	var bone: int = skel.find_bone(bone_name)
	if bone == -1:
		print("no bone ", bone_name)
		quit(1)
		return

	var clip_name: String = ap.get_animation_list()[0]
	var anim: Animation = ap.get_animation(clip_name)

	# Bone index -> {rot, pos, scale} track indices.
	var tracks := {}
	for t in range(anim.get_track_count()):
		var p := str(anim.track_get_path(t))
		var c := p.rfind(":")
		if c == -1:
			continue
		var b: int = skel.find_bone(p.substr(c + 1))
		if b == -1:
			continue
		if not tracks.has(b):
			tracks[b] = {}
		match anim.track_get_type(t):
			Animation.TYPE_ROTATION_3D: tracks[b]["rot"] = t
			Animation.TYPE_POSITION_3D: tracks[b]["pos"] = t
			Animation.TYPE_SCALE_3D: tracks[b]["scale"] = t

	# The parent chain up from the tracked bone is all the FK we need.
	var chain: Array[int] = []
	var walk: int = bone
	while walk != -1:
		chain.push_front(walk)
		walk = skel.get_bone_parent(walk)

	print("clip %s  length %.3f s" % [clip_name, anim.length])
	print("tracking %s  (chain: %s)" % [bone_name, chain.size()])
	var animated := 0
	for b in chain:
		if tracks.has(b) and tracks[b].has("rot"):
			animated += 1
	print("animated bones in chain: %d/%d" % [animated, chain.size()])
	if animated == 0:
		print("NOTHING in this chain is animated — the measurement would be a flat line.")
		quit(1)
		return
	print("\n%6s %8s %8s %8s %9s %9s"
			% ["t", "height", "fwd", "side", "dy/dt", "rootyaw"])

	var samples: Array = []
	var steps: int = int(round(anim.length * FPS))
	for s in range(steps + 1):
		var t: float = anim.length * float(s) / float(steps)
		var g := Transform3D.IDENTITY
		for b in chain:
			var rest: Transform3D = skel.get_bone_rest(b)
			var origin: Vector3 = rest.origin
			var basis: Basis = rest.basis
			if tracks.has(b):
				var tr: Dictionary = tracks[b]
				if tr.has("rot"):
					basis = Basis(anim.rotation_track_interpolate(tr["rot"], t))
				if tr.has("pos"):
					origin = anim.position_track_interpolate(tr["pos"], t)
				if tr.has("scale"):
					basis = basis.scaled(anim.scale_track_interpolate(tr["scale"], t))
			g = g * Transform3D(basis, origin)
		# Root yaw: how far the clip turns the body on its own. A clip that
		# spins the hips fights the code that aims Bobba at his target, and
		# reads as him wandering off mid-swing.
		var yaw := 0.0
		var hips: int = skel.find_bone("mixamorig_Hips")
		if hips != -1 and tracks.has(hips) and tracks[hips].has("rot"):
			var hb := Basis(anim.rotation_track_interpolate(tracks[hips]["rot"], t))
			var f: Vector3 = hb * Vector3.FORWARD
			yaw = rad_to_deg(atan2(f.x, f.z))
		samples.append({"t": t, "p": g.origin, "yaw": yaw})

	var lowest := INF
	var lowest_t := 0.0
	var fastest := 0.0
	var fastest_t := 0.0
	for i in range(samples.size()):
		var t: float = samples[i]["t"]
		var p: Vector3 = samples[i]["p"]
		var dy := 0.0
		if i > 0:
			dy = (p.y - (samples[i - 1]["p"] as Vector3).y) * FPS
		if p.y < lowest:
			lowest = p.y
			lowest_t = t
		if dy < fastest:
			fastest = dy
			fastest_t = t
		if i % 3 == 0:
			print("%6.3f %8.3f %8.3f %8.3f %9.2f %9.1f"
					% [t, p.y, p.z, p.x, dy, samples[i]["yaw"]])

	print("\nlowest point  : %.3f s  (y = %.3f)" % [lowest_t, lowest])
	print("peak downward : %.3f s  (%.2f/s)" % [fastest_t, fastest])
	print("as fractions of %.3f s: lowest %.3f, peak %.3f"
			% [anim.length, lowest_t / anim.length, fastest_t / anim.length])

	# Where the blade ends up relative to where the BODY is pointing. This is
	# the question the frontal cone is really asking, and neither the world-
	# space arc nor the root yaw answers it on its own: a clip can pivot the
	# hips a long way and still land the blow dead ahead.
	var hips_b: int = skel.find_bone("mixamorig_Hips")
	if hips_b != -1 and tracks.has(hips_b) and tracks[hips_b].has("rot"):
		var t_hit: float = fastest_t
		var hb := Basis(anim.rotation_track_interpolate(tracks[hips_b]["rot"], t_hit))
		var hips_pos: Vector3 = skel.get_bone_rest(hips_b).origin
		if tracks[hips_b].has("pos"):
			hips_pos = anim.position_track_interpolate(tracks[hips_b]["pos"], t_hit)
		var hand: Vector3 = Vector3.ZERO
		for s in samples:
			if is_equal_approx(float(s["t"]), t_hit):
				hand = s["p"]
		var to_hand: Vector3 = hand - hips_pos
		to_hand.y = 0.0
		var fwd: Vector3 = (hb * Vector3.BACK)
		fwd.y = 0.0
		if to_hand.length() > 0.01 and fwd.length() > 0.01:
			print("blade at impact : %.0f deg off the body's own forward"
					% rad_to_deg(fwd.normalized().signed_angle_to(
							to_hand.normalized(), Vector3.UP)))

	var yaw0: float = samples[0]["yaw"]
	var swing := 0.0
	for s in samples:
		swing = maxf(swing, absf(wrapf(float(s["yaw"]) - yaw0, -180.0, 180.0)))
	print("root yaw drift : %.1f deg from start to worst frame" % swing)
	if swing > 25.0:
		print("  ^ the clip turns the body itself. Code that aims the character")
		print("    is fighting it, and it will snap back when the clip ends.")
	quit(0)


func _find(node: Node, cls: String) -> Node:
	if node.get_class() == cls:
		return node
	for c in node.get_children():
		var r := _find(c, cls)
		if r:
			return r
	return null
