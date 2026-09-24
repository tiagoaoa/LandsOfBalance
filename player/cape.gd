extends SkeletonModifier3D

const COLS := 11
const ROWS := 17
const STEP := 1.0 / 120.0
const FABRIC = preload("res://player/cape.gdshader")

var rig: Skeleton3D
var chest: int
var rest_inv: Transform3D
var rest := PackedVector3Array()
var points := PackedVector3Array()
var previous := PackedVector3Array()
var anchors := PackedVector3Array()
var links := PackedVector2Array()
var lengths := PackedFloat32Array()
var stiffness := PackedFloat32Array()
#Solver copy of the links: pinned-to-pinned pairs dropped, the stiffness
#already divided by the free ends' count, which ends move known up front.
var link_a := PackedInt32Array()
var link_b := PackedInt32Array()
var link_rest := PackedFloat32Array()
var link_k := PackedFloat32Array()
var link_free := PackedInt32Array()
var tether_limits := PackedFloat32Array()
var bodies: Array[Vector2i] = []
var radii := PackedFloat32Array([.175, .15, .115, .115, .13, .09, .09, .28])
var starts := PackedVector3Array()
var ends := PackedVector3Array()
var tunic_basis := Basis.IDENTITY
var cloth: MeshInstance3D
var positions: Image
var texture: ImageTexture
var elapsed := 0.0
var time := 0.0
var origin := Vector3.ZERO
var travel := Vector3.ZERO
var sleeping := true
var step_usec := 0
var floor_query := PhysicsRayQueryParameters3D.new()
var floor_normal := Vector3.ZERO
var floor_offset := 0.0
var floor_tick := 0
var distant := false
var paladin := false


static func install(model: Node3D, skeleton: Skeleton3D, armored: bool = false) -> void:
	#Keep the imported skin binding alive until its skeleton is freed.
	var old := model.find_child("Armor and mantle", true, false) as MeshInstance3D
	if old:
		if armored:
			#The paladin's mantle shares a mesh with his cuirass and pauldrons.
			var hidden := ShaderMaterial.new()
			hidden.shader = Shader.new()
			hidden.shader.code = "shader_type spatial; void fragment() { discard; }"
			for i in range(old.mesh.get_surface_count()):
				var mat := old.mesh.surface_get_material(i)
				if mat and mat.resource_name == "Weathered wool":
					old.set_surface_override_material(i, hidden)
		else:
			old.hide()
			old.set_meta("retired_cape", true)
	var cape := load("res://player/cape.gd").new() as SkeletonModifier3D
	cape.name = "Cape"
	cape.paladin = armored
	skeleton.add_child(cape)


func _ready() -> void:
	add_to_group(&"perf_cape")  # autoload/perf_probe.gd sums step_usec
	rig = get_skeleton()
	chest = rig.find_bone("mixamorig_Spine2")
	rest_inv = rig.get_bone_global_rest(chest).affine_inverse()
	if paladin:
		radii = PackedFloat32Array([.21, .17, .13, .13, .13, .12, .12, .22])
	_cut()
	_seams()
	_body()
	_mesh()
	floor_query.collision_mask = 1
	var owner: Node = rig
	while owner and not owner is CharacterBody3D:
		owner = owner.get_parent()
	if owner:
		floor_query.exclude = [owner.get_rid()]


func _cut() -> void:
	for j in range(ROWS):
		var v := float(j) / (ROWS - 1)
		for i in range(COLS):
			var u := float(i) / (COLS - 1)
			var x := (u * 2.0 - 1.0) * (.24 + (.18 if paladin else .14) * sin(v * PI * .5))
			var y := (1.405 if paladin else 1.415) - (.94 if paladin else .9) * v - .045 * absf(u * 2.0 - 1.0)
			y += .035 * cos(u * TAU) * v * v
			var fold := sin(u * TAU * 2.5 + v * .8) * (.008 + .055 * v)
			rest.append(Vector3(x, y, (-.235 if paladin else -.155) - .055 * v + fold))
	points.resize(rest.size())
	previous.resize(rest.size())
	anchors.resize(COLS)
	tether_limits.resize(rest.size())
	for i in range(rest.size()):
		tether_limits[i] = rest[i].distance_to(rest[i % COLS]) * 1.06


func _seams() -> void:
	for j in range(ROWS):
		for i in range(COLS):
			var a := j * COLS + i
			if i + 1 < COLS:
				_link(a, a + 1, 1.0)
			if j + 1 < ROWS:
				_link(a, a + COLS, 1.0)
			if i + 1 < COLS and j + 1 < ROWS:
				_link(a, a + COLS + 1, .65)
				_link(a + 1, a + COLS, .65)
			if i + 2 < COLS:
				_link(a, a + 2, .12)
			if j + 2 < ROWS:
				_link(a, a + COLS * 2, .12)


