extends Node

## Automated Paladin test harness. Activated via --combat-scenario=A|B|GRASS
## on the command line; otherwise self-removes.
##
## A — Paladin wins combat vs Bobba with some HP left.
## B — Paladin loses combat but lands a handful of hits.
## GRASS — Teleports Paladin into a dense open-grass area, walks in a
##         small circle so the interactive blade-parting is visible, and
##         captures screenshots. No Bobba, no combat.
##
## Screenshots go to /tmp/combat_test/; a one-line outcome is printed on
## conclusion.

const SCREENSHOT_DIR: String = "/tmp/combat_test"
const SCREENSHOT_INTERVAL: float = 0.25
const MAX_DURATION_SEC: float = 60.0
const MELEE_HOLD_DIST: float = 1.7  # Desired separation from Bobba for melee
const APPROACH_SNAP_DIST: float = 3.5  # Teleport-snap if we get knocked too far

var scenario: String = ""
var _player: Node = null
var _bobba: Node = null
var _elapsed: float = 0.0
var _screenshot_timer: float = 0.0
var _attack_count: int = 0
var _outcome_logged: bool = false
var _start_wait_timer: float = 0.0
var _bobba_prev_state: int = -1
var _bobba_attack_count: int = 0


func _ready() -> void:
	var gs := get_node_or_null("/root/GameSettings")
	if gs and "combat_scenario" in gs:
		scenario = String(gs.combat_scenario).to_upper()
	if scenario == "":
		queue_free()
		return
	DirAccess.make_dir_recursive_absolute(SCREENSHOT_DIR)
	print("[CombatTest] Scenario %s armed — waiting for player and Bobba" % scenario)
	# The GRASS showcase forces DAY lighting so the grass field is visually
	# verifiable. Night mode stays on for normal gameplay / combat scenarios.
	if scenario == "GRASS":
		get_tree().create_timer(0.5).timeout.connect(_force_day_lighting)


func _force_day_lighting() -> void:
	var lm := get_tree().current_scene.find_child("LightingManager", true, false)
	if lm and lm.has_method("set_time"):
		# LightingManager.TimeOfDay.DAY = 0
		lm.set_time(0, true)
	# Also disable interactive grass bending during the showcase so the
	# tall blades stay at their full authored height instead of parting
	# around the player.
	var sgt := get_tree().current_scene.find_child("SimpleGrassTextured", true, false)
	if sgt and "interactive" in sgt:
		sgt.interactive = false
	var singleton := get_node_or_null("/root/SimpleGrass")
	if singleton and singleton.has_method("set_interactive"):
		singleton.set_interactive(false)


func _process(delta: float) -> void:
	if scenario == "":
		return

	if _player == null or not is_instance_valid(_player):
		_player = _find_in_group("player")
	if scenario != "GRASS" and (_bobba == null or not is_instance_valid(_bobba)):
		_bobba = _find_in_group("bobba")

	var need_bobba: bool = scenario != "GRASS"
	if _player == null or (need_bobba and _bobba == null):
		_start_wait_timer += delta
		if _start_wait_timer > 20.0:
			_finish("TIMEOUT_SPAWN")
		return

	if scenario == "PROMO":
		_drive_promo(delta)
		if _elapsed > 6.0:
			_finish("PROMO_DONE")
		_elapsed += delta
		_screenshot_timer += delta
		# Tight capture cadence — grab a frame every 120 ms so we're sure
		# to catch the mid-swing / best-lit moment.
		if _screenshot_timer >= 0.12:
			_screenshot_timer = 0.0
			_capture()
		return

	_elapsed += delta
	_screenshot_timer += delta
	if _screenshot_timer >= SCREENSHOT_INTERVAL:
		_screenshot_timer = 0.0
		_capture()

	if scenario == "GRASS":
		_drive_grass(delta)
		# Auto-exit after a short showcase window.
		if _elapsed > 12.0:
			_finish("GRASS_SHOWCASE_DONE")
		return

	if _elapsed > MAX_DURATION_SEC:
		_finish("TIMEOUT")
		return

	var paladin_hp: float = float(_player.current_health) if "current_health" in _player else 0.0
	var bobba_hp: float = float(_bobba.health) if "health" in _bobba else 0.0
	if paladin_hp <= 0.0:
		_finish("BOBBA_WINS")
		return
	if bobba_hp <= 0.0:
		_finish("PALADIN_WINS")
		return

	_drive(delta)


