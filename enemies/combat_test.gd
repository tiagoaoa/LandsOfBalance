extends Node

## Automated Paladin test harness. Activated via --combat-scenario=<NAME>
## on the command line; otherwise self-removes.
##
## A — Paladin wins combat vs Bobba with some HP left.
## B — Paladin loses combat but lands a handful of hits.
## GRASS — Teleports Paladin into a dense open-grass area, walks in a
##         small circle so the interactive blade-parting is visible, and
##         captures screenshots. No Bobba, no combat.
## PROMO/LOCKON/DODGE — capture director / lock-on orbit / roll i-frames.
## PARRY/BACKSTAB/ESTUS — scripted single-mechanic checks.
## SOULS — full live duel playing the whole kit (bait→parry→riposte,
##         estus under pressure); reports per-verb usage counts.
## MOVE — locomotion check: presses REAL input actions (walk, run,
##        strafe, back) and logs which clip the AnimationPlayer plays,
##        so input-driven movement animation regressions are visible.
##
## While any scenario is active the player's real input pipeline is
## disabled, so a stray click on the popped-up window can't fight
## alongside the script.
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
var _lockon_setup_done: bool = false
var _dodge_test_started: bool = false
var _scripted_test_started: bool = false  # one-shot latch for PARRY/BACKSTAB/ESTUS
var _coop_fire_dropped: bool = false  # spare one-shot latch (COOP/SKEL scripted events)
var _skel_arrow_shot: bool = false
var _darksim_haunt: Vector3 = Vector3.ZERO
var _noff_ally_hp: float = 0.0
var _noff_bobba_hp: float = 0.0
var _noff_paladin_hp: float = 0.0
var _noff_enemy_hurt: bool = false
var _noff_fire: Node = null
var _noff_bobba_hp_arrow: float = 0.0
var _noff_arrow_dealt: float = -1.0
## Where DARKSIM parks the player: outside moonlight (8 m) and outside the
## reach of a fire lit at his own feet, but inside the glow of one lit ON the
## pack (18 m). The whole mechanic lives in that gap.
const DARKSIM_STANDOFF := 16.0
var _poster_marks: Dictionary = {}  # actor → staged x/z mark (movie-set pinning)
var _bowsim_flags: Dictionary = {}
var _bowsim_freeze: int = 0
# BLOCKSIM: per-phase skeleton measurements (guard up while moving).
var _blocksim_phase: String = ""
var _blocksim_stats: Dictionary = {}
var _blocksim_prev_knee: Quaternion = Quaternion.IDENTITY
var _blocksim_prev_knee_valid: bool = false
var _blocksim_prev_arm: Quaternion = Quaternion.IDENTITY
var _blocksim_prev_arm_valid: bool = false
var _blocksim_phase_t: float = 0.0
# BLOCKSIM defense battery: does the guard come back after each verb?
var _blocksim_battery: bool = false
var _blocksim_flags: Dictionary = {}
var _blocksim_gap: float = 0.0
var _blocksim_gap_verb: String = ""
var _blocksim_verb: String = ""
var _blocksim_worst_gap: float = 0.0
var _blocksim_worst_verb: String = ""
var _blocksim_lost: int = 0
var _blocksim_freeze: int = 0
# ANIMSIM: locomotion-vs-actions stress detectors.
var _animsim_step: int = -1
var _animsim_dir_idx: int = 0
# GEARSIM: which loadout the turntable is currently showing.
var _gearsim_slot: int = -1
var _gearsim_hit_timer: float = 0.0
var _animsim_blocking: bool = false
var _animsim_stall: float = 0.0
var _animsim_max_stall: float = 0.0
var _animsim_stalls: int = 0
var _animsim_hard: int = 0
var _animsim_reported: bool = false
var _animsim_hard_reported: bool = false
var _animsim_guard_phantom: float = 0.0
var _animsim_guard_reported: bool = false
var _animsim_guard_stuck: int = 0
var _animsim_guard_dropped_t: float = 0.0
var _animsim_guard_drop_reported: bool = false
var _animsim_guard_dropped: int = 0
var _animsim_guard_anim_t: float = 0.0
var _animsim_guard_anim_reported: bool = false
var _animsim_guard_anim: int = 0
var _bowsim_noaim: int = 0
var _screenshots_enabled: bool = true


# SOULS scenario state — full live duel using the whole kit.
var _souls_parries: int = 0          # deflects that opened a riposte window
var _souls_ripostes: int = 0         # crits >= 250 dmg in one frame
var _souls_backstabs: int = 0        # crits 150..250 dmg in one frame
var _souls_estus_start: int = -1     # charges at fight start
var _souls_prev_riposte: bool = false
var _souls_prev_bobba_hp: float = -1.0
var _souls_parried_this_attack: bool = false


func _ready() -> void:
	var gs := get_node_or_null("/root/GameSettings")
	if gs and "combat_scenario" in gs:
		scenario = String(gs.combat_scenario).to_upper()
	if scenario == "":
		queue_free()
		return
	_screenshots_enabled = not _has_cmdline_flag("--combat-no-screenshots")
	if _screenshots_enabled:
		DirAccess.make_dir_recursive_absolute(SCREENSHOT_DIR)
	print("[CombatTest] Scenario %s armed — waiting for player and Bobba" % scenario)
	# The GRASS showcase forces DAY lighting so the grass field is visually
	# verifiable. Night mode stays on for normal gameplay / combat scenarios.
	if scenario == "GRASS" or scenario == "MOVE" or scenario == "DRAGON" \
			or scenario == "SKEL" or scenario == "BOWSIM" or scenario == "MOBSIM" \
			or scenario == "PALSIM" or scenario == "BLOCKSIM" \
			or scenario == "ANIMSIM" \
			or (scenario == "GEARSIM" and OS.get_environment("LOB_GEAR_NIGHT") != "1"):
			get_tree().create_timer(0.5).timeout.connect(_force_day_lighting)


func _has_cmdline_flag(flag: String) -> bool:
	var all_args := []
	all_args.append_array(OS.get_cmdline_args())
	all_args.append_array(OS.get_cmdline_user_args())
	return flag in all_args


func _force_day_lighting() -> void:
	var lm := get_tree().current_scene.find_child("LightingManager", true, false)
	if lm and lm.has_method("set_time"):
		# LightingManager.TimeOfDay.DAY = 0
		lm.set_time(0, true)
	# Disable interactive grass bending for the static GRASS showcase only
	# (so blades stay at full authored height). MOVE wants parting ON so we
	# can verify the field bends around the moving character.
	if scenario != "MOVE":
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
		# Scenarios drive the player by calling methods directly. Cut off
		# the real input pipeline so a stray click/keypress on the test
		# window (it pops up on the desktop and steals focus) can't fight
		# alongside the script and corrupt the measurements. PLAY and the
		# ARCHER playtest are the exceptions — there the human IS the driver.
		if _player != null and scenario != "PLAY" and scenario != "ARCHER" \
				and scenario != "COOP" and scenario != "MOBSIM" and scenario != "PALSIM" \
				and scenario != "BLOCKSIM" and scenario != "ANIMSIM":
			_player.set_process_input(false)
	var solo: bool = scenario == "GRASS" or scenario == "MOVE" or scenario == "RIVER" \
			or scenario == "DRAGON" or scenario == "BOWSIM" or scenario == "MOBSIM" \
			or scenario == "PALSIM" or scenario == "BLOCKSIM" \
			or (scenario == "GEARSIM" and OS.get_environment("LOB_GEAR_TARGET") != "bobba")
	if not solo and (_bobba == null or not is_instance_valid(_bobba)):
		_bobba = _find_in_group("bobba")

	var need_bobba: bool = not solo
	if _player == null or (need_bobba and _bobba == null):
		# COOP waits on the human in the character menu — no spawn timeout.
		if scenario != "COOP":
			_start_wait_timer += delta
			if _start_wait_timer > 20.0:
				_finish("TIMEOUT_SPAWN")
		return

	if scenario == "POSTER":
		_drive_poster(delta)
		if _elapsed > 9.0:
			_finish("POSTER_DONE")
		_elapsed += delta
		_screenshot_timer += delta
		if _screenshot_timer >= 0.12:
			_screenshot_timer = 0.0
			_capture()
		return

	if scenario == "GEARSIM":
		_drive_gearsim(delta)
		if _elapsed > GEARSIM_PER_CLASS * 3.0:
			_finish("GEARSIM_DONE")
		_elapsed += delta
		_screenshot_timer += delta
		# A held clip is often well under a second; at the turntable's cadence
		# you sample across loops instead of through the motion.
		var cadence: float = 0.06 if OS.get_environment("LOB_GEAR_CLIP") != "" else 0.25
		if _screenshot_timer >= cadence:
			_screenshot_timer = 0.0
			_capture()
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

	# PLAY: hands-on arena — set the stage once, then get out of the way.
	# No screenshots, no timeout, no scripted driving; deaths go through the
	# game's normal restart flow.
	if scenario == "PLAY":
		_setup_play_arena()
		return

	# ARCHER: hands-on bow playtest — archer class (forced by GameSettings),
	# spawned on the highest ground near Bobba's spawn, human keeps controls.
	# The first seconds are captured so the spawn/vantage can be verified
	# from logs+frames; after that, no more screenshots — it's a play session.
	if scenario == "ARCHER":
		_setup_archer_arena()
		if _elapsed < 3.0:
			_elapsed += delta
			_screenshot_timer += delta
			if _screenshot_timer >= SCREENSHOT_INTERVAL:
				_screenshot_timer = 0.0
				_capture()
		return

	# COOP: hands-on co-op playtest. The human chose Archer or Paladin in
	# the character menu and controls that character with the normal game
	# inputs; the AI companion plays the other class. No scripted driving —
	# only the first seconds are captured (spawn verification) plus a light
	# telemetry heartbeat so perception behavior can be reviewed from logs.
	if scenario == "COOP":
		var prev_elapsed := _elapsed
		_elapsed += delta
		if _elapsed < 3.0:
			_screenshot_timer += delta
			if _screenshot_timer >= SCREENSHOT_INTERVAL:
				_screenshot_timer = 0.0
				_capture()
		if int(_elapsed / 5.0) != int(prev_elapsed / 5.0):
			var comp := _find_in_group("companion")
			var tname: String = str(_bobba.target.name) \
					if ("target" in _bobba and _bobba.target != null) else "none"
			print("[CombatTest] COOP t=%d player=%s(hp %.0f) companion=%s bobba_target=%s bobba_hp=%.0f" % [
					int(_elapsed),
					"Paladin" if _player.character_class == _player.CharacterClass.PALADIN else "Archer",
					float(_player.current_health),
					("dead" if comp.is_dead else "hp %.0f" % float(comp.current_health)) if comp else "missing",
					tname, float(_bobba.health)])
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

	if scenario == "MOVE":
		_drive_move(delta)
		if _elapsed > 17.0:
			_finish("MOVE_DONE")
		return

	if scenario == "LOCKON":
		_drive_lockon(delta)
		if _elapsed > 9.0:
			_finish("LOCKON_DONE")
		return

	if scenario == "NOFF":
		_drive_noff(delta)
		if _elapsed > 26.0:
			_finish("NOFF_DONE")
		return

	if scenario == "DARKSIM":
		_drive_darksim(delta)
		if _elapsed > 34.0:
			_finish("DARKSIM_DONE")
		return

	if scenario == "DODGE":
		_drive_dodge(delta)
		if _elapsed > 12.0:
			_finish("DODGE_TIMEOUT")
		return

	if scenario == "PARRY":
		_drive_parry(delta)
		if _elapsed > 20.0:
			_finish("PARRY_TIMEOUT")
		return

	if scenario == "BACKSTAB":
		_drive_backstab(delta)
		if _elapsed > 20.0:
			_finish("BACKSTAB_TIMEOUT")
		return

	if scenario == "ESTUS":
		_drive_estus(delta)
		if _elapsed > 20.0:
			_finish("ESTUS_TIMEOUT")
		return

	if scenario == "COMBO":
		_drive_combo(delta)
		if _elapsed > 25.0:
			_finish("COMBO_TIMEOUT")
		return

	if scenario == "ARROW":
		_drive_arrow(delta)
		if _elapsed > 14.0:
			_finish("ARROW_DONE")
		return

	if scenario == "RIVER":
		_drive_river(delta)
		if _elapsed > 12.0:
			_finish("RIVER_DONE")
		return

	if scenario == "DRAGON":
		_drive_dragon(delta)
		if _elapsed > 26.0:
			_finish("DRAGON_DONE")
		return

	if scenario == "REVIVE":
		_drive_revive(delta)
		if _elapsed > 13.0:
			print("[CombatTest] REVIVE summary: interrupt_ok=%s revived_ok=%s crouch_ok=%s" % [
					str(_bowsim_flags.get("interrupt_ok", false)),
					str(_bowsim_flags.get("revived_ok", false)),
					str(_bowsim_flags.get("crouch_ok", false))])
			_finish("REVIVE_DONE")
		return

	if scenario == "PALSIM":
		_drive_palsim(delta)
		if _elapsed > 16.0:
			print("[CombatTest] PALSIM summary: taps=%d swings=%d dropped=%d max_latency=%.2fs combo_max=%d freeze=%d move_recover=%.2fs" % [
					int(_bowsim_flags.get("taps", 0)),
					int(_bowsim_flags.get("swings", 0)),
					int(_bowsim_flags.get("taps", 0)) - int(_bowsim_flags.get("swings", 0)),
					float(_bowsim_flags.get("max_latency", 0.0)),
					int(_bowsim_flags.get("combo_max", 0)),
					_bowsim_freeze,
					float(_bowsim_flags.get("move_recover", -1.0))])
			_finish("PALSIM_DONE")
		return

	if scenario == "MOBSIM":
		_drive_mobsim(delta)
		if _elapsed > 22.0:
			var stand_d: float = float(_bowsim_flags.get("stand_dist", 0.0))
			var move_d: float = float(_bowsim_flags.get("move_dist", 0.0))
			print("[CombatTest] MOBSIM summary: freeze=%d stuck_frames=%d shots=%d tap_recover=%s lostrelease_recover=%s walk_speed=%.1f run_speed=%.1f" % [
					_bowsim_freeze, int(_bowsim_flags.get("stuck_frames", 0)),
					int(_bowsim_flags.get("shots", 0)),
					str(_bowsim_flags.get("tap_recover", false)),
					str(_bowsim_flags.get("lostrelease_recover", false)),
					float(_bowsim_flags.get("walk_speed", 0.0)),
					float(_bowsim_flags.get("run_speed", 0.0))])
			print("[CombatTest] MOBSIM ranged: crouch_toggle=%s zoom_stand=%.2f zoom_move=%.2f stand_dist=%.1f move_dist=%.1f ratio=%.2f" % [
					str(_bowsim_flags.get("crouch_toggle", false)),
					float(_bowsim_flags.get("zoom_stand", 0.0)),
					float(_bowsim_flags.get("zoom_move", 0.0)),
					stand_d, move_d,
					(move_d / stand_d) if stand_d > 0.0 else -1.0])
			_finish("MOBSIM_DONE")
		return

	if scenario == "ANIMSIM":
		_drive_animsim(delta)
		if _elapsed > 46.0:
			_animsim_report()
			_finish("ANIMSIM_DONE")
		return

	if scenario == "BLOCKSIM":
		_drive_blocksim(delta)
		if _elapsed > 42.0:
			_blocksim_report()
			_finish("BLOCKSIM_DONE")
		return

	if scenario == "BOWSIM":
		_drive_bowsim(delta)
		if _elapsed > 14.0:
			print("[CombatTest] BOWSIM summary: freeze_frames=%d noaim_shots=%d airdraw_blocked=%s aircancel_ok=%s shots=%d" % [
					_bowsim_freeze, _bowsim_noaim,
					str(_bowsim_flags.get("airdraw_blocked", false)),
					str(_bowsim_flags.get("aircancel_ok", false)),
					int(_bowsim_flags.get("shots", 0))])
			_finish("BOWSIM_DONE")
		return

	if scenario == "SKEL":
		_drive_skel(delta)
		if _elapsed > 34.0:
			var alive := 0
			for sk in get_tree().get_nodes_in_group("skeletons"):
				if not sk.is_dead_skeleton:
					alive += 1
			print("[CombatTest] SKEL summary: alive=%d/5 player_hp=%.0f" % [
					alive, float(_player.current_health)])
			_finish("SKEL_DONE")
		return



	if scenario == "SOULS":
		_drive_souls(delta)
		var souls_php: float = float(_player.current_health)
		var souls_bhp: float = float(_bobba.health)
		if souls_php <= 0.0:
			_finish_souls("BOBBA_WINS")
		elif souls_bhp <= 0.0:
			_finish_souls("PALADIN_WINS")
		elif _elapsed > MAX_DURATION_SEC:
			_finish_souls("TIMEOUT")
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
## POSTER: staged promotional shot. One frame tells the whole game:
## the paladin trading blows with Bobba up front, the archer ally beset
## by the skeleton pack to the side, arrow-fires burning through the
## night grass, and the dragon rearing into its hover-breath overhead.
func _drive_poster(_delta: float) -> void:
	const P := Vector3(110.0, 0.0, -135.0)  # deep in the blade field
	# The skeleton crew rises ~1s after scene load — hold the whole staging
	# until the full cast is present.
	if get_tree().get_nodes_in_group("skeletons").is_empty():
		return
	if not _scripted_test_started:
		_scripted_test_started = true
		# --- Paladin vs Bobba, centre stage.
		var pp := P
		pp.y = _player.global_position.y
		_player.global_position = pp
		var bp: Vector3 = P + Vector3(-0.9, 0.0, 5.4)
		bp.y = _bobba.global_position.y
		_bobba.global_position = bp
		_poster_marks[_bobba] = bp
		var cam_pivot: Node3D = _player.get_node_or_null("CameraPivot") as Node3D
		if cam_pivot:
			cam_pivot.rotation.y = deg_to_rad(184.0)  # face +Z, tiny offset
			cam_pivot.rotation.x = deg_to_rad(9.0)    # lift to catch the dragon
		# --- Archer ally, beset by the pack on the right of frame.
		var archer: CharacterBody3D = load("res://player/player.tscn").instantiate()
		archer.name = "PromoArcher"
		archer.is_ai_companion = true
		archer.enable_multiplayer = false
		archer.enable_fifo = false
		archer.companion_class_override = 1  # ARCHER
		get_tree().current_scene.add_child(archer)
		var ap: Vector3 = P + Vector3(5.2, 0.0, 7.2)
		ap.y = pp.y
		archer.global_position = ap
		var apivot: Node3D = archer.get_node_or_null("CameraPivot") as Node3D
		if apivot:
			apivot.rotation.y = deg_to_rad(75.0)  # squares up to its attackers
		# --- Skeleton pack: three on the archer, two flanking the duel.
		var skels: Array = get_tree().get_nodes_in_group("skeletons")
		var slots: Array = [
			ap + Vector3(1.4, 0.0, 1.0), ap + Vector3(-0.6, 0.0, 1.7),
			ap + Vector3(1.7, 0.0, -1.0),
			P + Vector3(-3.2, 0.0, 6.6), P + Vector3(-4.2, 0.0, 9.0),
		]
		for i in mini(skels.size(), slots.size()):
			var sk: Node3D = skels[i]
			var sp: Vector3 = slots[i]
			sp.y = pp.y + 0.3
			sk.global_position = sp
			sk.home_post = sp
			_poster_marks[sk] = sp
		if skels.size() >= 3:
			skels[2].ignite(20.0)  # one brother burns — an arrow found him
		# --- Arrow-fires burning in the grass.
		for fp in [P + Vector3(2.6, 0.0, 12.5), P + Vector3(-7.2, 0.0, 12.0),
				P + Vector3(10.0, 0.0, 4.5), P + Vector3(-5.2, 0.0, 0.4)]:
			FireFX.create_ground_fire(get_tree().current_scene, fp,
					"PosterArrowGroundFire", 40.0, false)
		# --- Dragon: parked overhead behind the fight, forced straight
		# into the hover-breath so it rears and blows fire on camera.
		var dragon: Node3D = _find_in_group("dragon") as Node3D
		if dragon:
			dragon.patrol_center = Vector3(P.x + 5.0, 0.0, P.z + 34.0)
			dragon.patrol_radius = 40.0
			dragon.patrol_height = 11.0
			dragon.global_position = P + Vector3(5.0, 10.5, 34.0)
			dragon._hover_timer = 0.4
			# The night grade swallows an unlit dragon — park a promo fill
			# light in the air between camera and dragon.
			var dlight := OmniLight3D.new()
			dlight.name = "PosterDragonFill"
			dlight.light_color = Color(0.8, 0.85, 1.0)
			dlight.light_energy = 85.0
			dlight.omni_range = 90.0
			dlight.omni_attenuation = 1.1
			dlight.shadow_enabled = false
			get_tree().current_scene.add_child(dlight)
			dlight.global_position = P + Vector3(4.0, 14.0, 22.0)
		_hide_promo_ui()
		_boost_promo_lighting()
		_add_key_light()
	# Immortal cast — no red damage pops mid-capture.
	_player._spawn_immunity_timer = 30.0
	var promo_archer := get_tree().current_scene.get_node_or_null("PromoArcher")
	if promo_archer:
		promo_archer._spawn_immunity_timer = 30.0
	# Damage labels pop every hit — keep every 3D label dark for the shot.
	_hide_labels_recursive(_bobba)
	for sk in get_tree().get_nodes_in_group("skeletons"):
		_hide_labels_recursive(sk)
	# Movie-set pinning: the cast ACTS in place (swings, telegraphs, jaw
	# chatter) but nobody walks off their mark — fire panic and crowd
	# steering would otherwise scatter the composition.
	for actor in _poster_marks:
		if actor != null and is_instance_valid(actor):
			var mark: Vector3 = _poster_marks[actor]
			actor.global_position.x = mark.x
			actor.global_position.z = mark.z
	# Keep the paladin swinging so frames catch the golden slash arc.
	if not _player.is_attacking and "_attack_cooldown" in _player \
			and _player._attack_cooldown <= 0.0:
		_player._do_attack()


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


