extends Node3D

## Minimal Paladin-vs-Bobba combat arena.
##
## Stripped of village / grass / dragon / minimap / networking clutter so
## combat can be tuned in isolation. Reloads itself on either death to
## run the next round; `GameSettings.arena_round` persists the counter
## across reloads (autoload outlives `reload_current_scene()`).
##
## Launch with tools/run_combat_arena.sh (or pass
## `--scene res://tests/combat_arena/arena.tscn --singleplayer
## --character-class=paladin` to godot directly).

const PLAYER_SCENE: PackedScene = preload("res://player/player.tscn")
const BOBBA_SCENE: PackedScene = preload("res://enemies/bobba.tscn")

## Tight 20×20 m arena — small enough that a mis-timed Bobba knockback
## still leaves the Paladin in the fight, and walls stop either actor
## from ever leaving the floor. Wall height 8 m blocks a directional
## jump (JUMP_FORWARD_BOOST 5.5 m/s + JUMP_VELOCITY 6.0 m/s reaches ~2 m
## up across a few meters, well below the ceiling).
const ARENA_HALF_EXTENT: float = 10.0
const WALL_HEIGHT: float = 8.0
const WALL_THICKNESS: float = 0.6
const GROUND_Y: float = 0.0
const PLAYER_SPAWN := Vector3(0.0, 2.0, -4.0)
const BOBBA_SPAWN := Vector3(0.0, 2.0, 4.0)
const FUN_LOG_PATH := "res://docs/fun_log.ndjson"

var _round_label: Label
var _player: Node = null
var _bobba: Node = null
var _round_started_at_usec: int = 0
var _rating_pending: bool = false


func _ready() -> void:
	_build_environment()
	_build_ground()
	_build_ui()
	_spawn_combatants()
	# Bump the round counter as soon as the scene finishes loading. The
	# autoload (GameSettings) survives reload_current_scene so this is the
	# single source of truth for "how many fights have happened".
	var gs := get_node_or_null("/root/GameSettings")
	if gs:
		gs.arena_round += 1
		gs.arena_mode = true  # tell Player to skip its auto-reload timer
		if _round_label:
			_round_label.text = "ROUND %d" % gs.arena_round
	_round_started_at_usec = Time.get_ticks_usec()


func _physics_process(_delta: float) -> void:
	# Defensive: if walls fail and someone ends up below the floor, snap
	# them back to their spawn instead of letting them free-fall forever.
	if is_instance_valid(_player) and _player.global_position.y < -10.0:
		_player.global_position = PLAYER_SPAWN
		_player.velocity = Vector3.ZERO
	if is_instance_valid(_bobba) and _bobba.global_position.y < -10.0:
		_bobba.global_position = BOBBA_SPAWN


func _build_environment() -> void:
	# Bright daytime lighting so the user can read the fight clearly —
	# this scene is about tuning combat feel, not atmosphere.
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.42, 0.58, 0.82)
	sky_mat.sky_horizon_color = Color(0.75, 0.80, 0.85)
	sky_mat.ground_bottom_color = Color(0.15, 0.14, 0.13)
	sky_mat.ground_horizon_color = Color(0.40, 0.38, 0.34)
	sky.sky_material = sky_mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 1.0
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 1.2

	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45.0, -35.0, 0.0)
	sun.light_energy = 1.0
	sun.shadow_enabled = true
	add_child(sun)


