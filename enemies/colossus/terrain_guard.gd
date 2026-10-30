#World collision envelopes are separate from the smaller weapon hitboxes.
extends RefCounted

const HULL_SLACK := 0.025

var rig: ReptilianRig
var hulls := {}
var query := PhysicsShapeQueryParameters3D.new()
var bounds := {}
var rigid := {}
var blends := {}
var serial := {}
var matrices: Array[Transform3D] = []
var matrix_serial := -1
var dependencies := {}
var saved_poses := {}
var sweep_hulls := {}
var party_excluded := false
var last_hit := ""
var perf := OS.get_environment("LOB_BOSS_PROFILE") == "1"
var times := {}
var influence_boxes := {}
var world_boxes := {}
var world_serial := {}
var scenery: Array[AABB] = []


func _mark(label: String, since: int) -> int:
	if not perf:
		return 0
	var now := Time.get_ticks_usec()
	times[label] = int(times.get(label, 0)) + now - since
	return now


func build(r: ReptilianRig) -> void:
	rig = r
	query.collision_mask = 1
	query.margin = 0.22 + HULL_SLACK * rig.skel.global_basis.get_scale().x
	var exclude: Array[RID] = []
	for body: CollisionObject3D in rig.boss.find_children("*", "CollisionObject3D", true, false):
		exclude.append(body.get_rid())
	query.exclude = exclude
	var points := {}
	for mi: MeshInstance3D in rig.model.find_children("*", "MeshInstance3D", true, false):
		if mi.skin == null:
			continue
		for s in mi.mesh.get_surface_count():
			_collect(mi, s, points)
	_collect_scenery()
	for bn: String in points:
		var hull := ConvexPolygonShape3D.new()
		if points[bn].size() > 64:
			hull.points = points[bn]
			var unique := {}
			for p: Vector3 in hull.get_debug_mesh().get_faces():
				unique[p] = true
			points[bn] = PackedVector3Array(unique.keys())
		rigid[bn] = points[bn]
		hulls[bn] = hull
		var deps := {rig.skel.find_bone(bn): true}
		for parts: Array in blends[bn]:
			for part: Array in parts:
				deps[part[0]] = true
		dependencies[bn] = deps.keys()
		if perf:
			print("TERRAIN POINTS ", bn, " rigid=", rigid[bn].size(), " blend=", blends[bn].size())
		_build_boxes(bn)
		_shape(bn)
		var core := ConvexPolygonShape3D.new()
		core.points = _scaled(rigid[bn]) if rigid[bn].size() >= 4 else hull.points
		sweep_hulls[bn] = core


func _collect_scenery() -> void:
	for n in rig.boss.arena.get_children():
		if n is CSGBox3D and n.use_collision:
			scenery.append(n.global_transform * AABB(-n.size * 0.5, n.size))
		elif n is CSGCylinder3D and n.use_collision:
			var size := Vector3(n.radius * 2, n.height, n.radius * 2)
			scenery.append(n.global_transform * AABB(-size * 0.5, size))
	for cs: CollisionShape3D in rig.boss.arena.find_children("*", "CollisionShape3D", true, false):
		if rig.boss.is_ancestor_of(cs) or not cs.get_parent() is StaticBody3D:
			continue
		if cs.shape:
			scenery.append(cs.global_transform * cs.shape.get_debug_mesh().get_aabb())


func _build_boxes(bn: String) -> void:
	var boxes := {}
	var index := rig.skel.find_bone(bn)
	for p: Vector3 in rigid[bn]:
		boxes[index] = (boxes[index] as AABB).expand(p) if boxes.has(index) else AABB(p, Vector3.ZERO)
	for parts: Array in blends[bn]:
		for part: Array in parts:
			var i: int = part[0]
			var p: Vector3 = part[1]
			boxes[i] = (boxes[i] as AABB).expand(p) if boxes.has(i) else AABB(p, Vector3.ZERO)
	influence_boxes[bn] = boxes


#Positive skin weights keep each vertex inside the union of its influence
#bounds. These cheap conservative boxes reject empty space before fitting
#a detailed hull or asking Jolt to cook and intersect it.
func _world_box(bn: String) -> AABB:
	if world_serial.get(bn, -1) == rig.pose_serial:
		return world_boxes[bn]
	var box := AABB()
	var first := true
	for index: int in influence_boxes[bn]:
		var t := rig.skel.global_transform * rig.skel.get_bone_global_pose(index)
		var next: AABB = t * influence_boxes[bn][index]
		box = next if first else box.merge(next)
		first = false
	world_boxes[bn] = box.grow(query.margin + 0.04)
	world_serial[bn] = rig.pose_serial
	return world_boxes[bn]


func _near_scenery(bn: String) -> bool:
	var box := _world_box(bn)
	for solid in scenery:
		if box.intersects(solid):
			return true
	return false


