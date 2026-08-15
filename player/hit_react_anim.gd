class_name HitReactAnim
extends RefCounted
## Directional hit reactions for the player, composed onto the idle clip.
##
## The Paladin shipped no hit reaction at all, and the Archer's borrowed one
## is a single front-on flinch — so a blow from behind and a blow to the ribs
## looked identical, and the Paladin simply flashed and slid. What sells being
## hit is the body folding AROUND the impact, so this builds four: the torso
## curls away from wherever the blow came from and the head follows.
##
## Composed with PoseAnim, which layers character-space rotations over a base
## clip. Verified against the rigs with an isolation clip: -x leans BACK,
## +x folds FORWARD, +z rolls to the character's LEFT.

## <prefix>/ReactHit<Dir>. Dir is F/B/L/R for a hit taken from the front,
## behind, the character's left, and their right.
const DIRS: Array[String] = ["F", "B", "L", "R"]

## Short and sharp — long enough to read, short enough not to feel like a
## stun. The recovery is roughly twice the snap so it settles rather than
## springing.
const LENGTH: float = 0.45
const SNAP: float = 0.10


static func compose(anim_player: AnimationPlayer, skeleton: Skeleton3D,
		prefix: String) -> void:
	if anim_player == null or skeleton == null:
		return
	var lib_name := StringName(prefix)
	if not anim_player.has_animation_library(lib_name):
		return
	var lib: AnimationLibrary = anim_player.get_animation_library(lib_name)
	if lib == null or not lib.has_animation(&"Idle"):
		return
	var idle: Animation = lib.get_animation(&"Idle")
	if idle == null or idle.length <= 0.0:
		return

	var built: Array[String] = []
	for dir in DIRS:
		var name := StringName("ReactHit" + dir)
		if lib.has_animation(name):
			continue
		var clip: Animation = PoseAnim.compose(idle, skeleton, [
			{"t": 0.0, "pose": {}},
			{"t": SNAP, "pose": _pose(dir)},
			{"t": SNAP + 0.10, "pose": _scaled(_pose(dir), 0.45)},
			{"t": LENGTH, "pose": {}},
		], LENGTH, false)
		if clip != null:
			lib.add_animation(name, clip)
			built.append(String(name))
	if not built.is_empty():
		print("  Composed directional hit reacts for %s: %s" % [
				prefix, ", ".join(built)])


## The body curls AWAY from the blow: struck from the front, the chest caves
## back and the head snaps up; struck from the side, the spine bends over the
## opposite hip and the near shoulder drops into the hit.
static func _pose(dir: String) -> Dictionary:
	match dir:
		"F":
			return {
				"Spine": Vector3(-20, 0, 0), "Spine1": Vector3(-16, 0, 0),
				"Spine2": Vector3(-12, 0, 0), "Head": Vector3(-18, 0, 0),
				"LeftShoulder": Vector3(0, -12, 0), "RightShoulder": Vector3(0, 12, 0),
				"LeftArm": Vector3(-10, -16, 12), "RightArm": Vector3(-10, 16, -12),
				"LeftUpLeg": Vector3(9, 0, 0), "RightUpLeg": Vector3(9, 0, 0),
			}
		"B":
			return {
				"Spine": Vector3(22, 0, 0), "Spine1": Vector3(17, 0, 0),
				"Spine2": Vector3(12, 0, 0), "Head": Vector3(16, 0, 0),
				"LeftArm": Vector3(14, 0, -10), "RightArm": Vector3(14, 0, 10),
				"LeftUpLeg": Vector3(-8, 0, 0), "RightUpLeg": Vector3(-8, 0, 0),
			}
		"L":
			return {
				"Spine": Vector3(-6, 0, -22), "Spine1": Vector3(-4, 0, -17),
				"Spine2": Vector3(0, 0, -12), "Head": Vector3(-6, 8, -14),
				"LeftShoulder": Vector3(0, 0, -14),
				"LeftArm": Vector3(-8, -12, -16), "RightArm": Vector3(0, 10, 14),
				"Hips": Vector3(0, 0, 7),
			}
		_:
			return {
				"Spine": Vector3(-6, 0, 22), "Spine1": Vector3(-4, 0, 17),
				"Spine2": Vector3(0, 0, 12), "Head": Vector3(-6, -8, 14),
				"RightShoulder": Vector3(0, 0, 14),
				"RightArm": Vector3(-8, 12, 16), "LeftArm": Vector3(0, -10, -14),
				"Hips": Vector3(0, 0, -7),
			}


## Which of the four fits a blow arriving along `world_dir`, judged in the
## character's own frame so it is correct whichever way they are facing.
static func dir_for(character: Node3D, world_dir: Vector3) -> String:
	var v: Vector3 = world_dir
	v.y = 0.0
	if v.length() < 0.01:
		return "F"
	var local: Vector3 = character.global_transform.basis.inverse() * v.normalized()
	# The model faces -Z, so a blow travelling +Z came at them head on.
	if absf(local.z) >= absf(local.x):
		return "F" if local.z > 0.0 else "B"
	return "R" if local.x < 0.0 else "L"


static func _scaled(pose: Dictionary, k: float) -> Dictionary:
	var out := {}
	for bone in pose:
		out[bone] = (pose[bone] as Vector3) * k
	return out