func _build_ground() -> void:
	# CSGBox3D generates its own implicit collision body when it's a
	# scene-root CSG and use_collision is true. Wrapping it under a
	# StaticBody3D disables that, so these live as direct children of
	# the arena root (same pattern MainGround uses in the main scene).
	var floor_mat := StandardMaterial3D.new()
	floor_mat.albedo_color = Color(0.28, 0.24, 0.20)
	floor_mat.roughness = 0.92

	var floor := CSGBox3D.new()
	floor.name = "ArenaFloor"
	floor.size = Vector3(ARENA_HALF_EXTENT * 2.0, 1.0, ARENA_HALF_EXTENT * 2.0)
	floor.use_collision = true
	floor.position = Vector3(0, GROUND_Y - 0.5, 0)
	floor.material = floor_mat
	add_child(floor)

	# Four containment walls — each its own CSGBox3D with use_collision.
	var wall_mat := StandardMaterial3D.new()
	wall_mat.albedo_color = Color(0.14, 0.11, 0.08)
	wall_mat.roughness = 1.0

	var wall_defs := [
		# [name, center, size]
		["WallNorth",
		 Vector3(0, WALL_HEIGHT * 0.5, -ARENA_HALF_EXTENT - WALL_THICKNESS * 0.5),
		 Vector3(ARENA_HALF_EXTENT * 2.0 + WALL_THICKNESS * 2.0, WALL_HEIGHT, WALL_THICKNESS)],
		["WallSouth",
		 Vector3(0, WALL_HEIGHT * 0.5, ARENA_HALF_EXTENT + WALL_THICKNESS * 0.5),
		 Vector3(ARENA_HALF_EXTENT * 2.0 + WALL_THICKNESS * 2.0, WALL_HEIGHT, WALL_THICKNESS)],
		["WallWest",
		 Vector3(-ARENA_HALF_EXTENT - WALL_THICKNESS * 0.5, WALL_HEIGHT * 0.5, 0),
		 Vector3(WALL_THICKNESS, WALL_HEIGHT, ARENA_HALF_EXTENT * 2.0)],
		["WallEast",
		 Vector3(ARENA_HALF_EXTENT + WALL_THICKNESS * 0.5, WALL_HEIGHT * 0.5, 0),
		 Vector3(WALL_THICKNESS, WALL_HEIGHT, ARENA_HALF_EXTENT * 2.0)],
	]
	for wd in wall_defs:
		var wall := CSGBox3D.new()
		wall.name = wd[0]
		wall.size = wd[2]
		wall.position = wd[1]
		wall.use_collision = true
		wall.material = wall_mat
		add_child(wall)


func _build_ui() -> void:
	var canvas := CanvasLayer.new()
	canvas.layer = 50
	add_child(canvas)

	_round_label = Label.new()
	_round_label.text = "ROUND 1"
	_round_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_round_label.offset_top = 12
	_round_label.offset_bottom = 48
	_round_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_round_label.add_theme_font_size_override("font_size", 28)
	_round_label.add_theme_color_override("font_color", Color(0.98, 0.92, 0.75))
	_round_label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0))
	_round_label.add_theme_constant_override("outline_size", 4)
	canvas.add_child(_round_label)

	var help := Label.new()
	help.text = "Jump (Space) evades — airborne hits deal half damage"
	help.set_anchors_preset(Control.PRESET_TOP_WIDE)
	help.offset_top = 48
	help.offset_bottom = 72
	help.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	help.add_theme_font_size_override("font_size", 12)
	help.add_theme_color_override("font_color", Color(0.75, 0.70, 0.55))
	canvas.add_child(help)


func _spawn_combatants() -> void:
	_player = PLAYER_SCENE.instantiate()
	_player.position = PLAYER_SPAWN
	# Singleplayer arena — no network manager, no server sync.
	if "enable_multiplayer" in _player:
		_player.enable_multiplayer = false
	add_child(_player)

	_bobba = BOBBA_SCENE.instantiate()
	_bobba.position = BOBBA_SPAWN
	add_child(_bobba)

	# Player._ready() runs _spawn_at_tower() which forcibly picks a random
	# SPAWN_POINTS slot and overwrites our position. Re-snap both actors
	# to the arena's deterministic spawns on the next idle frame.
	call_deferred("_enforce_spawns")
	call_deferred("_connect_outcome_signals")


func _enforce_spawns() -> void:
	if is_instance_valid(_player):
		_player.global_position = PLAYER_SPAWN
		if "_spawn_immunity_timer" in _player:
			_player._spawn_immunity_timer = 1.5
	if is_instance_valid(_bobba):
		_bobba.global_position = BOBBA_SPAWN


func _connect_outcome_signals() -> void:
	# Deferred so the Player/Bobba _ready() has wired up their health
	# components before we try to hook their death signals.
	if _player and _player.has_signal("player_died"):
		_player.player_died.connect(_on_round_ended.bind("LOSS"))
	if _bobba and _bobba.has_signal("died"):
		_bobba.died.connect(_on_round_ended.bind("WIN"))


func _on_round_ended(outcome: String) -> void:
	if _rating_pending:
		return  # double-death edge case — one rating per round
	_rating_pending = true
	var duration_s: float = float(Time.get_ticks_usec() - _round_started_at_usec) / 1_000_000.0
	var hp_remaining: float = 0.0
	var hp_max: float = 150.0
	if is_instance_valid(_player) and "current_health" in _player:
		hp_remaining = float(_player.current_health)
		hp_max = float(_player.max_health) if "max_health" in _player else 150.0
	_show_rating_overlay(outcome, duration_s, hp_remaining, hp_max)


# ─── Fun-rating overlay ────────────────────────────────────────────────

