class_name GameConsole
extends CanvasLayer
## Quake-style drop-down console for in-game commands
## Press F2 to toggle. Supports lighting adjustments and presets.

signal console_toggled(is_open: bool)

## Global flag that other scripts can check
static var is_console_open: bool = false

const ANIMATION_DURATION: float = 0.2
const CONSOLE_HEIGHT_RATIO: float = 0.4  # 40% of screen height

var _is_open: bool = false
var _tween: Tween
var _command_history: Array[String] = []
var _history_index: int = -1

@onready var _panel: Panel = $Panel
@onready var _output: RichTextLabel = $Panel/VBoxContainer/Output
@onready var _input_field: LineEdit = $Panel/VBoxContainer/InputContainer/Input
@onready var _prompt: Label = $Panel/VBoxContainer/InputContainer/Prompt

# References to game systems (using dynamic typing to avoid circular dependency)
var _lighting_manager  # LightingManager
var _world_env: WorldEnvironment
var _dir_light: DirectionalLight3D
var _network_manager  # NetworkManager

# Lighting presets
const LIGHTING_PRESETS: Dictionary = {
	"test": {
		"name": "Testing (Golden Hour)",
		"dir_energy": 1.0,
		"dir_color": Color(1.0, 0.85, 0.7),
		"dir_rotation": Vector3(-45, -45, 0),
		"ambient_energy": 1.3,
		"ambient_color": Color(0.5, 0.4, 0.25),
		"ambient_sky_contribution": 0.7,
		"background_energy": 1.0,
		"sky_top": Color(0.5, 0.7, 0.9),
		"sky_horizon": Color(0.85, 0.75, 0.6),
		"fog_enabled": true,
		"fog_density": 0.015,
		"ssao_enabled": true,
		"ssao_intensity": 2.5,
	},
	"day": {
		"name": "Bright Day",
		"dir_energy": 1.2,
		"dir_color": Color(1.0, 0.96, 0.89),
		"dir_rotation": Vector3(-60, -45, 0),
		"ambient_energy": 1.0,
		"ambient_color": Color(0.6, 0.65, 0.7),
		"ambient_sky_contribution": 0.8,
		"background_energy": 1.0,
		"sky_top": Color(0.4, 0.6, 0.9),
		"sky_horizon": Color(0.7, 0.8, 0.9),
		"fog_enabled": false,
		"fog_density": 0.0,
		"ssao_enabled": true,
		"ssao_intensity": 2.0,
	},
	"sunset": {
		"name": "Sunset",
		"dir_energy": 0.8,
		"dir_color": Color(1.0, 0.6, 0.3),
		"dir_rotation": Vector3(-15, -60, 0),
		"ambient_energy": 1.0,
		"ambient_color": Color(0.6, 0.4, 0.3),
		"ambient_sky_contribution": 0.5,
		"background_energy": 0.8,
		"sky_top": Color(0.3, 0.4, 0.6),
		"sky_horizon": Color(1.0, 0.6, 0.4),
		"fog_enabled": true,
		"fog_density": 0.02,
		"ssao_enabled": true,
		"ssao_intensity": 2.5,
	},
	"night": {
		"name": "Moonlit Night",
		"dir_energy": 0.25,
		"dir_color": Color(0.3, 0.35, 0.5),
		"dir_rotation": Vector3(-30, 135, 0),
		"ambient_energy": 0.8,
		"ambient_color": Color(0.1, 0.15, 0.25),
		"ambient_sky_contribution": 0.3,
		"background_energy": 0.1,
		"sky_top": Color(0.05, 0.08, 0.15),
		"sky_horizon": Color(0.1, 0.15, 0.2),
		"fog_enabled": true,
		"fog_density": 0.025,
		"ssao_enabled": true,
		"ssao_intensity": 3.5,
	},
	"magic": {
		"name": "Magic Hour",
		"dir_energy": 0.6,
		"dir_color": Color(0.7, 0.5, 1.0),
		"dir_rotation": Vector3(-30, -60, 0),
		"ambient_energy": 1.0,
		"ambient_color": Color(0.4, 0.3, 0.5),
		"ambient_sky_contribution": 0.5,
		"background_energy": 0.6,
		"sky_top": Color(0.3, 0.2, 0.5),
		"sky_horizon": Color(0.6, 0.4, 0.7),
		"fog_enabled": true,
		"fog_density": 0.02,
		"ssao_enabled": true,
		"ssao_intensity": 3.0,
	},
}