## Locomotion check. Unlike the combat drivers (which teleport the player),
## this presses REAL input actions so the full input→physics→animation
## pipeline runs exactly as it does for a human at the keyboard. Each
## phase logs the clip the AnimationPlayer is actually playing.
const _MOVE_PHASES := [
	# [end_time, name, actions_held]
	[3.0, "walk_f", ["move_forward"]],
	[5.5, "run_f", ["move_forward", "run"]],
	[7.5, "strafe_l", ["move_left"]],
	[9.5, "strafe_r", ["move_right"]],
	[11.5, "walk_b", ["move_back"]],
	[13.0, "idle", []],
	[16.5, "walk_unarmed", ["move_forward"]],
]
const _MOVE_ALL_ACTIONS := ["move_forward", "move_back", "move_left", "move_right", "run"]
var _move_setup_done: bool = false
var _move_toggled_unarmed: bool = false
var _move_last_log: float = -1.0


func _drive_move(_delta: float) -> void:
	if not _move_setup_done:
		_move_setup_done = true
		const MOVE_CENTER := Vector3(120.0, 0.0, -140.0)
		var start_pos := MOVE_CENTER
		start_pos.y = _player.global_position.y
		_player.global_position = start_pos
		# keyboard_run in the player only counts when the mouse is captured.
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		# Light the rig like the promo shots — silhouettes hide broken limbs.
		_add_key_light()
		var cam_pivot: Node3D = _player.get_node_or_null("CameraPivot") as Node3D
		if cam_pivot:
			cam_pivot.rotation.x = deg_to_rad(-8.0)

	# Find the active phase and hold exactly its actions.
	var phase_name: String = "done"
	var held: Array = []
	for p in _MOVE_PHASES:
		if _elapsed < float(p[0]):
			phase_name = p[1]
			held = p[2]
			break
	if phase_name == "walk_unarmed" and not _move_toggled_unarmed:
		_move_toggled_unarmed = true
		if _player.has_method("_toggle_combat_mode"):
			_player._toggle_combat_mode()
	for action in _MOVE_ALL_ACTIONS:
		if action in held:
			Input.action_press(action)
		else:
			Input.action_release(action)

	# Log twice per second: phase, clip playing, and actual ground speed.
	if _elapsed - _move_last_log >= 0.5:
		_move_last_log = _elapsed
		var anim_name: String = "<none>"
		var playing: bool = false
		var ap: AnimationPlayer = _player._current_anim_player
		if ap != null:
			anim_name = String(ap.current_animation)
			playing = ap.is_playing()
		var hspeed: float = Vector3(_player.velocity.x, 0.0, _player.velocity.z).length()
		print("[CombatTest/MOVE] t=%05.2f phase=%s anim=%s playing=%s speed=%.2f" % [
			_elapsed, phase_name, anim_name, playing, hspeed])


## Lock-on verification. Pins Bobba, makes the Paladin immortal, engages
## lock-on (the same _toggle_lock_on() the T key calls), then orbits the
## Paladin around Bobba. If lock-on works the camera keeps Bobba centered,
## so the logged residual angle between camera-forward and the direction to
## Bobba stays near 0° the whole orbit. Screenshots show the bronze reticle
## parked over Bobba.
func _drive_lockon(delta: float) -> void:
	const CENTER := Vector3(120.0, 0.0, -140.0)
	const ORBIT_R: float = 4.0

	if not _lockon_setup_done:
		_lockon_setup_done = true
		var bp := CENTER
		bp.y = _bobba.global_position.y
		_bobba.global_position = bp
		var pp := CENTER + Vector3(0.0, 0.0, ORBIT_R)
		pp.y = _player.global_position.y
		_player.global_position = pp
		# Aim the camera at Bobba first so acquisition finds him in the cone.
		var cam_pivot: Node3D = _player.get_node_or_null("CameraPivot") as Node3D
		if cam_pivot:
			var d: Vector3 = _bobba.global_position - _player.global_position
			cam_pivot.rotation.y = atan2(-d.x, -d.z)
		if _player.has_method("_toggle_lock_on"):
			_player._toggle_lock_on()
		var got: bool = ("_lock_target" in _player) and (_player._lock_target != null)
		print("[CombatTest/LOCKON] acquire attempted — locked=%s" % str(got))
		return

	# Hold Bobba still and keep the Paladin immortal for a clean orbit.
	var bp2 := CENTER
	bp2.y = _bobba.global_position.y
	_bobba.global_position = bp2
	if "_spawn_immunity_timer" in _player:
		_player._spawn_immunity_timer = 30.0

	# Strafe the Paladin in a circle around Bobba.
	var ang: float = _elapsed * 0.9  # rad/s
	var orbit := CENTER + Vector3(sin(ang), 0.0, cos(ang)) * ORBIT_R
	orbit.y = _player.global_position.y
	_player.global_position = orbit

	# Twice a second, log the residual aim error. Near 0° == lock holding.
	if int(_elapsed * 2) != int((_elapsed - delta) * 2):
		var cam: Camera3D = _player.get_node_or_null("CameraPivot/SpringArm3D/Camera3D") as Camera3D
		if cam:
			var fwd: Vector3 = -cam.global_transform.basis.z
			var to_b: Vector3 = _bobba.global_position - _player.global_position
			fwd.y = 0.0
			to_b.y = 0.0
			var residual: float = rad_to_deg(fwd.normalized().angle_to(to_b.normalized()))
			var locked: bool = ("_lock_target" in _player) and (_player._lock_target != null)
			print("[CombatTest/LOCKON] t=%.1f orbit=%.0f° residual=%.1f° locked=%s" % [
				_elapsed, rad_to_deg(ang), residual, str(locked)])


## Dodge i-frame verification. Runs a one-shot scripted coroutine: roll, then
## land a scripted hit DURING the invuln window (expect no damage); roll again,
## land a hit during RECOVERY after the window (expect damage). Proves the roll
## negates damage only while invulnerable. Bobba is parked far away so its AI
## can't add stray hits — all damage in this test is the scripted take_hit().
func _drive_dodge(_delta: float) -> void:
	if _dodge_test_started:
		return
	_dodge_test_started = true
	_run_dodge_test()


func _run_dodge_test() -> void:
	const CENTER := Vector3(120.0, 0.0, -140.0)
	# Park Bobba 50 m away (outside its detection radius) so it stays roaming.
	var bp := CENTER + Vector3(50.0, 0.0, 0.0)
	bp.y = _bobba.global_position.y
	_bobba.global_position = bp
	var pp := CENTER
	pp.y = _player.global_position.y
	_player.global_position = pp
	# Let the player settle onto the ground so _try_dodge()'s is_on_floor passes.
	await get_tree().create_timer(0.4).timeout

	var kb := Vector3(0.0, 0.0, 5.0)

	# --- Test A: hit lands DURING the i-frame window -> expect no damage. ---
	_player._spawn_immunity_timer = 0.0
	var hp0: float = float(_player.current_health)
	_player._try_dodge()
	await get_tree().create_timer(0.20).timeout  # ~0.20s into 0.5s roll (window 0.06–0.40)
	_player._spawn_immunity_timer = 0.0
	_player.take_hit(50.0, kb, false, _bobba, true)
	await get_tree().process_frame
	var hp1: float = float(_player.current_health)
	print("[CombatTest/DODGE] A in-window:  hp %.0f -> %.0f (expect unchanged)" % [hp0, hp1])

	await get_tree().create_timer(0.7).timeout  # let the roll fully finish

	# --- Test B: hit lands during RECOVERY (after i-frames) -> expect damage. ---
	_player._spawn_immunity_timer = 0.0
	var hp2: float = float(_player.current_health)
	_player._try_dodge()
	await get_tree().create_timer(0.45).timeout  # past window end (0.40), still rolling (<0.5)
	_player._spawn_immunity_timer = 0.0
	_player.take_hit(50.0, kb, false, _bobba, true)
	await get_tree().process_frame
	var hp3: float = float(_player.current_health)
	print("[CombatTest/DODGE] B post-window: hp %.0f -> %.0f (expect -50)" % [hp2, hp3])

	var a_ok: bool = is_equal_approx(hp0, hp1)
	var b_ok: bool = hp3 < hp2 - 1.0
	print("[CombatTest/DODGE] RESULT iframe_negates=%s recovery_vulnerable=%s" % [str(a_ok), str(b_ok)])
	_finish("DODGE_DONE")


## Parry → riposte verification. Three scripted checks:
##   A) a Bobba hit landing INSIDE the parry's active frames deals no
##      damage and staggers Bobba into a riposte-ready stun;
##   B) a real sword swing during that window lands a 3× riposte crit;
##   C) a hit landing in the parry's RECOVERY (after the window) deals
##      full damage — whiffing the parry is punished.
func _drive_parry(_delta: float) -> void:
	if _scripted_test_started:
		return
	_scripted_test_started = true
	_run_parry_test()


func _run_parry_test() -> void:
	const CENTER := Vector3(120.0, 0.0, -140.0)
	var pp := CENTER
	pp.y = _player.global_position.y
	_player.global_position = pp
	# Bobba close enough for the riposte swing to connect, but held in
	# place by the parry stagger for part B.
	var bp := CENTER + Vector3(0.0, 0.0, 1.7)
	bp.y = _bobba.global_position.y
	_bobba.global_position = bp
	# Face Bobba (+Z) so the riposte swing connects: yaw for direction
	# (dx,dz) is atan2(-dx,-dz), same convention as the other scenarios.
	var cam_pivot: Node3D = _player.get_node_or_null("CameraPivot") as Node3D
	if cam_pivot:
		cam_pivot.rotation.y = atan2(-0.0, -1.0)  # PI — face +Z
	# Immunity stays up between scripted hits so Bobba's real swings can't
	# pollute the HP measurements; it's zeroed for exactly one scripted hit
	# at a time.
	_player._spawn_immunity_timer = 30.0
	await get_tree().create_timer(0.5).timeout

	var kb := Vector3(0.0, 0.0, 5.0)

	# --- A: hit inside the parry window -> deflected, Bobba staggered. ---
	var hp0: float = float(_player.current_health)
	_player._try_parry()
	await get_tree().create_timer(0.15).timeout  # inside window 0.05–0.28
	_player._spawn_immunity_timer = 0.0
	_player.take_hit(65.0, kb, false, _bobba, false)
	_player._spawn_immunity_timer = 30.0
	await get_tree().process_frame
	var hp1: float = float(_player.current_health)
	var staggered: bool = _bobba.state == 4  # Proto.BobbaState.STUNNED
	var riposte_open: bool = _bobba.is_riposte_ready()
	print("[CombatTest/PARRY] A deflect: hp %.0f -> %.0f (expect unchanged) bobba_stunned=%s riposte=%s" % [
		hp0, hp1, str(staggered), str(riposte_open)])

	# --- B: real sword swing during the riposte window -> 3x crit. ---
	# Wait out the rest of the parry commitment first (attack is gated
	# while is_parrying, 0.65s total); the riposte window is 2.5s so
	# there's time to spare.
	await get_tree().create_timer(0.60).timeout
	var bhp0: float = float(_bobba.health)
	_player._do_attack()
	await get_tree().create_timer(1.4).timeout  # let the swing land
	var bhp1: float = float(_bobba.health)
	var riposte_dmg: float = bhp0 - bhp1
	print("[CombatTest/PARRY] B riposte: bobba hp %.0f -> %.0f (dealt %.0f, expect ~270)" % [
		bhp0, bhp1, riposte_dmg])

	await get_tree().create_timer(0.6).timeout

	# --- C: hit in the parry's recovery -> full damage. ---
	var hp2: float = float(_player.current_health)
	_player._try_parry()
	await get_tree().create_timer(0.50).timeout  # past window end (0.38), still parrying (<0.65)
	_player._spawn_immunity_timer = 0.0
	_player.take_hit(50.0, kb, false, _bobba, false)
	_player._spawn_immunity_timer = 30.0
	await get_tree().process_frame
	var hp3: float = float(_player.current_health)
	print("[CombatTest/PARRY] C recovery: hp %.0f -> %.0f (expect -50)" % [hp2, hp3])

	var a_ok: bool = is_equal_approx(hp0, hp1) and staggered and riposte_open
	var b_ok: bool = riposte_dmg >= 250.0
	var c_ok: bool = hp3 < hp2 - 1.0
	print("[CombatTest/PARRY] RESULT deflect=%s riposte_crit=%s recovery_punished=%s" % [
		str(a_ok), str(b_ok), str(c_ok)])
	_finish("PARRY_DONE")


## PLAY: playable combat test. Same arena spot the scripted scenarios use,
## Paladin + singleplayer forced by the --combat-scenario flag, Bobba planted
## a few strides ahead — but the human keeps the controls.
var _play_setup_done: bool = false

func _setup_play_arena() -> void:
	if _play_setup_done:
		return
	_play_setup_done = true
	const CENTER := Vector3(120.0, 0.0, -140.0)
	var pp := CENTER
	pp.y = _player.global_position.y
	_player.global_position = pp
	var bp := CENTER + Vector3(0.0, 0.0, 5.0)
	bp.y = _bobba.global_position.y
	_bobba.global_position = bp
	var cam_pivot: Node3D = _player.get_node_or_null("CameraPivot") as Node3D
	if cam_pivot:
		cam_pivot.rotation.y = PI  # face Bobba
	print("[CombatTest] PLAY arena ready — you have the controls.")
	print("[CombatTest]   LMB/F attack (mash = 3-hit combo) | RMB block | G parry")
	print("[CombatTest]   X roll | T lock-on | H estus | Space jump | Shift run | L day/night")


