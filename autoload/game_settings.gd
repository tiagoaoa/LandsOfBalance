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

# Singleplayer mode - skips server connection, goes straight to game.
# Every client (including local test sessions) now connects to the game
# server by default (127.0.0.1 unless overridden with --server-host), so
# there's no host/non-host asymmetry. Pass --singleplayer on the command
# line to fall back to the old offline mode for quick iteration.
var singleplayer: bool = false

# Performance mode - disables or reduces expensive visuals for profiling and low-end hardware
# Set via command line: --performance-mode
var performance_mode: bool = false

# Combat scenario driver — when non-empty, enemies/combat_test.gd runs an
# automated Paladin-vs-Bobba fight. Set via --combat-scenario=A or =B.
# "A" tunes the Paladin to win while taking a couple of hits.
# "B" tunes the Paladin to lose while landing a few strikes.
var combat_scenario: String = ""


func _all_cmdline_args() -> Array[String]:
	var args: Array[String] = []
	for arg in OS.get_cmdline_args():
		args.append(str(arg))
	for arg in OS.get_cmdline_user_args():
		var value := str(arg)
		if not args.has(value):
			args.append(value)
	return args

func _ready() -> void:
	for arg in _all_cmdline_args():
		if arg == "--test-multiplayer":
			test_multiplayer = true
			print("GameSettings: TEST_MULTIPLAYER mode enabled - enemy AI disabled")
		elif arg == "--multiplayer":
			# Explicitly request multiplayer (default now, but keep for
			# backward-compatible scripts that still pass this flag).
			singleplayer = false
			print("GameSettings: Multiplayer mode enabled")
		elif arg == "--singleplayer":
			singleplayer = true
			print("GameSettings: Singleplayer mode enabled (offline)")
		elif arg == "--performance-mode":
			performance_mode = true
			print("GameSettings: Performance mode enabled")
		elif arg.begins_with("--combat-scenario="):
			combat_scenario = arg.substr("--combat-scenario=".length()).to_upper()
			selected_character_class = CharacterClass.PALADIN
			character_selected_from_menu = true
			singleplayer = true
			print("GameSettings: Combat scenario '%s' enabled (forcing Paladin + singleplayer)" % combat_scenario)
		elif arg.begins_with("--character-class="):
			var forced_class := arg.substr("--character-class=".length()).to_lower()
			match forced_class:
				"paladin":
					selected_character_class = CharacterClass.PALADIN
					character_selected_from_menu = true
					print("GameSettings: Character class forced to Paladin")
				"archer":
					selected_character_class = CharacterClass.ARCHER
					character_selected_from_menu = true
					print("GameSettings: Character class forced to Archer")
				_:
					print("GameSettings: Ignoring unknown character class '%s'" % forced_class)

	if singleplayer:
		character_selected_from_menu = true
		print("GameSettings: Singleplayer mode (offline, no server connection)")
	else:
		# In multiplayer, also auto-skip the join screen so local tests
		# start as a pure client as soon as the scene loads.
		character_selected_from_menu = true
		print("GameSettings: Multiplayer mode — connecting to server on startup")
