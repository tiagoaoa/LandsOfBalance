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
var _rain_bed: AudioStreamPlayer = null  # night ambience loop (rain + wind)

# Day preset — Skyrim-style cold Nordic overcast. Bright diffuse sky-light,
# strong atmospheric distance haze, a soft warm sun cutting the cool ambient,
# and a lightly desaturated cool grade. Reads as a windswept tundra noon.
const DAY_SETTINGS := {
	"background_energy": 1.0,            # full-bright overcast sky
	"ambient_color": Color(0.64, 0.71, 0.82),  # cool sky-blue skylight
	"ambient_energy": 0.85,             # overcast = strong, shadow-lifting fill
	"ambient_sky_contribution": 0.55,   # let the sky drive the ambient
	"fog_enabled": true,
	"fog_density": 0.0022,              # Nordic haze rolling over the distance
	"fog_color": Color(0.66, 0.74, 0.83),  # cool blue-grey
	"fog_light_energy": 0.6,
	"volumetric_fog_enabled": false,
	"ssao_enabled": true,
	"adjustment_enabled": true,
	"glow_enabled": true,
	"light_color": Color(1.0, 0.96, 0.86),  # soft sun, slightly warm vs the cool ambient
	"light_energy": 1.7,
	"light_rotation": Vector3(-48, -125, 0),  # mid-morning, long soft shadows
}

