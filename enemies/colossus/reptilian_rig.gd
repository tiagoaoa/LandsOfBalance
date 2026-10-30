## Combat pivots and skin poses for the reptilian boss bodies. Both share the
## 21-bone combat skeleton; what differs is the mesh and a few head-local
## points the fight needs (muzzle lock, skull underside, nostrils, mouth).
class_name ReptilianRig
extends RefCounted

## "titan": the Hunyuan3D-2mv lizard titan, helmeted and muzzled
## (tools/art/build_titan.py, titan_helmet.py, titan_export.py). "rex": the
## supplied alien body with the forged T-rex skull. LOB_BOSS_BODY picks.
## Head-local points are in the head pivot's frame (+Z snout, +Y up, model
## units); the rex jaw was modelled 30 degrees open, the titan's shut.
const BODIES := {
	"titan": {
		"path": "res://assets/characters/reptilian/titan_arena.glb",
		"palms_inward": true,
		"jaw_closed": 0.0,
		"head_hull_radius": 3.4,
		"hand_hull_keep": 0.7,
		"windup_lift": 5.0,
		# Shoulder top 4.9 over the joint (measured upright), turned by the hunch.
		"pad_offset": Vector3(0.8, 4.16, 2.60),
		# Measured upright in tools/art/source/lizard_titan.blend, then turned
		# by the hunch tools/art/titan_export.py bakes in (HUNCH_DEG = 32).
		"mouth": Vector3(0.00, -3.40, 3.18),
		"head_center": Vector3(0.00, -0.54, 2.37),
		"nostrils": [Vector3(-0.50, -2.97, 3.81), Vector3(0.50, -2.97, 3.81)],
		"contact": Vector3(0.00, -5.36, 0.84),
		"underside": [Vector3(0.00, -5.36, 0.84), Vector3(0.00, -4.26, 0.87), Vector3(0.00, -4.84, 1.81), Vector3(0.00, -3.18, 0.37), Vector3(-1.20, -3.54, 1.33), Vector3(1.20, -3.54, 1.33), Vector3(0.00, -4.42, 2.54)],
	},
	# The TRELLIS.2 generation of the same titan (TITAN_GEN=trellis through
	# the same three scripts): sharper hide, bigger blunter head. Same hunch,
	# same head bone; points measured in lizard_titan_trellis.blend.
	"trellis": {
		"path": "res://assets/characters/reptilian/titan_trellis_arena.glb",
		"palms_inward": true,
		"jaw_closed": 0.0,
		# Skull centre to snout tip, chin and crown is ~3 m; the horn roots
		# start just past it.
		"head_hull_radius": 3.1,
		"hand_hull_keep": 1.0,
		"hand_hull_weight": 0.95,
		"windup_lift": 5.0,
		# On the mane, 5.4 over the joint: at the Hunyuan titan's 4.9 the
		# front seat was all spikes and a rider mounting there was thrown off.
		"pad_offset": Vector3(0.8, 4.58, 2.86),
		"mouth": Vector3(0.00, -3.58, 3.66),
		"head_center": Vector3(0.00, -0.77, 2.94),
		"nostrils": [Vector3(-0.50, -3.00, 4.43), Vector3(0.50, -3.00, 4.43)],
		"contact": Vector3(0.00, -5.44, 1.97),
		"underside": [Vector3(0.00, -5.44, 1.97), Vector3(0.00, -4.15, 1.90), Vector3(0.00, -3.19, 0.95), Vector3(0.00, -2.83, -0.37), Vector3(-1.00, -2.20, -0.64), Vector3(1.00, -2.20, -0.64)],
	},
	"rex": {
		"path": "res://assets/characters/reptilian/reptilian_arena.glb",
		"jaw_closed": -30.0,
		"mouth": Vector3(0.0, -1.6, 9.6),
		"head_center": Vector3(0.0, 0.4, 4.3),
		"nostrils": [Vector3(-1.7, 0.65, 8.45), Vector3(1.7, 0.65, 8.45)],
		"contact": Vector3(0.0, -4.7, 6.6),
		"underside": [Vector3(0.0, -4.7, 6.6), Vector3(0.0, -3.4, 8.1), Vector3(0.0, -3.2, 5.0),
				Vector3(-1.6, -2.8, 6.5), Vector3(1.6, -2.8, 6.5), Vector3(-1.4, -2.6, 8.8),
				Vector3(1.4, -2.6, 8.8)],
	},
}


