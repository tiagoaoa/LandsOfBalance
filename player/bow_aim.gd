extends SkeletonModifier3D

var actor: Node3D
var spine: int
var chest: int
var left: int
var right: int
var aim := Quaternion.IDENTITY
var weight := 0.0


func setup(player: Node3D) -> void:
	actor = player
	var rig := get_skeleton()
	spine = rig.find_bone("mixamorig_Spine")
	chest = rig.find_bone("mixamorig_Spine2")
	left = rig.find_bone("mixamorig_LeftHand")
	right = rig.find_bone("mixamorig_RightHand")


func _process_modification_with_delta(delta: float) -> void:
	if not is_instance_valid(actor):
		return
	var drawing: bool = actor.is_archer() and not actor.is_dead and not actor.ai_driven \
			and (actor.is_drawing_bow or actor.is_holding_bow)
	var target := 1.0 if drawing else 0.0
	weight = move_toward(weight, target, delta / (.18 if drawing else .65))
	if actor.is_dead or actor.is_rolling or actor._is_stunned:
		weight = 0.0
	if weight <= 0.0:
		return
	if drawing:
		aim = _aim_rotation()
	#Share the bend between waist and chest; the hips and feet keep their stride.
	_rotate(spine, Quaternion.IDENTITY.slerp(aim, weight * .4))
	_rotate(chest, Quaternion.IDENTITY.slerp(aim, weight * .6))
	if drawing and weight >= .999:
		#Rotating the torso moves the nock: converge again for close targets.
		_rotate(chest, _aim_rotation())


func _aim_rotation() -> Quaternion:
	var rig := get_skeleton()
	var nock := rig.get_bone_global_pose(right) * Vector3(0, .06, 0)
	var grip := rig.get_bone_global_pose(left) * Vector3(0, .06, 0)
	var dir := (grip - nock).normalized()
	var from := rig.to_global(nock + dir * .465)
	var sight: Vector3 = actor._bow_aim_direction(from)
	var local := (rig.global_basis.inverse() * sight).normalized()
	return Quaternion(dir, local)


func _rotate(bone: int, turn: Quaternion) -> void:
	var rig := get_skeleton()
	var parent := rig.get_bone_parent(bone)
	var basis := rig.get_bone_global_pose(parent).basis.orthonormalized()
	var local := basis.inverse() * Basis(turn) * basis
	rig.set_bone_pose_rotation(bone,
			local.get_rotation_quaternion() * rig.get_bone_pose_rotation(bone))
