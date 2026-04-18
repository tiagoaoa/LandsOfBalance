class_name LightingManager
extends Node

## Manages day/night lighting presets for the game

enum TimeOfDay { DAY, NIGHT }

@export var time_of_day: TimeOfDay = TimeOfDay.DAY:
	set(value):
		time_of_day = value
		if is_inside_tree():
			_apply_lighting()

@export var transition_duration: float = 2.0  ## Seconds to transition between presets

var _world_env: WorldEnvironment
var _dir_light: DirectionalLight3D
var _moon: Node3D
var _tween: Tween

# Day preset (original bright lighting - reduced 70%)
const DAY_SETTINGS := {
	"background_energy": 0.3,
	"ambient_color": Color(0.7, 0.75, 0.8),
	"ambient_energy": 0.15,
	"ambient_sky_contribution": 0.3,
	"fog_enabled": true,
	"fog_density": 0.001,
	"fog_color": Color(0.75, 0.82, 0.9),
	"fog_light_energy": 0.3,
	"volumetric_fog_enabled": false,
	"ssao_enabled": false,
	"adjustment_enabled": false,
	"glow_enabled": false,
	"light_color": Color(1.0, 0.95, 0.85),
	"light_energy": 0.39,
	"light_rotation": Vector3(-45, -45, 0),
}

# Night preset - Cinematic dark-fantasy moonlit ruin (DS3 reference)
# Dark but readable — strong contrast between cool moonlit highlights and
# deep shadows without crushing the entire scene to black.
const NIGHT_SETTINGS := {
	"background_energy": 0.08,  # Sky dim but visible through clouds
	"ambient_color": Color(0.12, 0.16, 0.24),  # Cold blue-gray
	"ambient_energy": 0.45,  # Enough to see into shadows faintly
	"ambient_sky_contribution": 0.2,
	"fog_enabled": true,
	"fog_density": 0.0018,  # Atmospheric haze without swallowing everything
	"fog_color": Color(0.09, 0.12, 0.18),  # Cool blue-black
	"fog_light_energy": 0.28,
	"volumetric_fog_enabled": true,  # Enable for the vertical god-ray feel
	"ssao_enabled": true,
	"sdfgi_enabled": false,
	"adjustment_enabled": true,
	"glow_enabled": true,
	"light_color": Color(0.55, 0.62, 0.78),  # Cool silvery-blue moonlight
	"light_energy": 0.0,  # Directional sun OFF at night - Moon provides all light
	"light_rotation": Vector3(-35, 25, 0),  # Unused at night
}


func _ready() -> void:
	# Find WorldEnvironment and DirectionalLight3D in parent
	_world_env = _find_node_of_type(get_parent(), "WorldEnvironment")
	_dir_light = _find_node_of_type(get_parent(), "DirectionalLight3D")
	_moon = get_parent().get_node_or_null("Moon")

	if not _world_env:
		push_warning("LightingManager: No WorldEnvironment found")
	if not _dir_light:
		push_warning("LightingManager: No DirectionalLight3D found")
	if not _moon:
		push_warning("LightingManager: No Moon found")

	_apply_lighting()


func _find_node_of_type(parent: Node, type_name: String) -> Node:
	for child in parent.get_children():
		if child.get_class() == type_name:
			return child
	return null


func set_time(new_time: TimeOfDay, instant: bool = false) -> void:
	time_of_day = new_time
	if instant:
		_apply_lighting()
	else:
		_transition_lighting()


func toggle_time() -> void:
	if time_of_day == TimeOfDay.DAY:
		set_time(TimeOfDay.NIGHT)
	else:
		set_time(TimeOfDay.DAY)


