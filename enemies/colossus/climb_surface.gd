#The climbing capsule needs triangle distances near creases. Vertex
#distances alone change abruptly when the nearest sample changes sides.
extends RefCounted

const CELL := 1.0
var skin: SkinProbe
var verts: PackedVector3Array
var normals: PackedVector3Array
var bones: PackedInt32Array
var weights: PackedFloat32Array
var indices: PackedInt32Array
var cells := {}
var mats: Array[Transform3D] = []
var posed := {}
var body: StaticBody3D
var shape: ConcavePolygonShape3D
var query: PhysicsShapeQueryParameters3D
var capsule_shape: CapsuleShape3D


#The full mesh is only needed when choosing a route. Skin it off the
#physics thread so entering a climb does not freeze the animation.
class Bake extends RefCounted:
	var verts: PackedVector3Array
	var bones: PackedInt32Array
	var weights: PackedFloat32Array
	var indices: PackedInt32Array
	var mats: Array[Transform3D]
	var faces := PackedVector3Array()
	var shape: ConcavePolygonShape3D

	func run() -> void:
		var positions := PackedVector3Array()
		positions.resize(verts.size())
		for i in verts.size():
			var p := Vector3.ZERO
			for k in 4:
				var w := weights[i * 4 + k]
				if w > 0.0:
					p += (mats[bones[i * 4 + k]] * verts[i]) * w
			positions[i] = p
		faces.resize(indices.size())
		for k in indices.size():
			faces[k] = positions[indices[k]]
		shape = ConcavePolygonShape3D.new()
		shape.backface_collision = true
		shape.set_faces(faces)


var bake: Bake
var bake_task := -1
var stale := false


func prepare(owner: Node3D) -> bool:
	if body == null:
		_make_body(owner)
	if stale:
		discard()
		if stale:
			return false
	if bake_task < 0:
		bake = Bake.new()
		bake.verts = verts
		bake.bones = bones
		bake.weights = weights
		bake.indices = indices
		bake.mats = mats.duplicate()
		bake_task = WorkerThreadPool.add_task(bake.run)
		return false
	if not WorkerThreadPool.is_task_completed(bake_task):
		return false
	WorkerThreadPool.wait_for_task_completion(bake_task)
	shape = bake.shape
	(body.get_child(0) as CollisionShape3D).shape = shape
	body.global_transform = Transform3D.IDENTITY
	body.collision_layer = 1 << 19
	body.force_update_transform()
	bake_task = -1
	bake = null
	return true


func discard() -> void:
	stale = bake_task >= 0
	if stale and WorkerThreadPool.is_task_completed(bake_task):
		WorkerThreadPool.wait_for_task_completion(bake_task)
		bake_task = -1
		bake = null
		stale = false


func _make_body(owner: Node3D) -> void:
	body = StaticBody3D.new()
	body.collision_layer = 0
	body.collision_mask = 0
	owner.add_child(body)
	shape = ConcavePolygonShape3D.new()
	shape.backface_collision = true
	var collider := CollisionShape3D.new()
	collider.shape = shape
	body.add_child(collider)
	capsule_shape = CapsuleShape3D.new()
	query = PhysicsShapeQueryParameters3D.new()
	query.shape = capsule_shape
	query.collision_mask = 1 << 19


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and bake_task >= 0:
		WorkerThreadPool.wait_for_task_completion(bake_task)


func is_free(at: Vector3, margin: float = 0.0) -> bool:
	capsule_shape.radius = 0.44 + margin
	capsule_shape.height = 2.0 + margin * 2.0
	query.transform.origin = at + Vector3.UP * 0.9
	return body.get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty()


func clear(a: Vector3, b: Vector3) -> bool:
	capsule_shape.radius = 0.43
	capsule_shape.height = 2.0
	query.transform.origin = a + Vector3.UP * 0.9
	query.motion = b - a
	var ok := body.get_world_3d().direct_space_state.cast_motion(query)[0] >= 0.999
	query.motion = Vector3.ZERO
	return ok


