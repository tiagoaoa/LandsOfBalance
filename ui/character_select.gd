extends Control

## Character Selection Menu
## First screen shown to player - choose between Archer and Paladin

signal character_selected(character_class: int)

# Character class enum (matches Player.CharacterClass)
enum CharacterClass { PALADIN, ARCHER }

var _selected_class: CharacterClass = CharacterClass.ARCHER


func _ready() -> void:
	# Ensure mouse is visible for menu
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

	# Connect button signals
	$VBoxContainer/ButtonsContainer/ArcherButton.pressed.connect(_on_archer_pressed)
	$VBoxContainer/ButtonsContainer/PaladinButton.pressed.connect(_on_paladin_pressed)
	$VBoxContainer/PlayButton.pressed.connect(_on_play_pressed)

	# Default selection
	_update_selection(CharacterClass.ARCHER)


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


func _on_play_pressed() -> void:
	# Store selection in autoload/singleton for game scene to access
	GameSettings.selected_character_class = _selected_class
	GameSettings.character_selected_from_menu = true

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
			KEY_ENTER, KEY_SPACE:
				_on_play_pressed()