func _link(a: int, b: int, strength: float) -> void:
	links.append(Vector2(a, b))
	lengths.append(rest[a].distance_to(rest[b]))
	stiffness.append(strength)
	var free := int(a >= COLS) | int(b >= COLS) << 1
	if free == 0:
		return
	link_a.append(a)
	link_b.append(b)
	link_rest.append(lengths[-1])
	link_k.append(strength / (1.0 if free != 3 else 2.0))
	link_free.append(free)


func _body() -> void:
	for pair in [["Hips", "Spine2"], ["LeftUpLeg", "RightUpLeg"],
			["LeftUpLeg", "LeftLeg"], ["RightUpLeg", "RightLeg"], ["Neck", "Head"],
			["LeftShoulder", "LeftArm"], ["RightShoulder", "RightArm"], ["Hips", "Hips"]]:
		bodies.append(Vector2i(rig.find_bone("mixamorig_" + pair[0]),
				rig.find_bone("mixamorig_" + pair[1])))
	starts.resize(bodies.size())
	ends.resize(bodies.size())


func _mesh() -> void:
	positions = Image.create(COLS, ROWS, false, Image.FORMAT_RGBAF)
	texture = ImageTexture.create_from_image(positions)
	var mat := ShaderMaterial.new()
	mat.shader = FABRIC
	mat.set_shader_parameter("positions", texture)
	if paladin:
		mat.set_shader_parameter("cloth_color", Color(.30, .105, .085))
	var plane := PlaneMesh.new()
	plane.size = Vector2(1, 1)
	plane.subdivide_width = (COLS - 1) * 3 - 1
	plane.subdivide_depth = (ROWS - 1) * 3 - 1
	plane.material = mat
	cloth = MeshInstance3D.new()
	cloth.name = "WovenCape"
	cloth.mesh = plane
	cloth.custom_aabb = AABB(Vector3(-2, -1, -2), Vector3(4, 4, 4))
	cloth.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED
	add_child(cloth)


func _pose() -> Transform3D:
	for i in range(bodies.size()):
		starts[i] = rig.to_global(rig.get_bone_global_pose(bodies[i].x).origin)
		ends[i] = rig.to_global(rig.get_bone_global_pose(bodies[i].y).origin)
	#The long tunic needs clearance beyond the bare thigh capsules.
	ends[7] = (ends[2] + ends[3]) * .5
	tunic_basis = rig.global_basis.orthonormalized()
	return rig.global_transform * rig.get_bone_global_pose(chest) * rest_inv


func _physics_process(_delta: float) -> void:
	if not is_visible_in_tree() or distant:
		return
	floor_tick = (floor_tick + 1) % 4
	if floor_tick != 0:
		return
	floor_query.from = rig.global_position + Vector3.UP * .5
	floor_query.to = floor_query.from + Vector3.DOWN * 2.5
	var hit := get_world_3d().direct_space_state.intersect_ray(floor_query)
	floor_normal = hit.normal if not hit.is_empty() else Vector3.ZERO
	floor_offset = floor_normal.dot(hit.position) + .015 if not hit.is_empty() else 0.0


func _reset(pose: Transform3D) -> void:
	for i in range(points.size()):
		points[i] = pose * rest[i]
		previous[i] = points[i]
	for i in range(COLS):
		anchors[i] = points[i]
	elapsed = 0.0
	sleeping = false


func _process_modification_with_delta(delta: float) -> void:
	if not cloth or not is_visible_in_tree():
		sleeping = true
		step_usec = 0
		return
	var stamp := Time.get_ticks_usec()
	var pose := _pose()
	var camera := get_viewport().get_camera_3d()
	distant = camera != null and camera.global_position.distance_squared_to(rig.global_position) > 900.0
	if distant:
		_reset(pose)
		_upload()
		sleeping = true
		step_usec = Time.get_ticks_usec() - stamp
		return
	if sleeping or origin.distance_to(rig.global_position) > 1.5 or delta > .15:
		_reset(pose)
		floor_normal = Vector3.ZERO
		origin = rig.global_position
	travel = (rig.global_position - origin) * (STEP / maxf(delta, STEP))
	origin = rig.global_position
	time += delta
	elapsed += minf(delta, 1.0 / 30.0)
	var steps := mini(int(elapsed / STEP), 4)
	for n in range(steps):
		_integrate()
		_pin(pose, float(n + 1) / steps)
		for iteration in range(4):
			_relax()
			if iteration % 2 == 1:
				_collide()
		elapsed -= STEP
	#Keep the seam on the final aiming pose, including frames without a substep.
	for i in range(COLS):
		anchors[i] = _anchor(pose, i)
		points[i] = anchors[i]
		previous[i] = anchors[i]
	_upload()
	step_usec = Time.get_ticks_usec() - stamp


