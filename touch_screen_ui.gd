extends CanvasLayer

## Mobile touch controls for Lands of Balance
## - Virtual joystick on left (move to max for running)
## - Action buttons on right: Spell, Jump, Crouch, Attack
## - Character selection toggle: Paladin/Archer

signal character_class_changed(character_class: int)

# Character class enum (matches Player.CharacterClass)
enum CharacterClass { PALADIN, ARCHER }

var current_class: CharacterClass = CharacterClass.ARCHER

# UI References
var _joystick: Control
var _spell_btn: BaseButton
var _jump_btn: BaseButton
var _run_btn: BaseButton
var _attack_btn: BaseButton
var _class_btn: Button
var _class_label: Label

# Icon textures (legacy - now using righthud overlay)
var _icon_spell: Texture2D
var _icon_jump: Texture2D
var _icon_run: Texture2D
var _icon_attack: Texture2D

# Right HUD overlay texture
var _righthud_texture: Texture2D

# Action mappings for buttons
var _button_actions: Dictionary = {}

# Touch look variables
var _touch_look_area: Control
var _touch_look_active: bool = false
var _touch_look_index: int = -1  # Which touch index is controlling look
var _touch_look_last_pos: Vector2 = Vector2.ZERO
const TOUCH_LOOK_SENSITIVITY: float = 0.004  # Adjust for feel


func _ready() -> void:
	# Show on touch devices or mobile platforms
	var is_mobile: bool = OS.get_name() in ["Android", "iOS"]
	var is_touch: bool = DisplayServer.is_touchscreen_available()

	print("TouchUI: _ready() - is_mobile=%s, is_touch=%s" % [is_mobile, is_touch])

	if not is_mobile and not is_touch:
		print("TouchUI: Hiding - not a touch device")
		hide()
		return

	print("TouchUI: Showing touch controls")
	show()
	_setup_ui()

	# Sync with GameSettings
	if GameSettings:
		current_class = GameSettings.selected_character_class as CharacterClass
		_update_class_display()


func _setup_ui() -> void:
	print("TouchUI: _setup_ui() starting")

	# Load right HUD overlay texture
	_righthud_texture = load("res://righthud.png")
	print("TouchUI: Loaded righthud overlay: %s" % [_righthud_texture != null])

	# Get joystick reference
	_joystick = get_node_or_null("Virtual Joystick")
	print("TouchUI: Joystick found: %s" % (_joystick != null))

	# Setup touch look area (before buttons so it's behind them)
	_setup_touch_look_area()

	# Setup right-side action buttons
	_setup_action_buttons()

	# Setup character selection
	_setup_class_selector()

	print("TouchUI: _setup_ui() complete")


func _setup_touch_look_area() -> void:
	# Remove old touch look area if exists
	var old_look = get_node_or_null("TouchLookArea")
	if old_look:
		old_look.queue_free()

	# Create a transparent touch area covering the right half of screen
	_touch_look_area = Control.new()
	_touch_look_area.name = "TouchLookArea"

	# Cover right 60% of screen (leaving space for joystick on left)
	_touch_look_area.anchor_left = 0.4
	_touch_look_area.anchor_right = 1.0
	_touch_look_area.anchor_top = 0.0
	_touch_look_area.anchor_bottom = 1.0
	_touch_look_area.offset_left = 0
	_touch_look_area.offset_right = 0
	_touch_look_area.offset_top = 0
	_touch_look_area.offset_bottom = 0

	# Make it receive input but pass through to children (buttons)
	_touch_look_area.mouse_filter = Control.MOUSE_FILTER_PASS

	add_child(_touch_look_area)
	print("TouchUI: Touch look area created")


func _input(event: InputEvent) -> void:
	# Handle touch events for camera look
	if event is InputEventScreenTouch:
		_handle_touch(event)
	elif event is InputEventScreenDrag:
		_handle_drag(event)


