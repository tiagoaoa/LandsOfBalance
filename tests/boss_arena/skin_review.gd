extends Node3D


func _ready() -> void:
	seed(301)
	var arena: BossArena = load("res://tests/boss_arena/boss_arena.tscn").instantiate()
	add_child(arena)
	await get_tree().physics_frame
	arena.process_mode = Node.PROCESS_MODE_DISABLED
	var skin: SkinProbe = arena.boss._skin
	var times := []
	var serial := PackedVector3Array()
	var normals := PackedVector3Array()
	var failures := 0
	for threaded in [false, true, false, true]:
		skin.threaded = threaded
		for k in 5:
			skin.update()
		var begin := Time.get_ticks_usec()
		for k in 60:
			skin.update()
		times.append((Time.get_ticks_usec() - begin) / 60000.0)
		if not threaded:
			serial = skin.pos.duplicate()
			normals = skin.nrm.duplicate()
		elif skin.pos != serial or skin.nrm != normals:
			failures += 1
	for angle in [0.2, -0.3, 0.5]:
		arena.boss.reptile.head.rotation.y = angle
		arena.boss.reptile.drive(0.1)
		skin.threaded = false
		skin.update()
		serial = skin.pos.duplicate()
		normals = skin.nrm.duplicate()
		skin.threaded = true
		skin.update()
		if skin.pos != serial or skin.nrm != normals:
			failures += 1
	for k in 64:
		var p := Vector3(randf_range(-25, 25), randf_range(-8, 20), randf_range(-40, 10))
		var nearest := skin.nearest(p)
		var distance := INF
		for q in skin.pos:
			distance = minf(distance, p.distance_squared_to(q))
		if absf(nearest[1] - sqrt(distance)) > 0.0001:
			failures += 1
	print("SKIN REVIEW samples=%d failures=%d serial/parallel/serial/parallel ms=%s" % [
			skin.pos.size(), failures, times])
	get_tree().quit(1 if failures else 0)