# Command definitions
var _commands: Dictionary = {}


func _ready() -> void:
	_setup_ui()
	_register_commands()
	_find_lighting_nodes()
	_print_welcome()

	# Start hidden
	_panel.position.y = -_get_console_height()
	_panel.visible = false


func _setup_ui() -> void:
	# Panel styling
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.1, 0.12, 0.95)
	style.border_color = Color(0.3, 0.3, 0.35)
	style.border_width_bottom = 2
	_panel.add_theme_stylebox_override("panel", style)

	# Input styling
	_input_field.placeholder_text = "Type 'help' for commands..."
	_input_field.text_submitted.connect(_on_command_submitted)
	_input_field.gui_input.connect(_on_input_gui_input)

	# Prompt
	_prompt.text = "> "


func _register_commands() -> void:
	_commands = {
		"help": {
			"desc": "Show available commands",
			"usage": "help [command]",
			"func": _cmd_help,
		},
		"clear": {
			"desc": "Clear console output",
			"usage": "clear",
			"func": _cmd_clear,
		},
		"preset": {
			"desc": "Apply lighting preset",
			"usage": "preset <name> | preset list",
			"func": _cmd_preset,
		},
		"light": {
			"desc": "Adjust directional light",
			"usage": "light <property> <value>",
			"func": _cmd_light,
		},
		"ambient": {
			"desc": "Adjust ambient light",
			"usage": "ambient <property> <value>",
			"func": _cmd_ambient,
		},
		"sky": {
			"desc": "Adjust sky settings",
			"usage": "sky <property> <value>",
			"func": _cmd_sky,
		},
		"fog": {
			"desc": "Adjust fog settings",
			"usage": "fog <property> <value>",
			"func": _cmd_fog,
		},
		"ssao": {
			"desc": "Adjust SSAO settings",
			"usage": "ssao <property> <value>",
			"func": _cmd_ssao,
		},
		"status": {
			"desc": "Show current lighting values",
			"usage": "status",
			"func": _cmd_status,
		},
		"net": {
			"desc": "Network commands",
			"usage": "net connect [ip] | net disconnect | net status",
			"func": _cmd_net,
		},
	}


func _find_lighting_nodes() -> void:
	await get_tree().process_frame

	# Find LightingManager
	_lighting_manager = _find_node_by_class(get_tree().root, "LightingManager")

	# Find WorldEnvironment
	_world_env = _find_node_by_type(get_tree().root, "WorldEnvironment")

	# Find DirectionalLight3D
	_dir_light = _find_node_by_type(get_tree().root, "DirectionalLight3D")

	# Find NetworkManager
	_network_manager = get_node_or_null("/root/network_manager")

	if not _world_env:
		_print_error("WorldEnvironment not found!")
	if not _dir_light:
		_print_error("DirectionalLight3D not found!")


func _find_node_by_class(node: Node, class_name_str: String) -> Node:
	if node.get_class() == class_name_str or (node.get_script() and node.get_script().get_global_name() == class_name_str):
		return node
	for child in node.get_children():
		var result = _find_node_by_class(child, class_name_str)
		if result:
			return result
	return null


func _find_node_by_type(node: Node, type_name: String) -> Node:
	if node.get_class() == type_name:
		return node
	for child in node.get_children():
		var result = _find_node_by_type(child, type_name)
		if result:
			return result
	return null


func _get_console_height() -> float:
	return get_viewport().get_visible_rect().size.y * CONSOLE_HEIGHT_RATIO


func _unhandled_key_input(event: InputEvent) -> void:
	# F2 toggles console (this runs after GUI processing)
	if event is InputEventKey and event.pressed and event.keycode == KEY_F2:
		toggle()
		get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	# When console is open, block all game actions by checking Input directly
	# This prevents WASD etc from moving player while typing
	if _is_open:
		# Ensure input field stays focused
		if not _input_field.has_focus():
			_input_field.grab_focus()


func _on_input_gui_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_UP:
			_navigate_history(-1)
			_input_field.accept_event()
		elif event.keycode == KEY_DOWN:
			_navigate_history(1)
			_input_field.accept_event()
		elif event.keycode == KEY_ESCAPE:
			close()
			_input_field.accept_event()


