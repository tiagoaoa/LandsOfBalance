## The skinned wyvern behind ColossusBoss's dragon mode.
##
## The boss still thinks in rigid pivots (torso, upper arm, forearm, hand,
## head, jaw, tail): its IK, hitboxes, riders and every telegraph promise run
## on those, unchanged. This builds those pivots FROM the dragon's skeleton
## (so the arm lengths the IK uses are the bones' own) and then, every frame,
## drives the bones from them:
## - pivot bones (chest, wing-arms, head, jaw) copy their pivot exactly, so
##   what you see is what hits you;
## - the spine shares the torso's lean down to the hips;
## - the neck is a curve from the shoulders into the skull, so the head can
##   go anywhere and the neck follows like a neck, not a stick;
## - the tail is a sprung rope behind the tail pivot: it lags, whips and
##   settles (follow-through), and sways when idle;
## - the wing fingers fold along the forearm when the dragon walks on its
##   wrists and flare open when it rears, roars or staggers.
class_name DragonRig
extends RefCounted

const PATH := "res://assets/characters/dragon/dragon.glb"

var boss: Node3D
var model: Node3D
var skel: Skeleton3D
var skel_local := Transform3D.IDENTITY   # skeleton space -> boss local
var _idx := {}
var _rest := {}           # bone name -> rest transform, boss local

# pivots handed to the boss
var torso: Node3D
var head: Node3D
var jaw: Node3D
var eye: Node3D
var core: Node3D
var tail: Node3D
var neck: Node3D
var ua: Array[Node3D] = [null, null]
var fa: Array[Node3D] = [null, null]
var hand: Array[Node3D] = [null, null]

const SKIN := preload("res://enemies/colossus/dragon_skin.gdshader")
const MEMBRANE := preload("res://enemies/colossus/dragon_membrane.gdshader")

var eye_mat: StandardMaterial3D
var skin_mats: Array[ShaderMaterial] = []
var core_mat: StandardMaterial3D
var ember_mats: Array[StandardMaterial3D] = []
## Skull centre in the head pivot's frame (for head_pos()).
var head_center := Vector3.ZERO

var _off := {}             # bone -> pivot-relative offset
var _head_rest := Transform3D.IDENTITY
var _neck_in := Vector3.ZERO   # direction the neck enters the skull, head frame
var _neck_bones: Array[String] = []
var _neck_len: Array[float] = []
var _tail_bones: Array[String] = []
var _tail_len: Array[float] = []
var _tail_pts: Array[Vector3] = []
var _tail_vel: Array[Vector3] = []
var _tail_tip_rest := Vector3.ZERO    # tail tip, tail-pivot frame
var _tail_rest := Transform3D.IDENTITY
var _fold: Array[float] = [0.9, 0.9]
var _t := 0.0


static func available() -> bool:
	return ResourceLoader.exists(PATH)


func build(b: Node3D) -> bool:
	boss = b
	var scene := load(PATH) as PackedScene
	if scene == null:
		return false
	model = scene.instantiate() as Node3D
	boss.add_child(model)
	var found := model.find_children("*", "Skeleton3D", true, false)
	if found.is_empty():
		return false
	skel = found[0] as Skeleton3D
	var t := Transform3D.IDENTITY
	var n: Node = skel
	while n != boss:
		t = (n as Node3D).transform * t
		n = n.get_parent()
	skel_local = t
	for i in skel.get_bone_count():
		_idx[skel.get_bone_name(i)] = i
		_rest[skel.get_bone_name(i)] = skel_local * skel.get_bone_global_rest(i)
	for mi in model.find_children("*", "MeshInstance3D", true, false):
		# Skinned far from its rest pose: never let the renderer cull it.
		(mi as MeshInstance3D).extra_cull_margin = 16.0
	_build_pivots()
	_materials()
	return true


func has(bone: String) -> bool:
	return _idx.has(bone)


func rest_pos(bone: String) -> Vector3:
	return (_rest[bone] as Transform3D).origin


func _pivot(parent: Node3D, n: String, at: Vector3) -> Node3D:
	var p := Node3D.new()
	p.name = n
	p.position = at
	parent.add_child(p)
	return p