## Promo-shot director. Teleports Paladin into dense grass, plants Bobba
## a couple of meters ahead so both fit in frame, keeps NIGHT lighting
## active (god-ray moonlight), hides every piece of HUD / nameplate so
## the frame is pure composition, grants the Paladin invincibility so no
## red damage-label pops mid-capture, and loops a sword swing so each
## screenshot catches a blade arc in motion.
func _drive_promo(_delta: float) -> void:
	const PROMO_POS := Vector3(110.0, 0.0, -135.0)  # deep in the blade field
	const BOBBA_OFFSET := Vector3(0.0, 0.0, 5.0)    # Bobba 5m ahead of paladin

	# One-time setup on the first frame the actors are available.
	if _elapsed < 0.05:
		var paladin_pos := PROMO_POS
		paladin_pos.y = _player.global_position.y
		_player.global_position = paladin_pos
		if is_instance_valid(_bobba):
			var bobba_pos := paladin_pos + BOBBA_OFFSET
			bobba_pos.y = _bobba.global_position.y
			_bobba.global_position = bobba_pos
		# Camera yaw facing Bobba (+Z here) + small downward pitch so the
		# shot frames both fighters with the moonlit sky filling the top.
		var cam_pivot: Node3D = _player.get_node_or_null("CameraPivot") as Node3D
		if cam_pivot:
			cam_pivot.rotation.y = atan2(-BOBBA_OFFSET.x, -BOBBA_OFFSET.z)
			cam_pivot.rotation.x = deg_to_rad(-4.0)
		_hide_promo_ui()
		_boost_promo_lighting()
		_add_key_light()

	# Immortality so no red HP label pops during capture.
	if is_instance_valid(_player) and "_spawn_immunity_timer" in _player:
		_player._spawn_immunity_timer = 10.0

	# Keep Paladin swinging so screenshots catch a sword arc.
	if is_instance_valid(_player) and not _player.is_attacking:
		if "_attack_cooldown" in _player and _player._attack_cooldown <= 0.0:
			if _player.has_method("_do_attack"):
				_player._do_attack()


## Hide the cluttery banners ("Connecting to server…", network debug
## overlay) and every Label3D (nameplates, HP pops, damage numbers) —
## but KEEP the gothic HUD and minimap visible. The ornate HUD is part
## of the game's visual identity and should be in the promo shot.
func _hide_promo_ui() -> void:
	var root := get_tree().current_scene
	if root == null:
		return
	var hide_names := [
		"HealthBarUI",   # legacy hidden canvas, hide-safe
		"JoinScreen",    # "Connecting to server…" banner
		"NetworkDebug",  # latency / debug text
	]
	for n in hide_names:
		var node := root.find_child(n, true, false)
		if node and node is CanvasItem:
			(node as CanvasItem).visible = false
		elif node and node is CanvasLayer:
			(node as CanvasLayer).visible = false
	# Kill every Label3D in the scene — nameplates, HP pops, hit labels.
	_hide_labels_recursive(root)


func _hide_labels_recursive(node: Node) -> void:
	if node is Label3D:
		(node as Label3D).visible = false
	for child in node.get_children():
		_hide_labels_recursive(child)


## Push ambient + moon up for the promo so the NIGHT preset reads as
## "cinematic moonlit" instead of "near-black silhouettes". Leaves fog
## alone so god rays still cut through the scene.
func _boost_promo_lighting() -> void:
	var root := get_tree().current_scene
	if root == null:
		return
	# Environment: pump ambient and exposure.
	var we := root.find_child("WorldEnvironment", true, false) as WorldEnvironment
	if we and we.environment:
		var env := we.environment
		env.ambient_light_energy = 1.2
		env.ambient_light_color = Color(0.35, 0.42, 0.58)
		env.tonemap_exposure = 1.4
		env.background_energy_multiplier = 0.25
	# Moon: much brighter so it carves the scene.
	var moon := root.find_child("Moon", true, false)
	if moon and moon.has_method("set_light_energy"):
		moon.set_light_energy(3.5)
	if moon and moon.has_method("set_light_color"):
		moon.set_light_color(Color(0.70, 0.78, 0.95))


## Single bright key light above the Paladin so he doesn't get eaten by
## the NIGHT ambient. Cinematic trick — a hidden fill light so the hero
## reads against the moonlit backdrop without breaking the mood.
func _add_key_light() -> void:
	if _player == null:
		return
	var key := OmniLight3D.new()
	key.name = "PromoKeyLight"
	key.light_color = Color(0.98, 0.88, 0.70)  # warm torch/fire tint
	key.light_energy = 8.0
	key.omni_range = 8.0
	key.position = Vector3(1.2, 2.2, -2.0)  # camera-side, chest-height
	key.shadow_enabled = false
	_player.add_child(key)

	# Secondary cool rim from behind — makes the silhouette pop against
	# the moonlit backdrop. Classic three-point lighting.
	var rim := OmniLight3D.new()
	rim.name = "PromoRimLight"
	rim.light_color = Color(0.60, 0.78, 1.00)
	rim.light_energy = 5.5
	rim.omni_range = 6.0
	rim.position = Vector3(-1.6, 2.6, 2.0)
	rim.shadow_enabled = false
	_player.add_child(rim)