func _navigate_history(direction: int) -> void:
	if _command_history.is_empty():
		return

	_history_index = clampi(_history_index + direction, -1, _command_history.size() - 1)

	if _history_index >= 0:
		_input_field.text = _command_history[_history_index]
		_input_field.caret_column = _input_field.text.length()
	else:
		_input_field.text = ""


func toggle() -> void:
	if _is_open:
		close()
	else:
		open()


func open() -> void:
	if _is_open:
		return

	_is_open = true
	is_console_open = true
	_panel.visible = true
	_panel.size.y = _get_console_height()

	if _tween:
		_tween.kill()
	_tween = create_tween()
	_tween.set_ease(Tween.EASE_OUT)
	_tween.set_trans(Tween.TRANS_CUBIC)
	_tween.tween_property(_panel, "position:y", 0.0, ANIMATION_DURATION)
	_tween.tween_callback(func(): _input_field.grab_focus())

	console_toggled.emit(true)


func close() -> void:
	if not _is_open:
		return

	_is_open = false
	is_console_open = false
	_input_field.release_focus()

	if _tween:
		_tween.kill()
	_tween = create_tween()
	_tween.set_ease(Tween.EASE_IN)
	_tween.set_trans(Tween.TRANS_CUBIC)
	_tween.tween_property(_panel, "position:y", -_get_console_height(), ANIMATION_DURATION)
	_tween.tween_callback(func(): _panel.visible = false)

	console_toggled.emit(false)


func _on_command_submitted(text: String) -> void:
	if text.strip_edges().is_empty():
		_input_field.grab_focus()
		return

	_input_field.text = ""
	_input_field.grab_focus()  # Keep focus after submitting
	_print_input(text)

	# Add to history
	if _command_history.is_empty() or _command_history[0] != text:
		_command_history.insert(0, text)
		if _command_history.size() > 50:
			_command_history.pop_back()
	_history_index = -1

	_execute_command(text)


func _execute_command(text: String) -> void:
	var parts = text.strip_edges().split(" ", false)
	if parts.is_empty():
		return

	var cmd_name = parts[0].to_lower()
	var args = parts.slice(1)

	if _commands.has(cmd_name):
		_commands[cmd_name]["func"].call(args)
	else:
		_print_error("Unknown command: " + cmd_name)
		_print_info("Type 'help' for available commands")


func _print_welcome() -> void:
	_output.clear()
	_print_line("[color=#6699ff]═══════════════════════════════════════[/color]")
	_print_line("[color=#6699ff]  LANDS OF BALANCE - Developer Console[/color]")
	_print_line("[color=#6699ff]═══════════════════════════════════════[/color]")
	_print_line("[color=#888888]Press F2 to toggle | Type 'help' for commands[/color]")
	_print_line("")


func _print_line(text: String) -> void:
	_output.append_text(text + "\n")


func _print_input(text: String) -> void:
	_print_line("[color=#aaaaaa]> " + text + "[/color]")


func _print_info(text: String) -> void:
	_print_line("[color=#88cc88]" + text + "[/color]")


func _print_error(text: String) -> void:
	_print_line("[color=#ff6666]ERROR: " + text + "[/color]")


func _print_value(name: String, value: String) -> void:
	_print_line("[color=#cccccc]  " + name + ": [/color][color=#ffcc66]" + value + "[/color]")


# ═══════════════════════════════════════
# COMMANDS
# ═══════════════════════════════════════

func _cmd_help(args: Array) -> void:
	if args.size() > 0:
		var cmd_name = args[0].to_lower()
		if _commands.has(cmd_name):
			var cmd = _commands[cmd_name]
			_print_line("[color=#ffcc66]" + cmd_name + "[/color] - " + cmd["desc"])
			_print_line("  Usage: " + cmd["usage"])

			# Show specific help for commands
			match cmd_name:
				"preset":
					_print_line("  Available presets: " + ", ".join(LIGHTING_PRESETS.keys()))
				"light":
					_print_line("  Properties: energy, color, rotation")
					_print_line("  Examples:")
					_print_line("    light energy 1.5")
					_print_line("    light color 1.0 0.9 0.8")
					_print_line("    light rotation -45 -45 0")
				"ambient":
					_print_line("  Properties: energy, color, sky_contribution")
					_print_line("  Examples:")
					_print_line("    ambient energy 1.2")
					_print_line("    ambient color 0.5 0.4 0.3")
				"sky":
					_print_line("  Properties: top, horizon, energy")
					_print_line("  Examples:")
					_print_line("    sky top 0.4 0.6 0.9")
					_print_line("    sky horizon 0.8 0.7 0.6")
				"fog":
					_print_line("  Properties: enabled, density")
					_print_line("  Examples:")
					_print_line("    fog enabled 1")
					_print_line("    fog density 0.02")
				"ssao":
					_print_line("  Properties: enabled, intensity, radius")
					_print_line("  Examples:")
					_print_line("    ssao enabled 1")
					_print_line("    ssao intensity 2.5")
		else:
			_print_error("Unknown command: " + cmd_name)
		return

	_print_line("[color=#6699ff]Available Commands:[/color]")
	for cmd_name in _commands:
		var cmd = _commands[cmd_name]
		_print_line("  [color=#ffcc66]" + cmd_name + "[/color] - " + cmd["desc"])
	_print_line("")
	_print_line("[color=#888888]Type 'help <command>' for detailed usage[/color]")