## ARCHER playtest: find the highest ground within bow range of Bobba's
## spawn by raycasting a ring of candidate points, and perch the archer
## there facing him. Bobba stays at his natural spawn so the fight starts
## the way the real game does.
func _setup_archer_arena() -> void:
	if _play_setup_done:
		return
	_play_setup_done = true

	# Bobba stays at his ORIGINAL spawn — the point of this playtest is to
	# learn how close a fire arrow must land to clearly reveal him for the
	# other players. The archer just takes the best ground the probe finds
	# around that spawn, even if the area is nearly flat.
	var bobba_pos: Vector3 = _bobba.global_position
	var found: Dictionary = _probe_highest_ground(bobba_pos)

	_player.global_position = (found.pos as Vector3) + Vector3(0, 0.6, 0)
	_player.velocity = Vector3.ZERO

	# Face the camera down at Bobba from the perch.
	var cam_pivot: Node3D = _player.get_node_or_null("CameraPivot") as Node3D
	if cam_pivot:
		var to_bobba: Vector3 = bobba_pos - _player.global_position
		cam_pivot.rotation.y = atan2(-to_bobba.x, -to_bobba.z)
		cam_pivot.rotation.x = deg_to_rad(-12.0)

	print("[CombatTest] ARCHER perch ready at %.1f, %.1f, %.1f (%.1fm from Bobba, %.1fm above him) — you have the controls." % [
			_player.global_position.x, _player.global_position.y, _player.global_position.z,
			_player.global_position.distance_to(bobba_pos),
			_player.global_position.y - bobba_pos.y])
	print("[CombatTest]   hold LMB/F to draw, release to loose | arrows ignite ground fires")
	print("[CombatTest]   E spell | Space jump | Shift run | T lock-on | L day/night")


## Highest terrain point on probe rings around `center` (bow-fight radii).
## Returns {pos: Vector3, y: float}; y is -INF if nothing was hit.
func _probe_highest_ground(center: Vector3) -> Dictionary:
	var best := {"pos": center + Vector3(0, 0.5, 20.0), "y": -INF}
	for radius in [18.0, 26.0, 34.0]:
		for i in range(16):
			var ang: float = TAU * float(i) / 16.0
			var probe := center + Vector3(cos(ang) * radius, 0.0, sin(ang) * radius)
			var hit: Dictionary = _raycast_ground(probe)
			if hit and hit.position.y > float(best.y):
				best.y = hit.position.y
				best.pos = hit.position
	return best


## Straight-down world raycast (layer 1) at `xz`, from y+60 to y-30.
func _raycast_ground(xz: Vector3) -> Dictionary:
	var space: PhysicsDirectSpaceState3D = _player.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(
			Vector3(xz.x, xz.y + 60.0, xz.z), Vector3(xz.x, xz.y - 30.0, xz.z), 1)
	return space.intersect_ray(query)


## RIVER: night showcase of the upgraded river. First half frames the water
## and its earthy banks from the shore; second half pans up to the moon to
## verify the visible disc sits where the light comes from.
func _drive_river(_delta: float) -> void:
	var cam_pivot: Node3D = _player.get_node_or_null("CameraPivot") as Node3D
	if cam_pivot == null:
		return
	# Find the shader water surface the river builder spawned.
	var surface: Node3D = get_tree().current_scene.find_child("RiverWaterSurface", true, false) as Node3D
	if not _scripted_test_started:
		_scripted_test_started = true
		_player._spawn_immunity_timer = 60.0
		# Park Bobba far away — he wanders into the shot otherwise.
		var bobba := _find_in_group("bobba")
		if bobba:
			bobba.global_position = Vector3(180.0, bobba.global_position.y, 180.0)
		if surface:
			# Stand on the bank: off the surface centre, perpendicular to flow.
			var side: Vector3 = surface.global_transform.basis.x.normalized()
			var pos: Vector3 = surface.global_position + side * 9.0
			pos.y = _player.global_position.y
			_player.global_position = pos
			_player.velocity = Vector3.ZERO
	if _elapsed < 6.0 and surface:
		# Look across the water, slightly down.
		var to_river: Vector3 = surface.global_position - _player.global_position
		to_river.y = 0.0
		cam_pivot.rotation.y = atan2(-to_river.x, -to_river.z)
		cam_pivot.rotation.x = deg_to_rad(-16.0)
	else:
		# Pan up at the moon (azimuth 135° SE, elevation 40°).
		cam_pivot.rotation.y = deg_to_rad(-45.0)
		cam_pivot.rotation.x = deg_to_rad(30.0)


## SKEL: skeleton-pack verification (day-lit so the captures read).
## The player is parked 30 m from the pack's haunt — inside the 50 m
## dark-vision aggro — so the pack should RUSH and CROWD him. At t=10 one
## skeleton is destroyed by script (expect "rises again" 10 s later,
## somewhere else). At t=14 a ground fire is dropped between pack and
## player — the crowd must swerve around it and never stand in it.
func _drive_skel(_delta: float) -> void:
	var skels: Array = get_tree().get_nodes_in_group("skeletons")
	if skels.is_empty():
		return
	var crew := get_tree().current_scene.find_child("SkeletonCrew", true, false)
	if not _scripted_test_started:
		_scripted_test_started = true
		var center: Vector3 = crew.haunt_center if crew else (skels[0] as Node3D).global_position
		var pp: Vector3 = center + Vector3(30.0, 0.0, 0.0)
		pp.y = _player.global_position.y
		_player.global_position = pp
		_player.velocity = Vector3.ZERO
		# The observer must survive the whole crowd to verify revive + fire.
		_player._spawn_immunity_timer = 120.0
		print("[CombatTest] SKEL: player parked 30m from haunt %s" % str(center.snapped(Vector3.ONE)))
	var cam_pivot: Node3D = _player.get_node_or_null("CameraPivot") as Node3D
	if cam_pivot and crew:
		var to_c: Vector3 = crew.haunt_center - _player.global_position
		cam_pivot.rotation.y = atan2(-to_c.x, -to_c.z)
		cam_pivot.rotation.x = deg_to_rad(-4.0)
	# t=15: put a fire arrow into the nearest skeleton — it must catch
	# fire, burn, and every brother must keep clear of floor flames.
	if _elapsed >= 15.0 and not _skel_arrow_shot:
		_skel_arrow_shot = true
		var nearest_sk: Node3D = null
		var nd := INF
		for sk in skels:
			if not sk.is_dead_skeleton:
				var d: float = _player.global_position.distance_to((sk as Node3D).global_position)
				if d < nd:
					nd = d
					nearest_sk = sk
		if nearest_sk:
			var arrow = load("res://player/arrow.tscn").instantiate()
			arrow.shooter = _player
			arrow.is_local = true
			get_tree().current_scene.add_child(arrow)
			arrow.global_position = _player.global_position + Vector3(0, 1.5, 0)
			var aim: Vector3 = (nearest_sk.global_position + Vector3(0, 1.0, 0)) \
					- arrow.global_position
			arrow.launch(aim.normalized())
			print("[CombatTest] SKEL: fire arrow loosed at %s (%.1fm)" % [nearest_sk.name, nd])
	if _elapsed >= 10.0 and not _coop_fire_dropped:
		# (reusing the spare one-shot latch var) kill one skeleton...
		_coop_fire_dropped = true
		var victim: Node3D = skels[0]
		victim.take_hit(999.0, Vector3.ZERO)
		print("[CombatTest] SKEL: destroyed %s — expecting revive in 20s" % victim.name)
		FireFX.create_ground_fire(get_tree().current_scene,
				_player.global_position + Vector3(-6.0, 0.0, 0.0),
				"SkelTestGroundFire", 30.0, false)
		print("[CombatTest] SKEL: fire wall dropped between pack and player")
	if int(_elapsed) != int(_elapsed - _delta):
		var nearest := INF
		var alive := 0
		for sk in skels:
			if not sk.is_dead_skeleton:
				alive += 1
				nearest = minf(nearest, _player.global_position.distance_to((sk as Node3D).global_position))
		print("[CombatTest] SKEL t=%d alive=%d nearest=%.1f player_hp=%.0f" % [
				int(_elapsed), alive, nearest, float(_player.current_health)])


## NOFF: there is no friendly fire. Spawns an archer ally beside the paladin
## and turns every player-owned damage source on him in turn, checking his HP
## never moves — then turns the SAME ground fire on Bobba and checks that it
## does, because a rule that suppresses everything is indistinguishable from
## a test that fires nothing.
##
##   t=2   ally parked next to the paladin, and Bobba next to the ally
##   t=4   paladin swings, ally inside the sword hitbox
##   t=8   ground fire planted ON the ally (and reaching Bobba)
##   t=16  arrow loosed straight through the ally
##   t=24  verdict
func _drive_noff(_delta: float) -> void:
	var comp := _find_in_group("companion")
	if comp == null:
		if int(_elapsed) % 3 == 0 and int(_elapsed) != int(_elapsed - _delta):
			print("[CombatTest] NOFF: waiting for the companion")
		return
	var once := func(key: String, t: float) -> bool:
		if _elapsed >= t and not _bowsim_flags.has(key):
			_bowsim_flags[key] = true
			return true
		return false

	if once.call("setup", 2.0):
		comp.global_position = _player.global_position + Vector3(1.6, 0.5, 0.0)
		comp.set_physics_process(false)          # hold him in the blast
		_noff_ally_hp = float(comp.current_health)
		if _bobba:
			_bobba.set_physics_process(false)    # the control subject, held too
			_bobba.global_position = _player.global_position + Vector3(3.6, 0.0, 0.0)
			_noff_bobba_hp = float(_bobba.health)
		print("[CombatTest] NOFF: ally at %.1fm, bobba at %.1fm — ally hp=%.0f bobba hp=%.0f" % [
				_player.global_position.distance_to(comp.global_position),
				_player.global_position.distance_to((_bobba as Node3D).global_position) if _bobba else -1.0,
				_noff_ally_hp, _noff_bobba_hp])

	if once.call("sword", 4.0):
		_player._do_attack()
		print("[CombatTest] NOFF: paladin swung with the ally inside the hitbox")
	if once.call("sword_check", 6.0):
		print("[CombatTest] NOFF: after sword   ally hp=%.0f (was %.0f)" % [
				float(comp.current_health), _noff_ally_hp])

	if once.call("fire", 11.0):
		var fire_pos: Vector3 = comp.global_position
		var fire := FireFX.create_ground_fire(get_tree().current_scene, fire_pos,
				"NoffGroundFire", 30.0, false)
		_noff_fire = fire
		var aura = load("res://combat/damage_aura_area.gd").new()
		aura.name = "GroundFireAura"
		aura.radius = 5.0
		aura.damage_per_sec = 18.0
		aura.tick_interval = 1.0
		aura.lifetime = 30.0
		aura.source_node = comp     # the ARCHER's fire, as if he had shot it
		fire.add_child(aura)
		_coop_fire_dropped = true
		print("[CombatTest] NOFF: archer ground fire planted ON the ally")
	# Latch the control the moment it is observable. Bobba REGENERATES, and
	# the fire is strong enough to kill him outright — sampling his HP at the
	# verdict read 1000 again and reported the control as "never fired",
	# which would have looked exactly like the suppression being too broad.
	if _coop_fire_dropped and _bobba != null and is_instance_valid(_bobba) \
			and float(_bobba.health) < _noff_bobba_hp - 0.01:
		_noff_enemy_hurt = true
	if once.call("fire_check", 18.0):
		print("[CombatTest] NOFF: after 7s fire ally hp=%.0f (was %.0f)  enemy_took_damage=%s" % [
				float(comp.current_health), _noff_ally_hp, _noff_enemy_hurt])

	if once.call("arrow", 19.0):
		var arrow = load("res://player/arrow.tscn").instantiate()
		arrow.shooter = comp        # the ARCHER's arrow, aimed through the paladin
		arrow.is_local = true
		get_tree().current_scene.add_child(arrow)
		arrow.global_position = comp.global_position + Vector3(0, 1.4, 0)
		var aim: Vector3 = (_player.global_position + Vector3(0, 1.2, 0)) - arrow.global_position
		arrow.launch(aim.normalized())
		_noff_paladin_hp = float(_player.current_health)
		print("[CombatTest] NOFF: arrow loosed at the paladin from %.1fm" % aim.length())

	# Now that the control is latched, pull Bobba clear of the flames and put
	# one arrow into him — the damage model check. Absolute damage means this
	# number must be DIRECT_HIT_DAMAGE exactly, whatever his max HP is; under
	# percent damage it was 5% of 1000 = 50, and would have changed the day
	# anyone retuned his health bar.
	# The damage-model check runs BEFORE anything is set alight. Measuring it
	# afterwards read 89, then 71, because the ground-fire aura keeps a body
	# in its list until Area3D reports the exit and queue_free lands at the
	# end of the frame - both readings were the arrow plus stray 18 HP ticks.
	# Ordering the phases costs nothing and removes the interference entirely.
	if once.call("enemy_arrow", 7.0) and _bobba != null:
		# Silence every fire on the field first, and zero their auras rather
		# than only freeing them (queue_free lands at end of frame, a tick
		# can still get in). The COMPANION IS AN AI ARCHER: left to itself it
		# llooses fire arrows into the dark on its own initiative, and its
		# ground fires were landing 18 HP ticks in the middle of the reading.
		# Zero the auras rather than free the fires: the archer's fire-circle
		# node is in this group AND is a child of the caster, so freeing group
		# members tears out a live player's own spell.
		for gf in get_tree().get_nodes_in_group("ground_fire"):
			for ch in gf.get_children():
				if "damage_per_sec" in ch:
					ch.damage_per_sec = 0.0
		_noff_bobba_hp_arrow = float(_bobba.health)
		var ea = load("res://player/arrow.tscn").instantiate()
		ea.shooter = comp
		ea.is_local = true
		get_tree().current_scene.add_child(ea)
		ea.global_position = (_bobba as Node3D).global_position + Vector3(-2.0, 1.2, 0)
		ea.launch(Vector3(1, 0, 0))
		print("[CombatTest] NOFF: arrow into Bobba (hp %.0f before)" % _noff_bobba_hp_arrow)
		# +0.6 s, not +2 s. A fire arrow lights a ground fire WHERE IT LANDS, so
	# a target standing in the flames it just started keeps taking 18 HP a
	# second - the first two readings here (89, then 89 again with no other
	# fire on the field) were the direct hit plus its own DoT. The aura's
	# first tick is a full second out, so a short window isolates the hit.
	if once.call("enemy_arrow_check", 7.6) and _bobba != null:
		var dealt: float = _noff_bobba_hp_arrow - float(_bobba.health)
		_noff_arrow_dealt = dealt
		print("[CombatTest] NOFF: arrow dealt %.1f HP to Bobba (expect 35.0 flat; it was 50 = 5%% of 1000)"
				% dealt)

	if once.call("verdict", 24.0):
		var ally_ok: bool = float(comp.current_health) >= _noff_ally_hp - 0.01
		var paladin_ok: bool = float(_player.current_health) >= _noff_paladin_hp - 0.01
		var bobba_hurt: bool = _noff_enemy_hurt
		var flat_ok: bool = absf(_noff_arrow_dealt - 35.0) < 0.51
		print("[CombatTest] NOFF ally_unharmed=%s paladin_unharmed=%s enemy_still_burns=%s arrow_flat=%s verdict=%s" % [
				ally_ok, paladin_ok, bobba_hurt, flat_ok,
				"PASS" if (ally_ok and paladin_ok and bobba_hurt and flat_ok) else "FAIL"])

## DARKSIM: does the archer's fire actually FIND anything? Runs at NIGHT —
## the only skeleton scenario that does, since SKEL forces daylight so its
## captures read, which is exactly why nobody noticed the dark rules were
## inert.
##
## The player stands 22 m off the haunt: outside moonlight, inside the range
## a ground fire lights. Nothing is lit for the first 10 s (the baseline —
## AI-visible should be ZERO and the screen should be near-black), then a fire
## is planted between the party and the pack. Every second it reports the two
## numbers that matter and that used to be impossible to tell apart:
##
##   ai_sees  — how many skeletons Perception says are visible
##   lit      — how many stand in a fire's glow
##
## Before the radius fix those were the same number whatever you did, because
## the free moonlight range covered fire's entirely.
func _drive_darksim(_delta: float) -> void:
	var skels: Array = get_tree().get_nodes_in_group("skeletons")
	if skels.is_empty():
		if int(_elapsed) % 3 == 0 and int(_elapsed) != int(_elapsed - _delta):
			print("[CombatTest] DARKSIM: waiting for the crew to rise")
		return
	var crew := get_tree().current_scene.find_child("SkeletonCrew", true, false)
	if not _scripted_test_started:
		_scripted_test_started = true
		var center: Vector3 = crew.haunt_center if crew else (skels[0] as Node3D).global_position
		_darksim_haunt = center
		# Stand off on the far side of the haunt FROM Bobba, and hold him
		# there. He spawns 25-40 m from the pack, and parked on his side of
		# it he simply walked into the shot and filled it — the frames were
		# of an orc, not of a dark field with something in it.
		var away := Vector3(1, 0, 0)
		if _bobba != null and is_instance_valid(_bobba):
			(_bobba as Node3D).set_physics_process(false)
			var d: Vector3 = center - (_bobba as Node3D).global_position
			d.y = 0.0
			if d.length() > 0.5:
				away = d.normalized()
		var pp: Vector3 = center + away * DARKSIM_STANDOFF
		pp.y = _player.global_position.y
		_player.global_position = pp
		_player.velocity = Vector3.ZERO
		_player._spawn_immunity_timer = 120.0
		# HOLD the pack where it rose. Skeletons have dark vision and a 50 m
		# aggro, so left alone they cross 18 m in five seconds and every
		# reading afterwards is taken at knife range, where the light rules
		# no longer separate anything. Freezing them is the only way to ask
		# the question this scenario exists for: at a FIXED distance, what
		# changes when the archer lights a fire?
		for sk in skels:
			(sk as Node3D).set_physics_process(false)
		print("[CombatTest] DARKSIM: player %.0fm from haunt %s, pack held, no fire"
				% [DARKSIM_STANDOFF, str(center.snapped(Vector3.ONE))])
	var cam_pivot: Node3D = _player.get_node_or_null("CameraPivot") as Node3D
	if cam_pivot:
		var to_c: Vector3 = _darksim_haunt - _player.global_position
		cam_pivot.rotation.y = atan2(-to_c.x, -to_c.z)
		cam_pivot.rotation.x = deg_to_rad(-6.0)

	# t=12: the archer's fire arrow lands ON the pack — the shot that turns
	# "something is out there" into "there are five of them, there".
	if _elapsed >= 12.0 and not _coop_fire_dropped:
		_coop_fire_dropped = true
		FireFX.create_ground_fire(get_tree().current_scene, _darksim_haunt,
				"DarkSimGroundFire", 60.0, false)
		print("[CombatTest] DARKSIM: --- FIRE LIT on the haunt ---")

	if int(_elapsed) != int(_elapsed - _delta):
		var sees := 0
		var lit := 0
		var nearest := INF
		for sk in skels:
			if sk.is_dead_skeleton:
				continue
			nearest = minf(nearest, _player.global_position.distance_to(
					(sk as Node3D).global_position))
			if Perception.can_see(_player, sk):
				sees += 1
			if Perception.is_lit_by_fire(sk):
				lit += 1
		print("[CombatTest] DARKSIM t=%d fire=%s ai_sees=%d lit=%d nearest=%.1f" % [
				int(_elapsed), "yes" if _coop_fire_dropped else "no",
				sees, lit, nearest])