func _handle_touch(event: InputEventScreenTouch) -> void:
	var screen_size := get_viewport().get_visible_rect().size

	# Check if touch is in the right side of screen (look area)
	# But not on the action buttons (right edge)
	var touch_x_ratio := event.position.x / screen_size.x

	if event.pressed:
		# Touch started - check if in look zone (right 60% but not far right edge with buttons)
		if touch_x_ratio > 0.4 and touch_x_ratio < 0.92:
			# Only start tracking if we're not already tracking a touch
			if _touch_look_index == -1:
				_touch_look_active = true
				_touch_look_index = event.index
				_touch_look_last_pos = event.position
				print("TouchUI: Look started at index %d" % event.index)
	else:
		# Touch ended
		if event.index == _touch_look_index:
			_touch_look_active = false
			_touch_look_index = -1
			print("TouchUI: Look ended")


func _handle_drag(event: InputEventScreenDrag) -> void:
	# Only process if this is our tracked touch
	if event.index != _touch_look_index or not _touch_look_active:
		return

	# Calculate relative movement with 2x sensitivity multiplier
	var relative := (event.position - _touch_look_last_pos) * 2.0
	_touch_look_last_pos = event.position

	# Emit a mouse motion event so the player's camera code receives it
	var mouse_event := InputEventMouseMotion.new()
	mouse_event.relative = relative
	mouse_event.position = event.position

	# Parse the event to send it through the input system
	Input.parse_input_event(mouse_event)


func _setup_action_buttons() -> void:
	# Remove old containers if exists
	var old_container = get_node_or_null("HBoxContainer")
	if old_container:
		old_container.queue_free()
	var old_actions = get_node_or_null("ActionButtons")
	if old_actions:
		old_actions.queue_free()
	var old_hud = get_node_or_null("RightHUD")
	if old_hud:
		old_hud.queue_free()

	# Create container for the right HUD overlay
	var container := Control.new()
	container.name = "RightHUD"
	container.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	container.anchor_left = 1.0
	container.anchor_right = 1.0
	container.anchor_top = 1.0
	container.anchor_bottom = 1.0

	# Use anchors for proper positioning at bottom-right
	# HUD scale increased by 50% for bigger visual buttons
	var hud_scale := 0.375
	var hud_width := 768.0 * hud_scale  # ~288
	var hud_height := 510.0  # Increased height for bigger HUD

	# Anchor to bottom-right, moved 30% towards center
	container.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	container.anchor_left = 1.0
	container.anchor_right = 1.0
	container.anchor_top = 1.0
	container.anchor_bottom = 1.0
	var center_offset := hud_width * 0.3  # 30% towards center
	container.offset_left = -hud_width - 10 - center_offset
	container.offset_top = -hud_height - 10
	container.offset_right = -10 - center_offset
	container.offset_bottom = -10
	add_child(container)

	# Add the HUD image - only show bottom portion with buttons
	var hud_image := TextureRect.new()
	hud_image.name = "HUDImage"
	hud_image.texture = _righthud_texture
	hud_image.custom_minimum_size = Vector2(hud_width, hud_width * 1.77)  # Keep aspect ratio
	hud_image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	hud_image.stretch_mode = TextureRect.STRETCH_SCALE
	# Shift image - raised 10% from previous position
	var img_y_offset := 77.0
	hud_image.position = Vector2(0, img_y_offset)
	hud_image.modulate = Color(1, 1, 1, 0.9)
	hud_image.mouse_filter = Control.MOUSE_FILTER_IGNORE
	container.add_child(hud_image)

	# Button touch area size - matches visual button size + 10%
	# Original button ~200px, scaled by 0.375 = 75px, +10% = ~83px
	var btn_size := Vector2(83, 83)

	# Button positions based on actual image layout (768x1360 original)
	# Row 1: spell (wand) center - lowered
	# Row 2: jump (left), run (right) - running figures (CORRECT)
	# Row 3: attack (left sword)
	var spell_pos := Vector2(384 * hud_scale, 400 * hud_scale + img_y_offset)  # Lowered from 270
	var jump_pos := Vector2(150 * hud_scale, 610 * hud_scale + img_y_offset)   # Row 2 left - CORRECT
	var run_pos := Vector2(618 * hud_scale, 610 * hud_scale + img_y_offset)    # Row 2 right - running figure
	var attack_pos := Vector2(269 * hud_scale, 820 * hud_scale + img_y_offset) # Row 3 - sword (centered)

	print("TouchUI: RightHUD anchored bottom-right, size=(%d,%d)" % [int(hud_width), int(hud_height)])

	# Create invisible touch buttons over each icon position
	_spell_btn = _create_touch_area("spell_cast", spell_pos, btn_size)
	container.add_child(_spell_btn)

	_jump_btn = _create_touch_area("jump", jump_pos, btn_size)
	container.add_child(_jump_btn)

	_attack_btn = _create_touch_area("attack", attack_pos, btn_size)
	container.add_child(_attack_btn)

	_run_btn = _create_touch_area("run", run_pos, btn_size)
	container.add_child(_run_btn)


