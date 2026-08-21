extends Node

## GameSettings Autoload
## Stores global game settings like selected character class

# Character class enum (matches Player.CharacterClass)
enum CharacterClass { PALADIN, ARCHER }

# Selected character class - default to Archer
var selected_character_class: int = CharacterClass.ARCHER

# Flag indicating character was selected from menu (skip join_screen prompt)
var character_selected_from_menu: bool = false

# True only when a CLI flag (--character-class / a class-forcing scenario)
# pre-picked the class. The COOP menu keys on THIS to decide between
# auto-advance (automation) and waiting for the human's choice —
# character_selected_from_menu is too broad (every singleplayer run sets it).
var class_forced_by_cli: bool = false

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

# Co-op mode: the human's menu pick decides their class, and the OTHER
# class spawns as an AI companion (player/companion_ai.gd). Toggled in the
# character select menu, or forced with --coop / the COOP scenario.
var coop_mode: bool = false

# Spectate mode: NOBODY is human. Both classes spawn as bots and the
# viewport rides a free chase camera (player/ai/spectate_cam.gd) instead of
# either character's own. Set with --spectate or the WATCH scenario.
var spectate: bool = false

# Combat scenario driver — when non-empty, enemies/combat_test.gd runs an
# automated Paladin-vs-Bobba fight. Set via --combat-scenario=A or =B.
# "A" tunes the Paladin to win while taking a couple of hits.
# "B" tunes the Paladin to lose while landing a few strikes.
var combat_scenario: String = ""

# Combat-arena round counter — incremented each time the arena scene
# loads (including via reload_current_scene after a player/Bobba death).
# Persists across scene reloads because the autoload survives them.
var arena_round: int = 0

# When true, Player._trigger_game_restart() skips its auto-reload timer
# and hands control to the arena scene instead (which shows the fun-rating
# overlay before reloading on the user's click).
var arena_mode: bool = false


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
		elif arg == "--spectate":
			spectate = true
			coop_mode = true
			print("GameSettings: Spectate mode enabled (both classes are bots)")
		elif arg == "--coop":
			coop_mode = true
			print("GameSettings: Co-op mode enabled (AI companion)")
		elif arg.begins_with("--combat-scenario="):
			combat_scenario = arg.substr("--combat-scenario=".length()).to_upper()
			# COOP is a human playtest: the MENU decides the player's class
			# and the AI companion takes the other one — force nothing here.
			# ARCHER is the one scripted bow-user run; every other scenario
			# drives the melee kit.
			if combat_scenario in ["COOP", "COOPSIM", "REVIVE", "NOFF", "WATCH"]:
				coop_mode = true
			# WATCH is the two-bot showcase: nobody drives, we just watch.
			if combat_scenario == "WATCH":
				spectate = true
			if combat_scenario == "COOP":
				pass  # menu picks the class
			elif combat_scenario == "ARCHER" or combat_scenario == "BOWSIM" \
					or combat_scenario == "MOBSIM":
				selected_character_class = CharacterClass.ARCHER
				character_selected_from_menu = true
				class_forced_by_cli = true
			else:
				selected_character_class = CharacterClass.PALADIN
				character_selected_from_menu = true
				class_forced_by_cli = true
			singleplayer = true
			print("GameSettings: Combat scenario '%s' enabled (%s, singleplayer)" % [
					combat_scenario,
					"menu picks class, AI plays the other" if combat_scenario == "COOP"
					else ("forcing Archer" if combat_scenario == "ARCHER" else "forcing Paladin")])
		elif arg.begins_with("--character-class="):
			var forced_class := arg.substr("--character-class=".length()).to_lower()
			match forced_class:
				"paladin":
					selected_character_class = CharacterClass.PALADIN
					character_selected_from_menu = true
					class_forced_by_cli = true
					print("GameSettings: Character class forced to Paladin")
				"archer":
					selected_character_class = CharacterClass.ARCHER
					character_selected_from_menu = true
					class_forced_by_cli = true
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