## REVIVE: co-op revive + crouch simulation. Kills the AI companion,
## then drives the human through the E-hold channel: an interrupted
## channel must reset to zero, a full 5s channel must raise the ally at
## half HP, and a crouched hit must land at 75% damage.
func _drive_revive(_delta: float) -> void:
	var comp := _find_in_group("companion")
	if comp == null:
		return
	var once := func(key: String, t: float) -> bool:
		if _elapsed >= t and not _bowsim_flags.has(key):
			_bowsim_flags[key] = true
			return true
		return false

	if once.call("setup", 0.0):
		var bobba := _find_in_group("bobba")
		if bobba:
			bobba.global_position = Vector3(200.0, bobba.global_position.y, 200.0)
		comp.global_position = _player.global_position \
				+ Vector3(2.0, 0.5, 0.0)
	if once.call("kill", 1.0):
		comp.take_hit(999.0, Vector3.ZERO, false)
		print("[CombatTest] REVIVE: companion killed (dead=%s)" % str(comp.is_dead))
	if once.call("marker_check", 1.4):
		var marker := get_tree().current_scene.find_child("*DeathMarker*", true, false)
		print("[CombatTest] REVIVE: death marker present=%s" % str(marker != null))
	if once.call("hold1", 2.0):
		Input.action_press(&"revive")
	if once.call("release1", 4.0):
		Input.action_release(&"revive")
	if once.call("check_interrupt", 4.3):
		var ok: bool = not _player.is_reviving and _player._revive_progress == 0.0 \
				and comp.is_dead
		_bowsim_flags["interrupt_ok"] = ok
		print("[CombatTest] REVIVE: interrupt resets progress -> %s" % str(ok))
	if once.call("hold2", 4.6):
		Input.action_press(&"revive")
	if once.call("check_revived", 10.4):
		Input.action_release(&"revive")
		var ok: bool = not comp.is_dead \
				and absf(float(comp.current_health) - float(comp.max_health) * 0.5) < 1.0
		_bowsim_flags["revived_ok"] = ok
		print("[CombatTest] REVIVE: ally revived at half hp -> %s (dead=%s hp=%.0f)" % [
				str(ok), str(comp.is_dead), float(comp.current_health)])
	if once.call("crouch_on", 11.0):
		_player._spawn_immunity_timer = 0.0
		Input.action_press(&"crouch")
	if once.call("crouch_hit", 11.5):
		var before: float = float(_player.current_health)
		_player.take_hit(40.0, Vector3.ZERO, false)
		var dealt: float = before - float(_player.current_health)
		var ok: bool = absf(dealt - 30.0) < 1.5
		_bowsim_flags["crouch_ok"] = ok
		print("[CombatTest] REVIVE: crouched 40dmg hit dealt %.1f (expect 30) -> %s" % [dealt, str(ok)])
		Input.action_release(&"crouch")


## PALSIM: MOBILE input-path simulation for the PALADIN. Touch taps on
## the attack button arrive as InputEventAction press/release pairs; the
## joystick as analog move actions. Measures what "unresponsive" means in
## numbers: tap→swing latency, TAPS THAT PRODUCE NO SWING AT ALL (taps
## landing in the recovery tail / cooldown are silently eaten), combo
## chains from fast taps, locomotion freezes, and how long movement takes
## to come back after a chain.
func _drive_palsim(_delta: float) -> void:
	var once := func(key: String, t: float) -> bool:
		if _elapsed >= t and not _bowsim_flags.has(key):
			_bowsim_flags[key] = true
			return true
		return false
	var tap := func() -> void:
		var ev := InputEventAction.new()
		ev.action = "attack"
		ev.pressed = true
		Input.parse_input_event(ev)
		var ev2 := InputEventAction.new()
		ev2.action = "attack"
		ev2.pressed = false
		Input.parse_input_event(ev2)
		_bowsim_flags["taps"] = int(_bowsim_flags.get("taps", 0)) + 1
		_bowsim_flags["last_tap_t"] = _elapsed

	if once.call("setup", 0.0):
		var start := Vector3(120.0, 0.0, -140.0)
		var space: PhysicsDirectSpaceState3D = _player.get_world_3d().direct_space_state
		var query := PhysicsRayQueryParameters3D.create(
				start + Vector3(0, 60, 0), start + Vector3(0, -60, 0), 1)
		var hit: Dictionary = space.intersect_ray(query)
		start.y = (hit.position.y + 0.3) if hit.has("position") else _player.global_position.y
		_player.global_position = start
		_player.velocity = Vector3.ZERO
		_player._spawn_immunity_timer = 120.0
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		var bobba := _find_in_group("bobba")
		if bobba:
			bobba.global_position = Vector3(200.0, bobba.global_position.y, 200.0)
		_add_key_light()

	# A: plain walk baseline.
	if once.call("walk_on", 0.5):
		Input.action_press(&"move_forward", 1.0)
		_bowsim_flags["input_held"] = true
	if once.call("walk_off", 2.2):
		Input.action_release(&"move_forward")
		_bowsim_flags["input_held"] = false

	# B: single tap — latency probe.
	if once.call("tap1", 2.6):
		tap.call()

	# C: fast triple-tap combo (0.25s apart, inside the 0.5s click window).
	if once.call("c1", 4.4):
		tap.call()
	if once.call("c2", 4.65):
		tap.call()
	if once.call("c3", 4.9):
		tap.call()

	# D: the "eaten tap": swing, then tap in the recovery tail (~0.9s in),
	# then tap during the post-chain cooldown.
	if once.call("d1", 8.0):
		tap.call()
	if once.call("d2", 8.9):
		tap.call()
	if once.call("d3", 9.65):
		tap.call()

	# E: tap-spam while moving (real thumb behaviour), then movement
	# recovery measurement after the last swing.
	if once.call("e_move", 10.6):
		Input.action_press(&"move_forward", 1.0)
		_bowsim_flags["input_held"] = true
	for i in range(6):
		if once.call("spam%d" % i, 10.8 + 0.22 * i):
			tap.call()
	if once.call("e_done", 13.4):
		_bowsim_flags["watch_recover"] = true

	# ---- per-frame detectors ------------------------------------------
	# Swing rising edge + latency from the most recent tap.
	var attacking: bool = _player.is_attacking
	if attacking and not bool(_bowsim_flags.get("prev_attacking", false)):
		_bowsim_flags["swings"] = int(_bowsim_flags.get("swings", 0)) + 1
		if _bowsim_flags.has("last_tap_t"):
			var lat: float = _elapsed - float(_bowsim_flags["last_tap_t"])
			_bowsim_flags["max_latency"] = maxf(float(_bowsim_flags.get("max_latency", 0.0)), lat)
	_bowsim_flags["prev_attacking"] = attacking
	_bowsim_flags["combo_max"] = maxi(int(_bowsim_flags.get("combo_max", 0)), int(_player._combo_step))

	if bool(_bowsim_flags.get("watch_recover", false)) and _elapsed >= 15.2:
		_bowsim_flags["move_recover"] = Vector2(_player.velocity.x, _player.velocity.z).length()
		_bowsim_flags["watch_recover"] = false
		var app: AnimationPlayer = _player._current_anim_player
		print("[CombatTest] PALSIM: speed 1.8s after last tap = %.1f (attacking=%s anim=%s playing=%s pos=%.2f step=%d cd=%.2f bank=%d stam=%.0f)" % [
				float(_bowsim_flags["move_recover"]), str(_player.is_attacking),
				String(app.current_animation) if app else "nil",
				str(app.is_playing()) if app else "nil",
				app.current_animation_position if (app and app.current_animation != "") else -1.0,
				int(_player._combo_step), float(_player._attack_cooldown),
				int(_player._combo_clicks_buffered),
				float(_player._stamina.current) if ("current" in _player._stamina) else -1.0])
		Input.action_release(&"move_forward")
		_bowsim_flags["input_held"] = false

	var ap2: AnimationPlayer = _player._current_anim_player
	if ap2 != null and _player.is_on_floor() \
			and Vector2(_player.velocity.x, _player.velocity.z).length() > 2.0 \
			and bool(_bowsim_flags.get("input_held", false)) and not attacking:
		var anim := String(ap2.current_animation)
		var loco: bool = ("Walk" in anim or "Run" in anim or "Strafe" in anim) and ap2.is_playing()
		if not loco:
			_bowsim_freeze += 1
			if _bowsim_freeze <= 5:
				print("[CombatTest] PALSIM FREEZE t=%.2f anim=%s" % [_elapsed, anim])


## MOBSIM: MOBILE input-path simulation for the archer. The touch UI
## drives the game exclusively through InputEventAction press/release
## pairs ("attack" button, joystick move actions with analog strength) —
## this scenario replays that exact stream through the player's real
## _input pipeline, including the failure mode phones produce: a LOST
## RELEASE (finger slides off the button / touch cancelled → the action
## resets but the release EVENT never arrives). Detectors: frozen-legs
## frames, stuck-draw frames (drawing/holding while the action is up),
## shots fired, and analog walk vs full-tilt run speeds.
func _drive_mobsim(_delta: float) -> void:
	var once := func(key: String, t: float) -> bool:
		if _elapsed >= t and not _bowsim_flags.has(key):
			_bowsim_flags[key] = true
			return true
		return false
	var touch := func(pressed: bool) -> void:
		var ev := InputEventAction.new()
		ev.action = "attack"
		ev.pressed = pressed
		Input.parse_input_event(ev)

	if once.call("setup", 0.0):
		# Snap to the actual ground so no phase starts mid-fall (a falling
		# player reads as zero speed / non-locomotion and pollutes detectors).
		var start := Vector3(120.0, 0.0, -140.0)
		var space: PhysicsDirectSpaceState3D = _player.get_world_3d().direct_space_state
		var query := PhysicsRayQueryParameters3D.create(
				start + Vector3(0, 60, 0), start + Vector3(0, -60, 0), 1)
		var hit: Dictionary = space.intersect_ray(query)
		start.y = (hit.position.y + 0.3) if hit.has("position") else _player.global_position.y
		_player.global_position = start
		_player.velocity = Vector3.ZERO
		_player._spawn_immunity_timer = 120.0
		var bobba := _find_in_group("bobba")
		if bobba:
			bobba.global_position = Vector3(200.0, bobba.global_position.y, 200.0)
		var pivot: Node3D = _player.get_node_or_null("CameraPivot") as Node3D
		if pivot:
			pivot.rotation.x = 0.0
		_add_key_light()

	# A: analog walk (joystick half-tilt), then full tilt.
	if once.call("walk_half", 0.3):
		Input.action_press(&"move_forward", 0.5)
		_bowsim_flags["input_held"] = true
	if once.call("walk_half_meas", 1.5):
		_bowsim_flags["walk_speed"] = Vector2(_player.velocity.x, _player.velocity.z).length()
		print("[CombatTest] MOBSIM probe: strength=%.2f vec=%s crouch=%s reviving=%s anim=%s" % [
				Input.get_action_strength(&"move_forward"),
				str(Input.get_vector(&"move_left", &"move_right", &"move_forward", &"move_back", 0.15)),
				str(_player.is_crouching), str(_player.is_reviving),
				String(_player._archer_anim_player.current_animation) if _player._archer_anim_player else "nil"])
	if once.call("walk_full", 1.6):
		Input.action_press(&"move_forward", 1.0)
	if once.call("walk_full_meas", 2.8):
		_bowsim_flags["run_speed"] = Vector2(_player.velocity.x, _player.velocity.z).length()
	if once.call("walk_stop", 3.0):
		Input.action_release(&"move_forward")
		_bowsim_flags["input_held"] = false

	# B: touch hold-shot.
	if once.call("hold1", 3.4):
		touch.call(true)
	if once.call("shot1", 4.4):
		touch.call(false)

	# C: five rapid taps (cancel path), then a clean hold-shot.
	for i in range(5):
		if once.call("tapd%d" % i, 5.0 + 0.24 * i):
			touch.call(true)
		if once.call("tapu%d" % i, 5.12 + 0.24 * i):
			touch.call(false)
	if once.call("hold2", 6.6):
		touch.call(true)
	if once.call("shot2", 7.6):
		touch.call(false)
	if once.call("tapcheck", 7.9):
		_bowsim_flags["tap_recover"] = int(_bowsim_flags.get("shots", 0)) >= 2
		print("[CombatTest] MOBSIM: hold-shot after tap burst -> %s" % str(_bowsim_flags["tap_recover"]))

	# D: LOST RELEASE — the phone killer. Press arrives, release never does.
	if once.call("lost_press", 8.4):
		touch.call(true)
	if once.call("lost_silent", 8.8):
		Input.action_release(&"attack")  # action resets, NO event delivered
		print("[CombatTest] MOBSIM: simulated lost touch-release")
	if once.call("lost_retry_press", 10.0):
		touch.call(true)
	if once.call("lost_retry_release", 11.0):
		touch.call(false)
	if once.call("lost_check", 11.3):
		_bowsim_flags["lostrelease_recover"] = int(_bowsim_flags.get("shots", 0)) >= 3
		print("[CombatTest] MOBSIM: shot after lost release -> %s (shots=%d)" % [
				str(_bowsim_flags["lostrelease_recover"]), int(_bowsim_flags.get("shots", 0))])

	# E: aim-walking on touch — measure zoom (must NOT engage while
	# moving) and the moving shot's flight distance.
	if once.call("walkaim_on", 12.0):
		Input.action_press(&"move_forward", 1.0)
		_bowsim_flags["input_held"] = true
	if once.call("walkaim_draw", 12.3):
		var pv: Node3D = _player.get_node_or_null("CameraPivot") as Node3D
		if pv:
			pv.rotation.x = deg_to_rad(30.0)  # max-range lob for the measurement
		touch.call(true)
	if once.call("walkaim_zoom_meas", 13.1):
		_bowsim_flags["zoom_move"] = _player._spring_arm.spring_length
	if once.call("walkaim_shot", 13.3):
		touch.call(false)
		_bowsim_flags["watch_move_shot"] = true
	if once.call("walkaim_off", 14.2):
		Input.action_release(&"move_forward")
		_bowsim_flags["input_held"] = false

	# F: standing zoom + standing shot distance (comparison baseline).
	if once.call("standaim_draw", 15.0):
		var pv2: Node3D = _player.get_node_or_null("CameraPivot") as Node3D
		if pv2:
			pv2.rotation.x = deg_to_rad(30.0)
		touch.call(true)
	if once.call("standaim_zoom_meas", 16.2):
		_bowsim_flags["zoom_stand"] = _player._spring_arm.spring_length
	if once.call("standaim_shot", 16.4):
		touch.call(false)
		_bowsim_flags["watch_stand_shot"] = true

	# G: mobile crouch toggle (tap semantics — action persists).
	if once.call("crouch_tap", 19.5):
		var ev := InputEventAction.new()
		ev.action = "crouch"
		ev.pressed = true
		Input.parse_input_event(ev)
	if once.call("crouch_check", 20.0):
		var on: bool = _player.is_crouching
		var ev2 := InputEventAction.new()
		ev2.action = "crouch"
		ev2.pressed = false
		Input.parse_input_event(ev2)
		_bowsim_flags["crouch_toggle"] = on
		print("[CombatTest] MOBSIM: crouch after toggle-tap -> %s" % str(on))

	# ---- arrow flight tracking (standing vs moving loose) -------------
	for arrow in get_tree().get_nodes_in_group("fire_arrows"):
		if not (arrow is RigidBody3D) or not is_instance_valid(arrow):
			continue
		if not _bowsim_flags.has("origin_%d" % arrow.get_instance_id()):
			_bowsim_flags["origin_%d" % arrow.get_instance_id()] = (arrow as Node3D).global_position
			if _bowsim_flags.get("watch_move_shot", false):
				_bowsim_flags["move_arrow"] = arrow.get_instance_id()
				_bowsim_flags["watch_move_shot"] = false
				print("[CombatTest] MOBSIM: moving-shot arrow speed=%.1f" % (arrow as RigidBody3D).linear_velocity.length())
			elif _bowsim_flags.get("watch_stand_shot", false):
				_bowsim_flags["stand_arrow"] = arrow.get_instance_id()
				_bowsim_flags["watch_stand_shot"] = false
				print("[CombatTest] MOBSIM: standing-shot arrow speed=%.1f" % (arrow as RigidBody3D).linear_velocity.length())
		if (arrow as RigidBody3D).freeze:
			var oid := arrow.get_instance_id()
			var dist: float = (arrow as Node3D).global_position.distance_to(
					_bowsim_flags["origin_%d" % oid])
			if int(_bowsim_flags.get("move_arrow", -1)) == oid and not _bowsim_flags.has("move_dist"):
				_bowsim_flags["move_dist"] = dist
				print("[CombatTest] MOBSIM: moving-shot landed at %.1fm" % dist)
			elif int(_bowsim_flags.get("stand_arrow", -1)) == oid and not _bowsim_flags.has("stand_dist"):
				_bowsim_flags["stand_dist"] = dist
				print("[CombatTest] MOBSIM: standing-shot landed at %.1fm" % dist)

	# ---- per-frame detectors ------------------------------------------
	var new_arrows := get_tree().get_nodes_in_group("fire_arrows").size()
	var prev := int(_bowsim_flags.get("arrow_count", 0))
	if new_arrows > prev:
		_bowsim_flags["shots"] = int(_bowsim_flags.get("shots", 0)) + (new_arrows - prev)
	_bowsim_flags["arrow_count"] = new_arrows

	if (_player.is_drawing_bow or _player.is_holding_bow) \
			and not Input.is_action_pressed(&"attack"):
		_bowsim_flags["stuck_frames"] = int(_bowsim_flags.get("stuck_frames", 0)) + 1

	var ap: AnimationPlayer = _player._archer_anim_player
	if ap != null and _player.is_on_floor() \
			and Vector2(_player.velocity.x, _player.velocity.z).length() > 1.2 \
			and bool(_bowsim_flags.get("input_held", false)):
		var anim := String(ap.current_animation)
		var loco: bool = anim in ["archer/Walk", "archer/Run", "archer/StrafeLeft", "archer/StrafeRight"] \
				and ap.is_playing()
		var aim_burst: bool = anim == "archer/Attack" \
				and (_player.is_attacking or _player.is_drawing_bow or _player.is_holding_bow)
		if not loco and not aim_burst:
			_bowsim_freeze += 1
			if _bowsim_freeze <= 5:
				print("[CombatTest] MOBSIM FREEZE t=%.2f anim=%s playing=%s" % [
						_elapsed, anim, str(ap.is_playing())])