func _build_pivots() -> void:
	torso = _pivot(boss, "Colossus_Torso", Vector3.ZERO)
	var up := Vector3.UP
	for i in 2:
		var s := "L" if i == 0 else "R"
		var shoulder := rest_pos("upperarm." + s)
		var elbow := rest_pos("forearm." + s)
		var wrist := rest_pos("hand." + s)
		var fist := rest_pos("fist." + s)
		ua[i] = _pivot(torso, "Colossus_UpperArm_" + s, shoulder)
		fa[i] = _pivot(ua[i], "Colossus_Forearm_" + s, Vector3(0, -(elbow - shoulder).length(), 0))
		hand[i] = _pivot(fa[i], "Colossus_Hand_" + s, Vector3(0, -(wrist - elbow).length(), 0))
		var pole: Vector3 = boss.call("_arm_pole", i, Basis.IDENTITY)
		var ub: Basis = boss.call("_along", (elbow - shoulder).normalized(), pole)
		var fb: Basis = boss.call("_along", (wrist - elbow).normalized(), pole)
		# The fist: local -Y along the thumb claw, -Z the back of the wrist.
		var y := -(fist - wrist).normalized()
		var z := -(up - y * up.dot(y)).normalized()
		var hb := Basis(y.cross(z).normalized(), y, z).orthonormalized()
		ua[i].basis = ub
		fa[i].basis = ub.inverse() * fb
		hand[i].basis = fb.inverse() * hb
	# Head pivot: +Z down the skull to the snout, +Y up the head.
	var hpos := rest_pos("head")
	var hz := (rest_pos("snout") - hpos).normalized()
	var hx := up.cross(hz).normalized()
	head = _pivot(torso, "Colossus_Head", hpos)
	head.basis = Basis(hx, hz.cross(hx).normalized(), hz)
	_head_rest = head.transform
	head_center = head.basis.inverse() * ((rest_pos("snout") - hpos) * 0.45)
	jaw = _pivot(head, "Colossus_Jaw", head.basis.inverse() * (rest_pos("jaw") - hpos))
	eye = _pivot(head, "Colossus_Eye", head.basis.inverse() * (rest_pos("mouth") - hpos))
	core = _pivot(torso, "Colossus_Core", rest_pos("core"))
	neck = _pivot(torso, "Colossus_Neck", rest_pos("neck2"))
	var tb := rest_pos("tail1")
	tail = _pivot(torso, "Colossus_Tail", tb)
	var tdir := (rest_pos("tailtip") - tb).normalized()
	tail.basis = boss.call("_along", tdir, Vector3.RIGHT)
	_tail_rest = tail.transform
	_tail_tip_rest = tail.basis.inverse() * (rest_pos("tailtip") - tb)
	# Offsets: bone rest in its pivot's rest frame.
	for i in 2:
		var s := "L" if i == 0 else "R"
		_off["upperarm." + s] = _local(ua[i]).affine_inverse() * _rest["upperarm." + s]
		_off["forearm." + s] = _local(fa[i]).affine_inverse() * _rest["forearm." + s]
		_off["hand." + s] = _local(hand[i]).affine_inverse() * _rest["hand." + s]
	_off["head"] = _local(head).affine_inverse() * _rest["head"]
	_off["jaw"] = _local(jaw).affine_inverse() * _rest["jaw"]
	for k in range(1, 10):
		if has("neck%d" % k):
			_neck_bones.append("neck%d" % k)
	for k in _neck_bones.size():
		var a := rest_pos(_neck_bones[k])
		var b2 := rest_pos(_neck_bones[k + 1]) if k + 1 < _neck_bones.size() else rest_pos("head")
		_neck_len.append(a.distance_to(b2))
	_neck_in = head.basis.inverse() * (rest_pos("head") - rest_pos(_neck_bones[-1])).normalized()
	for k in range(1, 20):
		if has("tail%d" % k):
			_tail_bones.append("tail%d" % k)
	for k in _tail_bones.size():
		var a := rest_pos(_tail_bones[k])
		var b2 := rest_pos(_tail_bones[k + 1]) if k + 1 < _tail_bones.size() else rest_pos("tailtip")
		_tail_len.append(a.distance_to(b2))
		_tail_pts.append(a)
		_tail_vel.append(Vector3.ZERO)
	_tail_pts.append(rest_pos("tailtip"))
	_tail_vel.append(Vector3.ZERO)