func _apply_lighting() -> void:
	if not _world_env or not _world_env.environment:
		return

	var settings: Dictionary = NIGHT_SETTINGS if time_of_day == TimeOfDay.NIGHT else DAY_SETTINGS
	var env := _world_env.environment

	# Apply environment settings
	env.background_energy_multiplier = settings.background_energy
	env.ambient_light_color = settings.ambient_color
	env.ambient_light_energy = settings.ambient_energy
	env.ambient_light_sky_contribution = settings.ambient_sky_contribution

	# Tonemap - ACES Filmic for cinematic look. Night pulls exposure down
	# slightly for gloom but not so far that the scene becomes unreadable.
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	if time_of_day == TimeOfDay.NIGHT:
		env.tonemap_exposure = 1.1
		env.tonemap_white = 6.0
	else:
		env.tonemap_exposure = 2.0
		env.tonemap_white = 8.0

	# Fog
	env.fog_enabled = settings.fog_enabled
	env.fog_density = settings.fog_density
	env.fog_light_color = settings.fog_color
	env.fog_light_energy = settings.fog_light_energy
	if time_of_day == TimeOfDay.NIGHT:
		env.fog_sun_scatter = 0.2  # Moonlight scatters through fog

	# Volumetric fog (night only) — thick enough that moonbeams become
	# visible god rays through breaks in the cloud cover. The Moon child
	# has its own light source that will carve through this.
	env.volumetric_fog_enabled = settings.volumetric_fog_enabled
	if settings.volumetric_fog_enabled:
		env.volumetric_fog_density = 0.012  # Moderate — visible god rays without fogging out gameplay
		env.volumetric_fog_albedo = Color(0.16, 0.20, 0.28)  # Cool mist
		env.volumetric_fog_emission = Color(0.0, 0.0, 0.0)
		env.volumetric_fog_emission_energy = 0.0
		env.volumetric_fog_gi_inject = 0.3
		env.volumetric_fog_anisotropy = 0.55  # Forward scatter for beams
		env.volumetric_fog_length = 140.0
		env.volumetric_fog_detail_spread = 1.2
		env.volumetric_fog_ambient_inject = 0.0

	# SDFGI - Real-time global illumination for dynamic colored bounce light
	if settings.get("sdfgi_enabled", false):
		env.sdfgi_enabled = true
		env.sdfgi_use_occlusion = true
		env.sdfgi_cascades = 4
		env.sdfgi_min_cell_size = 0.5
		env.sdfgi_energy = 1.0
		env.sdfgi_bounce_feedback = 0.4
		env.sdfgi_normal_bias = 1.1
		env.sdfgi_probe_bias = 1.1
	else:
		env.sdfgi_enabled = false

	# SSAO - Subtle contact shadows
	env.ssao_enabled = settings.ssao_enabled
	if settings.ssao_enabled:
		env.ssao_radius = 0.5
		env.ssao_intensity = 1.0
		env.ssao_power = 1.5
		env.ssao_detail = 0.0
		env.ssao_light_affect = 0.2

	# Color adjustment - cold cinematic desaturation with punchy contrast.
	env.adjustment_enabled = settings.adjustment_enabled
	if settings.adjustment_enabled:
		if time_of_day == TimeOfDay.NIGHT:
			env.adjustment_brightness = 0.95
			env.adjustment_contrast = 1.22  # Punch without crushing mids
			env.adjustment_saturation = 0.68  # Desaturated, cold mood but readable
		else:
			env.adjustment_brightness = 0.95
			env.adjustment_contrast = 1.2
			env.adjustment_saturation = 0.75

	# Glow - Subtle bloom on torches and emissives
	env.glow_enabled = settings.glow_enabled
	if settings.glow_enabled:
		env.glow_intensity = 0.5
		env.glow_strength = 1.0
		env.glow_bloom = 0.15
		env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT
		env.glow_hdr_threshold = 1.0  # Only bright sources bloom
		env.glow_hdr_scale = 2.0
		# Enable multiple glow levels for soft halos
		env.set_glow_level(0, true)
		env.set_glow_level(1, true)
		env.set_glow_level(2, false)
		env.set_glow_level(3, true)
		env.set_glow_level(4, false)
		env.set_glow_level(5, false)
		env.set_glow_level(6, false)

	# Directional light (sun - off at night, moon handles lighting)
	if _dir_light:
		_dir_light.light_color = settings.light_color
		_dir_light.light_energy = settings.light_energy
		_dir_light.rotation_degrees = settings.light_rotation

	# Moon visibility and settings - only show at night
	if _moon:
		if _moon.has_method("set_visible_mode"):
			_moon.set_visible_mode(time_of_day == TimeOfDay.NIGHT)
		else:
			_moon.visible = (time_of_day == TimeOfDay.NIGHT)
		# Bright cool moonlight — carves god rays through the volumetric fog
		# and rim-lights grass tips without washing out shadows.
		if time_of_day == TimeOfDay.NIGHT:
			if _moon.has_method("set_light_color"):
				_moon.set_light_color(Color(0.55, 0.62, 0.85))
			if _moon.has_method("set_light_energy"):
				_moon.set_light_energy(1.1)


func _transition_lighting() -> void:
	if _tween:
		_tween.kill()

	_tween = create_tween()
	_tween.set_ease(Tween.EASE_IN_OUT)
	_tween.set_trans(Tween.TRANS_SINE)

	var settings: Dictionary = NIGHT_SETTINGS if time_of_day == TimeOfDay.NIGHT else DAY_SETTINGS
	var env := _world_env.environment

	# Tween main properties
	_tween.tween_property(env, "background_energy_multiplier", settings.background_energy, transition_duration)
	_tween.parallel().tween_property(env, "ambient_light_color", settings.ambient_color, transition_duration)
	_tween.parallel().tween_property(env, "ambient_light_energy", settings.ambient_energy, transition_duration)
	_tween.parallel().tween_property(env, "fog_density", settings.fog_density, transition_duration)
	_tween.parallel().tween_property(env, "fog_light_color", settings.fog_color, transition_duration)
	_tween.parallel().tween_property(env, "fog_light_energy", settings.fog_light_energy, transition_duration)

	if _dir_light:
		_tween.parallel().tween_property(_dir_light, "light_color", settings.light_color, transition_duration)
		_tween.parallel().tween_property(_dir_light, "light_energy", settings.light_energy, transition_duration)
		_tween.parallel().tween_property(_dir_light, "rotation_degrees", settings.light_rotation, transition_duration)

	# Toggle boolean properties at halfway point
	# Note: Detailed values are already set by _apply_lighting() which runs before transition
	_tween.tween_callback(func():
		env.volumetric_fog_enabled = settings.volumetric_fog_enabled
		env.ssao_enabled = settings.ssao_enabled
		env.adjustment_enabled = settings.adjustment_enabled
		env.glow_enabled = settings.glow_enabled
	).set_delay(transition_duration * 0.5)


func _unhandled_key_input(event: InputEvent) -> void:
	# Press 'L' to toggle day/night (for testing) - only when console is closed
	# Find console instance in scene tree
	var console = get_tree().get_first_node_in_group("game_console")
	if console == null:
		console = get_node_or_null("/root/Game/GameConsole")
	if console and "is_console_open" in console and console.is_console_open:
		return
	if event is InputEventKey and event.pressed and event.keycode == KEY_L:
		toggle_time()
		print("Switched to: ", "NIGHT" if time_of_day == TimeOfDay.NIGHT else "DAY")