## Drop the Paladin into the dense uniform grass field, walk straight
## forward so the camera frames the character standing in tall grass
## stretching to the horizon in all directions. The showcase spot is
## well inside the 260×260m populated area and outside every exclusion.
func _drive_grass(delta: float) -> void:
	const GRASS_CENTER := Vector3(120.0, 0.0, -140.0)  # east-north of village
	const WALK_SPEED := 0.8

	if _elapsed < 0.3 and _player.global_position.distance_to(GRASS_CENTER) > 2.0:
		var start_pos := GRASS_CENTER
		start_pos.y = _player.global_position.y
		_player.global_position = start_pos
		var cam_pivot: Node3D = _player.get_node_or_null("CameraPivot") as Node3D
		if cam_pivot:
			cam_pivot.rotation.y = 0.0
			cam_pivot.rotation.x = 0.0
		return

	# Once per second, log the player's settled Y so we can confirm blade
	# heights reach actual shoulder level on the living character.
	if int(_elapsed) != int(_elapsed - delta):
		print("[CombatTest/GRASS] Paladin Y=%.2f  feet at ~Y=%.2f" %
			[_player.global_position.y, _player.global_position.y - 1.0])

	# Gentle forward drift along +Z so we see fresh grass all the time.
	_player.global_position += Vector3(0, 0, 1) * WALK_SPEED * delta


func _drive(delta: float) -> void:
	var to_bobba: Vector3 = _bobba.global_position - _player.global_position
	to_bobba.y = 0.0
	var dist: float = to_bobba.length()
	if dist < 0.001:
		return
	var dir: Vector3 = to_bobba / dist

	# Face Bobba. The character model rotates to _camera_pivot.rotation.y + PI,
	# and at rotation θ+π its forward vector is (-sin θ, 0, -cos θ). For the
	# character to face (dx, dz) we therefore need θ = atan2(-dx, -dz).
	var cam_pivot: Node3D = _player.get_node_or_null("CameraPivot") as Node3D
	if cam_pivot:
		cam_pivot.rotation.y = atan2(-dir.x, -dir.z)

	# Close to melee. Real movement is slow and easy to stall under knockback;
	# do a soft "glide": teleport when too far, otherwise nudge in-place.
	if dist > APPROACH_SNAP_DIST:
		var snap_pos: Vector3 = _bobba.global_position - dir * MELEE_HOLD_DIST
		snap_pos.y = _player.global_position.y
		_player.global_position = snap_pos
	elif dist > MELEE_HOLD_DIST + 0.2:
		var step: float = minf(6.0 * delta, dist - MELEE_HOLD_DIST)
		_player.global_position += dir * step

	match scenario:
		"A":
			_scenario_a()
		"B":
			_scenario_b(dist)
		_:
			pass


func _scenario_a() -> void:
	# Only start blocking after Paladin has actually lost some HP — spawn
	# immunity swallows the first strike, so counting Bobba swings isn't
	# enough. Once we've been clipped, block every subsequent attack.
	var bobba_attacking: bool = _bobba.state == 2  # Proto.BobbaState.ATTACKING
	var max_hp: float = float(_player.max_health) if "max_health" in _player else 150.0
	var cur_hp: float = float(_player.current_health)
	var damage_taken: float = max_hp - cur_hp
	var should_block: bool = bobba_attacking and damage_taken >= 30.0
	_player.is_blocking = should_block
	if not bobba_attacking:
		_try_attack()


func _scenario_b(dist: float) -> void:
	# Paladin never blocks and backs off every third swing so the hit
	# whiffs, giving Bobba the tempo to kill the 150-HP knight before
	# Bobba's 1000 HP pool runs out.
	_player.is_blocking = false
	if _player.is_attacking and (_attack_count % 3 == 2):
		var retreat_dir: Vector3 = (_player.global_position - _bobba.global_position).normalized()
		retreat_dir.y = 0
		_player.global_position += retreat_dir * 1.6
	else:
		_try_attack()


func _try_attack() -> void:
	if _player.is_attacking:
		return
	if "_attack_cooldown" in _player and _player._attack_cooldown > 0.0:
		return
	if _player.has_method("_do_attack"):
		_player._do_attack()
		_attack_count += 1


func _find_in_group(gname: String) -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	for n in tree.get_nodes_in_group(gname):
		if is_instance_valid(n):
			return n
	return null


func _capture() -> void:
	var tree := get_tree()
	if tree == null:
		return
	var vp: Viewport = tree.root.get_viewport()
	if vp == null:
		return
	var tex := vp.get_texture()
	if tex == null:
		return
	var img := tex.get_image()
	if img == null:
		return
	var paladin_hp: int = int(round(float(_player.current_health))) if _player and "current_health" in _player else -1
	var bobba_hp: int = int(round(float(_bobba.health))) if _bobba and "health" in _bobba else -1
	var fname: String = "%s/s%s_%06.2fs_p%04d_b%04d.png" % [
		SCREENSHOT_DIR, scenario, _elapsed, paladin_hp, bobba_hp,
	]
	img.save_png(fname)


func _finish(outcome: String) -> void:
	if _outcome_logged:
		return
	_outcome_logged = true
	var paladin_hp: float = float(_player.current_health) if _player and "current_health" in _player else -1.0
	var bobba_hp: float = float(_bobba.health) if _bobba and "health" in _bobba else -1.0
	print("[CombatTest] Scenario %s — %s | paladin_hp=%.1f bobba_hp=%.1f attacks=%d duration=%.1fs" % [
		scenario, outcome, paladin_hp, bobba_hp, _attack_count, _elapsed,
	])
	_capture()
	var t := get_tree().create_timer(1.0)
	t.timeout.connect(func(): get_tree().quit())
