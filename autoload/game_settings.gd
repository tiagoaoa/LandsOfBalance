extends Node

## GameSettings Autoload
## Stores global game settings like selected character class

# Character class enum (matches Player.CharacterClass)
enum CharacterClass { PALADIN, ARCHER }

# Selected character class - default to Archer
var selected_character_class: int = CharacterClass.ARCHER

# Flag indicating character was selected from menu (skip join_screen prompt)
var character_selected_from_menu: bool = false

# Test mode - disables enemy AI for multiplayer testing
# Set via command line: --test-multiplayer
var test_multiplayer: bool = false

func _ready() -> void:
	# Check for test multiplayer flag
	for arg in OS.get_cmdline_args():
		if arg == "--test-multiplayer":
			test_multiplayer = true
			print("GameSettings: TEST_MULTIPLAYER mode enabled - enemy AI disabled")
			break
