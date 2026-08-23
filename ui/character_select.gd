extends Control

## Character Selection Menu
## First screen shown to player - choose between Archer and Paladin

signal character_selected(character_class: int)

# Character class enum (matches Player.CharacterClass)
enum CharacterClass { PALADIN, ARCHER }

var _selected_class: CharacterClass = CharacterClass.ARCHER

# How the match is crewed: the class you pick is always yours; AI CO-OP
# gives the other class to an AI teammate, MULTIPLAYER joins the shared
# server match together with everyone else who picked MULTIPLAYER.
enum PlayMode { AI_COOP, MULTIPLAYER }
var _mode: PlayMode = PlayMode.AI_COOP
var _mode_button: Button
# Whether NetworkManager already auto-connected at boot (multiplayer-default
# launches: run_local.sh and friends). Governs connect/disconnect on Play.
var _connected_at_boot: bool = false


func _ready() -> void:
	# Ensure mouse is visible for menu
	CloudInput.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

	# Connect button signals
	$VBoxContainer/ButtonsContainer/ArcherButton.pressed.connect(_on_archer_pressed)
	$VBoxContainer/ButtonsContainer/PaladinButton.pressed.connect(_on_paladin_pressed)
	$VBoxContainer/PlayButton.pressed.connect(_on_play_pressed)

	# Mode toggle under the class buttons: a real button, because cloud
	# players drive this menu with a streamed mouse.
	_mode_button = Button.new()
	_mode_button.name = "ModeButton"
	_mode_button.flat = true
	_mode_button.pressed.connect(_toggle_mode)
	$VBoxContainer.add_child(_mode_button)
	if GameSettings and not GameSettings.singleplayer:
		# Booted straight into multiplayer (local test scripts): keep that
		# as the menu default so pressing Play changes nothing.
		_mode = PlayMode.MULTIPLAYER
		_connected_at_boot = true
	_update_mode_button()

	# Default selection
	_update_selection(CharacterClass.ARCHER)

	# Auto-advance for automated combat tests (see enemies/combat_test.gd).
	# Respect the class GameSettings picked for the scenario — the ARCHER
	# playtest forces Archer; every other scenario forces Paladin.
	# COOP is the exception: the human MUST choose here (Archer or Paladin —
	# the AI companion plays the other), so the menu stays interactive
	# unless a --character-class flag pre-picked for automation.
	if "combat_scenario" in GameSettings and String(GameSettings.combat_scenario) != "":
		if String(GameSettings.combat_scenario) == "COOP":
			_mode = PlayMode.AI_COOP
			_update_mode_button()
			if GameSettings.class_forced_by_cli:  # --character-class automation
				_update_selection(GameSettings.selected_character_class as CharacterClass)
				call_deferred("_on_play_pressed")
		else:
			_update_selection(GameSettings.selected_character_class as CharacterClass)
			call_deferred("_on_play_pressed")


func _on_archer_pressed() -> void:
	_update_selection(CharacterClass.ARCHER)


func _on_paladin_pressed() -> void:
	_update_selection(CharacterClass.PALADIN)


func _update_selection(char_class: CharacterClass) -> void:
	_selected_class = char_class

	# Update button visuals
	var archer_btn: Button = $VBoxContainer/ButtonsContainer/ArcherButton
	var paladin_btn: Button = $VBoxContainer/ButtonsContainer/PaladinButton

	if char_class == CharacterClass.ARCHER:
		archer_btn.add_theme_color_override("font_color", Color.WHITE)
		archer_btn.modulate = Color(1.2, 1.2, 1.2)
		paladin_btn.add_theme_color_override("font_color", Color.GRAY)
		paladin_btn.modulate = Color(0.7, 0.7, 0.7)
		$VBoxContainer/DescriptionLabel.text = "Archer - Ranged combat with bow and fire magic"
	else:
		paladin_btn.add_theme_color_override("font_color", Color.WHITE)
		paladin_btn.modulate = Color(1.2, 1.2, 1.2)
		archer_btn.add_theme_color_override("font_color", Color.GRAY)
		archer_btn.modulate = Color(0.7, 0.7, 0.7)
		$VBoxContainer/DescriptionLabel.text = "Paladin - Melee combat with sword and lightning magic"


func _toggle_mode() -> void:
	_mode = PlayMode.MULTIPLAYER if _mode == PlayMode.AI_COOP else PlayMode.AI_COOP
	_update_mode_button()


func _update_mode_button() -> void:
	if _mode_button == null:
		return
	if _mode == PlayMode.MULTIPLAYER:
		_mode_button.text = "[M] Mode: MULTIPLAYER  (shared online match)"
		_mode_button.modulate = Color(0.65, 0.85, 1.0)
	else:
		_mode_button.text = "[M] Mode: AI CO-OP  (an AI ally plays the other class)"
		_mode_button.modulate = Color(0.9, 0.85, 0.6)


func _on_play_pressed() -> void:
	# Store selection in autoload/singleton for game scene to access
	GameSettings.selected_character_class = _selected_class
	GameSettings.character_selected_from_menu = true
	# Scenario runs set coop_mode themselves (auto-advance must not stomp it)
	if String(GameSettings.combat_scenario) == "":
		var nm := get_node_or_null("/root/NetworkManager")
		if _mode == PlayMode.MULTIPLAYER:
			GameSettings.singleplayer = false
			GameSettings.coop_mode = false
			# Booted offline (the cloud default): the connection nobody
			# made at startup happens now; JoinScreen takes it from there.
			if nm and not _connected_at_boot:
				nm.spectate_server()
		else:
			GameSettings.singleplayer = true
			GameSettings.coop_mode = true
			if nm and _connected_at_boot:
				nm.disconnect_from_server()

	# Load game scene
	get_tree().change_scene_to_file("res://game.tscn")


func _input(event: InputEvent) -> void:
	# Keyboard shortcuts
	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_1:
				_update_selection(CharacterClass.PALADIN)
			KEY_2:
				_update_selection(CharacterClass.ARCHER)
			KEY_M, KEY_C:
				_toggle_mode()
			KEY_ENTER, KEY_SPACE:
				_on_play_pressed()