## A pivot's transform in boss-local space (the boss root carries the scale).
func _local(p: Node3D) -> Transform3D:
	var t := p.transform
	var n := p.get_parent()
	while n != boss:
		t = (n as Node3D).transform * t
		n = n.get_parent()
	# Pivot bases are scaled by sz in the IK; boss local is unscaled.
	return Transform3D(t.basis.orthonormalized(), t.origin)


func _pose(bone: String, boss_local: Transform3D) -> void:
	skel.set_bone_global_pose(_idx[bone], skel_local.affine_inverse() * boss_local)


func _materials() -> void:
	for mi in model.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		for s in m.mesh.get_surface_count():
			var src := m.mesh.surface_get_material(s) as StandardMaterial3D
			if src == null:
				continue
			var mat := src.duplicate() as StandardMaterial3D
			var name := String(src.resource_name)
			mat.texture_repeat = true
			if name in ["Dragon_Hide", "Dragon_Belly"]:
				var sm := ShaderMaterial.new()
				sm.shader = SKIN
				sm.set_shader_parameter("albedo_tex", src.albedo_texture)
				sm.set_shader_parameter("seam_tex", src.albedo_texture)
				sm.set_shader_parameter("normal_tex", src.normal_texture)
				if src.roughness_texture:
					sm.set_shader_parameter("rough_tex", src.roughness_texture)
					sm.set_shader_parameter("has_rough", true)
				sm.set_shader_parameter("rough_base", 0.55 if name == "Dragon_Belly" else 0.6)
				skin_mats.append(sm)
				m.set_surface_override_material(s, sm)
				continue
			if name == "Dragon_Horn":
				mat.vertex_color_use_as_albedo = true
				mat.vertex_color_is_srgb = true
				# Moonlight catching the scales on the silhouette.
				mat.rim_enabled = true
				mat.rim = 0.35
				mat.rim_tint = 0.6
				mat.normal_scale = 1.2
				mat.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX
			elif name == "Dragon_Membrane":
				var wm := ShaderMaterial.new()
				wm.shader = MEMBRANE
				wm.set_shader_parameter("albedo_tex", src.albedo_texture)
				wm.set_shader_parameter("normal_tex", src.normal_texture)
				m.set_surface_override_material(s, wm)
				continue
			elif name.begins_with("Colossus_Eye"):
				mat.emission_enabled = true
				# Amber, lit from within but not a lamp: the slit must read.
				mat.albedo_color = Color(0.9, 0.55, 0.1)
				mat.emission = Color(1.0, 0.5, 0.08)
				mat.emission_energy_multiplier = 0.8
				mat.roughness = 0.05
				mat.clearcoat_enabled = true
				eye_mat = mat
			elif name.begins_with("Dragon_Core"):
				# Fire seen through the seams of the chest scutes.
				mat.albedo_texture = load("res://assets/characters/dragon/dragon_core_albedo.png")
				mat.albedo_color = Color.WHITE
				mat.emission_enabled = true
				mat.emission = Color(1.0, 0.45, 0.12)
				mat.emission_texture = load("res://assets/characters/dragon/dragon_core_emit.png")
				mat.emission_energy_multiplier = 0.7
				mat.roughness = 0.5
				core_mat = mat
			elif name.begins_with("Colossus_Ember"):
				mat.emission_enabled = true
				mat.emission = Color(1.0, 0.32, 0.05)
				mat.emission_energy_multiplier = 0.5
				# One per wrist, in L, R order (by mesh name).
				if String(m.name).ends_with("R") or String(m.get_parent().name).ends_with("R"):
					ember_mats.resize(2)
					ember_mats[1] = mat
				else:
					if ember_mats.is_empty():
						ember_mats.append(mat)
					else:
						ember_mats[0] = mat
			m.set_surface_override_material(s, mat)


## Fire through the scale seams: chest (core), throat (breath), wrists.
func set_glow(core_k: float, throat_k: float, ember_l: float, ember_r: float) -> void:
	for sm in skin_mats:
		sm.set_shader_parameter("core_glow", core_k)
		sm.set_shader_parameter("throat_glow", throat_k)
		sm.set_shader_parameter("ember_l", ember_l)
		sm.set_shader_parameter("ember_r", ember_r)


# =================================================================== drive ===

