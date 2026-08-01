class_name GearLoadout
extends RefCounted
## Hangs the new grim-Nordic gear off the existing mixamorig skeletons.
##
## The gear is NOT skinned. Each piece is a rigid mesh on a BoneAttachment3D,
## so it inherits whatever the bone is doing — which means every one of the
## seventy-odd animation clips carries the new gear for free, with nothing
## to re-rig and no risk of breaking a deform that already works.
##
## Pieces that replace shipped geometry (the Paladin's sword and shield, the
## Archer's bow) hide the original mesh instead of removing it, so a bad
## offset shows up as two swords rather than none.
##
## Offsets are in CHARACTER space and are the whole tuning surface: `pos` in
## metres, `rot` in degrees, both relative to the character's own upright
## frame rather than the bone's. Every attach bone's rest basis has Y on
## world up with only a small yaw, so "0,0,0" means upright and forward on
## every piece; see _attach for how that is solved back into bone space.
##
## Run `tools/run_combat_scenario.sh GEARSIM` for a turntable of all three
## loadouts plus a log of where each piece landed.

const GEAR_DIR := "res://assets/gear/"

## piece -> {file, bone, pos, rot, scale, hides}
## `hides` is a substring match against MeshInstance3D names on the
## character; the shipped mesh stays in the tree, just invisible.
const PALADIN_GEAR: Array[Dictionary] = [
	{
		"name": "Greathelm", "file": "greathelm", "bone": "mixamorig_Head",
		"pos": Vector3(0.0, -0.01, 0.012), "rot": Vector3(0, 0, 0),
		"scale": 0.76, "hides": "",
	},
	{
		"name": "Greatsword", "file": "greatsword", "bone": "mixamorig_Sword_joint",
		"pos": Vector3(0.0, 0.0, 0.0), "rot": Vector3(0, 0, 0),
		"scale": 1.0, "hides": "_Sword",
	},
	{
		"name": "NorseShield", "file": "norse_shield", "bone": "mixamorig_Shield_joint",
		"pos": Vector3(0.0, 0.06, 0.0), "rot": Vector3(0, 0, 0),
		"scale": 1.0, "hides": "_Shield",
	},
	{
		"name": "Scabbard", "file": "scabbard", "bone": "mixamorig_Hips",
		"pos": Vector3(0.14, 0.0, -0.04), "rot": Vector3(0, 0, -18),
		"scale": 0.68, "hides": "",
	},
]

const ARCHER_GEAR: Array[Dictionary] = [
	{
		"name": "RangerHood", "file": "ranger_hood", "bone": "mixamorig_Head",
		"pos": Vector3(0.0, 0.02, -0.01), "rot": Vector3(0, 0, 0),
		"scale": 1.0, "hides": "",
	},
	{
		"name": "Longbow", "file": "longbow", "bone": "mixamorig_Left_arch1",
		"pos": Vector3(0.0, 0.0, 0.0), "rot": Vector3(0, 0, 0),
		"scale": 1.0, "hides": "_Bow_Mesh",
	},
	{
		"name": "Quiver", "file": "quiver", "bone": "mixamorig_Spine2",
		"pos": Vector3(-0.10, 0.06, -0.14), "rot": Vector3(-20, 0, 25),
		"scale": 1.0, "hides": "",
	},
]

## The estus system has had charges, a heal, a drink clip and an interrupt
## rule since long before it had a flask. Both classes carry one on the hip.
const FLASK_GEAR: Dictionary = {
	"name": "EstusFlask", "file": "estus_flask", "bone": "mixamorig_Hips",
	"pos": Vector3(-0.15, -0.20, 0.03), "rot": Vector3(0, 0, 12),
	"scale": 0.85, "hides": "",
}


## Equips `prefix`'s loadout onto `character`. Safe to call twice (a second
## call is a no-op) and on a character whose skeleton is missing a bone.
static func equip(character: Node3D, prefix: String) -> void:
	if character == null or character.has_meta(&"gear_equipped"):
		return
	# LOB_NO_GEAR=1 runs the shipped look, for A/B against a gear frame.
	if OS.get_environment("LOB_NO_GEAR") == "1":
		return
	var skeleton: Skeleton3D = _find_skeleton(character)
	if skeleton == null:
		return
	character.set_meta(&"gear_equipped", true)

	var loadout: Array[Dictionary] = []
	match prefix:
		"armed":
			loadout = PALADIN_GEAR.duplicate()
		"unarmed":
			# Sheathed Paladin: same head and belt, no sword or shield in hand.
			for piece in PALADIN_GEAR:
				if piece["bone"] in ["mixamorig_Head", "mixamorig_Hips"]:
					loadout.append(piece)
		"archer":
			loadout = ARCHER_GEAR.duplicate()
		_:
			return
	loadout.append(FLASK_GEAR)

	var equipped: Array[String] = []
	for piece in loadout:
		if _attach(character, skeleton, piece):
			equipped.append(String(piece["name"]))
	if not equipped.is_empty():
		print("  Equipped %s gear: %s" % [prefix, ", ".join(equipped)])


static func _attach(character: Node3D, skeleton: Skeleton3D, piece: Dictionary) -> bool:
	var bone: String = String(piece["bone"])
	if skeleton.find_bone(bone) == -1:
		push_warning("GearLoadout: %s has no bone %s" % [character.name, bone])
		return false
	var scene: PackedScene = load(GEAR_DIR + String(piece["file"]) + ".glb") as PackedScene
	if scene == null:
		push_warning("GearLoadout: missing asset %s" % piece["file"])
		return false

	var attachment := BoneAttachment3D.new()
	attachment.name = String(piece["name"]) + "Attach"
	attachment.bone_name = bone
	skeleton.add_child(attachment)

	var mesh: Node3D = scene.instantiate() as Node3D
	mesh.name = String(piece["name"])
	var s: float = float(piece["scale"])

	# Orient in CHARACTER space, not bone space. The mixamorig bone axes are
	# not consistent between limbs — the Head, the Sword_joint and the Hips
	# each point their local +Y somewhere different — so a hand-guessed euler
	# per bone is unmaintainable. Instead: take the bone's REST pose, and
	# solve for the local rotation that lands the piece at `rot` degrees
	# relative to the character's own frame. Every piece then reads as
	# "upright and facing forward, plus this tweak", and still follows its
	# bone from then on.
	var bone_idx: int = skeleton.find_bone(bone)
	var bone_rest: Basis = (skeleton.global_transform
			* skeleton.get_bone_global_rest(bone_idx)).basis
	var want: Basis = character.global_transform.basis \
			* Basis.from_euler(Vector3(piece["rot"]) * (PI / 180.0))
	var local: Basis = bone_rest.orthonormalized().inverse() * want.orthonormalized()

	mesh.transform = Transform3D(local.scaled(Vector3(s, s, s)),
			bone_rest.orthonormalized().inverse() * Vector3(piece["pos"]))
	attachment.add_child(mesh)

	var hides: String = String(piece.get("hides", ""))
	if not hides.is_empty():
		_hide_meshes(character, hides)
	return true


## Hides — never frees — the shipped mesh a new piece stands in for, so a
## mis-placed offset reads as duplicate gear rather than a missing weapon.
static func _hide_meshes(node: Node, needle: String) -> void:
	if node is MeshInstance3D and String(node.name).contains(needle):
		(node as MeshInstance3D).visible = false
	for child in node.get_children():
		_hide_meshes(child, needle)


static func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node as Skeleton3D
	for child in node.get_children():
		var found: Skeleton3D = _find_skeleton(child)
		if found != null:
			return found
	return null