func _collect(mi: MeshInstance3D, surface: int, points: Dictionary) -> void:
	var arr := mi.mesh.surface_get_arrays(surface)
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var bones: PackedInt32Array = arr[Mesh.ARRAY_BONES]
	var weights: PackedFloat32Array = arr[Mesh.ARRAY_WEIGHTS]
	var stride := maxi(1, verts.size() / 6000)
	#Match the skin probe's finer contact samples so a preserved fingertip
	#cannot fall between terrain samples and pass through the floor.
	var fine := maxi(1, stride / 4) if rig.spec.get("palms_inward", false) else stride
	stride = maxi(1, stride / fine) * fine
	for i in range(0, verts.size(), fine):
		var best := 0
		for k in range(1, 4):
			if weights[i * 4 + k] > weights[i * 4 + best]:
				best = k
		var bi := bones[i * 4 + best]
		var bn := String(mi.skin.get_bind_name(bi))
		if bn == "":
			bn = rig.skel.get_bone_name(mi.skin.get_bind_bone(bi))
		if bn not in ["head", "jaw", "hand.L", "hand.R"] and i % stride != 0:
			continue
		if not points.has(bn):
			points[bn] = PackedVector3Array()
			blends[bn] = []
		if weights[i * 4 + best] > 0.999:
			points[bn].append(mi.skin.get_bind_pose(bi) * verts[i])
		else:
			blends[bn].append(_blend(mi.skin, verts[i], bones, weights, i))


func _blend(skin: Skin, v: Vector3, bones: PackedInt32Array,
		weights: PackedFloat32Array, i: int) -> Array:
	var parts := []
	for k in 4:
		var w := weights[i * 4 + k]
		if w <= 0.0:
			continue
		var bi := bones[i * 4 + k]
		var index := skin.get_bind_bone(bi)
		if index < 0:
			index = rig.skel.find_bone(skin.get_bind_name(bi))
		parts.append([index, skin.get_bind_pose(bi) * v, w])
	return parts


#Joint vertices move with several bones. Refit those points in the dominant
#bone's frame; a rigid rest-pose hull cut through the bent wrist and elbow.
func _shape(bn: String) -> Shape3D:
	if serial.get(bn, -1) == rig.pose_serial:
		return hulls[bn]
	#A rigid skull/helmet changes its query transform, never its hull.
	if blends[bn].is_empty() and bounds.has(bn):
		serial[bn] = rig.pose_serial
		return hulls[bn]
	if matrix_serial != rig.pose_serial:
		matrices.clear()
		for i in rig.skel.get_bone_count():
			matrices.append(rig.skel.get_bone_global_pose(i))
		matrix_serial = rig.pose_serial
	var poses: Array[Transform3D] = []
	var inv := matrices[rig.skel.find_bone(bn)].affine_inverse()
	for i: int in dependencies[bn]:
		poses.append(inv * matrices[i])
	#Only relative joint motion deforms an envelope. Root translation and
	#rotation previously recooked every convex shape, including rigid teeth.
	if not _same_poses(bn, poses, saved_poses.get(bn, [])):
		var stamp := Time.get_ticks_usec() if perf else 0
		var pts: PackedVector3Array = rigid[bn].duplicate()
		for parts: Array in blends[bn]:
			var p := Vector3.ZERO
			for part: Array in parts:
				p += (matrices[part[0]] * part[1]) * part[2]
			pts.append(inv * p)
		stamp = _mark("blend", stamp)
		#A bone stretched along its length (a far punch) keeps that scale out
		#of the query transform, so bake it into the points with the size.
		var bone_scale := (rig.skel.global_transform * matrices[rig.skel.find_bone(bn)]).basis.get_scale()
		var cooked := pts.duplicate()
		for k in cooked.size():
			cooked[k] *= bone_scale
		#The submerged-body cut can leave only a few samples on a bone.
		#Give those points a small volume so Jolt can build a convex shape.
		if cooked.size() < 4:
			for p: Vector3 in cooked.duplicate():
				for axis in [Vector3.RIGHT, Vector3.UP, Vector3.BACK]:
					cooked.append(p + axis * HULL_SLACK)
					cooked.append(p - axis * HULL_SLACK)
		hulls[bn].points = cooked
		_mark("cook", stamp)
		bounds[bn] = pts
		saved_poses[bn] = poses
	serial[bn] = rig.pose_serial
	return hulls[bn]


