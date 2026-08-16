class_name BoneHandles
extends Node3D
## Clickable joint handles drawn over the character.
##
## Sliders in a side panel are precise but blind — you have to already know
## which number moves which limb, which is exactly the knowledge that was
## missing. Grabbing the joint itself and dragging is direct: the thing you
## point at is the thing that moves.
##
## Handles are drawn unshaded and without depth test so a joint buried inside
## the mesh is still reachable, and picking is done in SCREEN space so a
## handle behind an arm can still be clicked if it is the nearest one.

signal picked(bone: String)

## The joints worth posing. Fingers and eyes would bury the useful ones.
const POSEABLE: Array[String] = [
	"Hips", "Spine", "Spine1", "Spine2", "Neck", "Head",
	"LeftShoulder", "LeftArm", "LeftForeArm", "LeftHand",
	"RightShoulder", "RightArm", "RightForeArm", "RightHand",
	"LeftUpLeg", "LeftLeg", "LeftFoot", "LeftToeBase",
	"RightUpLeg", "RightLeg", "RightFoot", "RightToeBase",
]
const PICK_RADIUS_PX: float = 26.0
const R_IDLE := 0.035
const R_HOVER := 0.055

var skeleton: Skeleton3D
var camera: Camera3D
var selected: String = ""

var _handles: Dictionary = {}     ## short bone name -> MeshInstance3D
var _bone_idx: Dictionary = {}    ## short bone name -> skeleton index
var _hovered: String = ""


func setup(skel: Skeleton3D, cam: Camera3D) -> void:
	skeleton = skel
	camera = cam
	for i in skeleton.get_bone_count():
		var short: String = skeleton.get_bone_name(i) \
				.replace("mixamorig:", "").replace("mixamorig_", "")
		if not POSEABLE.has(short) or _bone_idx.has(short):
			continue
		_bone_idx[short] = i
		_handles[short] = _make_handle()
	set_process(true)


func _make_handle() -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var sph := SphereMesh.new()
	sph.radius = R_IDLE
	sph.height = R_IDLE * 2.0
	sph.radial_segments = 10
	sph.rings = 6
	mi.mesh = sph
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(0.30, 0.80, 1.0, 0.9)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.no_depth_test = true            # reachable even inside the mesh
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return mi


func _process(_delta: float) -> void:
	if skeleton == null:
		return
	var skel_xf: Transform3D = skeleton.global_transform
	for short in _handles:
		var mi: MeshInstance3D = _handles[short]
		mi.global_position = skel_xf * skeleton.get_bone_global_pose(_bone_idx[short]).origin
		var mat: StandardMaterial3D = mi.material_override
		var r: float = R_HOVER if (short == selected or short == _hovered) else R_IDLE
		var sph: SphereMesh = mi.mesh
		sph.radius = r
		sph.height = r * 2.0
		if short == selected:
			mat.albedo_color = Color(1.0, 0.75, 0.15, 1.0)
		elif short == _hovered:
			mat.albedo_color = Color(0.6, 0.95, 1.0, 1.0)
		else:
			mat.albedo_color = Color(0.30, 0.80, 1.0, 0.75)


## Nearest handle to a screen point, or "" if none is close enough.
func pick_at(screen_pos: Vector2) -> String:
	if camera == null:
		return ""
	var best := ""
	var best_d: float = PICK_RADIUS_PX
	for short in _handles:
		var mi: MeshInstance3D = _handles[short]
		if camera.is_position_behind(mi.global_position):
			continue
		var d: float = camera.unproject_position(mi.global_position).distance_to(screen_pos)
		if d < best_d:
			best_d = d
			best = short
	return best


func hover_at(screen_pos: Vector2) -> void:
	_hovered = pick_at(screen_pos)


func select(bone: String) -> void:
	selected = bone
	picked.emit(bone)