## Create an invisible touch area button (for use with HUD overlay)
func _create_touch_area(action: String, center_pos: Vector2, btn_size: Vector2) -> Button:
	var btn := Button.new()
	btn.name = action + "_btn"

	# Invisible button - HUD image provides the visual
	btn.flat = true
	var transparent_style := StyleBoxFlat.new()
	transparent_style.bg_color = Color(0, 0, 0, 0)
	btn.add_theme_stylebox_override("normal", transparent_style)
	btn.add_theme_stylebox_override("hover", transparent_style)
	btn.add_theme_stylebox_override("pressed", transparent_style)
	btn.add_theme_stylebox_override("focus", transparent_style)

	# Size and position
	btn.custom_minimum_size = btn_size
	btn.size = btn_size
	btn.position = center_pos - btn_size / 2

	# Ensure button can receive input
	btn.mouse_filter = Control.MOUSE_FILTER_STOP
	btn.focus_mode = Control.FOCUS_ALL

	# Store action mapping
	_button_actions[btn] = action

	# Connect signals
	btn.button_down.connect(_on_touch_area_down.bind(btn))
	btn.button_up.connect(_on_touch_area_up.bind(btn))

	print("TouchUI: Created touch area '%s' at %s size=%s" % [action, center_pos, btn_size])

	return btn


## Handle touch area press
func _on_touch_area_down(btn: Button) -> void:
	var action: String = _button_actions.get(btn, "")
	if action != "":
		print("TouchUI: Touch DOWN - action '%s'" % action)
		var event := InputEventAction.new()
		event.action = action
		event.pressed = true
		Input.parse_input_event(event)


## Handle touch area release
func _on_touch_area_up(btn: Button) -> void:
	var action: String = _button_actions.get(btn, "")
	if action != "":
		print("TouchUI: Touch UP - action '%s'" % action)
		var event := InputEventAction.new()
		event.action = action
		event.pressed = false
		Input.parse_input_event(event)


## Create an icon-based touch button using TextureButton (legacy - kept for compatibility)
func _create_icon_button(icon: Texture2D, action: String, btn_size: Vector2 = Vector2(72, 72)) -> TextureButton:
	var btn := TextureButton.new()
	btn.name = action + "_btn"

	# Set the icon texture
	btn.texture_normal = icon
	btn.texture_pressed = icon

	# Size for mobile - use provided size
	btn.custom_minimum_size = btn_size
	btn.size = btn_size
	btn.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
	btn.ignore_texture_size = true

	# Semi-transparent background for better visibility
	btn.modulate = Color(1, 1, 1, 0.9)

	# Ensure button can receive input
	btn.mouse_filter = Control.MOUSE_FILTER_STOP
	btn.focus_mode = Control.FOCUS_ALL

	# Store action mapping
	_button_actions[btn] = action

	# Connect signals to trigger input actions
	btn.button_down.connect(_on_action_button_down.bind(btn))
	btn.button_up.connect(_on_action_button_up.bind(btn))

	print("TouchUI: Created button '%s' size=%s" % [action, btn_size])

	return btn


func _on_action_button_down(btn: TextureButton) -> void:
	var action: String = _button_actions.get(btn, "")
	if action != "":
		print("TouchUI: Button DOWN - action '%s'" % action)
		# Create and emit a proper InputEvent so _input() handlers receive it
		var event := InputEventAction.new()
		event.action = action
		event.pressed = true
		Input.parse_input_event(event)


