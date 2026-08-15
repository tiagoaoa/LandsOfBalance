class_name SlashTrail
extends MeshInstance3D

## Hack-and-slash swing ribbon — a world-space trail stretched between two
## points along a weapon (grip → tip) sampled every frame while `emitting`.
## Stays inside the golden rule: the trail only *shows* the arc the real
## hitbox travels, it never deals damage itself. No hitstop / screen shake —
## this plus knockback is the whole feedback channel.

var emitter: Node3D = null
var base_offset: Vector3 = Vector3.ZERO
var tip_offset: Vector3 = Vector3(0, 0, 1.0)
var color: Color = Color(1.0, 0.9, 0.55, 0.85)
var lifetime: float = 0.22
var emitting: bool = false
## Smears are air, not steel: they fade along their length as well as their
## age, so the outer edge dissolves instead of ending in a hard rim.
var is_smear: bool = false

var _points: Array[Dictionary] = []  # {b: Vector3, t: Vector3, at: float}
var _mesh: ImmediateMesh = ImmediateMesh.new()
var _time: float = 0.0


## Build a trail, parent it to `host`, and follow `emitter_node`.
static func attach(host: Node, emitter_node: Node3D, base_off: Vector3,
		tip_off: Vector3, col: Color) -> SlashTrail:
	var trail := SlashTrail.new()
	trail.emitter = emitter_node
	trail.base_offset = base_off
	trail.tip_offset = tip_off
	trail.color = col
	host.add_child(trail)
	return trail


## A wind smear: the same ribbon, but a wide soft band of displaced air rather
## than the bright edge of the blade.
##
## It rides OUTSIDE the weapon — starting partway along it and reaching past
## the tip — so it reads as air torn along by the swing instead of a second
## blade. Longer lifetime leaves a tail behind the sharp ribbon, which is what
## sells the speed; low alpha keeps it from competing with the edge.
##
## `reach` scales the span outward from the emitter's origin: 1.0 is the
## weapon itself, so the default overhangs the tip by nearly half again.
static func attach_smear(host: Node, emitter_node: Node3D, base_off: Vector3,
		tip_off: Vector3, col: Color = Color(0.82, 0.88, 1.0, 0.18),
		reach: float = 1.45) -> SlashTrail:
	var smear := SlashTrail.attach(host, emitter_node,
			base_off.lerp(tip_off, 0.3), tip_off * reach, col)
	smear.lifetime = 0.34   # trails behind the blade ribbon
	smear.is_smear = true
	return smear


## One-shot spark burst at a hit point — the "clang" of a landed swing.
static func spawn_hit_spark(host: Node, pos: Vector3, col: Color) -> void:
	var scene_root: Node = host.get_tree().current_scene
	if scene_root == null:
		return
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.explosiveness = 1.0
	p.amount = 14
	p.lifetime = 0.3
	p.direction = Vector3.UP
	p.spread = 180.0
	p.initial_velocity_min = 3.0
	p.initial_velocity_max = 6.5
	p.gravity = Vector3(0, -14.0, 0)
	p.scale_amount_min = 0.5
	p.scale_amount_max = 1.0
	var quad := QuadMesh.new()
	quad.size = Vector2(0.09, 0.09)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.albedo_color = col
	quad.material = mat
	p.mesh = quad
	scene_root.add_child(p)
	p.global_position = pos
	p.emitting = true
	p.get_tree().create_timer(0.8).timeout.connect(p.queue_free)


func _ready() -> void:
	top_level = true
	global_transform = Transform3D.IDENTITY
	mesh = _mesh
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.vertex_color_use_as_albedo = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.no_depth_test = false
	material_override = mat


func _process(delta: float) -> void:
	_time += delta
	if emitting and emitter != null and is_instance_valid(emitter) and emitter.is_inside_tree():
		var xf: Transform3D = emitter.global_transform
		_points.append({"b": xf * base_offset, "t": xf * tip_offset, "at": _time})
	while _points.size() > 0 and _time - _points[0]["at"] > lifetime:
		_points.pop_front()
	_rebuild()


func _rebuild() -> void:
	_mesh.clear_surfaces()
	if _points.size() < 2:
		return
	_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for p in _points:
		var age: float = (_time - p["at"]) / lifetime
		var fade: float = (1.0 - age) * (1.0 - age)  # quadratic tail fade
		var c := Color(color.r, color.g, color.b, color.a * fade)
		if is_smear:
			# Solid at the inner edge, dissolving at the outer one.
			_mesh.surface_set_color(c)
			_mesh.surface_add_vertex(p["b"])
			_mesh.surface_set_color(Color(c.r, c.g, c.b, 0.0))
			_mesh.surface_add_vertex(p["t"])
		else:
			_mesh.surface_set_color(c)
			_mesh.surface_add_vertex(p["b"])
			_mesh.surface_set_color(c)
			_mesh.surface_add_vertex(p["t"])
	_mesh.surface_end()