func _cmd_clear(_args: Array) -> void:
	_print_welcome()


func _cmd_preset(args: Array) -> void:
	if args.is_empty():
		_print_error("Usage: preset <name> | preset list")
		return

	var preset_name = args[0].to_lower()

	if preset_name == "list":
		_print_line("[color=#6699ff]Available Presets:[/color]")
		for key in LIGHTING_PRESETS:
			var preset = LIGHTING_PRESETS[key]
			_print_line("  [color=#ffcc66]" + key + "[/color] - " + preset["name"])
		return

	if not LIGHTING_PRESETS.has(preset_name):
		_print_error("Unknown preset: " + preset_name)
		_print_info("Use 'preset list' to see available presets")
		return

	_apply_preset(preset_name)
	_print_info("Applied preset: " + LIGHTING_PRESETS[preset_name]["name"])


func _apply_preset(preset_name: String) -> void:
	var preset = LIGHTING_PRESETS[preset_name]

	# DirectionalLight3D
	if _dir_light:
		_dir_light.light_energy = preset["dir_energy"]
		_dir_light.light_color = preset["dir_color"]
		_dir_light.rotation_degrees = preset["dir_rotation"]

	# WorldEnvironment
	if _world_env and _world_env.environment:
		var env = _world_env.environment
		env.ambient_light_energy = preset["ambient_energy"]
		env.ambient_light_color = preset["ambient_color"]
		env.ambient_light_sky_contribution = preset["ambient_sky_contribution"]
		env.background_energy_multiplier = preset["background_energy"]

		# Fog
		env.volumetric_fog_enabled = preset["fog_enabled"]
		env.fog_enabled = preset["fog_enabled"]
		if preset["fog_enabled"]:
			env.volumetric_fog_density = preset["fog_density"]
			env.fog_density = preset["fog_density"]

		# SSAO
		env.ssao_enabled = preset["ssao_enabled"]
		if preset["ssao_enabled"]:
			env.ssao_intensity = preset["ssao_intensity"]

		# Sky
		var sky = env.sky
		if sky and sky.sky_material is ProceduralSkyMaterial:
			var sky_mat = sky.sky_material as ProceduralSkyMaterial
			sky_mat.sky_top_color = preset["sky_top"]
			sky_mat.sky_horizon_color = preset["sky_horizon"]


func _cmd_light(args: Array) -> void:
	if not _dir_light:
		_print_error("DirectionalLight3D not found")
		return

	if args.is_empty():
		_print_line("[color=#6699ff]DirectionalLight3D:[/color]")
		_print_value("energy", str(_dir_light.light_energy))
		_print_value("color", _color_to_str(_dir_light.light_color))
		_print_value("rotation", _vec3_to_str(_dir_light.rotation_degrees))
		return

	var prop = args[0].to_lower()
	var values = args.slice(1)

	match prop:
		"energy":
			if values.is_empty():
				_print_value("energy", str(_dir_light.light_energy))
			else:
				_dir_light.light_energy = float(values[0])
				_print_info("Set light energy to " + str(_dir_light.light_energy))
		"color":
			if values.size() < 3:
				_print_value("color", _color_to_str(_dir_light.light_color))
			else:
				_dir_light.light_color = Color(float(values[0]), float(values[1]), float(values[2]))
				_print_info("Set light color to " + _color_to_str(_dir_light.light_color))
		"rotation":
			if values.size() < 3:
				_print_value("rotation", _vec3_to_str(_dir_light.rotation_degrees))
			else:
				_dir_light.rotation_degrees = Vector3(float(values[0]), float(values[1]), float(values[2]))
				_print_info("Set light rotation to " + _vec3_to_str(_dir_light.rotation_degrees))
		_:
			_print_error("Unknown property: " + prop)