static func body_name() -> String:
	var want := OS.get_environment("LOB_BOSS_BODY")
	if BODIES.has(want) and ResourceLoader.exists(String(BODIES[want].path)):
		return want
	return "titan" if ResourceLoader.exists(String(BODIES.titan.path)) else "rex"


static func path() -> String:
	return String(BODIES[body_name()].path)


var spec: Dictionary = BODIES[body_name()]

var boss: Node3D
var model: Node3D
var skel: Skeleton3D
var skel_local := Transform3D.IDENTITY
var torso: Node3D
var head: Node3D
var jaw: Node3D
var mouth: Node3D
var focus: Node3D
var tail: Node3D
var ua: Array[Node3D] = [null, null]
var fa: Array[Node3D] = [null, null]
var hand: Array[Node3D] = [null, null]
var head_center: Vector3 = spec.head_center
var _idx := {}
var _rest := {}
var _off := {}
var _t := 0.0
var pose_serial := 0


func build(b: Node3D) -> bool:
	boss = b
	model = (load(path()) as PackedScene).instantiate()
	boss.add_child(model)
	var found := model.find_children("*", "Skeleton3D", true, false)
	if found.is_empty():
		push_error("Reptilian model has no combat skeleton")
		model.queue_free()
		return false
	skel = found[0]
	var n: Node3D = skel
	while n != boss:
		skel_local = n.transform * skel_local
		n = n.get_parent() as Node3D
	for i in skel.get_bone_count():
		var bn := skel.get_bone_name(i)
		_idx[bn] = i
		_rest[bn] = skel_local * skel.get_bone_global_rest(i)
	_build_pivots()
	for mi: MeshInstance3D in model.find_children("*", "MeshInstance3D", true, false):
		mi.extra_cull_margin = 24.0
		for s in mi.mesh.get_surface_count():
			var mat := mi.mesh.surface_get_material(s).duplicate() as StandardMaterial3D
			if mat.resource_name == "Reptilian_DarkScales":
				mat.normal_scale = 0.22
				mat.roughness = 0.95
				mat.albedo_color = Color(0.8, 0.82, 0.9)
				mat.uv1_scale = Vector3(2.5, 2.5, 1)
			elif mat.resource_name == "Rex_Old_Ivory":
				mat.albedo_color = Color(0.58, 0.49, 0.37)
			elif mat.resource_name == "Rex_Amber":
				# Embers behind the helmet slits: the one thing on him that
				# still shows when every brazier on the platform is out.
				mat.emission_enabled = true
				mat.emission = Color(1.0, 0.42, 0.08)
				mat.emission_energy_multiplier = 2.2
			mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
			mi.set_surface_override_material(s, mat)
	return true


func rest_pos(bone: String) -> Vector3:
	return (_rest[bone] as Transform3D).origin


func _pivot(parent: Node3D, name: String, at: Vector3) -> Node3D:
	var p := Node3D.new()
	p.name = name
	p.position = at
	parent.add_child(p)
	return p