## ANIMSIM: locomotion-vs-actions STRESS test, with Bobba live so real
## hits land mid-action. Holds a movement direction at all times and fires
## the whole action vocabulary through the real _input pipeline (attack,
## block hold/release, parry, dodge, estus, spell, combat-mode toggle,
## jump) on a fast cadence, for both classes. Detector: while moving on
## the ground with input held, the AnimationPlayer must be RUNNING a
## locomotion clip; anything else accumulates stall time. A stall past
## STALL_WARN gets a full state dump (which gate flag holds the body,
## which clip is loaded, whether the player is even playing) and past
## STALL_HARD counts as a stuck-forever freeze.
const ANIMSIM_STALL_WARN: float = 1.2
const ANIMSIM_STALL_HARD: float = 3.0
const ANIMSIM_ACTIONS: Array[String] = [
	"attack", "attack", "block_on", "attack", "parry", "block_off",
	"dodge", "attack", "spell", "attack", "toggle", "attack",
	"block_on", "dodge", "attack", "block_off", "estus", "jump",
	"attack", "attack", "parry", "toggle", "attack", "block_on",
	"attack", "attack", "block_off", "dodge",
]
const ANIMSIM_DIRS: Array[StringName] = [&"move_forward", &"move_right",
		&"move_back", &"move_left"]


## GEARSIM: turntable rig for the bone-attached gear. Parks the character in
## flat daylight, pulls the camera in to a bust shot and orbits it, cycling
## armed -> unarmed -> archer so every loadout gets a full revolution. The
## gear offsets are hand-tuned against these frames — the mixamorig bone axes
## are not consistent limb to limb, so eyes beat arithmetic here.
## Overridable from the shell so one scenario covers the whole graphics
## matrix: LOB_GEAR_ORBIT (camera distance), LOB_GEAR_HEIGHT (look-at), and
## LOB_GEAR_NIGHT=1 to skip the day override and shoot the game's DEFAULT
## rainy-night lighting, which is what players actually see.
const GEARSIM_ORBIT_DEFAULT: float = 4.6
const GEARSIM_HEIGHT_DEFAULT: float = 1.05
const GEARSIM_PER_CLASS: float = 6.0  # seconds per loadout

func _drive_gearsim(delta: float) -> void:
	const P := Vector3(120.0, 0.0, -140.0)
	if not _scripted_test_started:
		_scripted_test_started = true
		var pp := P
		pp.y = _player.global_position.y
		_player.global_position = pp
		_player.velocity = Vector3.ZERO
		print("[CombatTest/GEARSIM] turntable start")

	# LOB_GEAR_TARGET=bobba turntables the ENEMY instead of the player. The
	# camera rig is bolted to the player, so ride the player to Bobba's spot
	# and hide its body: the camera then orbits Bobba and looks straight at
	# it, which is the only way to get a controlled shot of an enemy model.
	if OS.get_environment("LOB_GEAR_TARGET") == "bobba" \
			and _bobba != null and is_instance_valid(_bobba):
		_player.global_position = (_bobba as Node3D).global_position
		_player.velocity = Vector3.ZERO
		# Hide the whole player, not just a node guessed by name — riding it
		# to Bobba means any visible part of it sits exactly between the
		# camera and the subject, and at some yaws it filled the frame.
		for n in _gearsim_mesh_list(_player):
			n.visible = false
		# LOB_GEAR_CLIP=<name> holds Bobba on one clip so an authored motion
		# can be watched in isolation. The AI would otherwise wander him
		# through idle and attacks and the clip would never be visible.
		# LOB_GEAR_HIT=1 strikes Bobba on a fixed cadence so the whole
		# received-hit stack — flash, squash, lurch, react clip, smear — can
		# be watched in day light on a still camera. The combat scenarios
		# shoot this at night from inside his legs.
		if OS.get_environment("LOB_GEAR_HIT") == "1":
			_gearsim_hit_timer += delta
			if _gearsim_hit_timer >= 1.5:
				_gearsim_hit_timer = 0.0
				var kb: Vector3 = -(_bobba as Node3D).global_transform.basis.z * 6.0
				_bobba.take_hit(40.0, kb, false, _player, false)
				print("[CombatTest/GEARSIM] struck Bobba at t=%.2f" % _elapsed)

		var clip := OS.get_environment("LOB_GEAR_CLIP")
		if clip != "":
			_bobba.set_physics_process(OS.get_environment("LOB_GEAR_HIT") == "1")
			var ap: AnimationPlayer = _bobba.get("_anim_player") as AnimationPlayer
			var full := StringName("bobba/" + clip)
			if ap != null and ap.has_animation(full) \
					and ap.current_animation != String(full):
				ap.play(full)
				ap.get_animation(full).loop_mode = Animation.LOOP_LINEAR
				print("[CombatTest/GEARSIM] holding Bobba on %s (%.2fs)" % [
						full, ap.get_animation(full).length])
			# LOB_GEAR_SEEK=<0..1> pins the clip at an exact fraction instead
			# of letting it run. Sampling a playing clip by wall clock is not
			# phase-locked, so "the apex frame" was never reliably the apex —
			# several rounds of tuning were done against mis-sampled poses.
			var seek := OS.get_environment("LOB_GEAR_SEEK")
			if ap != null and seek.is_valid_float() and ap.current_animation != "":
				ap.seek(clampf(float(seek), 0.0, 1.0) * ap.current_animation_length, true)
				ap.pause()
			# Physics is off above, so anything Bobba does per-frame to his
			# gear has to be ticked by hand or the capture shows a pose the
			# game never draws. A whole second of delta snaps the blend.
			if _bobba.has_method("_update_axe_grip"):
				_bobba._update_axe_grip(1.0)
	elif OS.get_environment("LOB_GEAR_CLIP") != "":
		# Same treatment for the PLAYER, so an authored player clip can be
		# read frame by frame too. LOB_GEAR_CLIP is unprefixed here as well;
		# the current loadout's library supplies the prefix, which keeps one
		# clip name working across armed, unarmed and archer.
		_gearsim_hold_player_clip()

	# The camera rig eases spring_length back to DEFAULT_SPRING_LENGTH every
	# physics frame, so a one-shot assignment is undone before the next
	# capture. Hold the framing here instead, every frame.
	var arm: SpringArm3D = _player.get_node_or_null(
			"CameraPivot/SpringArm3D") as SpringArm3D
	if arm:
		arm.spring_length = _gearsim_orbit()
		# The arm shortens on collision, and orbiting this close it kept
		# collapsing into the character — every frame came out as a
		# close-up of the inside of the helmet.
		arm.collision_mask = 0
		arm.margin = 0.0
	var cam: Camera3D = _player.get_node_or_null(
			"CameraPivot/SpringArm3D/Camera3D") as Camera3D
	if cam:
		# SpringArm3D owns the camera's Z — it is what pushes the camera out
		# to spring_length. Only clear the over-the-shoulder X/Y offset;
		# zeroing all three pinned the camera onto the pivot and every frame
		# came back as a close-up of the character's shoulder.
		cam.position.x = 0.0
		cam.position.y = 0.0
		cam.fov = 45.0

	# One revolution per loadout, then switch class — unless a clip is being
	# held, in which case the loadout must stay put: cycling it swaps the
	# animation library out from under the clip being examined.
	var slot: int = int(_elapsed / GEARSIM_PER_CLASS)
	if OS.get_environment("LOB_GEAR_CLIP") != "":
		slot = _gearsim_slot
	if slot != _gearsim_slot:
		_gearsim_slot = slot
		match slot:
			1:
				if _player.has_method("_toggle_combat_mode"):
					_player._toggle_combat_mode()  # armed -> unarmed
			2:
				if _player.has_method("_switch_character_class"):
					_player._switch_character_class(1)  # CharacterClass.ARCHER
		_gearsim_report()

	var pivot: Node3D = _player.get_node_or_null("CameraPivot") as Node3D
	if pivot:
		# Holding a clip? Freeze the orbit at a three-quarter view — otherwise
		# the camera's rotation is mixed into the frames and the motion of the
		# clip itself cannot be read.
		if OS.get_environment("LOB_GEAR_CLIP") != "":
			# LOB_GEAR_ANGLE picks the frozen viewing angle — a two-handed
			# grip or a weapon crossing the body is unreadable from the
			# default three-quarter and needs a front or side look.
			var ang := OS.get_environment("LOB_GEAR_ANGLE")
			pivot.rotation.y = deg_to_rad(float(ang) if ang.is_valid_float() else 38.0)
		else:
			pivot.rotation.y = _elapsed * (TAU / GEARSIM_PER_CLASS)
		pivot.rotation.x = 0.0
		pivot.position.y = _gearsim_height()


## Hold the PLAYER on one clip, pinned at LOB_GEAR_SEEK. The player drives its
## own animation every frame from movement state, so a clip set once is gone by
## the next frame — this re-asserts it, and freezes the body so locomotion does
## not fight the pose being examined.
func _gearsim_hold_player_clip() -> void:
	if _player == null or not is_instance_valid(_player):
		return
	var ap: AnimationPlayer = _player.get("_current_anim_player") as AnimationPlayer
	if ap == null:
		return
	var clip := OS.get_environment("LOB_GEAR_CLIP")
	var prefix: String = "armed"
	if _player.has_method("_get_current_mode_prefix"):
		prefix = _player._get_current_mode_prefix()
	var full := StringName("%s/%s" % [prefix, clip])
	if not ap.has_animation(full):
		return
	_player.velocity = Vector3.ZERO
	if ap.current_animation != String(full):
		ap.play(full)
		print("[CombatTest/GEARSIM] holding player on %s (%.2fs)" % [
				full, ap.get_animation(full).length])
	var seek := OS.get_environment("LOB_GEAR_SEEK")
	if seek.is_valid_float():
		ap.seek(clampf(float(seek), 0.0, 1.0) * ap.current_animation_length, true)
		ap.pause()


## Logs where every attached piece actually ended up in world space, so a
## piece that is off by a metre is obvious in the log without squinting at
## a screenshot.
func _gearsim_report() -> void:
	# All three characters live under the player at once (only one visible),
	# so report every skeleton and say which body each piece hangs on —
	# reading just the first one silently showed the unarmed loadout forever.
	var origin: Vector3 = (_player as Node3D).global_position
	var found := 0
	for skel in _gearsim_skeletons(_player):
		var owner_name: String = _gearsim_owner(skel)
		var shown: bool = (skel as Node3D).is_visible_in_tree()
		print("[CombatTest/GEARSIM] %s skeleton world_scale=%s" % [
				owner_name, str(skel.global_transform.basis.get_scale())])
		# What each attach bone's own axes point at in world space, at REST.
		# Without this the correct euler for a piece is pure trial and error.
		for bone_name in ["mixamorig_Head", "mixamorig_Sword_joint",
				"mixamorig_Shield_joint", "mixamorig_Hips", "mixamorig_Spine2",
				"mixamorig_Left_arch1"]:
			var bi: int = skel.find_bone(bone_name)
			if bi == -1:
				continue
			var b: Basis = (skel.global_transform
					* skel.get_bone_global_rest(bi)).basis.orthonormalized()
			print("[CombatTest/GEARSIM]   %-24s X=%s Y=%s Z=%s" % [bone_name,
					_v3(b.x), _v3(b.y), _v3(b.z)])


		for child in skel.get_children():
			if not (child is BoneAttachment3D):
				continue
			for piece in child.get_children():
				if not (piece is Node3D):
					continue
				found += 1
				var rel: Vector3 = (piece as Node3D).global_position - origin
				# World AABB relative to the character's feet, so "this piece
				# towers over the head" is a number and not an impression.
				var lo := INF
				var hi := -INF
				for mi in _gearsim_mesh_list(piece):
					var ab: AABB = mi.get_aabb()
					for c in 8:
						var w: Vector3 = mi.global_transform * ab.get_endpoint(c)
						lo = minf(lo, w.y - origin.y)
						hi = maxf(hi, w.y - origin.y)
				var extent := "y=%.2f..%.2f" % [lo, hi] if hi > lo else "y=n/a"
				print("[CombatTest/GEARSIM] %-9s %-12s %-24s at +(%5.2f,%5.2f,%5.2f) %s shown=%s" % [
						owner_name, piece.name,
						(child as BoneAttachment3D).bone_name,
						rel.x, rel.y, rel.z, extent, str(shown)])
	print("[CombatTest/GEARSIM] slot=%d pieces=%d" % [_gearsim_slot, found])
	_gearsim_meshes(_player, "")


func _gearsim_orbit() -> float:
	var v := OS.get_environment("LOB_GEAR_ORBIT")
	return float(v) if v.is_valid_float() else GEARSIM_ORBIT_DEFAULT


func _gearsim_height() -> float:
	var v := OS.get_environment("LOB_GEAR_HEIGHT")
	return float(v) if v.is_valid_float() else GEARSIM_HEIGHT_DEFAULT


func _v3(v: Vector3) -> String:
	return "(%5.2f,%5.2f,%5.2f)" % [v.x, v.y, v.z]


## Every MeshInstance3D under the player with its visibility, so "the body
## vanished" can be traced to the exact node instead of guessed at.
func _gearsim_meshes(node: Node, path: String) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		print("[CombatTest/GEARSIM] mesh %-42s visible=%s in_tree=%s" % [
				path + String(node.name), str(mi.visible),
				str(mi.is_visible_in_tree())])
	for child in node.get_children():
		_gearsim_meshes(child, path)


