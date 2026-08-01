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
var _crouch_btn: Button
var _crouch_icon: TextureRect
var _crouch_on: bool = false
var _attack_btn: BaseButton
var _class_btn: Button
var _class_label: Label

# Icon textures (legacy - now using righthud overlay)
var _revive_btn: Button = null
var _guard_btn: Button = null
var _guard_draw: Control = null
var _revive_draw: Control = null
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

	# Co-op revive button (hidden until the player stands by a fallen ally)
	_setup_revive_button()
	_setup_guard_button()

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

	# CROUCH: was never wired on mobile at all. Tap-to-TOGGLE (holding a
	# crouch button while also steering and aiming is impossible on touch).
	# The action state persists between taps, so player.gd's normal
	# Input.is_action_pressed("crouch") polling just works.
	var crouch_pos := Vector2(560 * hud_scale, 820 * hud_scale + img_y_offset)
	_crouch_icon = TextureRect.new()
	_crouch_icon.name = "CrouchIcon"
	_crouch_icon.texture = load("res://assets/hud_icons/icon_crouch_new.png")
	_crouch_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_crouch_icon.custom_minimum_size = Vector2(64, 64)
	_crouch_icon.size = Vector2(64, 64)
	_crouch_icon.position = crouch_pos - Vector2(32, 32)
	_crouch_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_crouch_icon.modulate = Color(1, 1, 1, 0.55)
	container.add_child(_crouch_icon)
	_crouch_btn = Button.new()
	_crouch_btn.name = "crouch_btn"
	_crouch_btn.flat = true
	var t_style := StyleBoxFlat.new()
	t_style.bg_color = Color(0, 0, 0, 0)
	for st in ["normal", "hover", "pressed", "focus"]:
		_crouch_btn.add_theme_stylebox_override(st, t_style)
	_crouch_btn.custom_minimum_size = btn_size
	_crouch_btn.size = btn_size
	_crouch_btn.position = crouch_pos - btn_size / 2
	_crouch_btn.mouse_filter = Control.MOUSE_FILTER_STOP
	_crouch_btn.pressed.connect(_on_crouch_toggled)
	container.add_child(_crouch_btn)
	print("TouchUI: Created crouch toggle at %s" % crouch_pos)


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


## ------------------------------------------------------------------
## CO-OP REVIVE BUTTON (mobile): a round hospital-cross button that only
## appears when the player is standing close enough to a fallen ally to
## revive them. Holding it channels the revive; the channel's progress is
## drawn as a bright arc lighting up the button's circular edge, sweeping
## CLOCKWISE from 12 o'clock.
## ------------------------------------------------------------------
const REVIVE_BTN_SIZE := 116.0

func _setup_revive_button() -> void:
	# Invisible touch button drives the "revive" action (hold-to-channel).
	_revive_btn = _create_touch_area("revive",
			Vector2.ZERO, Vector2(REVIVE_BTN_SIZE, REVIVE_BTN_SIZE))
	_revive_btn.name = "ReviveButton"
	# Anchor to the right edge, above the action cluster.
	_revive_btn.anchor_left = 1.0
	_revive_btn.anchor_right = 1.0
	_revive_btn.anchor_top = 0.5
	_revive_btn.anchor_bottom = 0.5
	_revive_btn.position = Vector2.ZERO
	_revive_btn.offset_left = -REVIVE_BTN_SIZE - 34.0
	_revive_btn.offset_right = -34.0
	_revive_btn.offset_top = -REVIVE_BTN_SIZE * 0.5
	_revive_btn.offset_bottom = REVIVE_BTN_SIZE * 0.5
	add_child(_revive_btn)

	# The visual rides on top and never eats input.
	_revive_draw = Control.new()
	_revive_draw.name = "ReviveButtonArt"
	_revive_draw.set_anchors_preset(Control.PRESET_FULL_RECT)
	_revive_draw.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_revive_draw.draw.connect(_draw_revive_button)
	_revive_btn.add_child(_revive_draw)

	_revive_btn.visible = false


## ------------------------------------------------------------------
## GUARD BUTTON (mobile): hold to defend, release to drop the guard.
## Touch had NO defend control at all — only a controller could block.
## Strict hold semantics: the action is pressed exactly while the finger
## is down, and _process force-releases it if the button ever reports
## "up" while the action is still latched (a finger sliding off a touch
## button does not always deliver button_up).
## ------------------------------------------------------------------
const GUARD_BTN_SIZE := 104.0

func _setup_guard_button() -> void:
	_guard_btn = _create_touch_area("block",
			Vector2.ZERO, Vector2(GUARD_BTN_SIZE, GUARD_BTN_SIZE))
	_guard_btn.name = "GuardButton"
	# Left of the action cluster, above the attack button — reachable with
	# the right thumb without covering the crouch/attack row.
	_guard_btn.anchor_left = 1.0
	_guard_btn.anchor_right = 1.0
	_guard_btn.anchor_top = 1.0
	_guard_btn.anchor_bottom = 1.0
	# Just LEFT of the right-hand action cluster (that overlay ends about
	# 384px in from the right edge), at attack-row height — right thumb
	# reach, clear of the joystick, the HUD art and the revive button.
	_guard_btn.offset_left = -500.0
	_guard_btn.offset_right = -500.0 + GUARD_BTN_SIZE
	_guard_btn.offset_top = -244.0
	_guard_btn.offset_bottom = -244.0 + GUARD_BTN_SIZE
	add_child(_guard_btn)

	_guard_draw = Control.new()
	_guard_draw.name = "GuardButtonArt"
	_guard_draw.set_anchors_preset(Control.PRESET_FULL_RECT)
	_guard_draw.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_guard_draw.draw.connect(_draw_guard_button)
	_guard_btn.add_child(_guard_draw)