func _build_pivots() -> void:
	torso = _pivot(boss, "ReptilianTorso", Vector3.ZERO)
	head = _pivot(torso, "ReptilianHead", rest_pos("head"))
	jaw = _pivot(head, "ReptilianJaw", rest_pos("jaw") - head.position)
	# Between the shut lips, behind the muzzle; follows the skull as it aims.
	mouth = _pivot(head, "Mouth", spec.mouth)
	focus = _pivot(torso, "TorsoFocus", rest_pos("chest"))
	tail = _pivot(torso, "ReptilianTail", rest_pos("tail1"))
	for i in 2:
		var s := ".L" if i == 0 else ".R"
		var shoulder := rest_pos("upperarm" + s)
		var elbow := rest_pos("forearm" + s)
		var wrist := rest_pos("hand" + s)
		ua[i] = _pivot(torso, "UpperArm" + s, shoulder)
		fa[i] = _pivot(ua[i], "Forearm" + s, Vector3(0, -shoulder.distance_to(elbow), 0))
		hand[i] = _pivot(fa[i], "Hand" + s, Vector3(0, -elbow.distance_to(wrist), 0))
		var pole: Vector3 = boss.call("_arm_pole", i, Basis.IDENTITY)
		var ub: Basis = boss.call("_along", (elbow - shoulder).normalized(), pole)
		var fb: Basis = boss.call("_along", (wrist - elbow).normalized(), pole)
		var y: Vector3 = -(_rest["hand" + s] as Transform3D).basis.y.normalized()
		var z := -(Vector3.UP - y * y.dot(Vector3.UP)).normalized()
		#The titans' hanging palms face inward in the source mesh. Turn the
		#rest frame before binding offsets: +Z is the animated palm normal.
		if spec.get("palms_inward", false):
			var palm := Vector3.RIGHT if i == 0 else Vector3.LEFT
			z = (palm - y * palm.dot(y)).normalized()
		var hb := Basis(y.cross(z).normalized(), y, z)
		ua[i].basis = ub
		fa[i].basis = ub.inverse() * fb
		hand[i].basis = fb.inverse() * hb
		for pair in [["upperarm" + s, ua[i]], ["forearm" + s, fa[i]], ["hand" + s, hand[i]]]:
			_off[pair[0]] = _local(pair[1]).affine_inverse() * _rest[pair[0]]
	_off["head"] = _local(head).affine_inverse() * _rest["head"]
	_off["jaw"] = _local(jaw).affine_inverse() * _rest["jaw"]
	jaw.rotation.x = deg_to_rad(float(spec.jaw_closed))
	# A far punch lengthens the upper arm and forearm along their bones. A
	# skeleton keeps local poses as position/rotation/scale, so the child of
	# a stretched bone, bent at the joint, would need shear and came back
	# skewed: the claw itself warped and its terrain hull sank into the stone.
	# Every arm bone is driven in skeleton space anyway, so the forearm and
	# hand stand on their own instead of inheriting.
	for i in 2:
		var s := ".L" if i == 0 else ".R"
		for bn: String in ["forearm" + s, "hand" + s]:
			var at := skel.get_bone_global_rest(_idx[bn])
			skel.set_bone_parent(_idx[bn], -1)
			skel.set_bone_rest(_idx[bn], at)
			skel.reset_bone_pose(_idx[bn])


func _local(p: Node3D) -> Transform3D:
	return boss.global_transform.affine_inverse() * p.global_transform


func _pose(bone: String, t: Transform3D) -> void:
	skel.set_bone_global_pose(_idx[bone], skel_local.affine_inverse() * t)


func drive(delta: float) -> void:
	pose_serial += 1
	_t += delta
	var t := _local(torso)
	for bn: String in ["pelvis", "spine", "chest"]:
		var k := 0.35 if bn == "pelvis" else (0.65 if bn == "spine" else 1.0)
		var d := Transform3D.IDENTITY.interpolate_with(t, k)
		_pose(bn, d * _rest[bn])
	for i in 2:
		var s := ".L" if i == 0 else ".R"
		# A far punch uncoils the arm: lengthen each segment along its pivot's
		# -Y (the bone direction), never the claw.
		# Stretched along each bone's own +Y (its length), never sheared.
		var seg: Vector2 = boss.call("segment_stretch", i)
		var su := Transform3D(Basis.from_scale(Vector3(1.0, seg.x, 1.0)), Vector3.ZERO)
		var sf := Transform3D(Basis.from_scale(Vector3(1.0, seg.y, 1.0)), Vector3.ZERO)
		_pose("upperarm" + s, _local(ua[i]) * _off["upperarm" + s] * su)
		_pose("forearm" + s, _local(fa[i]) * _off["forearm" + s] * sf)
		_pose("hand" + s, _local(hand[i]) * _off["hand" + s])
	var h: Transform3D = _local(head) * _off["head"]
	var hd: Transform3D = h * (_rest["head"] as Transform3D).affine_inverse()
	_pose("neck", t.interpolate_with(hd, 0.5) * _rest["neck"])
	_pose("head", h)
	_pose("jaw", _local(jaw) * _off["jaw"])
	for i in 3:
		var bn := "tail%d" % (i + 1)
		var sway := Basis(Vector3.UP, sin(_t * 0.75 - i * 0.5) * 0.035 * (i + 1))
		_pose(bn, t.interpolate_with(Transform3D.IDENTITY, 0.6) * Transform3D(sway, Vector3.ZERO) * _rest[bn])
