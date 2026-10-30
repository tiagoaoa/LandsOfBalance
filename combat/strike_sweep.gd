extends RefCounted

#Sweep a fist or axe head between poses, never the empty space around Bobba.
var previous := Vector3.ZERO
var ready := false
var shape := CapsuleShape3D.new()


func reset() -> void:
	ready = false


func contacts(space: PhysicsDirectSpaceState3D, point: Vector3,
		radius: float, active: bool, excluded: Array[RID]) -> Array[Node3D]:
	var start := previous if ready else point
	previous = point
	ready = true
	var found: Array[Node3D] = []
	if not active:
		return found
	if start.distance_to(point) > 4.0:
		start = point
	var travel := point - start
	shape.radius = radius
	shape.height = travel.length() + radius * 2.0
	var basis := Basis.IDENTITY
	if travel.length() > 0.001:
		basis = Basis(Quaternion(Vector3.UP, travel.normalized()))
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform = Transform3D(basis, (start + point) * 0.5)
	query.collision_mask = 1 | 8
	query.exclude = excluded
	for hit in space.intersect_shape(query, 16):
		var node := hit.collider as Node3D
		if node and not found.has(node):
			found.append(node)
	return found