func _on_action_button_up(btn: TextureButton) -> void:
	var action: String = _button_actions.get(btn, "")
	if action != "":
		print("TouchUI: Button UP - action '%s'" % action)
		# Create and emit a proper InputEvent
		var event := InputEventAction.new()
		event.action = action
		event.pressed = false
		Input.parse_input_event(event)


func _setup_class_selector() -> void:
	# Create class selector at top-right
	var class_container := VBoxContainer.new()
	class_container.name = "ClassSelector"
	class_container.anchors_preset = Control.PRESET_TOP_RIGHT
	class_container.anchor_left = 1.0
	class_container.anchor_right = 1.0
	class_container.offset_left = -160
	class_container.offset_top = 20
	class_container.offset_right = -20
	class_container.offset_bottom = 100
	class_container.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	add_child(class_container)

	# Class label
	_class_label = Label.new()
	_class_label.name = "ClassLabel"
	_class_label.text = "CLASS"
	_class_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_class_label.add_theme_font_size_override("font_size", 14)
	_class_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	class_container.add_child(_class_label)

	# Class toggle button
	_class_btn = Button.new()
	_class_btn.name = "ClassButton"
	_class_btn.text = "ARCHER"
	_class_btn.custom_minimum_size = Vector2(140, 50)
	_class_btn.pressed.connect(_on_class_button_pressed)

	# Style the button
	var btn_style := StyleBoxFlat.new()
	btn_style.bg_color = Color(0.3, 0.5, 0.7)
	btn_style.corner_radius_top_left = 10
	btn_style.corner_radius_top_right = 10
	btn_style.corner_radius_bottom_left = 10
	btn_style.corner_radius_bottom_right = 10
	btn_style.border_width_left = 2
	btn_style.border_width_right = 2
	btn_style.border_width_top = 2
	btn_style.border_width_bottom = 2
	btn_style.border_color = Color(1, 1, 1, 0.3)
	_class_btn.add_theme_stylebox_override("normal", btn_style)

	var btn_hover := btn_style.duplicate()
	btn_hover.bg_color = Color(0.4, 0.6, 0.8)
	_class_btn.add_theme_stylebox_override("hover", btn_hover)

	var btn_pressed := btn_style.duplicate()
	btn_pressed.bg_color = Color(0.2, 0.4, 0.6)
	_class_btn.add_theme_stylebox_override("pressed", btn_pressed)

	class_container.add_child(_class_btn)

	_update_class_display()


func _on_class_button_pressed() -> void:
	# Toggle between Paladin and Archer
	if current_class == CharacterClass.ARCHER:
		current_class = CharacterClass.PALADIN
	else:
		current_class = CharacterClass.ARCHER

	_update_class_display()

	# Update GameSettings
	if GameSettings:
		GameSettings.selected_character_class = current_class

	# Emit signal for player to handle
	character_class_changed.emit(current_class)

	# Also send input action for compatibility
	if current_class == CharacterClass.PALADIN:
		Input.action_press("class_paladin")
		await get_tree().create_timer(0.1).timeout
		Input.action_release("class_paladin")
	else:
		Input.action_press("class_archer")
		await get_tree().create_timer(0.1).timeout
		Input.action_release("class_archer")


func _update_class_display() -> void:
	if not _class_btn:
		return

	match current_class:
		CharacterClass.PALADIN:
			_class_btn.text = "PALADIN"
			var style: StyleBoxFlat = _class_btn.get_theme_stylebox("normal").duplicate()
			style.bg_color = Color(0.7, 0.5, 0.2)  # Gold/orange for Paladin
			_class_btn.add_theme_stylebox_override("normal", style)
		CharacterClass.ARCHER:
			_class_btn.text = "ARCHER"
			var style: StyleBoxFlat = _class_btn.get_theme_stylebox("normal").duplicate()
			style.bg_color = Color(0.3, 0.6, 0.4)  # Green for Archer
			_class_btn.add_theme_stylebox_override("normal", style)


func set_character_class(new_class: CharacterClass) -> void:
	current_class = new_class
	_update_class_display()
