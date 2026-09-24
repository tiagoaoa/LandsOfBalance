extends MeshInstance3D

var origin := Vector3.ZERO
var end := Vector3.UP
var max_deviation := 0.09
var _clock := 0.0
var _mesh := ImmediateMesh.new()


func _ready() -> void:
	mesh = _mesh
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = Color(0.3, 0.62, 1.0, 0.65)
	mat.emission_enabled = true
	mat.emission = Color(0.15, 0.35, 0.7)
	mat.emission_energy_multiplier = 1.5
	material_override = mat


func set_origin(pos: Vector3) -> void:
	origin = pos


func set_end(pos: Vector3) -> void:
	end = pos


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	_clock -= delta
	if _clock > 0:
		return
	_clock = 0.09
	var cam := get_viewport().get_camera_3d()
	var eye := to_local(cam.global_position) if cam else Vector3(0, 1, 5)
	_mesh.clear_surfaces()
	_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	var a := origin
	for i in range(1, 13):
		var b := origin.lerp(end, float(i) / 12.0)
		if i < 12:
			b += Vector3(randf_range(-1, 1), randf_range(-1, 1),
					randf_range(-1, 1)) * max_deviation
		_segment(a, b, eye)
		_segment(a, b, eye, .028, .12)
		if i == 4 or i == 8:
			var branch := b + Vector3(randf_range(-.45, .45), .55, randf_range(-.45, .45))
			_segment(b, branch, eye, .004, .65)
		a = b
	_mesh.surface_end()


func _segment(a: Vector3, b: Vector3, eye: Vector3, width: float = .009, alpha: float = 1.0) -> void:
	var side := (b - a).cross(eye - a).normalized() * width
	_mesh.surface_set_color(Color(1, 1, 1, alpha))
	for pos in [a - side, a + side, b + side,
			a - side, b + side, b - side]:
		_mesh.surface_add_vertex(pos)