func _gearsim_mesh_list(node: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if node is MeshInstance3D:
		out.append(node as MeshInstance3D)
	for child in node.get_children():
		out.append_array(_gearsim_mesh_list(child))
	return out


func _gearsim_skeletons(node: Node) -> Array[Skeleton3D]:
	var out: Array[Skeleton3D] = []
	if node is Skeleton3D:
		out.append(node as Skeleton3D)
	for child in node.get_children():
		out.append_array(_gearsim_skeletons(child))
	return out


func _gearsim_owner(skel: Node) -> String:
	var n: Node = skel
	while n != null:
		var nm := String(n.name)
		if nm.ends_with("Character"):
			return nm.replace("Character", "")
		n = n.get_parent()
	return "?"


func _drive_animsim(delta: float) -> void:
	var once := func(key: String, t: float) -> bool:
		if _elapsed >= t and not _bowsim_flags.has(key):
			_bowsim_flags[key] = true
			return true
		return false
	var act := func(action: StringName, down: bool) -> void:
		var ev := InputEventAction.new()
		ev.action = action
		ev.pressed = down
		Input.parse_input_event(ev)

	if once.call("setup", 0.0):
		var start: Vector3 = _bobba.global_position + Vector3(3.5, 0.0, 0.0)
		var space: PhysicsDirectSpaceState3D = _player.get_world_3d().direct_space_state
		var query := PhysicsRayQueryParameters3D.create(
				start + Vector3(0, 60, 0), start + Vector3(0, -60, 0), 1)
		var hit: Dictionary = space.intersect_ray(query)
		start.y = (hit.position.y + 0.3) if hit.has("position") else _player.global_position.y
		_player.global_position = start
		_player.velocity = Vector3.ZERO
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		_add_key_light()
		_player._switch_character_class(_player.CharacterClass.PALADIN)
		Input.action_press(ANIMSIM_DIRS[0], 1.0)

	# Halfway: same battery as the archer.
	if once.call("archer", 24.0):
		_animsim_note("--- switching to ARCHER ---")
		_player._switch_character_class(_player.CharacterClass.ARCHER)

	# Keep the tester alive — we want hit-reactions landing mid-action for
	# 45 seconds, not a death/respawn that resets every flag under test.
	if _player.current_health < _player.max_health * 0.6:
		_player.current_health = _player.max_health

	# Circle around: a new heading every 2.5s so we stay near Bobba.
	var dir_idx: int = int(_elapsed / 2.5) % ANIMSIM_DIRS.size()
	if dir_idx != _animsim_dir_idx:
		Input.action_release(ANIMSIM_DIRS[_animsim_dir_idx])
		Input.action_press(ANIMSIM_DIRS[dir_idx], 1.0)
		_animsim_dir_idx = dir_idx

	# ---- injected guard failures --------------------------------------
	# (1) LOST RELEASE: the press event arrives, then the action state is
	# reset with NO release event — what a phone/controller produces on a
	# focus change, app pause, touch cancel or a trigger snapping back.
	if once.call("guard_lost_press", 9.6):
		act.call(&"block", true)
	if once.call("guard_lost_drop", 9.9):
		Input.action_release(&"block")
		_animsim_note("injected LOST RELEASE of block (state cleared, no event)")
	if once.call("guard_lost_check", 11.2):
		_bowsim_flags["guard_lost_ok"] = not _player.is_blocking
		_animsim_note("after lost release: is_blocking=%s (want false)" % str(_player.is_blocking))
		act.call(&"block", false)
	# (2) PARRY WHILE HOLDING GUARD: _do_parry drops is_blocking, but the
	# button is still down and only an EDGE would ever set it back.
	if once.call("guard_parry_press", 12.6):
		act.call(&"block", true)
	if once.call("guard_parry_fire", 13.0):
		act.call(&"parry", true)
		act.call(&"parry", false)
	if once.call("guard_parry_check", 14.4):
		_bowsim_flags["guard_parry_ok"] = _player.is_blocking
		_animsim_note("after parry recovery, button still held: is_blocking=%s (want true)" % str(_player.is_blocking))
		act.call(&"block", false)

	# Action battery on a 0.4s cadence.
	var step: int = int((_elapsed - 0.5) / 0.4)
	# The battery owns the block button too, so it stands down inside the
	# injected-guard-failure windows — otherwise its own block_off would
	# "heal" the injection and the measurement would be meaningless.
	var guard_test: bool = (_elapsed >= 9.5 and _elapsed <= 11.4) \
			or (_elapsed >= 12.5 and _elapsed <= 14.6)
	if step >= 0 and step > _animsim_step and not guard_test:
		_animsim_step = step
		match ANIMSIM_ACTIONS[step % ANIMSIM_ACTIONS.size()]:
			"attack":
				act.call(&"attack", true)
				act.call(&"attack", false)
			"block_on":
				act.call(&"block", true)
				_animsim_blocking = true
			"block_off":
				act.call(&"block", false)
				_animsim_blocking = false
			"parry":
				act.call(&"parry", true)
				act.call(&"parry", false)
			"dodge":
				act.call(&"dodge", true)
				act.call(&"dodge", false)
			"estus":
				act.call(&"estus", true)
				act.call(&"estus", false)
			"spell":
				act.call(&"spell_cast", true)
				act.call(&"spell_cast", false)
			"toggle":
				act.call(&"toggle_combat", true)
				act.call(&"toggle_combat", false)
			"jump":
				act.call(&"jump", true)
				act.call(&"jump", false)

	_animsim_detect(delta)


## Per-frame stall detection with a full diagnosis on the way in/out.
## Every clip that legitimately carries the character's weight. Matched on
## the whole leaf name, not a suffix: "WalkBack" and "BlockWalkBack" are
## real strides but do not END with "Walk", so a suffix test read every
## backpedal as a frozen body.
const ANIMSIM_LOCO_BASES: Array[String] = ["Walk", "Run", "Sprint",
		"StrafeLeft", "StrafeRight", "RunStrafeLeft", "RunStrafeRight",
		"WalkBack", "RunBack"]


func _animsim_is_locomotion(clip: String) -> bool:
	var leaf: String = clip.get_slice("/", 1) if clip.contains("/") else clip
	for base in ANIMSIM_LOCO_BASES:
		# Bare stride, guard-up twin, and the archer's aim-locomotion.
		if leaf == base or leaf == "Block" + base or leaf == "Aim" + base:
			return true
	# Aim strafes are named AimStrafeLeft/Right rather than Aim + a base.
	return leaf.begins_with("AimStrafe")


func _animsim_detect(delta: float) -> void:
	var ap: AnimationPlayer = _player._current_anim_player
	if ap == null:
		return
	var hspeed: float = Vector2(_player.velocity.x, _player.velocity.z).length()
	var moving: bool = _player.is_on_floor() and hspeed > 1.5
	var clip := String(ap.current_animation)
	var loco: bool = ap.is_playing() and _animsim_is_locomotion(clip)

	if moving and not loco:
		_animsim_stall += delta
		if _animsim_stall >= ANIMSIM_STALL_WARN and not _animsim_reported:
			_animsim_reported = true
			_animsim_stalls += 1
			if _animsim_stalls <= 10:
				_animsim_note("STALL t=%.1f dur=%.1fs clip=%s playing=%s | attack=%s sheath=%s trans=%s cast=%s roll=%s parry=%s drink=%s draw=%s hold=%s stun=%s block=%s cur=%s" % [
						_elapsed, _animsim_stall, clip, str(ap.is_playing()),
						str(_player.is_attacking), str(_player.is_sheathing),
						str(_player.is_transitioning), str(_player.is_casting),
						str(_player.is_rolling), str(_player.is_parrying),
						str(_player.is_drinking), str(_player.is_drawing_bow),
						str(_player.is_holding_bow), str(_player._is_stunned),
						str(_player.is_blocking), String(_player._current_anim)])
		if _animsim_stall >= ANIMSIM_STALL_HARD and not _animsim_hard_reported:
			_animsim_hard_reported = true
			_animsim_hard += 1
			_animsim_note("HARD FREEZE t=%.1f — body has been non-locomotive for %.1fs while moving" % [
					_elapsed, _animsim_stall])
		_animsim_max_stall = maxf(_animsim_max_stall, _animsim_stall)
	else:
		_animsim_stall = 0.0
		_animsim_reported = false
		_animsim_hard_reported = false

	_animsim_guard_detect(delta, clip)


## Guard-state detectors. is_blocking is the flag every mitigation reads
## and the guard animation follows, so it must track the real button:
##   phantom — guard held while the action is UP (stuck defending),
##   dropped — action DOWN but no guard (silently undefended),
##   anim    — a Block* clip on the body while not blocking at all.
func _animsim_guard_detect(delta: float, clip: String) -> void:
	var held: bool = Input.is_action_pressed(&"block")
	var alive: bool = not _player.is_dead and not _player.is_reviving

	if _player.is_blocking and not held:
		_animsim_guard_phantom += delta
		if _animsim_guard_phantom > 0.3 and not _animsim_guard_reported:
			_animsim_guard_reported = true
			_animsim_guard_stuck += 1
			_animsim_note("PHANTOM GUARD t=%.1f — is_blocking with the button UP (clip=%s parry=%s)" % [
					_elapsed, clip, str(_player.is_parrying)])
	else:
		_animsim_guard_phantom = 0.0
		_animsim_guard_reported = false

	if held and not _player.is_blocking and not _player.is_parrying and alive:
		_animsim_guard_dropped_t += delta
		if _animsim_guard_dropped_t > 0.8 and not _animsim_guard_drop_reported:
			_animsim_guard_drop_reported = true
			_animsim_guard_dropped += 1
			_animsim_note("DROPPED GUARD t=%.1f — button held but not blocking (clip=%s)" % [
					_elapsed, clip])
	else:
		_animsim_guard_dropped_t = 0.0
		_animsim_guard_drop_reported = false

	if not _player.is_blocking and not _player.is_parrying \
			and clip.contains("Block") and not clip.contains("BlockWalk") \
			and not clip.contains("BlockRun") and not clip.contains("BlockStrafe") \
			and not clip.contains("BlockSprint"):
		_animsim_guard_anim_t += delta
		if _animsim_guard_anim_t > 0.5 and not _animsim_guard_anim_reported:
			_animsim_guard_anim_reported = true
			_animsim_guard_anim += 1
			_animsim_note("STUCK GUARD ANIM t=%.1f — %s playing while not blocking" % [_elapsed, clip])
	else:
		_animsim_guard_anim_t = 0.0
		_animsim_guard_anim_reported = false


func _animsim_note(msg: String) -> void:
	print("[CombatTest] ANIMSIM %s" % msg)


func _animsim_report() -> void:
	var ap: AnimationPlayer = _player._current_anim_player
	print("[CombatTest] ANIMSIM final: clip=%s playing=%s attack=%s sheath=%s trans=%s cast=%s" % [
			String(ap.current_animation) if ap else "nil",
			str(ap.is_playing()) if ap else "nil",
			str(_player.is_attacking), str(_player.is_sheathing),
			str(_player.is_transitioning), str(_player.is_casting)])
	print("[CombatTest] ANIMSIM guard: phantom=%d dropped=%d stuck_anim=%d lost_release_ok=%s parry_hold_ok=%s" % [
			_animsim_guard_stuck, _animsim_guard_dropped, _animsim_guard_anim,
			str(_bowsim_flags.get("guard_lost_ok", false)),
			str(_bowsim_flags.get("guard_parry_ok", false))])
	var guard_ok: bool = _animsim_guard_stuck == 0 and _animsim_guard_dropped == 0 \
			and _animsim_guard_anim == 0 \
			and bool(_bowsim_flags.get("guard_lost_ok", false)) \
			and bool(_bowsim_flags.get("guard_parry_ok", false))
	print("[CombatTest] ANIMSIM summary: stalls=%d hard_freezes=%d max_stall=%.1fs guard_ok=%s verdict=%s" % [
			_animsim_stalls, _animsim_hard, _animsim_max_stall, str(guard_ok),
			"PASS" if _animsim_hard == 0 and _animsim_max_stall < ANIMSIM_STALL_WARN and guard_ok else "FAIL"])


## BLOCKSIM: guard-up locomotion simulation for BOTH classes. Holds the
## real `block` action (dispatched as an InputEventAction, the same path a
## mouse/R2 press takes) while driving real movement input, and measures
## what actually happens to the SKELETON — not just which clip is named:
##   knee travel  — summed rotation of the knee bone per second. A frozen
##                  stride reads ~0 no matter what clip is playing.
##   guard drift  — angle between the forearm pose while walking-blocking
##                  and while standing-blocking. Large = the guard dropped.
##   freeze       — moving on the ground with guard up but no clip running.
func _drive_blocksim(delta: float) -> void:
	var once := func(key: String, t: float) -> bool:
		if _elapsed >= t and not _bowsim_flags.has(key):
			_bowsim_flags[key] = true
			return true
		return false
	var block := func(down: bool) -> void:
		var ev := InputEventAction.new()
		ev.action = &"block"
		ev.pressed = down
		Input.parse_input_event(ev)
	var act_action := func(action: StringName) -> void:
		var ev := InputEventAction.new()
		ev.action = action
		ev.pressed = true
		Input.parse_input_event(ev)
		var ev2 := InputEventAction.new()
		ev2.action = action
		ev2.pressed = false
		Input.parse_input_event(ev2)
	var phase := func(name: String) -> void:
		_blocksim_phase = name
		_blocksim_prev_knee_valid = false
		_blocksim_prev_arm_valid = false
		_blocksim_phase_t = 0.0

	if once.call("setup", 0.0):
		var start := Vector3(120.0, 0.0, -140.0)
		var space: PhysicsDirectSpaceState3D = _player.get_world_3d().direct_space_state
		var query := PhysicsRayQueryParameters3D.create(
				start + Vector3(0, 60, 0), start + Vector3(0, -60, 0), 1)
		var hit: Dictionary = space.intersect_ray(query)
		start.y = (hit.position.y + 0.3) if hit.has("position") else _player.global_position.y
		_player.global_position = start
		_player.velocity = Vector3.ZERO
		_player._spawn_immunity_timer = 300.0
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		_add_key_light()
		_player._switch_character_class(_player.CharacterClass.PALADIN)

	# ---- Paladin, sword + shield ---------------------------------------
	if once.call("p_walk", 0.6):
		Input.action_press(&"move_forward", 1.0)
		phase.call("paladin-armed/walk")
	if once.call("p_blockwalk", 2.6):
		block.call(true)
		phase.call("paladin-armed/block-walk")
	if once.call("p_blockstand", 4.6):
		Input.action_release(&"move_forward")
		phase.call("paladin-armed/block-stand")
	if once.call("p_blockrun", 6.0):
		Input.action_press(&"move_forward", 1.0)
		Input.action_press(&"run")
		phase.call("paladin-armed/block-run")
	if once.call("p_blockstrafe", 7.6):
		Input.action_release(&"move_forward")
		Input.action_release(&"run")
		Input.action_press(&"move_right", 1.0)
		phase.call("paladin-armed/block-strafe")
	if once.call("p_end", 9.0):
		Input.action_release(&"move_right")
		block.call(false)
		phase.call("")
		_player._toggle_combat_mode()  # sheath -> unarmed guard

	# ---- Paladin, unarmed ----------------------------------------------
	if once.call("u_walk", 10.6):
		Input.action_press(&"move_forward", 1.0)
		phase.call("paladin-unarmed/walk")
	if once.call("u_blockwalk", 12.2):
		block.call(true)
		phase.call("paladin-unarmed/block-walk")
	if once.call("u_end", 14.0):
		Input.action_release(&"move_forward")
		block.call(false)
		phase.call("")
		_player._switch_character_class(_player.CharacterClass.ARCHER)

	# ---- Archer ---------------------------------------------------------
	if once.call("a_walk", 15.0):
		Input.action_press(&"move_forward", 1.0)
		phase.call("archer/walk")
	if once.call("a_blockwalk", 17.0):
		block.call(true)
		phase.call("archer/block-walk")
	if once.call("a_blockstand", 19.0):
		Input.action_release(&"move_forward")
		phase.call("archer/block-stand")
	if once.call("a_blockrun", 20.5):
		Input.action_press(&"move_forward", 1.0)
		Input.action_press(&"run")
		phase.call("archer/block-run")
	if once.call("a_end", 22.2):
		Input.action_release(&"move_forward")
		Input.action_release(&"run")
		block.call(false)
		phase.call("")

	# ---- defense battery: the guard must SURVIVE every interruption ----
	# Button held down the whole way; each verb steals the body for its
	# clip, and the guard has to come back on its own afterwards.
	if once.call("d_setup", 23.0):
		_player._switch_character_class(_player.CharacterClass.PALADIN)
		_player.current_health = _player.max_health
		_player.estus_charges = 3
		# The parry verb is PALADIN + ARMED only — the earlier phases left
		# him unarmed, which would have made that step a silent no-op.
		if _player.combat_mode != _player.CombatMode.ARMED:
			_player._toggle_combat_mode()
		block.call(true)
		Input.action_press(&"move_forward", 1.0)
		_blocksim_battery = true
	if once.call("d_attack", 24.2):
		_blocksim_mark("attack")
		act_action.call(&"attack")
	if once.call("d_dodge", 26.4):
		_blocksim_mark("dodge")
		act_action.call(&"dodge")
	if once.call("d_parry", 28.4):
		_blocksim_mark("parry")
		act_action.call(&"parry")
		_blocksim_flags["parry_mode"] = "armed" if _player.combat_mode == _player.CombatMode.ARMED else "unarmed"
	if once.call("d_parry_fired", 28.55):
		_blocksim_flags["parry_fired"] = _player.is_parrying
	if once.call("d_parry_speed", 29.6):
		var ap_chk: AnimationPlayer = _player._current_anim_player
		_blocksim_flags["parry_speed"] = ap_chk.get_playing_speed() if ap_chk else -1.0
		_blocksim_flags["parry_clip"] = String(ap_chk.current_animation) if ap_chk else "nil"
	if once.call("d_hit", 30.4):
		_blocksim_mark("hit")
		_player.take_hit(18.0, Vector3(0, 0, 2.0), true, null, true)
	if once.call("d_estus", 32.0):
		_blocksim_mark("estus")
		_player.current_health = _player.max_health * 0.5
		act_action.call(&"estus")
	if once.call("d_toggle", 34.0):
		_blocksim_mark("sheath")
		act_action.call(&"toggle_combat")
	if once.call("d_jump", 36.0):
		_blocksim_mark("jump")
		act_action.call(&"jump")
	# Rapid mashing: 8 press/release pairs — the guard must end UP,
	# matching the final press, with no state left flickering.
	for i in range(8):
		if once.call("d_mash%d" % i, 38.0 + 0.12 * i):
			block.call(i % 2 == 0)
	if once.call("d_mash_end", 39.1):
		block.call(true)
	if once.call("d_mash_check", 39.9):
		_blocksim_flags["mash_guard"] = _player.is_blocking
		_blocksim_flags["mash_clip"] = String(_player._current_anim_player.current_animation) \
				if _player._current_anim_player else "nil"
	# Release: the guard must disappear promptly.
	if once.call("d_release", 40.4):
		block.call(false)
	if once.call("d_release_check", 41.2):
		var ap_rel: AnimationPlayer = _player._current_anim_player
		var clip_rel := String(ap_rel.current_animation) if ap_rel else ""
		_blocksim_flags["release_clear"] = not _player.is_blocking and not clip_rel.contains("Block")
		_blocksim_flags["release_clip"] = clip_rel
		Input.action_release(&"move_forward")
		_blocksim_battery = false

	_blocksim_sample(delta)
	_blocksim_battery_detect(delta)


## While the guard button is HELD and no action owns the body, a Block*
## clip must be playing. Measures the longest such gap per verb — "the
## guard did not come back" — and flags any that never recovered.
func _blocksim_battery_detect(delta: float) -> void:
	if not _blocksim_battery:
		return
	if not Input.is_action_pressed(&"block"):
		return
	var ap: AnimationPlayer = _player._current_anim_player
	if ap == null:
		return
	var busy: bool = _player.is_attacking or _player.is_rolling or _player.is_parrying \
			or _player.is_drinking or _player.is_casting or _player.is_sheathing \
			or _player.is_transitioning or not _player.is_on_floor()
	var guard_up: bool = String(ap.current_animation).contains("Block") and _player.is_blocking
	if busy or guard_up:
		if _blocksim_gap > _blocksim_worst_gap:
			_blocksim_worst_gap = _blocksim_gap
			_blocksim_worst_verb = _blocksim_gap_verb
		_blocksim_gap = 0.0
		return
	if _blocksim_gap == 0.0:
		_blocksim_gap_verb = _blocksim_verb
	_blocksim_gap += delta
	if _blocksim_gap > 1.5 and not _blocksim_flags.has("lost_" + _blocksim_verb):
		_blocksim_flags["lost_" + _blocksim_verb] = true
		_blocksim_lost += 1
		print("[CombatTest] BLOCKSIM GUARD LOST after '%s' t=%.1f — %.1fs with the button held and no guard (clip=%s blocking=%s)" % [
				_blocksim_verb, _elapsed, _blocksim_gap,
				String(ap.current_animation), str(_player.is_blocking)])


func _blocksim_mark(verb: String) -> void:
	_blocksim_verb = verb


## Per-frame measurement of the phase in progress.
func _blocksim_sample(delta: float) -> void:
	if _blocksim_phase == "":
		return
	var skel: Skeleton3D = _blocksim_skeleton()
	if skel == null:
		return
	var knee: int = skel.find_bone("mixamorig_LeftLeg")
	var arm: int = skel.find_bone("mixamorig_LeftForeArm")
	if knee < 0 or arm < 0:
		return

	# Ignore the first moments of a phase: the 0.25s cross-blend into the
	# guard is real motion, but it is a TRANSITION, not the steady state
	# this test is about.
	_blocksim_phase_t += delta
	if _blocksim_phase_t < 0.6:
		_blocksim_prev_arm_valid = false
		_blocksim_prev_knee_valid = false
		return

	var stat: Dictionary = _blocksim_stats.get(_blocksim_phase, {
		"time": 0.0, "knee_deg": 0.0, "speed": 0.0, "frames": 0,
		"freeze": 0, "anim": "", "arm": Quaternion.IDENTITY,
		"arm_deg": 0.0, "speed_scale": 1.0,
	})
	# Guard steadiness: a held guard barely moves. A looping block MOTION
	# (raise-block-lower) shows up here as a huge arm travel rate — that
	# is the "defense animation is bugged" pumping.
	var arm_q: Quaternion = skel.get_bone_pose_rotation(arm)
	if _blocksim_prev_arm_valid:
		stat["arm_deg"] = float(stat.get("arm_deg", 0.0)) \
				+ rad_to_deg(_blocksim_prev_arm.angle_to(arm_q))
	_blocksim_prev_arm = arm_q
	_blocksim_prev_arm_valid = true
	var ap_speed: AnimationPlayer = _player._current_anim_player
	if ap_speed != null:
		stat["speed_scale"] = ap_speed.get_playing_speed()

	var knee_q: Quaternion = skel.get_bone_pose_rotation(knee)
	if _blocksim_prev_knee_valid:
		stat["knee_deg"] = float(stat["knee_deg"]) \
				+ rad_to_deg(_blocksim_prev_knee.angle_to(knee_q))
	_blocksim_prev_knee = knee_q
	_blocksim_prev_knee_valid = true

	var hspeed: float = Vector2(_player.velocity.x, _player.velocity.z).length()
	stat["time"] = float(stat["time"]) + delta
	stat["frames"] = int(stat["frames"]) + 1
	stat["speed"] = float(stat["speed"]) + hspeed
	stat["arm"] = skel.get_bone_pose_rotation(arm)
	stat["blocking"] = _player.is_blocking

	var ap: AnimationPlayer = _player._current_anim_player
	if ap != null:
		stat["anim"] = String(ap.current_animation)
		# Guard up and actually moving: SOME clip has to be running.
		if _blocksim_phase.contains("block-") and not _blocksim_phase.ends_with("stand") \
				and _player.is_on_floor() and hspeed > 1.5 and not ap.is_playing():
			stat["freeze"] = int(stat["freeze"]) + 1
			_blocksim_freeze += 1
	_blocksim_stats[_blocksim_phase] = stat


## The skeleton of whichever character model is currently shown.
func _blocksim_skeleton() -> Skeleton3D:
	for model in [_player._armed_character, _player._unarmed_character,
			_player._archer_character]:
		if model != null and is_instance_valid(model) and model.visible:
			return _player._find_skeleton(model)
	return null


## Compares every guard phase against its plain-locomotion baseline.
func _blocksim_report() -> void:
	print("[CombatTest] BLOCKSIM per-phase measurements:")
	for phase_name in _blocksim_stats:
		var s: Dictionary = _blocksim_stats[phase_name]
		var t: float = maxf(float(s["time"]), 0.001)
		print("[CombatTest]   %-26s knee=%6.1f deg/s guard_arm=%6.1f deg/s playspeed=%.2f speed=%4.1f blocking=%s anim=%s freeze=%d" % [
				phase_name, float(s["knee_deg"]) / t, float(s.get("arm_deg", 0.0)) / t,
				float(s.get("speed_scale", 1.0)),
				float(s["speed"]) / maxf(float(s["frames"]), 1.0),
				str(s.get("blocking", false)), s["anim"], int(s["freeze"])])

	var verdict := true
	for pair in [["paladin-armed/walk", "paladin-armed/block-walk", "paladin-armed/block-stand"],
			["paladin-unarmed/walk", "paladin-unarmed/block-walk", ""],
			["archer/walk", "archer/block-walk", "archer/block-stand"]]:
		if not _blocksim_stats.has(pair[0]) or not _blocksim_stats.has(pair[1]):
			print("[CombatTest] BLOCKSIM %s: MISSING SAMPLES" % pair[1])
			verdict = false
			continue
		var base_rate: float = _blocksim_knee_rate(pair[0])
		var block_rate: float = _blocksim_knee_rate(pair[1])
		var ratio: float = (block_rate / base_rate) if base_rate > 1.0 else -1.0
		var guard_drift: float = -1.0
		if pair[2] != "" and _blocksim_stats.has(pair[2]):
			var a: Quaternion = _blocksim_stats[pair[1]]["arm"]
			var b: Quaternion = _blocksim_stats[pair[2]]["arm"]
			guard_drift = rad_to_deg(a.angle_to(b))
		var ok: bool = ratio >= 0.5 and (guard_drift < 0.0 or guard_drift <= 35.0)
		verdict = verdict and ok
		print("[CombatTest] BLOCKSIM %-22s stride_kept=%.2f (walk %.1f -> guard %.1f deg/s) guard_drift=%.1f deg -> %s" % [
				pair[1], ratio, base_rate, block_rate, guard_drift, "OK" if ok else "FAIL"])
	if _blocksim_worst_gap < _blocksim_gap:
		_blocksim_worst_gap = _blocksim_gap
		_blocksim_worst_verb = _blocksim_gap_verb
	var battery_ok: bool = _blocksim_lost == 0 and _blocksim_worst_gap < 1.5 \
			and bool(_blocksim_flags.get("parry_fired", false)) \
			and bool(_blocksim_flags.get("mash_guard", false)) \
			and bool(_blocksim_flags.get("release_clear", false)) \
			and absf(float(_blocksim_flags.get("parry_speed", -1.0)) - 1.0) < 0.01
	print("[CombatTest] BLOCKSIM battery: guard_lost=%d worst_gap=%.2fs after '%s' | parry_fired=%s (%s) parry_speed=%.2f (clip %s) mash_guard=%s (clip %s) release_clear=%s (clip %s)" % [
			_blocksim_lost, _blocksim_worst_gap, _blocksim_worst_verb,
			str(_blocksim_flags.get("parry_fired", false)),
			str(_blocksim_flags.get("parry_mode", "?")),
			float(_blocksim_flags.get("parry_speed", -1.0)),
			str(_blocksim_flags.get("parry_clip", "?")),
			str(_blocksim_flags.get("mash_guard", false)),
			str(_blocksim_flags.get("mash_clip", "?")),
			str(_blocksim_flags.get("release_clear", false)),
			str(_blocksim_flags.get("release_clip", "?"))])
	print("[CombatTest] BLOCKSIM summary: freeze_frames=%d battery_ok=%s verdict=%s" % [
			_blocksim_freeze, str(battery_ok),
			"PASS" if verdict and battery_ok else "FAIL"])


func _blocksim_knee_rate(phase: String) -> float:
	var s: Dictionary = _blocksim_stats[phase]
	return float(s["knee_deg"]) / maxf(float(s["time"]), 0.001)


## BOWSIM: archer bow/locomotion state-machine simulation. Drives REAL
## movement input plus the actual draw/release methods through every
## combination — walk, standing shot, aim-walking shot, quick-cancel,
## airborne draw attempt, jump-cancel mid-draw — while per-frame detectors
## count anomalies:
##   freeze_frames — moving on the ground but no locomotion clip playing
##                   (the "walking stops" bug),
##   noaim_shots   — an arrow released without the Attack clip visibly
##                   playing its loose (the "no aiming movement" bug).
func _drive_bowsim(_delta: float) -> void:
	var once := func(key: String, t: float) -> bool:
		if _elapsed >= t and not _bowsim_flags.has(key):
			_bowsim_flags[key] = true
			return true
		return false

	if once.call("setup", 0.0):
		var start := Vector3(120.0, 0.0, -140.0)
		start.y = _player.global_position.y
		_player.global_position = start
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		_add_key_light()
		_player._spawn_immunity_timer = 120.0

	# ---- scripted timeline --------------------------------------------
	if once.call("walk_on", 0.2):
		Input.action_press(&"move_forward")
		_bowsim_flags["input_held"] = true
	if once.call("walk_off", 2.0):
		Input.action_release(&"move_forward")
		_bowsim_flags["input_held"] = false
	if once.call("draw1", 2.3):
		_player._start_bow_draw()
	if once.call("shot1", 3.3):
		_bowsim_release("standing")
	if once.call("walk2_on", 4.0):
		Input.action_press(&"move_forward")
		_bowsim_flags["input_held"] = true
	if once.call("draw2", 4.5):
		_player._start_bow_draw()
	if once.call("shot2", 5.5):
		_bowsim_release("aim-walking")
	if once.call("draw3", 6.3):
		_player._start_bow_draw()
	if once.call("shot3", 7.3):
		_bowsim_release("aim-walking-2")
	if once.call("walk2_off", 8.0):
		Input.action_release(&"move_forward")
		_bowsim_flags["input_held"] = false
	if once.call("draw4", 8.2):
		_player._start_bow_draw()
	if once.call("cancel4", 8.35):
		_player._release_bow()  # early release: cancel path, no shot
	if once.call("draw5", 8.7):
		_player._start_bow_draw()
	if once.call("shot5", 9.7):
		_bowsim_release("standing-2")
	if once.call("jump1", 10.3):
		Input.action_press(&"jump")
	if once.call("jump1_off", 10.45):
		Input.action_release(&"jump")
	if once.call("airdraw", 10.55):
		if not _player.is_on_floor():
			_player._start_bow_draw()
			_bowsim_flags["airdraw_blocked"] = not _player.is_drawing_bow
			print("[CombatTest] BOWSIM: airborne draw attempt -> drawing=%s" % str(_player.is_drawing_bow))
		else:
			_bowsim_flags["airdraw_blocked"] = true  # landed too fast to test
	if once.call("draw6", 11.4):
		_player._start_bow_draw()
	if once.call("jump2", 11.7):
		Input.action_press(&"jump")
	if once.call("jump2_off", 11.85):
		Input.action_release(&"jump")
	if once.call("aircheck", 12.4):
		_bowsim_flags["aircancel_ok"] = not _player.is_drawing_bow and not _player.is_holding_bow
		print("[CombatTest] BOWSIM: after jump mid-draw -> drawing=%s holding=%s" % [
				str(_player.is_drawing_bow), str(_player.is_holding_bow)])

	# ---- per-frame detectors ------------------------------------------
	var ap: AnimationPlayer = _player._archer_anim_player
	if ap == null:
		return
	var anim := String(ap.current_animation)
	var hspeed := Vector2(_player.velocity.x, _player.velocity.z).length()
	if _player.is_on_floor() and hspeed > 2.5 \
			and bool(_bowsim_flags.get("input_held", false)):
		# Locomotion counts only if the clip is actually RUNNING — a paused
		# Walk while moving is precisely the frozen-legs bug.
		var loco: bool = anim in ["archer/Walk", "archer/Run", "archer/StrafeLeft", "archer/StrafeRight"] \
				and ap.is_playing()
		var aim_burst: bool = anim == "archer/Attack" \
				and (_player.is_attacking or _player.is_drawing_bow or _player.is_holding_bow)
		if not loco and not aim_burst:
			_bowsim_freeze += 1
			if _bowsim_freeze <= 5:
				print("[CombatTest] BOWSIM FREEZE t=%.2f anim=%s speed=%.1f attacking=%s draw=%s hold=%s" % [
						_elapsed, anim, hspeed, str(_player.is_attacking),
						str(_player.is_drawing_bow), str(_player.is_holding_bow)])


## Release the bow expecting a SHOT: verifies the loose animation is
## actually playing right after the arrow leaves.
func _bowsim_release(label: String) -> void:
	var was_ready: bool = _player.is_holding_bow
	_player._release_bow()
	_bowsim_flags["shots"] = int(_bowsim_flags.get("shots", 0)) + (1 if was_ready else 0)
	if was_ready:
		var ap: AnimationPlayer = _player._archer_anim_player
		var ok: bool = ap != null and ap.current_animation == "archer/Attack" and ap.is_playing()
		if not ok:
			_bowsim_noaim += 1
			print("[CombatTest] BOWSIM NO-AIM shot (%s): anim=%s playing=%s" % [
					label, String(ap.current_animation) if ap else "nil", str(ap.is_playing()) if ap else "nil"])
		else:
			print("[CombatTest] BOWSIM shot ok (%s)" % label)


## DRAGON: flight-animation observation. Pins the dragon's patrol to a short
## leg near a fixed viewpoint so it sweeps past the camera repeatedly, then
## tracks it every frame. Frames land in /tmp/combat_test for review of the
## wing/neck/tail/head motion.
func _drive_dragon(_delta: float) -> void:
	var dragon: Node3D = _find_in_group("dragon") as Node3D
	if dragon == null:
		return
	var cam_pivot: Node3D = _player.get_node_or_null("CameraPivot") as Node3D
	if cam_pivot == null:
		return
	const VIEW := Vector3(0.0, 0.0, 130.0)
	if not _scripted_test_started:
		_scripted_test_started = true
		_player._spawn_immunity_timer = 120.0
		var bobba := _find_in_group("bobba")
		if bobba:
			bobba.global_position = Vector3(180.0, bobba.global_position.y, 180.0)
		var pp := VIEW
		pp.y = _player.global_position.y
		_player.global_position = pp
		_player.velocity = Vector3.ZERO
		# The paladin model otherwise fills the frame when the camera pitches
		# up to track the dragon overhead — this is a dragon shoot, hide the
		# mesh only (hiding the whole player node takes the camera with it).
		if _player._character_model:
			_player._character_model.visible = false
		# Lift the camera pivot above the shoulder-high grass — the shots
		# are otherwise fenced in by foreground blades.
		cam_pivot.position.y = 7.0
		# Short patrol leg centred in front of the viewpoint: the dragon
		# crosses the frame, turns around, and crosses back.
		dragon.patrol_center = Vector3(0.0, 0.0, 10.0)
		dragon.patrol_radius = 120.0
		dragon.position = Vector3(-100.0, dragon.patrol_height, 10.0)
	# Track the dragon.
	var to_dragon: Vector3 = dragon.global_position - _player.global_position
	var flat := Vector2(to_dragon.x, to_dragon.z).length()
	cam_pivot.rotation.y = atan2(-to_dragon.x, -to_dragon.z)
	cam_pivot.rotation.x = atan2(to_dragon.y - 1.5, flat)
	if int(_elapsed * 4.0) != int((_elapsed - _delta) * 4.0) and int(_elapsed * 4.0) % 4 == 0:
		print("[CombatTest] DRAGON t=%.1f dragon=%s player=%s pivot=(%.1f°,%.1f°)" % [
				_elapsed, str(dragon.global_position.snapped(Vector3.ONE)),
				str(_player.global_position.snapped(Vector3.ONE)),
				rad_to_deg(cam_pivot.rotation.x), rad_to_deg(cam_pivot.rotation.y)])


## ARROW: fire-arrow showcase under the rainy-night lighting. Hangs one
## frozen arrow in front of the camera for model inspection, then launches
## a volley downrange so the ground fires (flames/embers/smoke/scorch/light)
## are visible burning in the grass. Bobba is parked near the impact zone
## so his fire-avoidance keeps working against the new FireFX nodes.
func _drive_arrow(_delta: float) -> void:
	if _scripted_test_started:
		return
	_scripted_test_started = true
	_run_arrow_test()


func _run_arrow_test() -> void:
	const CENTER := Vector3(120.0, 0.0, -140.0)
	var pp := CENTER
	pp.y = _player.global_position.y
	_player.global_position = pp
	_player._spawn_immunity_timer = 60.0
	var bp := CENTER + Vector3(3.0, 0.0, 14.0)
	bp.y = _bobba.global_position.y
	_bobba.global_position = bp
	var cam_pivot: Node3D = _player.get_node_or_null("CameraPivot") as Node3D
	if cam_pivot:
		cam_pivot.rotation.y = PI  # look +Z, downrange
		cam_pivot.rotation.x = deg_to_rad(-3.0)
	await get_tree().create_timer(0.4).timeout

	var arrow_scene: PackedScene = load("res://player/arrow.tscn")

	# Static arrow floating in front of the camera — model close-up.
	var display = arrow_scene.instantiate()
	display.shooter = _player
	get_tree().current_scene.add_child(display)
	display.global_position = pp + Vector3(-0.7, 1.6, 2.2)
	display.freeze = true
	display.rotation_degrees = Vector3(0, 115, 0)
	# Inspection light — the wooden shaft is invisible in the rainy night.
	var inspect := OmniLight3D.new()
	inspect.light_color = Color(0.9, 0.9, 1.0)
	inspect.light_energy = 3.0
	inspect.omni_range = 3.0
	inspect.position = Vector3(0.5, 0.8, 0.5)
	display.add_child(inspect)
	print("[CombatTest/ARROW] display arrow spawned")

	# Volley: three arrows arcing downrange into the grass.
	for i in range(3):
		var arrow = arrow_scene.instantiate()
		arrow.shooter = _player
		get_tree().current_scene.add_child(arrow)
		arrow.global_position = pp + Vector3(0, 1.6, 0)
		var target := pp + Vector3(-2.0 + 2.0 * i, 0.0, 9.0 + 3.0 * i)
		var dir: Vector3 = (target - arrow.global_position).normalized()
		arrow.launch(dir + Vector3(0, 0.12, 0))
		print("[CombatTest/ARROW] volley arrow %d launched" % i)
		await get_tree().create_timer(1.2).timeout
	# Let the fires burn on camera; _process finishes the scenario at 14s.


## Hack-and-slash combo verification.
## A: mash attack — the paladin should chain SwordSlash → Attack1 → Attack2
##    (combo steps 0→1→2) and land three separate hits on a pinned Bobba.
## B: stand in range — Bobba should chain swipe → punch → jump slam
##    (his combo steps 0→1→2) before backing into the punish cooldown.
func _drive_combo(_delta: float) -> void:
	if _scripted_test_started:
		return
	_scripted_test_started = true
	_run_combo_test()


func _run_combo_test() -> void:
	const CENTER := Vector3(120.0, 0.0, -140.0)
	var pp := CENTER
	pp.y = _player.global_position.y
	_player.global_position = pp
	var bp := CENTER + Vector3(0.0, 0.0, 2.2)
	bp.y = _bobba.global_position.y
	_bobba.global_position = bp
	var cam_pivot: Node3D = _player.get_node_or_null("CameraPivot") as Node3D
	if cam_pivot:
		cam_pivot.rotation.y = PI  # face +Z, toward Bobba
	_player._spawn_immunity_timer = 60.0  # Bobba's swings can't pollute part A
	# No opportunistic blocking — part A measures raw chain damage.
	_bobba.is_blocking = false
	_bobba._block_check_cooldown = 999.0
	await get_tree().create_timer(0.5).timeout

	# --- A: THREE FAST CLICKS (0.18s apart) must bank and play the whole
	# 3-hit chain. 6s watch window: the finisher plays at 0.95 speed. ---
	var bhp0: float = float(_bobba.health)
	var hits: int = 0
	var max_step: int = -1
	var prev_bhp: float = bhp0
	var clicks_left: int = 3
	var click_timer: float = 0.0
	var t: float = 0.0
	while t < 6.0:
		await get_tree().process_frame
		var dt: float = get_process_delta_time()
		t += dt
		click_timer += dt
		if clicks_left > 0 and click_timer >= 0.18:
			click_timer = 0.0
			clicks_left -= 1
			_player._do_attack()
		max_step = maxi(max_step, int(_player._combo_step))
		# Pin Bobba so knockback can't carry him out of the later swings.
		_bobba.global_position = bp
		_bobba.velocity = Vector3.ZERO
		var cur_bhp: float = float(_bobba.health)
		if cur_bhp < prev_bhp - 0.5:
			hits += 1
			print("[CombatTest/COMBO] A hit %d: %.0f dmg (combo step %d)" % [
				hits, prev_bhp - cur_bhp, int(_player._combo_step)])
		prev_bhp = cur_bhp
	var dealt: float = bhp0 - float(_bobba.health)
	print("[CombatTest/COMBO] A chain: %d hits, %.0f dmg, max_step=%d (expect 3 hits, step 2)" % [
		hits, dealt, max_step])

	# --- A2: SLOW clicks (0.9s apart) must NOT chain — each is its own
	# opener swing, combo step stays 0. ---
	await get_tree().create_timer(1.0).timeout
	var slow_max_step: int = -1
	var slow_clicks_left: int = 3
	click_timer = 0.9  # click immediately, then every 0.9s
	t = 0.0
	while t < 4.0:
		await get_tree().process_frame
		var dt2: float = get_process_delta_time()
		t += dt2
		click_timer += dt2
		if slow_clicks_left > 0 and click_timer >= 0.9:
			click_timer = 0.0
			slow_clicks_left -= 1
			_player._do_attack()
		slow_max_step = maxi(slow_max_step, int(_player._combo_step))
		_bobba.global_position = bp
		_bobba.velocity = Vector3.ZERO
	print("[CombatTest/COMBO] A2 slow clicks: max_step=%d (expect 0 — no chain)" % slow_max_step)

	# --- B: Bobba combo chain. Stand in range, immune, and watch his steps. ---
	await get_tree().create_timer(1.0).timeout
	_bobba.attack_cooldown = 0.0
	var bobba_max_step: int = -1
	var anims_seen: Dictionary = {}
	t = 0.0
	while t < 8.0:
		await get_tree().process_frame
		t += get_process_delta_time()
		# Keep the player parked inside chain range.
		_player.global_position = pp
		_player.velocity = Vector3.ZERO
		if _bobba.state == 2:  # Proto.BobbaState.ATTACKING
			bobba_max_step = maxi(bobba_max_step, int(_bobba._combo_step))
			anims_seen[String(_bobba._current_anim)] = true
	print("[CombatTest/COMBO] B bobba chain: max_step=%d anims=%s" % [
		bobba_max_step, str(anims_seen.keys())])

	var a_ok: bool = hits >= 3 and max_step >= 2
	var a2_ok: bool = slow_max_step == 0
	var b_ok: bool = bobba_max_step >= 2
	print("[CombatTest/COMBO] RESULT player_chain=%s slow_no_chain=%s bobba_chain=%s" % [
		str(a_ok), str(a2_ok), str(b_ok)])
	_finish("COMBO_DONE")


## Backstab verification: the same sword swing deals 2× from Bobba's rear
## cone and 1× from the front. Bobba is pinned (position + facing reset
## every frame while we swing) so the geometry stays controlled.
func _drive_backstab(_delta: float) -> void:
	if _scripted_test_started:
		return
	_scripted_test_started = true
	_run_backstab_test()


## Holds Bobba at `pos` facing +Z while one player swing resolves, then
## returns how much HP Bobba lost to it.
func _swing_and_measure(bobba_pos: Vector3) -> float:
	var bhp0: float = float(_bobba.health)
	_player._do_attack()
	for i in range(90):  # ~1.5s at 60fps, pinning Bobba each frame
		_bobba.global_position = bobba_pos
		if "_model" in _bobba and _bobba._model:
			_bobba._model.rotation.y = 0.0  # forward = +Z
		_bobba.velocity = Vector3.ZERO
		await get_tree().process_frame
	return bhp0 - float(_bobba.health)


func _run_backstab_test() -> void:
	const CENTER := Vector3(120.0, 0.0, -140.0)
	var bobba_pos := CENTER
	bobba_pos.y = _bobba.global_position.y
	_bobba.global_position = bobba_pos
	await get_tree().create_timer(0.4).timeout
	bobba_pos.y = _bobba.global_position.y
	_player._spawn_immunity_timer = 30.0

	# --- A: attack from BEHIND (Bobba faces +Z; stand on -Z side). ---
	# Camera-yaw convention: to face direction (dx,dz), yaw = atan2(-dx,-dz).
	var pp := CENTER + Vector3(0.0, 0.0, -1.7)
	pp.y = _player.global_position.y
	_player.global_position = pp
	var cam_pivot: Node3D = _player.get_node_or_null("CameraPivot") as Node3D
	if cam_pivot:
		cam_pivot.rotation.y = PI  # face +Z (toward Bobba)
	await get_tree().create_timer(0.35).timeout  # let the model finish turning
	var back_dmg: float = await _swing_and_measure(bobba_pos)
	print("[CombatTest/BACKSTAB] A from behind: dealt %.0f (expect ~200)" % back_dmg)

	await get_tree().create_timer(0.6).timeout

	# --- B: attack from the FRONT (+Z side, facing -Z back at Bobba). ---
	pp = CENTER + Vector3(0.0, 0.0, 1.7)
	pp.y = _player.global_position.y
	_player.global_position = pp
	if cam_pivot:
		cam_pivot.rotation.y = 0.0  # face -Z (toward Bobba)
	await get_tree().create_timer(0.35).timeout  # let the model finish turning
	var front_dmg: float = await _swing_and_measure(bobba_pos)
	print("[CombatTest/BACKSTAB] B from front: dealt %.0f (expect ~100)" % front_dmg)

	var a_ok: bool = back_dmg >= 150.0
	var b_ok: bool = front_dmg > 1.0 and front_dmg < 150.0
	print("[CombatTest/BACKSTAB] RESULT backstab_crit=%s front_normal=%s" % [str(a_ok), str(b_ok)])
	_finish("BACKSTAB_DONE")


## Estus verification:
##   A) drinking heals 45% of max HP and consumes a charge;
##   B) an unblocked hit mid-drink cancels the heal but the charge stays
##      spent (healing under pressure is a gamble);
##   C) charges can run out.
func _drive_estus(_delta: float) -> void:
	if _scripted_test_started:
		return
	_scripted_test_started = true
	_run_estus_test()


func _run_estus_test() -> void:
	const CENTER := Vector3(120.0, 0.0, -140.0)
	# Park Bobba far away so all damage here is scripted.
	var bp := CENTER + Vector3(50.0, 0.0, 0.0)
	bp.y = _bobba.global_position.y
	_bobba.global_position = bp
	var pp := CENTER
	pp.y = _player.global_position.y
	_player.global_position = pp
	await get_tree().create_timer(0.4).timeout

	var kb := Vector3(0.0, 0.0, 3.0)
	_player._spawn_immunity_timer = 0.0

	# --- A: full drink heals and spends a charge. ---
	_player.take_damage(100.0)
	var hp0: float = float(_player.current_health)
	var charges0: int = int(_player.estus_charges)
	_player._try_estus()
	await get_tree().create_timer(1.4).timeout  # drink takes 1.1s
	var hp1: float = float(_player.current_health)
	var charges1: int = int(_player.estus_charges)
	print("[CombatTest/ESTUS] A drink: hp %.0f -> %.0f charges %d -> %d (expect +%.0f, -1 charge)" % [
		hp0, hp1, charges0, charges1, float(_player.max_health) * 0.45])

	# --- B: interrupted drink wastes the charge. ---
	_player._spawn_immunity_timer = 0.0
	_player.take_damage(50.0)
	var hp2: float = float(_player.current_health)
	var charges2: int = int(_player.estus_charges)
	_player._try_estus()
	await get_tree().create_timer(0.3).timeout  # mid-channel
	_player._spawn_immunity_timer = 0.0
	_player.take_hit(10.0, kb, false, _bobba, false)
	await get_tree().create_timer(1.2).timeout  # would have finished by now
	var hp3: float = float(_player.current_health)
	var charges3: int = int(_player.estus_charges)
	print("[CombatTest/ESTUS] B interrupt: hp %.0f -> %.0f charges %d -> %d (expect -10 hp, -1 charge, NO heal)" % [
		hp2, hp3, charges2, charges3])

	var heal_amount: float = hp1 - hp0
	var a_ok: bool = heal_amount >= float(_player.max_health) * 0.40 and charges1 == charges0 - 1
	var b_ok: bool = hp3 <= hp2 - 5.0 and charges3 == charges2 - 1
	print("[CombatTest/ESTUS] RESULT heals=%s interrupt_wastes_charge=%s" % [str(a_ok), str(b_ok)])
	_finish("ESTUS_DONE")


## SOULS — the integration duel. Paladin fights Bobba to the death using
## the full souls kit against Bobba's REAL attacks (no scripted take_hit),
## playing the genre's rhythm instead of trading blows:
##   • bait: hold just inside Bobba's 2 m attack trigger with the sword
##     DOWN — never swing into a ready Bobba (a swing would gate the parry);
##   • parry: pressed on reaction as Bobba's swing enters its damage
##     window, so the punch lands inside the deflect frames;
##   • riposte: the 3× crit punish while Bobba is parry-staggered;
##   • estus: drinks while Bobba is staggered/far, kiting backward —
##     whiffed parries are punished with full damage and healed back here.
## Outcome line reports how often each verb actually fired.
const SOULS_BAIT_DIST: float = 1.8  # inside Bobba's 2.0 m attack trigger

func _drive_souls(delta: float) -> void:
	# ── Kit-usage stat tracking (frame deltas) ──
	var riposte_now: bool = bool(_bobba.is_riposte_ready()) if _bobba.has_method("is_riposte_ready") else false
	if riposte_now and not _souls_prev_riposte:
		_souls_parries += 1
	_souls_prev_riposte = riposte_now

	var bhp: float = float(_bobba.health)
	if _souls_prev_bobba_hp >= 0.0:
		var dealt: float = _souls_prev_bobba_hp - bhp
		if dealt >= 250.0:
			_souls_ripostes += 1
		elif dealt >= 150.0:
			_souls_backstabs += 1
	_souls_prev_bobba_hp = bhp

	if _souls_estus_start < 0 and "estus_charges" in _player:
		_souls_estus_start = int(_player.estus_charges)

	# ── Geometry: always face Bobba (the lock-on equivalent) ──
	var to_bobba: Vector3 = _bobba.global_position - _player.global_position
	to_bobba.y = 0.0
	var dist: float = to_bobba.length()
	if dist < 0.001:
		return
	var dir: Vector3 = to_bobba / dist
	var cam_pivot: Node3D = _player.get_node_or_null("CameraPivot") as Node3D
	if cam_pivot:
		cam_pivot.rotation.y = atan2(-dir.x, -dir.z)

	# ── Drinking: kite backward until the swig finishes ──
	if _player.is_drinking:
		_player.global_position += -dir * 5.5 * delta
		return

	var bobba_attacking: bool = _bobba.state == 2  # Proto.BobbaState.ATTACKING
	var bobba_stunned: bool = _bobba.state == 4    # Proto.BobbaState.STUNNED

	# ── Riposte: highest-priority punish while the window is open ──
	if riposte_now:
		if dist > MELEE_HOLD_DIST + 0.2:
			var rstep: float = minf(8.0 * delta, dist - MELEE_HOLD_DIST)
			_player.global_position += dir * rstep
		_try_attack()
		return

	# ── Defense: parry the incoming swing on reaction, holding ground ──
	if bobba_attacking:
		if not _player.is_parrying and not _souls_parried_this_attack:
			# Press off predicted CONTACT, like a player reacting to the
			# incoming fist — not off the windup. At the 1.8 m bait
			# distance the fist arc reaches us a measured ~0.5s after the
			# damage window arms (it needs full arm extension), so aim the
			# press ~0.15s before that moment, mid-deflect-frames.
			const CONTACT_AFTER_WINDOW: float = 0.50
			var t_to_contact: float = _time_to_bobba_hit_window() + CONTACT_AFTER_WINDOW
			if t_to_contact >= 0.10 and t_to_contact <= 0.20:
				_player._try_parry()
				_souls_parried_this_attack = _player.is_parrying
				print("[CombatTest/SOULS] parry pressed (t_to_contact=%.3f, accepted=%s)" % [
					t_to_contact, str(_player.is_parrying)])
		return  # never trade mid-swing
	_souls_parried_this_attack = false

	# ── Heal: hurt and it's safe (Bobba staggered or far away) ──
	if float(_player.current_health) <= 100.0 and (bobba_stunned or dist > 4.0):
		_player._try_estus()
		if _player.is_drinking:
			return

	# ── Stagger punish: free hit while Bobba is stunned (post-riposte) ──
	if bobba_stunned and dist <= MELEE_HOLD_DIST + 0.3:
		_try_attack()
		return

	# ── Neutral: bait at 1.8 m with the sword down ──
	if dist > APPROACH_SNAP_DIST:
		var snap_pos: Vector3 = _bobba.global_position - dir * SOULS_BAIT_DIST
		snap_pos.y = _player.global_position.y
		_player.global_position = snap_pos
	elif dist > SOULS_BAIT_DIST + 0.2:
		var step: float = minf(6.0 * delta, dist - SOULS_BAIT_DIST)
		_player.global_position += dir * step


## Seconds until Bobba's current swing enters its damage window (30% of
## the attack animation — the same threshold bobba.gd uses to arm its
## hand hitboxes). Negative once inside or past the window.
func _time_to_bobba_hit_window() -> float:
	if not ("_anim_player" in _bobba) or _bobba._anim_player == null:
		return -1.0
	var ap: AnimationPlayer = _bobba._anim_player
	var anim_len: float = ap.current_animation_length
	if anim_len <= 0.0:
		return -1.0
	return 0.3 * anim_len - ap.current_animation_position


func _finish_souls(outcome: String) -> void:
	if _outcome_logged:
		return
	var estus_used: int = 0
	if _souls_estus_start >= 0 and "estus_charges" in _player:
		estus_used = _souls_estus_start - int(_player.estus_charges)
	print("[CombatTest/SOULS] KIT parries=%d ripostes=%d backstabs=%d estus_used=%d" % [
		_souls_parries, _souls_ripostes, _souls_backstabs, estus_used])
	_finish(outcome)


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
	# Drive the real guard button — the player reconciles is_blocking with
	# the action every frame, so poking the flag directly no longer sticks.
	if should_block:
		Input.action_press(&"block", 1.0)
	else:
		Input.action_release(&"block")
	if not bobba_attacking:
		_try_attack()


func _scenario_b(dist: float) -> void:
	# Paladin never blocks and backs off every third swing so the hit
	# whiffs, giving Bobba the tempo to kill the 150-HP knight before
	# Bobba's 1000 HP pool runs out.
	Input.action_release(&"block")
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
		# _do_attack refuses silently in several states (winded stamina,
		# airborne from Bobba's knockback, hit-stun roll, ...). Only count
		# presses that actually started a swing — the `attacks=` figure in
		# the outcome line must equal real swings with armed hitboxes, not
		# raw input presses.
		if _player.is_attacking:
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
	if not _screenshots_enabled:
		return
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
	# Silence every audio player (rain bed, river loop emitters, one-shots)
	# so the AudioServer releases their stream playbacks during the grace
	# second below. Loops still playing at quit() show up as "ObjectDB
	# instances leaked at exit" + "resources still in use" in every headless
	# run. Gate the Sfx autoload too — gameplay keeps running through the
	# grace second and any one-shot it starts (footstep, whoosh) would leak
	# its playback at quit. The FINAL sweep must be the last thing before
	# quit(): with frames between sweep and quit, a sound started in those
	# frames re-arms the leak (that race made the leak flaky, not fixed).
	var sfx := get_node_or_null("/root/Sfx")
	if sfx != null and "muted" in sfx:
		sfx.muted = true
	_stop_all_audio(get_tree().root)
	var t := get_tree().create_timer(1.0)
	t.timeout.connect(func():
		await get_tree().process_frame
		await get_tree().process_frame
		_stop_all_audio(get_tree().root)
		get_tree().quit())


## Recursively stop every AudioStreamPlayer/2D/3D under `node` and drop the
## stream reference so nothing holds the WAV resources at exit.
func _stop_all_audio(node: Node) -> void:
	if node is AudioStreamPlayer or node is AudioStreamPlayer2D or node is AudioStreamPlayer3D:
		node.stop()
		node.stream = null
	for child in node.get_children():
		_stop_all_audio(child)
