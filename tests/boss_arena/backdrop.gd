#Offline renders with depth-writing cutout edges: no lit cliff geometry or shadows.
extends RefCounted

const IMAGES := {
	"cliff": preload("res://assets/environment/arena_backdrops/cliff.png"),
	"ruin": preload("res://assets/environment/arena_backdrops/ruin.png"),
}
var sizes: Dictionary
var meshes := {}


func _init() -> void:
	sizes = JSON.parse_string(FileAccess.get_file_as_string("res://assets/environment/arena_backdrops/sizes.json"))
	for kind: String in IMAGES:
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		mat.alpha_scissor_threshold = 0.45
		mat.albedo_texture = IMAGES[kind]
		mat.albedo_color = Color(0.55, 0.57, 0.59)
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		var quad := QuadMesh.new()
		quad.size = Vector2(sizes[kind].width, sizes[kind].height)
		quad.material = mat
		meshes[kind] = quad


func add(parent: Node3D, kind: String, at: Vector3, size: Vector3, turn: float) -> void:
	var spec: Dictionary = sizes[kind]
	var card := MeshInstance3D.new()
	card.name = kind.capitalize() + "Backdrop"
	card.mesh = meshes[kind]
	card.scale = Vector3(size.x, size.y, 1)
	card.rotation.y = turn
	card.position = at + Basis(Vector3.UP, turn) * Vector3(spec.x * size.x, spec.y * size.y, 0)
	card.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(card, true)