func _show_rating_overlay(outcome: String, duration_s: float,
		hp_remaining: float, hp_max: float) -> void:
	# Get the mouse back so the player can click the buttons.
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

	var canvas := CanvasLayer.new()
	canvas.name = "RatingOverlay"
	canvas.layer = 200
	add_child(canvas)

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	canvas.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	canvas.add_child(center)

	var panel := PanelContainer.new()
	center.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 18)
	vbox.custom_minimum_size = Vector2(540, 0)
	panel.add_child(vbox)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 32)
	margin.add_theme_constant_override("margin_right", 32)
	margin.add_theme_constant_override("margin_top", 24)
	margin.add_theme_constant_override("margin_bottom", 24)
	vbox.add_child(margin)

	var inner := VBoxContainer.new()
	inner.add_theme_constant_override("separation", 14)
	margin.add_child(inner)

	var title := Label.new()
	title.text = "YOU DIED" if outcome == "LOSS" else "BOBBA DEFEATED"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 36)
	title.add_theme_color_override("font_color",
		Color(1.0, 0.25, 0.25) if outcome == "LOSS" else Color(0.30, 1.0, 0.45))
	inner.add_child(title)

	var stat := Label.new()
	var gs := get_node_or_null("/root/GameSettings")
	var round_num: int = int(gs.arena_round) if gs else 0
	stat.text = "Round %d   •   %.1fs   •   HP %d / %d" % [
		round_num, duration_s, int(round(hp_remaining)), int(round(hp_max)),
	]
	stat.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	stat.add_theme_font_size_override("font_size", 14)
	stat.add_theme_color_override("font_color", Color(0.82, 0.78, 0.68))
	inner.add_child(stat)

	var prompt := Label.new()
	prompt.text = "How was this round?"
	prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	prompt.add_theme_font_size_override("font_size", 20)
	prompt.add_theme_color_override("font_color", Color(0.98, 0.92, 0.78))
	inner.add_child(prompt)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 18)
	inner.add_child(row)

	var fun_btn := Button.new()
	fun_btn.text = "FUN"
	fun_btn.custom_minimum_size = Vector2(180, 64)
	fun_btn.add_theme_font_size_override("font_size", 22)
	fun_btn.pressed.connect(_finalize_rating.bind("fun", outcome, duration_s,
			hp_remaining, hp_max, round_num, canvas))
	row.add_child(fun_btn)

	var not_fun_btn := Button.new()
	not_fun_btn.text = "NOT FUN"
	not_fun_btn.custom_minimum_size = Vector2(180, 64)
	not_fun_btn.add_theme_font_size_override("font_size", 22)
	not_fun_btn.pressed.connect(_finalize_rating.bind("not_fun", outcome, duration_s,
			hp_remaining, hp_max, round_num, canvas))
	row.add_child(not_fun_btn)

	var note := Label.new()
	note.text = "[click a button, then you'll respawn]"
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	note.add_theme_font_size_override("font_size", 11)
	note.add_theme_color_override("font_color", Color(0.55, 0.50, 0.40))
	inner.add_child(note)


func _finalize_rating(rating: String, outcome: String, duration_s: float,
		hp_remaining: float, hp_max: float, round_num: int,
		overlay: CanvasLayer) -> void:
	_write_fun_log_entry(rating, outcome, duration_s, hp_remaining, hp_max, round_num)
	if is_instance_valid(overlay):
		overlay.queue_free()
	# Recapture mouse + reload on next idle frame.
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	call_deferred("_reload_round")


func _reload_round() -> void:
	get_tree().reload_current_scene()


## Append one NDJSON line per round to docs/fun_log.ndjson. Flat text
## format so the log can be read by humans, grep'd, or parsed by any
## tool — no JSON file to keep balanced.
func _write_fun_log_entry(rating: String, outcome: String, duration_s: float,
		hp_remaining: float, hp_max: float, round_num: int) -> void:
	var entry := {
		"ts": Time.get_datetime_string_from_system(true),
		"round": round_num,
		"outcome": outcome,
		"rating": rating,
		"duration_s": "%.2f" % duration_s,
		"hp_remaining": int(round(hp_remaining)),
		"hp_max": int(round(hp_max)),
	}
	var line: String = JSON.stringify(entry)
	# Use FileAccess in append mode; create file if missing.
	var existing_len: int = 0
	if FileAccess.file_exists(FUN_LOG_PATH):
		var rd := FileAccess.open(FUN_LOG_PATH, FileAccess.READ)
		if rd:
			existing_len = rd.get_length()
	var f := FileAccess.open(FUN_LOG_PATH, FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open(FUN_LOG_PATH, FileAccess.WRITE)
	if f == null:
		push_warning("FunLog: could not open %s" % FUN_LOG_PATH)
		return
	f.seek(existing_len)
	f.store_line(line)
	f.close()
	print("[FunLog] ", line)
