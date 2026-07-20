extends Control

## Character Selection Menu
## First screen shown to player - choose between Archer and Paladin

signal character_selected(character_class: int)

# Character class enum (matches Player.CharacterClass)
enum CharacterClass { PALADIN, ARCHER }

var _selected_class: CharacterClass = CharacterClass.ARCHER
# Co-op with an AI companion is the default mode: the class you pick is
# yours, the other one joins as an AI teammate. Toggle with C.
var _coop_enabled: bool = true
var _coop_label: Label


func _ready() -> void:
	# Ensure mouse is visible for menu
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

	# Connect button signals
	$VBoxContainer/ButtonsContainer/ArcherButton.pressed.connect(_on_archer_pressed)
	$VBoxContainer/ButtonsContainer/PaladinButton.pressed.connect(_on_paladin_pressed)
	$VBoxContainer/PlayButton.pressed.connect(_on_play_pressed)

	# Co-op toggle line under the class buttons
	_coop_label = Label.new()
	_coop_label.name = "CoopLabel"
	_coop_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	$VBoxContainer.add_child(_coop_label)
	_update_coop_label()

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
			_coop_enabled = true
			_update_coop_label()
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


func _update_coop_label() -> void:
	if _coop_label:
		_coop_label.text = "[C] Co-op with AI companion: %s" % ("ON" if _coop_enabled else "OFF")
		_coop_label.modulate = Color(0.9, 0.85, 0.6) if _coop_enabled else Color(0.55, 0.55, 0.55)


func _on_play_pressed() -> void:
	# Store selection in autoload/singleton for game scene to access
	GameSettings.selected_character_class = _selected_class
	GameSettings.character_selected_from_menu = true
	# Scenario runs set coop_mode themselves (auto-advance must not stomp it)
	if String(GameSettings.combat_scenario) == "":
		GameSettings.coop_mode = _coop_enabled

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
			KEY_C:
				_coop_enabled = not _coop_enabled
				_update_coop_label()
			KEY_ENTER, KEY_SPACE:
				_on_play_pressed()