func _cmd_ambient(args: Array) -> void:
	if not _world_env or not _world_env.environment:
		_print_error("WorldEnvironment not found")
		return

	var env = _world_env.environment

	if args.is_empty():
		_print_line("[color=#6699ff]Ambient Light:[/color]")
		_print_value("energy", str(env.ambient_light_energy))
		_print_value("color", _color_to_str(env.ambient_light_color))
		_print_value("sky_contribution", str(env.ambient_light_sky_contribution))
		return

	var prop = args[0].to_lower()
	var values = args.slice(1)

	match prop:
		"energy":
			if values.is_empty():
				_print_value("energy", str(env.ambient_light_energy))
			else:
				env.ambient_light_energy = float(values[0])
				_print_info("Set ambient energy to " + str(env.ambient_light_energy))
		"color":
			if values.size() < 3:
				_print_value("color", _color_to_str(env.ambient_light_color))
			else:
				env.ambient_light_color = Color(float(values[0]), float(values[1]), float(values[2]))
				_print_info("Set ambient color to " + _color_to_str(env.ambient_light_color))
		"sky_contribution":
			if values.is_empty():
				_print_value("sky_contribution", str(env.ambient_light_sky_contribution))
			else:
				env.ambient_light_sky_contribution = float(values[0])
				_print_info("Set sky contribution to " + str(env.ambient_light_sky_contribution))
		_:
			_print_error("Unknown property: " + prop)


func _cmd_sky(args: Array) -> void:
	if not _world_env or not _world_env.environment:
		_print_error("WorldEnvironment not found")
		return

	var env = _world_env.environment
	var sky = env.sky
	if not sky or not sky.sky_material is ProceduralSkyMaterial:
		_print_error("ProceduralSkyMaterial not found")
		return

	var sky_mat = sky.sky_material as ProceduralSkyMaterial

	if args.is_empty():
		_print_line("[color=#6699ff]Sky:[/color]")
		_print_value("top", _color_to_str(sky_mat.sky_top_color))
		_print_value("horizon", _color_to_str(sky_mat.sky_horizon_color))
		_print_value("energy", str(env.background_energy_multiplier))
		return

	var prop = args[0].to_lower()
	var values = args.slice(1)

	match prop:
		"top":
			if values.size() < 3:
				_print_value("top", _color_to_str(sky_mat.sky_top_color))
			else:
				sky_mat.sky_top_color = Color(float(values[0]), float(values[1]), float(values[2]))
				_print_info("Set sky top to " + _color_to_str(sky_mat.sky_top_color))
		"horizon":
			if values.size() < 3:
				_print_value("horizon", _color_to_str(sky_mat.sky_horizon_color))
			else:
				sky_mat.sky_horizon_color = Color(float(values[0]), float(values[1]), float(values[2]))
				_print_info("Set sky horizon to " + _color_to_str(sky_mat.sky_horizon_color))
		"energy":
			if values.is_empty():
				_print_value("energy", str(env.background_energy_multiplier))
			else:
				env.background_energy_multiplier = float(values[0])
				_print_info("Set background energy to " + str(env.background_energy_multiplier))
		_:
			_print_error("Unknown property: " + prop)


func _cmd_fog(args: Array) -> void:
	if not _world_env or not _world_env.environment:
		_print_error("WorldEnvironment not found")
		return

	var env = _world_env.environment

	if args.is_empty():
		_print_line("[color=#6699ff]Fog:[/color]")
		_print_value("enabled", str(env.volumetric_fog_enabled))
		_print_value("density", str(env.volumetric_fog_density))
		return

	var prop = args[0].to_lower()
	var values = args.slice(1)

	match prop:
		"enabled":
			if values.is_empty():
				_print_value("enabled", str(env.volumetric_fog_enabled))
			else:
				env.volumetric_fog_enabled = int(values[0]) != 0
				env.fog_enabled = env.volumetric_fog_enabled
				_print_info("Set fog enabled to " + str(env.volumetric_fog_enabled))
		"density":
			if values.is_empty():
				_print_value("density", str(env.volumetric_fog_density))
			else:
				env.volumetric_fog_density = float(values[0])
				env.fog_density = float(values[0])
				_print_info("Set fog density to " + str(env.volumetric_fog_density))
		_:
			_print_error("Unknown property: " + prop)