# Night preset — rainy night under a full moon. Humid air (dense fog +
# volumetric moon shafts), a bright silver moon as the only key light, and
# every surface WET: the ground and grass drop to low roughness / raised
# specular (see _apply_surface_wetness) so the moonlight lays a balanced
# sheen across the field instead of dying in matte darkness.
const NIGHT_SETTINGS := {
	"background_energy": 0.08,  # moonlit rain clouds — barely there
	"ambient_color": Color(0.10, 0.14, 0.22),  # cold rain-cloud bounce
	# DELIBERATELY dark: firelight is a gameplay mechanic — the archer's
	# arrows light paths and reveal enemies for the paladin. The darker the
	# baseline, the more those fires matter.
	"ambient_energy": 0.3,
	"ambient_sky_contribution": 0.25,
	"fog_enabled": true,
	"fog_density": 0.0028,  # humid rainy air — thicker than dry-night haze
	"fog_color": Color(0.07, 0.10, 0.16),  # deep blue-black wet air
	"fog_light_energy": 0.22,
	"volumetric_fog_enabled": true,  # moon shafts through the rain haze
	"ssao_enabled": true,
	"sdfgi_enabled": false,
	"adjustment_enabled": true,
	"glow_enabled": true,
	"light_color": Color(0.55, 0.62, 0.78),  # (sun, unused at night)
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
	print("LightingManager: applying %s (sun energy -> %.1f)" % [
			"NIGHT" if time_of_day == TimeOfDay.NIGHT else "DAY", settings.light_energy])

	# Apply environment settings
	env.background_energy_multiplier = settings.background_energy
	env.ambient_light_color = settings.ambient_color
	env.ambient_light_energy = settings.ambient_energy
	env.ambient_light_sky_contribution = settings.ambient_sky_contribution

	# Tonemap - ACES Filmic for cinematic look. Night pulls exposure down
	# slightly for gloom but not so far that the scene becomes unreadable.
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	if time_of_day == TimeOfDay.NIGHT:
		env.tonemap_exposure = 1.0
		env.tonemap_white = 6.0
	else:
		# Bright overcast sky — keep exposure near 1 so highlights don't blow.
		env.tonemap_exposure = 1.05
		env.tonemap_white = 8.0

	# Fog
	env.fog_enabled = settings.fog_enabled
	env.fog_density = settings.fog_density
	env.fog_light_color = settings.fog_color
	env.fog_light_energy = settings.fog_light_energy
	if time_of_day == TimeOfDay.NIGHT:
		env.fog_sun_scatter = 0.2  # Moonlight scatters through fog
	else:
		env.fog_sun_scatter = 0.35  # Hazy sun-bloom toward the horizon
		env.fog_aerial_perspective = 0.5  # distant geometry fades into the haze

	# Volumetric fog (night only) — thick enough that moonbeams become
	# visible god rays through breaks in the cloud cover. The Moon child
	# has its own light source that will carve through this.
	env.volumetric_fog_enabled = settings.volumetric_fog_enabled
	if settings.volumetric_fog_enabled:
		# 0.010: humid enough for moon shafts; above ~0.015 the glowing air
		# washes the whole night scene milky-pale.
		env.volumetric_fog_density = 0.010
		env.volumetric_fog_albedo = Color(0.15, 0.19, 0.27)  # Cool mist
		env.volumetric_fog_emission = Color(0.0, 0.0, 0.0)
		env.volumetric_fog_emission_energy = 0.0
		env.volumetric_fog_gi_inject = 0.3
		env.volumetric_fog_anisotropy = 0.6  # Forward scatter for beams
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
			env.adjustment_contrast = 1.18  # Punch without crushing mids
			env.adjustment_saturation = 0.6  # rain washes the colour out
		else:
			env.adjustment_brightness = 1.0
			env.adjustment_contrast = 1.0  # overcast is low-contrast; don't crush shadows
			env.adjustment_saturation = 0.85  # lightly desaturated cool grade

	# Glow - Subtle bloom on torches and emissives. Night pushes it a bit
	# harder so the moon and the wet-surface glints halo softly.
	env.glow_enabled = settings.glow_enabled
	if settings.glow_enabled:
		env.glow_intensity = 0.55 if time_of_day == TimeOfDay.NIGHT else 0.5
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
		# Soft sun shadows in daylight; the sun is dark at night so its
		# shadow map would only waste fill-rate.
		if time_of_day == TimeOfDay.DAY:
			_dir_light.light_cull_mask = 0xFFFFF  # affect every visual layer
			_dir_light.shadow_enabled = true
			_dir_light.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
			_dir_light.directional_shadow_max_distance = 120.0
			_dir_light.shadow_blur = 1.5  # soft overcast contact shadows
			_dir_light.light_specular = 0.4  # muted speculars under overcast
		else:
			_dir_light.shadow_enabled = false

	# Moon visibility and settings - only show at night
	if _moon:
		if _moon.has_method("set_visible_mode"):
			_moon.set_visible_mode(time_of_day == TimeOfDay.NIGHT)
		else:
			_moon.visible = (time_of_day == TimeOfDay.NIGHT)
		# FULL moon — the sole key light of the rainy night. Bright silver,
		# carving god rays through the humid volumetric fog and laying the
		# specular sheen across the wet grass and ground.
		if time_of_day == TimeOfDay.NIGHT:
			if _moon.has_method("set_light_color"):
				_moon.set_light_color(Color(0.62, 0.70, 0.92))
			if _moon.has_method("set_light_energy"):
				# Calibrated against ACES + the 1.18 night contrast, which
				# crush the low end: below ~1.0 the field renders pitch
				# black; ~3.0 is fully readable. 2.5 keeps terrain navigable
				# while an enemy 18m out is a barely-there smudge — the
				# archer's fires do the revealing. NOTE: the old "night too
				# bright near spawn" was NEVER the moon — it was a
				# 1000-energy floodlight baked into the village FBX
				# (village_loader._tame_imported_lights).
				# 2.5 → 2.0: user-requested extra 20% dim.
				_moon.set_light_energy(2.0)

	# Wet/dry surface response must run after every _ready (the grass placer
	# writes its own material defaults synchronously at scene start).
	_apply_surface_wetness.call_deferred()

	# Ambience bed follows the weather: rain+wind loop at night, silence in
	# the overcast day (the toggle owns it so L swaps it with the preset).
	var sfx := get_node_or_null("/root/Sfx")
	if sfx:
		if time_of_day == TimeOfDay.NIGHT and _rain_bed == null:
			_rain_bed = sfx.loop2d("night_rain_loop", -22.0)
		elif time_of_day == TimeOfDay.DAY and _rain_bed != null:
			_rain_bed.queue_free()
			_rain_bed = null


## Rainy night = wet world. Drop roughness and raise specular on the ground
## and the grass so the moonlight reflects with a balanced sheen — visible
## glints, not a mirror. Day restores the dry Skyrim-tundra response.
func _apply_surface_wetness() -> void:
	var wet: bool = time_of_day == TimeOfDay.NIGHT
	var scene_root: Node = get_parent()

	# Ground (CSG MainGround, Ground037 PBR material).
	var ground: Node = scene_root.find_child("MainGround", true, false)
	if ground and "material" in ground and ground.material is StandardMaterial3D:
		var mat: StandardMaterial3D = ground.material
		if wet:
			mat.roughness = 0.42            # rain-slick earth catches the moon
			mat.metallic_specular = 0.7
			mat.albedo_color = Color(0.53, 0.57, 0.46)  # wet soil reads darker
		else:
			mat.roughness = 0.95
			mat.metallic_specular = 0.5
			mat.albedo_color = Color(0.74, 0.79, 0.62)

	# Grass (SimpleGrassTextured multimesh material). Milder than the ground:
	# a million glossy blades facing the moon otherwise add up to a solid
	# silver sheet — the sheen should read per-blade, not per-field.
	var sgt: Node = scene_root.find_child("SimpleGrassTextured", true, false)
	if sgt:
		if "roughness" in sgt:
			sgt.roughness = 0.7 if wet else 1.0
		if "specular" in sgt:
			# Low: at grazing angles toward the moon a million glossy blades
			# still sum into a pale sheet that silhouettes enemies — the
			# firelight, not the moon, is supposed to reveal things.
			sgt.specular = 0.2 if wet else 0.5
		if "albedo" in sgt:
			# Rain deepens the green hard (the blade texture itself is pale
			# toward the tips); day restores the dry tundra olive.
			sgt.albedo = Color(0.26, 0.34, 0.20) if wet else Color(0.46, 0.56, 0.28)


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