## Called by the boss after its pivots are posed for the frame.
func drive(delta: float, lean: float, sink: float, fold_goal: Array) -> void:
	_t += delta
	var sz: float = boss.get("sz")
	var down := Vector3(0, -sink / sz, 0)
	var spine := {"pelvis": 0.35, "spine1": 0.55, "spine2": 0.8, "chest": 1.0}
	for bn: String in spine:
		var k: float = spine[bn]
		_pose(bn, Transform3D(Basis(Vector3.RIGHT, lean * k), down) * _rest[bn])
	var chest_d := Basis(Vector3.RIGHT, lean)
	for i in 2:
		var s := "L" if i == 0 else "R"
		_pose("upperarm." + s, _local(ua[i]) * _off["upperarm." + s])
		_pose("forearm." + s, _local(fa[i]) * _off["forearm." + s])
		var hb: Transform3D = _local(hand[i]) * _off["hand." + s]
		_pose("hand." + s, hb)
		_fold[i] = lerpf(_fold[i], fold_goal[i], 1.0 - exp(-3.5 * delta))
		_drive_fingers(i, hb)
	var hl := _local(head)
	_drive_neck(chest_d, down, hl)
	_pose("head", hl * _off["head"])
	_pose("jaw", _local(jaw) * _off["jaw"])
	_drive_tail(delta, lean, down)


## Bezier from the base of the neck (riding the chest) into the skull.
func _drive_neck(chest_d: Basis, down: Vector3, hl: Transform3D) -> void:
	var n := _neck_bones.size()
	var base := chest_d * rest_pos(_neck_bones[0]) + down
	var t0 := (chest_d * (rest_pos(_neck_bones[1]) - rest_pos(_neck_bones[0]))).normalized()
	var end := hl.origin
	var t1 := (hl.basis * _neck_in).normalized()
	var total := 0.0
	for l in _neck_len:
		total += l
	var reach := base.distance_to(end)
	var c1 := base + t0 * maxf(total, reach) * 0.38
	var c2 := end - t1 * maxf(total, reach) * 0.38
	# arc-length table
	var samples: Array[Vector3] = []
	var cum: Array[float] = [0.0]
	for k in 25:
		var u := k / 24.0
		var p := base.bezier_interpolate(c1, c2, end, u)
		if k > 0:
			cum.append(cum[-1] + p.distance_to(samples[-1]))
		samples.append(p)
	var pts: Array[Vector3] = [base]
	var acc := 0.0
	for k in n:
		acc += _neck_len[k]
		pts.append(_along_table(samples, cum, acc / total * cum[-1]))
	var q0 := Quaternion(chest_d)
	var q1 := Quaternion(hl.basis * _head_rest.basis.inverse())
	for k in n:
		var bn := _neck_bones[k]
		var q := q0.slerp(q1, (k + 0.5) / n)
		var r: Transform3D = _rest[bn]
		var rest_dir := (rest_pos(_neck_bones[k + 1]) if k + 1 < n else rest_pos("head")) - r.origin
		var cur := Basis(q) * rest_dir
		var want := pts[k + 1] - pts[k]
		var b := Basis(_arc(cur, want)) * Basis(q) * r.basis
		_pose(bn, Transform3D(b, pts[k]))


func _along_table(samples: Array[Vector3], cum: Array[float], d: float) -> Vector3:
	for k in range(1, cum.size()):
		if cum[k] >= d:
			var seg := maxf(cum[k] - cum[k - 1], 1e-6)
			return samples[k - 1].lerp(samples[k], (d - cum[k - 1]) / seg)
	return samples[-1]


func _arc(a: Vector3, b: Vector3) -> Quaternion:
	var an := a.normalized()
	var bn := b.normalized()
	if an.dot(bn) > 0.99999:
		return Quaternion.IDENTITY
	if an.dot(bn) < -0.9999:
		return Quaternion(an.cross(Vector3.UP).normalized(), PI)
	return Quaternion(an, bn)