func _cmd_ssao(args: Array) -> void:
	if not _world_env or not _world_env.environment:
		_print_error("WorldEnvironment not found")
		return

	var env = _world_env.environment

	if args.is_empty():
		_print_line("[color=#6699ff]SSAO:[/color]")
		_print_value("enabled", str(env.ssao_enabled))
		_print_value("intensity", str(env.ssao_intensity))
		_print_value("radius", str(env.ssao_radius))
		return

	var prop = args[0].to_lower()
	var values = args.slice(1)

	match prop:
		"enabled":
			if values.is_empty():
				_print_value("enabled", str(env.ssao_enabled))
			else:
				env.ssao_enabled = int(values[0]) != 0
				_print_info("Set SSAO enabled to " + str(env.ssao_enabled))
		"intensity":
			if values.is_empty():
				_print_value("intensity", str(env.ssao_intensity))
			else:
				env.ssao_intensity = float(values[0])
				_print_info("Set SSAO intensity to " + str(env.ssao_intensity))
		"radius":
			if values.is_empty():
				_print_value("radius", str(env.ssao_radius))
			else:
				env.ssao_radius = float(values[0])
				_print_info("Set SSAO radius to " + str(env.ssao_radius))
		_:
			_print_error("Unknown property: " + prop)


func _cmd_status(_args: Array) -> void:
	_print_line("[color=#6699ff]═══ Current Lighting Status ═══[/color]")

	if _dir_light:
		_print_line("[color=#ffcc66]DirectionalLight3D:[/color]")
		_print_value("energy", str(_dir_light.light_energy))
		_print_value("color", _color_to_str(_dir_light.light_color))
		_print_value("rotation", _vec3_to_str(_dir_light.rotation_degrees))

	if _world_env and _world_env.environment:
		var env = _world_env.environment
		_print_line("[color=#ffcc66]Ambient:[/color]")
		_print_value("energy", str(env.ambient_light_energy))
		_print_value("color", _color_to_str(env.ambient_light_color))
		_print_value("sky_contribution", str(env.ambient_light_sky_contribution))

		_print_line("[color=#ffcc66]Background:[/color]")
		_print_value("energy", str(env.background_energy_multiplier))

		_print_line("[color=#ffcc66]Fog:[/color]")
		_print_value("enabled", str(env.volumetric_fog_enabled))
		_print_value("density", str(env.volumetric_fog_density))

		_print_line("[color=#ffcc66]SSAO:[/color]")
		_print_value("enabled", str(env.ssao_enabled))
		_print_value("intensity", str(env.ssao_intensity))


func _color_to_str(c: Color) -> String:
	return "%.2f %.2f %.2f" % [c.r, c.g, c.b]


func _vec3_to_str(v: Vector3) -> String:
	return "%.1f %.1f %.1f" % [v.x, v.y, v.z]


func _cmd_net(args: Array) -> void:
	if not _network_manager:
		_network_manager = get_node_or_null("/root/network_manager")
	if not _network_manager:
		_print_error("NetworkManager not found!")
		return

	if args.is_empty():
		_print_line("[color=#6699ff]Network Commands:[/color]")
		_print_line("  net connect [ip]  - Connect to server (default: 127.0.0.1)")
		_print_line("  net disconnect    - Disconnect from server")
		_print_line("  net status        - Show connection status")
		return

	var subcmd = args[0].to_lower()

	match subcmd:
		"connect":
			var ip = "127.0.0.1"
			if args.size() > 1:
				ip = args[1]
			_print_info("Connecting to %s..." % ip)
			if _network_manager.connect_to_server(ip):
				_print_info("Connection initiated")
			else:
				_print_error("Failed to connect")

		"disconnect":
			_network_manager.disconnect_from_server()
			_print_info("Disconnected")

		"status":
			_print_line("[color=#6699ff]═══ Network Status ═══[/color]")
			var connected = _network_manager.is_network_connected()
			_print_value("connected", "Yes" if connected else "No")
			if connected:
				_print_value("player_id", str(_network_manager.my_player_id))
				_print_value("is_host", "Yes" if _network_manager.is_host else "No")
				_print_value("player_name", _network_manager.player_name)

		_:
			_print_error("Unknown subcommand: " + subcmd)