## A heater shield, filled while the guard is actually up.
func _draw_guard_button() -> void:
	var s := GUARD_BTN_SIZE
	var up: bool = _guard_btn != null and _guard_btn.button_pressed
	var body := Color(0.75, 0.80, 0.90, 0.95) if up else Color(0.55, 0.60, 0.68, 0.55)
	var edge := Color(0.95, 0.98, 1.0, 0.95) if up else Color(0.80, 0.85, 0.92, 0.6)
	var pts := PackedVector2Array([
		Vector2(s * 0.5, s * 0.14),
		Vector2(s * 0.86, s * 0.28),
		Vector2(s * 0.80, s * 0.60),
		Vector2(s * 0.5, s * 0.88),
		Vector2(s * 0.20, s * 0.60),
		Vector2(s * 0.14, s * 0.28),
	])
	_guard_draw.draw_colored_polygon(pts, body)
	for i in range(pts.size()):
		_guard_draw.draw_line(pts[i], pts[(i + 1) % pts.size()], edge, 3.0)
	# Boss + cross band so it reads as a shield at thumb size.
	_guard_draw.draw_line(Vector2(s * 0.5, s * 0.18), Vector2(s * 0.5, s * 0.82), edge, 2.5)
	_guard_draw.draw_line(Vector2(s * 0.18, s * 0.40), Vector2(s * 0.82, s * 0.40), edge, 2.5)


func _draw_revive_button() -> void:
	var c := Vector2(REVIVE_BTN_SIZE, REVIVE_BTN_SIZE) * 0.5
	var r := REVIVE_BTN_SIZE * 0.5 - 6.0
	# Disc + rim
	_revive_draw.draw_circle(c, r, Color(0.04, 0.10, 0.20, 0.82))
	_revive_draw.draw_arc(c, r, 0.0, TAU, 48, Color(0.25, 0.45, 0.7, 0.9), 3.0)
	# Hospital cross
	var arm := r * 0.62
	var thick := r * 0.42
	var cross_col := Color(0.95, 0.98, 1.0, 0.95)
	_revive_draw.draw_rect(Rect2(c.x - thick * 0.5, c.y - arm, thick, arm * 2.0), cross_col)
	_revive_draw.draw_rect(Rect2(c.x - arm, c.y - thick * 0.5, arm * 2.0, thick), cross_col)
	# Channel progress: bright blue edge arc, CLOCKWISE from the top.
	var progress := _revive_progress_frac()
	if progress > 0.0:
		_revive_draw.draw_arc(c, r + 1.0, -PI / 2.0, -PI / 2.0 + TAU * progress,
				64, Color(0.35, 0.85, 1.0, 1.0), 7.0)


func _revive_progress_frac() -> float:
	var player := get_tree().get_first_node_in_group("player")
	if player == null or not ("_revive_progress" in player):
		return 0.0
	return clampf(float(player._revive_progress) / float(player.REVIVE_TIME), 0.0, 1.0)


func _process(_delta: float) -> void:
	# GUARD: strict hold semantics. If the button is not held but the
	# action is still latched (finger slid off, touch cancelled, scene
	# change mid-hold), release it — a stuck guard is exactly the bug
	# this button must never reproduce.
	if _guard_btn != null:
		if not _guard_btn.button_pressed and Input.is_action_pressed(&"block"):
			var gev := InputEventAction.new()
			gev.action = "block"
			gev.pressed = false
			Input.parse_input_event(gev)
		_guard_draw.queue_redraw()

	if _revive_btn == null:
		return
	var player := get_tree().get_first_node_in_group("player")
	var other := get_tree().get_first_node_in_group("companion")
	var can_revive := false
	if player != null and is_instance_valid(player) and other != null \
			and is_instance_valid(other) and "is_dead" in other and other.is_dead \
			and not ("is_dead" in player and player.is_dead):
		var dist: float = player.global_position.distance_to(other.global_position)
		can_revive = dist <= float(player.REVIVE_RANGE)
	if _revive_btn.visible != can_revive:
		_revive_btn.visible = can_revive
		if not can_revive:
			# Walking away mid-hold must also release the action.
			var ev := InputEventAction.new()
			ev.action = "revive"
			ev.pressed = false
			Input.parse_input_event(ev)
	if can_revive:
		_revive_draw.queue_redraw()


func _on_crouch_toggled() -> void:
	_crouch_on = not _crouch_on
	var ev := InputEventAction.new()
	ev.action = "crouch"
	ev.pressed = _crouch_on
	Input.parse_input_event(ev)
	if _crouch_icon:
		_crouch_icon.modulate = Color(0.5, 0.9, 1.0, 1.0) if _crouch_on \
				else Color(1, 1, 1, 0.55)
	print("TouchUI: crouch toggled %s" % ("ON" if _crouch_on else "OFF"))


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