## The tail: the pivot says where the tip should be (rest, or raking the
## platform); a curve says how the tail gets there; springs that loosen
## toward the tip make it lag, whip and settle.
func _drive_tail(delta: float, lean: float, down: Vector3) -> void:
	var pel := Basis(Vector3.RIGHT, lean * 0.35)
	var base := pel * rest_pos(_tail_bones[0]) + down
	var t0 := (pel * (rest_pos(_tail_bones[1]) - rest_pos(_tail_bones[0]))).normalized()
	var tl := _local(tail)
	var tip := tl.origin + tl.basis * _tail_tip_rest
	var total := 0.0
	for l in _tail_len:
		total += l
	var sway := Vector3(sin(_t * 0.6) * 1.6, 0.0, cos(_t * 0.43) * 0.8)
	var c1 := base + t0 * total * 0.35
	var c2 := tip + (base - tip).normalized() * total * 0.25 + Vector3(0, -total * 0.15, 0)
	var n := _tail_bones.size()
	var acc := 0.0
	_tail_pts[0] = base
	var dt := minf(delta, 1.0 / 30.0)
	for k in range(1, n + 1):
		acc += _tail_len[k - 1]
		var u := acc / total
		var goal := base.bezier_interpolate(c1, c2, tip, u) + sway * u * u
		var w := lerpf(26.0, 5.5, u)
		var zeta := lerpf(1.0, 0.45, u)
		var x := _tail_pts[k]
		var v := _tail_vel[k]
		v += ((goal - x) * w * w - v * 2.0 * zeta * w) * dt
		x += v * dt
		_tail_pts[k] = x
		_tail_vel[k] = v
	# keep the bones their own length, base outward
	for k in range(1, n + 1):
		var d := _tail_pts[k] - _tail_pts[k - 1]
		var fixed := _tail_pts[k - 1] + d.normalized() * _tail_len[k - 1] if d.length() > 1e-4 \
				else _tail_pts[k - 1] + t0 * _tail_len[k - 1]
		_tail_vel[k] += (fixed - _tail_pts[k]) / maxf(dt, 1e-4) * 0.2
		_tail_pts[k] = fixed
	var q := Quaternion(pel)
	for k in n:
		var bn := _tail_bones[k]
		var r: Transform3D = _rest[bn]
		var rest_dir := (rest_pos(_tail_bones[k + 1]) if k + 1 < n else rest_pos("tailtip")) - r.origin
		var cur := Basis(q) * rest_dir
		var b := Basis(_arc(cur, _tail_pts[k + 1] - _tail_pts[k])) * Basis(q) * r.basis
		_pose(bn, Transform3D(b, _tail_pts[k]))


## Wing fingers between their spread rest and folded along the forearm,
## tips standing up past the elbow the way a perched wyvern carries them.
func _drive_fingers(i: int, hb: Transform3D) -> void:
	var s := "L" if i == 0 else "R"
	var side := -1.0 if i == 0 else 1.0
	var hr: Transform3D = _rest["hand." + s]
	var to_cur := hb * hr.affine_inverse()      # rest -> now, rigid with the hand
	var wrist := hb.origin
	var elbow := _local(fa[i]).origin
	var back := (elbow - wrist).normalized()
	var up := (Vector3.UP - back * Vector3.UP.dot(back)).normalized()
	# back x up points right for both arms: outward is +side
	var out := (back.cross(up) * side).normalized()
	# Laid back along the outside of the forearm, the longest finger rising
	# past the elbow: the folded wing reads as a cloak, not a fan of sticks.
	# Close together, a cloak not a fan: spread wide they read as stone slabs.
	var folds := [back * 0.85 + up * 0.42 + out * 0.14, back * 0.95 + up * 0.3 + out * 0.2,
			back * 0.95 + up * 0.16 + out * 0.26]
	var f := _fold[i]
	for k in 3:
		var a := "f%da.%s" % [k + 1, s]
		var b := "f%db.%s" % [k + 1, s]
		var t := "f%dt.%s" % [k + 1, s]
		if not has(a):
			continue
		var ra: Transform3D = to_cur * _rest[a]
		var rb: Transform3D = to_cur * _rest[b]
		var len_a := rest_pos(a).distance_to(rest_pos(b))
		var spread_a := (rb.origin - ra.origin).normalized()
		var fold_a: Vector3 = (folds[k] as Vector3).normalized()
		var dir_a := spread_a.slerp(fold_a, f)
		var qa := _arc(spread_a, dir_a)
		_pose(a, Transform3D(Basis(qa) * ra.basis, ra.origin))
		var knuckle := ra.origin + dir_a * len_a
		var spread_b := (to_cur * rest_pos(t) - rb.origin).normalized()
		var fold_b := (fold_a - up * 0.3 + out * 0.15).normalized()
		var dir_b := (Basis(qa) * spread_b).slerp(fold_b, f)
		var qb := _arc(spread_b, dir_b)
		_pose(b, Transform3D(Basis(qb) * rb.basis, knuckle))
