extends RefCounted

# Sweep the actual blade between physics poses. Area overlap alone skips
# targets when a fast slash passes through them between two physics ticks.
var _previous := Transform3D.IDENTITY
var _has_previous := false
var _shape := CapsuleShape3D.new()


func reset() -> void:
	_has_previous = false


func contacts(space: PhysicsDirectSpaceState3D, pose: Transform3D,
		excluded: Array[RID]) -> Array[Node3D]:
	var found: Array[Node3D] = []
	var query := PhysicsShapeQueryParameters3D.new()
	query.collision_mask = 2
	query.exclude = excluded
	query.shape = _shape
	_shape.radius = 0.14
	for i in range(7):
		var point := Vector3(0, 0, 0.08 + i * 0.24)
		var tip := pose * point
		var start := _previous * point if _has_previous else tip
		# A teleport or a new animation must never sweep across the level.
		if start.distance_to(tip) > 3.0:
			start = tip
		var travel := tip - start
		_shape.height = travel.length() + _shape.radius * 2.0
		var basis := Basis(Quaternion(Vector3.UP, travel.normalized())) \
				if travel.length() > 0.001 else Basis.IDENTITY
		query.transform = Transform3D(basis, (start + tip) * 0.5)
		for contact in space.intersect_shape(query, 16):
			var body := contact.collider as Node3D
			if body != null and not found.has(body):
				found.append(body)
	_previous = pose
	_has_previous = true
	return found