func _integrate() -> void:
	var wind := Vector3(.5 + .35 * sin(time * .9), .08, -.6 + .2 * sin(time * 1.3))
	var pts := points
	var prev := previous
	var last := pts.size() - 1
	for i in range(COLS, pts.size()):
		#Damp wrinkles relative to the wearer; air drag handles forward speed.
		var p := pts[i]
		var velocity := travel + (p - prev[i] - travel) * .982
		velocity = velocity.limit_length(.12)
		var across := pts[mini(i + 1, last)] - pts[i - 1]
		var down := p - pts[i - COLS]
		var normal := across.cross(down).normalized()
		var air := wind - velocity / STEP
		var pressure := clampf(air.dot(normal), -12, 12)
		var force := Vector3(0, -9.81, 0) + air * .35
		force += normal * pressure * absf(pressure) * .18
		prev[i] = p
		pts[i] = p + velocity + force.limit_length(35.0) * STEP * STEP


func _pin(pose: Transform3D, fraction: float) -> void:
	for i in range(COLS):
		points[i] = anchors[i].lerp(_anchor(pose, i), fraction)
		previous[i] = points[i]


func _anchor(pose: Transform3D, i: int) -> Vector3:
	var p := rest[i]
	#Gather the wider cut under the collar; the free rows form soft pleats.
	p.x *= .8
	return pose * p


#The solver loops below alias the member arrays into locals (packed arrays
#are shared by reference) — same math, a third of the lookups.
func _relax() -> void:
	var pts := points
	var la := link_a
	var lb := link_b
	var lr := link_rest
	var lk := link_k
	var lf := link_free
	for k in range(la.size()):
		var a := la[k]
		var b := lb[k]
		var diff := pts[b] - pts[a]
		var length := diff.length()
		if length < .00001:
			continue
		var correction := diff * ((length - lr[k]) / length * lk[k])
		var free := lf[k]
		if free & 1:
			pts[a] += correction
		if free & 2:
			pts[b] -= correction


func _collide() -> void:
	var pts := points
	var prev := previous
	var tethers := tether_limits
	var body_count := bodies.size()
	#Per-body terms are the same for every point: hoist them out.
	var segs := PackedVector3Array()
	var inv_len := PackedFloat32Array()
	var radii_sq := PackedFloat32Array()
	segs.resize(body_count)
	inv_len.resize(body_count)
	radii_sq.resize(body_count)
	for k in range(body_count):
		segs[k] = ends[k] - starts[k]
		inv_len[k] = 1.0 / maxf(segs[k].length_squared(), .0001)
		radii_sq[k] = radii[k] * radii[k]
	var tunic_inv := tunic_basis.transposed()
	var has_floor := floor_normal != Vector3.ZERO
	for i in range(COLS, pts.size()):
		var p := pts[i]
		for k in range(body_count):
			var segment := segs[k]
			var start := starts[k]
			var t := clampf((p - start).dot(segment) * inv_len[k], 0, 1)
			var center := start + segment * t
			var diff := p - center
			if k == 7:
				diff = tunic_inv * diff
				diff.x *= .65
			if diff.length_squared() < radii_sq[k]:
				var normal := diff.normalized()
				var surface := normal * radii[k]
				if k == 7:
					surface.x /= .65
					surface = tunic_basis * surface
					normal.x *= .65
					normal = (tunic_basis * normal).normalized()
				var velocity := p - prev[i]
				p = center + surface
				prev[i] = p - velocity.slide(normal) * .85
		#Long tethers prevent visible stretch after a fast dodge or abrupt turn.
		var top := pts[i % COLS]
		var span := p - top
		var limit := tethers[i]
		if span.length_squared() > limit * limit:
			var before := p
			p = top + span.normalized() * limit
			prev[i] += p - before
		if has_floor:
			var depth := floor_offset - p.dot(floor_normal)
			if depth > 0.0:
				var velocity := p - prev[i]
				p += floor_normal * depth
				prev[i] = p - velocity.slide(floor_normal) * .8
		pts[i] = p


func _upload() -> void:
	var local := rig.global_transform.affine_inverse()
	for j in range(ROWS):
		for i in range(COLS):
			var p := local * points[j * COLS + i]
			positions.set_pixel(i, j, Color(p.x, p.y, p.z, 1))
	texture.update(positions)
