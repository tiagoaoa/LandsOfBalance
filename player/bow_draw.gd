extends Node3D

var actor: Node3D
var skeleton: Skeleton3D
var source: MeshInstance3D
var arrow: Node3D
var left: int
var right: int
var tips: Array[Vector3] = []
var strings: Array[MeshInstance3D] = []
var aim: SkeletonModifier3D


func setup(player: Node3D, model: Node3D) -> void:
	actor = player
	skeleton = player._find_skeleton(model)
	source = model.find_child("BowString", true, false) as MeshInstance3D
	if not source:
		set_process(false)
		return
	left = skeleton.find_bone("mixamorig_LeftHand")
	right = skeleton.find_bone("mixamorig_RightHand")
	_find_tips()
	arrow = Arrow.create_visual()
	arrow.name = "NockedArrow"
	add_child(arrow)
	_make_strings()
	aim = preload("res://player/bow_aim.gd").new()
	skeleton.add_child(aim)
	aim.setup(actor)
	#Read the final pose before Skeleton3D restores the animation's bones.
	aim.modification_processed.connect(_update_draw)
	_update_draw()


func _find_tips() -> void:
	#The imported bow lies along Z in the bind pose.
	var verts: PackedVector3Array = source.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var rest := skeleton.get_bone_global_rest(left).affine_inverse()
	var ends := [verts[0], verts[0]]
	for v in verts:
		if v.z < ends[0].z:
			ends[0] = v
		if v.z > ends[1].z:
			ends[1] = v
	for v in ends:
		tips.append(rest * skeleton.to_local(source.to_global(v)))


func _make_strings() -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.65, 0.59, 0.43)
	mat.roughness = 0.9
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.0015
	mesh.bottom_radius = 0.0015
	mesh.height = 1.0
	mesh.radial_segments = 6
	for i in range(2):
		var strand := MeshInstance3D.new()
		strand.mesh = mesh
		strand.material_override = mat
		add_child(strand)
		strings.append(strand)


func _hand_point(bone: int) -> Vector3:
	return skeleton.to_global(skeleton.get_bone_global_pose(bone) * Vector3(0, 0.06, 0))


func release_position() -> Vector3:
	if not arrow:
		return actor.global_position + Vector3(0, 1.5, 0)
	return arrow.global_position


func _update_draw() -> void:
	var drawing: bool = actor.is_archer() \
			and (actor.is_drawing_bow or actor.is_holding_bow) and not actor.is_dead
	source.visible = not drawing
	arrow.visible = drawing
	for strand in strings:
		strand.visible = drawing
	if not drawing:
		return
	var hand := skeleton.get_bone_global_pose(left)
	var nock := _hand_point(right)
	var grip := _hand_point(left)
	var dir := (grip - nock).normalized()
	arrow.global_position = nock + dir * 0.465
	arrow.look_at(arrow.global_position + dir)
	for i in range(2):
		_stretch(strings[i], skeleton.to_global(hand * tips[i]), nock)


func _stretch(strand: MeshInstance3D, a: Vector3, b: Vector3) -> void:
	strand.global_position = (a + b) * 0.5
	strand.look_at(b)
	strand.rotate_object_local(Vector3.RIGHT, PI * 0.5)
	strand.scale = Vector3(1, a.distance_to(b), 1)
