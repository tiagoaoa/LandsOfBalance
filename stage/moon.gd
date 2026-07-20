class_name Moon
extends Node3D

## Moon object that provides visible moon sphere with texture and moonlight
## Only visible during night mode

@export var moon_size: float = 50.0  ## Diameter of the moon sphere
@export var moon_distance: float = 800.0  ## Distance from origin
## Moderate elevation: grazing moonlight is what makes vertical grass
## blades readable (a high moon barely lights them). Azimuth SE keeps the
## light clear of the tall western range that shadowed the spawn field.
@export var moon_elevation: float = 40.0  ## Degrees above horizon
@export var moon_azimuth: float = 135.0  ## Degrees from north (Y rotation)

@export var light_energy: float = 1.0  ## Moon light intensity (full moon)
@export var light_color: Color = Color(0.6, 0.65, 0.8)  ## Silvery-blue moonlight

var _moon_mesh: MeshInstance3D
var _moon_light: DirectionalLight3D
var _moon_material: StandardMaterial3D


func _ready() -> void:
	_create_moon_mesh()
	_create_moon_light()
	_position_moon()
	# Start visible - LightingManager will hide if in day mode
	visible = true


func _create_moon_mesh() -> void:
	_moon_mesh = MeshInstance3D.new()
	_moon_mesh.name = "MoonMesh"

	# Create sphere mesh for moon
	var sphere := SphereMesh.new()
	sphere.radius = moon_size / 2.0
	sphere.height = moon_size
	sphere.radial_segments = 32
	sphere.rings = 16
	_moon_mesh.mesh = sphere

	# Create emissive material with moon texture
	_moon_material = StandardMaterial3D.new()
	_moon_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED  # Self-illuminated

	# Try to load moon texture - if not imported yet, use fallback
	var moon_texture: Texture2D = null
	if ResourceLoader.exists("res://assets/textures/moon.png"):
		moon_texture = load("res://assets/textures/moon.png") as Texture2D

	if moon_texture:
		_moon_material.albedo_color = Color(1.0, 1.0, 1.0)
		_moon_material.albedo_texture = moon_texture
	else:
		# Fallback to bright yellowish-white for moon
		_moon_material.albedo_color = Color(0.95, 0.95, 0.85)

	# Emissive well past the glow threshold so the disc blooms — the light
	# in the scene must visibly COME from this object, not from nowhere.
	_moon_material.emission_enabled = true
	_moon_material.emission = Color(0.9, 0.92, 0.98)
	_moon_material.emission_energy_multiplier = 2.2

	_moon_mesh.material_override = _moon_material

	# Moon doesn't cast shadows
	_moon_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	add_child(_moon_mesh)


func _create_moon_light() -> void:
	_moon_light = DirectionalLight3D.new()
	_moon_light.name = "MoonLight"
	_moon_light.light_color = light_color
	_moon_light.light_energy = light_energy
	_moon_light.light_indirect_energy = 0.4  # Colored bounce light for GI
	_moon_light.light_specular = 0.7  # clear glints on the wet ground/grass
	_moon_light.light_volumetric_fog_energy = 1.0  # Moon visible in volumetric fog
	_moon_light.shadow_enabled = true
	_moon_light.shadow_blur = 1.2
	_moon_light.shadow_bias = 0.04
	_moon_light.shadow_normal_bias = 1.5
	# Stronger shadows — DS3-style deep darkness under the blades.
	_moon_light.shadow_opacity = 0.95
	_moon_light.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	_moon_light.directional_shadow_max_distance = 120.0

	add_child(_moon_light)


func _position_moon() -> void:
	# Calculate moon position based on elevation and azimuth
	var elevation_rad := deg_to_rad(moon_elevation)
	var azimuth_rad := deg_to_rad(moon_azimuth)

	# Spherical to Cartesian conversion
	var x := moon_distance * cos(elevation_rad) * sin(azimuth_rad)
	var y := moon_distance * sin(elevation_rad)
	var z := moon_distance * cos(elevation_rad) * cos(azimuth_rad)

	_moon_mesh.position = Vector3(x, y, z)

	# Moon mesh always faces origin (billboard-like but fixed)
	_moon_mesh.look_at(Vector3.ZERO, Vector3.UP)

	# Light direction points from moon toward ground
	# DirectionalLight3D shines along its -Z axis, so we aim it downward from the moon's position
	_moon_light.look_at_from_position(Vector3(x, y, z), Vector3.ZERO, Vector3.UP)


func set_visible_mode(is_night: bool) -> void:
	## Show/hide moon based on time of day
	visible = is_night
	if _moon_light:
		_moon_light.visible = is_night


func set_light_energy(energy: float) -> void:
	light_energy = energy
	if _moon_light:
		_moon_light.light_energy = energy


func set_light_color(color: Color) -> void:
	light_color = color
	if _moon_light:
		_moon_light.light_color = color