func _init(probe: SkinProbe) -> void:
	skin = probe
	var a := skin.mi.mesh.surface_get_arrays(0)
	verts = a[Mesh.ARRAY_VERTEX]
	normals = a[Mesh.ARRAY_NORMAL]
	bones = a[Mesh.ARRAY_BONES]
	weights = a[Mesh.ARRAY_WEIGHTS]
	indices = a[Mesh.ARRAY_INDEX]
	for t in range(0, indices.size(), 3):
		var lo := verts[indices[t]].min(verts[indices[t + 1]]).min(verts[indices[t + 2]])
		var hi := verts[indices[t]].max(verts[indices[t + 1]]).max(verts[indices[t + 2]])
		for x in range(floori(lo.x / CELL), floori(hi.x / CELL) + 1):
			for y in range(floori(lo.y / CELL), floori(hi.y / CELL) + 1):
				for z in range(floori(lo.z / CELL), floori(hi.z / CELL) + 1):
					var key := Vector3i(x, y, z)
					if not cells.has(key):
						cells[key] = []
					cells[key].append(t)


func update() -> void:
	mats.clear()
	posed.clear()
	for k in skin.bind_bone.size():
		var pose := skin.skel.get_bone_global_pose(skin.bind_bone[k])
		mats.append(skin.mi.global_transform * pose * skin.skin.get_bind_pose(k))


func vertex(i: int) -> Array:
	if posed.has(i):
		return posed[i]
	var p := Vector3.ZERO
	var n := Vector3.ZERO
	for k in 4:
		if weights[i * 4 + k] <= 0.0:
			continue
		var m := mats[bones[i * 4 + k]]
		p += (m * verts[i]) * weights[i * 4 + k]
		n += (m.basis * normals[i]) * weights[i * 4 + k]
	posed[i] = [p, n.normalized()]
	return posed[i]


func near_faces(sample: int) -> Dictionary:
	var rest := skin.rest_pos[sample]
	var faces := {}
	for x in range(floori(rest.x - 0.65), floori(rest.x + 0.65) + 1):
		for y in range(floori(rest.y - 0.65), floori(rest.y + 0.65) + 1):
			for z in range(floori(rest.z - 0.65), floori(rest.z + 0.65) + 1):
				for t: int in cells.get(Vector3i(x, y, z), []):
					faces[t] = true
	return faces


func contact(p: Vector3) -> Dictionary:
	var sample: int = skin.nearest(p)[0]
	var faces := near_faces(sample)
	var outside := skin.winding(p) <= 0.5
	var best := INF
	var hit := {"depth": -INF, "normal": Vector3.UP, "bone": ""}
	for t: int in faces:
		var va := vertex(indices[t])
		var a: Vector3 = va[0]
		var b: Vector3 = vertex(indices[t + 1])[0]
		var c: Vector3 = vertex(indices[t + 2])[0]
		var lo := a.min(b).min(c)
		var hi := a.max(b).max(c)
		if p.distance_squared_to(p.clamp(lo, hi)) >= best:
			continue
		var q := triangle_point(p, a, b, c)
		var d := p.distance_squared_to(q)
		if d >= best:
			continue
		var n := (b - a).cross(c - a).normalized()
		if n.dot(va[1]) < 0.0:
			n = -n
		best = d
		hit.depth = -sqrt(d) if outside else sqrt(d)
		hit.normal = (p - q).normalized() if outside and d > 0.0001 else n
		hit.bone = skin.bone_names[skin.dominant[sample]]
	return hit


func capsule(at: Vector3) -> Dictionary:
	var best := {"depth": -INF, "normal": Vector3.UP, "bone": ""}
	for h: float in [0.3, 0.6, 0.9, 1.2, 1.5]:
		var hit := contact(at + Vector3.UP * h)
		hit.depth += 0.34
		if hit.depth > best.depth:
			best = hit
	return best


func triangle_point(p: Vector3, a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	var n := (b - a).cross(c - a)
	if n.length_squared() > 1e-10:
		var q := p - n * (p - a).dot(n) / n.length_squared()
		var u := (b - q).cross(c - q).dot(n)
		var v := (c - q).cross(a - q).dot(n)
		var w := (a - q).cross(b - q).dot(n)
		if minf(u, minf(v, w)) >= -1e-7:
			return q
	var best := Geometry3D.get_closest_point_to_segment(p, a, b)
	for edge in [[b, c], [c, a]]:
		var q := Geometry3D.get_closest_point_to_segment(p, edge[0], edge[1])
		if p.distance_squared_to(q) < p.distance_squared_to(best):
			best = q
	return best