func _same_poses(bn: String, a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in a.size():
		var box: AABB = influence_boxes[bn][dependencies[bn][i]]
		var center := box.get_center()
		var half := box.size * 0.5
		var next: Transform3D = a[i]
		var prev: Transform3D = b[i]
		var error := (next * center - prev * center).abs()
		error += (next.basis.x - prev.basis.x).abs() * half.x
		error += (next.basis.y - prev.basis.y).abs() * half.y
		error += (next.basis.z - prev.basis.z).abs() * half.z
		#Bounds the displacement of every influence point, hence every
		#positive weighted skin vertex. The query margin includes this slack.
		#Small breaths can reuse Jolt's cooked hull without losing coverage.
		if error.length_squared() > HULL_SLACK * HULL_SLACK:
			return false
	return true


func pose(bn: String) -> Transform3D:
	return rig.skel.global_transform * rig.skel.get_bone_global_pose(rig.skel.find_bone(bn))


func _scaled(points: PackedVector3Array) -> PackedVector3Array:
	#Bake size into the geometry. Scaled query transforms missed ramp
	#contacts at 0.6x even when the visible vertex was inside the hull.
	var out := points.duplicate()
	var size := rig.skel.global_basis.get_scale().x
	for i in out.size():
		out[i] *= size
	return out


func _query_pose(t: Transform3D) -> Transform3D:
	return Transform3D(t.basis.orthonormalized(), t.origin)


func blocked(bones: Array) -> bool:
	var stamp := Time.get_ticks_usec() if perf else 0
	if not party_excluded:
		var exclude := query.exclude
		for player: CollisionObject3D in rig.boss.arena.party():
			exclude.append(player.get_rid())
		query.exclude = exclude
		party_excluded = true
	var space := rig.boss.get_world_3d().direct_space_state
	for bn: String in bones:
		if not _near_scenery(bn):
			continue
		query.shape = _shape(bn)
		query.transform = _query_pose(pose(bn))
		query.motion = Vector3.ZERO
		var query_start := Time.get_ticks_usec() if perf else 0
		var hits := space.intersect_shape(query, 1)
		_mark("intersect", query_start)
		if not hits.is_empty():
			last_hit = "%s/%s" % [bn, hits[0].collider.name]
			_mark("blocked", stamp)
			return true
	_mark("blocked", stamp)
	return false


func floor_lift(bones: Array) -> float:
	var stamp := Time.get_ticks_usec() if perf else 0
	var arena: Node3D = rig.boss.arena
	var lift := 0.0
	for bn: String in bones:
		if _world_box(bn).position.y > arena.floor_y:
			continue
		_shape(bn)
		var t := pose(bn)
		for v: Vector3 in bounds[bn]:
			var p := t * v
			if Vector2(p.x - arena.center.x, p.z - arena.center.z).length() <= arena.radius + 0.08:
				lift = maxf(lift, arena.floor_y + query.margin + 0.04 - p.y)
	_mark("floor", stamp)
	return lift


func lowest(bn: String) -> float:
	_shape(bn)
	var t := pose(bn)
	var y := INF
	for v: Vector3 in bounds[bn]:
		y = minf(y, (t * v).y)
	return y


#Translation casts plus short rotational steps catch a fast claw crossing a
#thin pillar even when neither frame's endpoint overlaps the pillar.
func motion_clear(bn: String, from: Transform3D, to: Transform3D) -> bool:
	var space := rig.boss.get_world_3d().direct_space_state
	var a := from.basis.orthonormalized().get_rotation_quaternion()
	var b := to.basis.orthonormalized().get_rotation_quaternion()
	var steps := maxi(1, ceili(a.angle_to(b) / 0.06))
	#Blended joint points change shape during a bend. Casting that new shape
	#from the old pose invents contacts; sweep the rigid core, then check the
	#complete deformed envelope at the endpoint in blocked().
	query.shape = sweep_hulls[bn]
	var prev := from
	for i in range(1, steps + 1):
		var next := from.interpolate_with(to, float(i) / steps)
		query.transform = Transform3D(next.basis.orthonormalized(), prev.origin)
		query.motion = next.origin - prev.origin
		if space.cast_motion(query)[0] < 0.999:
			last_hit = bn + "/motion"
			return false
		query.transform = _query_pose(next)
		query.motion = Vector3.ZERO
		var hits := space.intersect_shape(query, 1)
		if not hits.is_empty():
			last_hit = "%s/%s" % [bn, hits[0].collider.name]
			return false
		prev = next
	return true


func projectile_hit(from: Vector3, to: Vector3, radius: float) -> Dictionary:
	var sphere := SphereShape3D.new()
	sphere.radius = radius
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = sphere
	q.collision_mask = 1
	q.exclude = query.exclude
	q.transform.origin = from
	q.motion = to - from
	var space := rig.boss.get_world_3d().direct_space_state
	var fraction := space.cast_motion(q)
	if fraction[0] >= 1.0:
		return {}
	q.transform.origin = from.lerp(to, minf(1.0, fraction[1] + 0.01))
	q.motion = Vector3.ZERO
	var hit := space.get_rest_info(q)
	return {"point": from.lerp(to, fraction[0]), "normal": hit.get("normal", Vector3.UP)}
