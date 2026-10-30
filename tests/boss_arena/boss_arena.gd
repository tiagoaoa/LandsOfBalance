class_name BossArena
extends Node3D

## THE CHAINED COLOSSUS — a co-op boss arena.
##
## A round stone platform (~113 m², radius 6) floats over a fog-drowned abyss
## on the same rainy full-moon night as the main game. Vaelgor stands in the
## abyss beside it and fights across the rim. Two rock perches rise from the
## platform edge on ramps (the archer's high ground: level with the
## boss's mouth, above its low sweeps, with stone cover nearby),
## and a low stump at the far side clears a sweep for anyone who hops onto it.
##
## FALLING ENDS THE MATCH: anyone who leaves the platform — knocked off by a
## sweep, thrown by a grab, or a careless roll — restarts it for both.
## So does a party wipe; a kill shows the result and restarts too.
##
##   tools/run_boss_arena.sh                 # you: archer, bot: paladin
##   tools/run_boss_arena.sh --paladin       # you: paladin, bot: archer
##   tools/run_boss_arena.sh --watch         # two bots, spectator camera
##   tools/run_boss_sims.sh                  # headless batches, match reports
##
## Each match appends one JSON line (outcome, duration, who did what) to
## LOB_BOSS_LOG (default user://boss_matches.ndjson).

const PLAYER_SCENE: PackedScene = preload("res://player/player.tscn")

const RADIUS := 6.0
const BOSS_SCALE := 0.6
const FALL_Y := -3.0
const MATCH_TIMEOUT := 600.0
const RESULT_HOLD := 5.0

var center := Vector3.ZERO
## LOB_ARENA_AREA: the platform's area as a multiple of the original ~113 m²
## (1 = the tight original; the 6x and 10x builds are the big-field ones).
var area_factor: float = maxf(1.0, float(OS.get_environment("LOB_ARENA_AREA"))) \
		if OS.get_environment("LOB_ARENA_AREA") != "" else 1.0
var radius := RADIUS * sqrt(area_factor)
## The giant grows with the field (1.0 = the original 6 m arena).
var boss_size := 1.0 + (RADIUS * sqrt(area_factor) - RADIUS) * 0.055
var floor_y := 0.0
var boss_distance := 11.0
var boss_base_y := -4.0
## High ground the AI knows about: {top: Vector3, radius, ramp_base: Vector3, ramp_top: Vector3}
var perches: Array[Dictionary] = []
## Everything solid standing on the stone, for the bots' detours: {at: Vector2, r}.
var obstacles: Array[Dictionary] = []
var stump := {}

var boss: ColossusBoss
var _human: Player
var _ally: Player
var _hud: CanvasLayer
var _boss_bar: ProgressBar
var _boss_bar_ghost: ProgressBar
var _boss_name: Label
var _banner: Label
var _banner_left := 0.0
var _clock: Label
var _party_box: VBoxContainer
var _party_bars := {}
var _match_t := 0.0
var _over := false
var _report := {}
var _last_hit := {}
var _trace_t := 0.0     # body name -> what last landed on it, for "how did they fall"
var _previous_physics_hz := 120


func _ready() -> void:
	_previous_physics_hz = Engine.physics_ticks_per_second
	#Swept strikes and interpolated bodies retain continuous motion at 60 Hz.
	#120 Hz left this CPU-bound boss unable to keep up with simulation time.
	Engine.physics_ticks_per_second = 60
	add_to_group("boss_arena")   # the co-op AI finds the platform rules here
	var gs := get_node_or_null("/root/GameSettings")
	if gs:
		gs.arena_round += 1
		gs.arena_mode = true   # this scene owns every restart
		# Solo control runs must not get Player's own auto-spawned companion.
		gs.coop_mode = OS.get_environment("LOB_BOSS_SOLO") == ""
		gs.singleplayer = true
	var scale := OS.get_environment("LOB_TIME_SCALE")
	if scale != "":
		Engine.time_scale = float(scale)
	_build_environment()
	_build_platform()
	_build_perches()
	_build_braziers()
	var sanctuary := preload("res://tests/boss_arena/sanctuary.gd").new()
	add_child(sanctuary)
	sanctuary.build(self)
	_build_backdrop()
	_spawn_boss()
	_spawn_party()
	_build_hud()
	_report = {"round": gs.arena_round if gs else 0, "events": {}, "dealt": {},
			"weak_dealt": {}, "taken": {}, "outcome": "", "duration": 0.0}
	_banner_text(boss.display_name, 4.0)


func _exit_tree() -> void:
	Engine.physics_ticks_per_second = _previous_physics_hz
	if RenderingServer.get_current_rendering_method() == "forward_plus":
		RenderingServer.environment_set_volumetric_fog_volume_size(
				ProjectSettings.get_setting("rendering/environment/volumetric_fog/volume_size", 128),
				ProjectSettings.get_setting("rendering/environment/volumetric_fog/volume_depth", 64))


# ================================================================ party =====

## The party, as the boss (and its AI opponents) see it.
func party() -> Array:
	var out: Array = []
	for b in [_human, _ally]:
		if b != null and is_instance_valid(b):
			out.append(b)
	return out


func _spawn_party() -> void:
	var gs := get_node_or_null("/root/GameSettings")
	var human_class: int = gs.selected_character_class if gs else 1
	var spectate: bool = gs != null and gs.spectate
	# LOB_BOSS_SOLO=paladin|archer: a control run with only that class on the
	# platform — the measure of whether the fight really needs both.
	var solo := OS.get_environment("LOB_BOSS_SOLO")
	if solo != "":
		human_class = 0 if solo == "paladin" else 1
	var spawn_z := 2.2 if area_factor <= 1.0 else radius * 0.45
	_human = _make_body(false, human_class, Vector3(-1.2, 0.5, spawn_z))
	if solo == "":
		_ally = _make_body(true, 1 - human_class, Vector3(1.2, 0.5, spawn_z))
	if spectate:
		var mine := CompanionAI.new()
		mine.name = "CompanionAI"
		mine.body = _human
		_human.add_child(mine)
		var rig := SpectateCam.new()
		rig.name = "SpectateCam"
		add_child(rig)
		rig.watch(_human)
		# Recording for outside playtesters: no bot internals on screen, and a
		# steady broadcast camera instead of the clipping chase rig.
		if OS.get_environment("LOB_BOSS_CAMERA_CYCLE") != "":
			var cam := preload("res://tests/boss_arena/watch_camera.gd").new()
			cam.arena = self
			cam.rig = rig
			add_child(cam)
		elif OS.get_environment("LOB_BOSS_SHOTS") != "":
			rig.get_node("SpectateHUD").visible = false
			_add_broadcast_cam()
	call_deferred("_settle_party")


func _make_body(companion: bool, cls: int, at: Vector3) -> Player:
	var p: Player = PLAYER_SCENE.instantiate()
	p.name = "Companion" if companion else "Player"
	p.is_ai_companion = companion
	p.enable_multiplayer = false
	if "enable_fifo" in p:
		p.enable_fifo = false
	if companion:
		p.companion_class_override = cls
	add_child(p)
	p.global_position = at
	if companion:
		var ai := CompanionAI.new()
		ai.name = "CompanionAI"
		ai.body = p
		p.add_child(ai)
	p.set_meta("spawn_at", at)
	p.set_meta("want_class", cls)
	return p


func _settle_party() -> void:
	# Player._ready() picks a random world spawn and the default class: put
	# both back where this arena wants them, as the classes it dealt.
	for p in party():
		p._switch_character_class(p.get_meta("want_class"))
		p.global_position = p.get_meta("spawn_at")
		p.velocity = Vector3.ZERO
		p._spawn_immunity_timer = 2.0
		p.reset_physics_interpolation()
		boss.configure_player_collision(p)
		# The giant's shoulder ledges are carried explicitly (ColossusBoss
		# _carry_riders). Taking the physics platform velocity as well, and
		# keeping it on leaving, catapulted riders 20 m into the abyss.
		p.platform_floor_layers = 0
		p.platform_wall_layers = 0
		p.platform_on_leave = CharacterBody3D.PLATFORM_ON_LEAVE_DO_NOTHING
		var sp := BossSpells.new()
		sp.name = "BossSpells"
		sp.body = p
		sp.arena = self
		sp.kind = BossSpells.kind_for(p)
		p.add_child(sp)
		sp.cast.connect(func(k: String) -> void:
				_on_boss_event("spell", {"who": p.name, "how": k}))
		# A faint lantern-light on each hero: tiny figures in dark cloth were
		# lost against the night stone (the art critics' "where are they?").
		# A coloured ring at each hero's feet: gold knight, blue archer —
		# readable at a glance from the broadcast camera.
		if OS.get_environment("LOB_BOSS_SHOTS") != "" and not p.has_node("HeroRing"):
			var ring := MeshInstance3D.new()
			ring.name = "HeroRing"
			var tm := TorusMesh.new()
			tm.inner_radius = 0.55
			tm.outer_radius = 0.68
			tm.rings = 24
			tm.ring_segments = 6
			ring.mesh = tm
			var rm := StandardMaterial3D.new()
			rm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			rm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			rm.albedo_color = Color(1.0, 0.78, 0.35, 0.55) if p.is_paladin() else Color(0.45, 0.75, 1.0, 0.55)
			ring.material_override = rm
			ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			ring.scale = Vector3(1, 0.15, 1)
			ring.position = Vector3(0, 0.06, 0)
			p.add_child(ring)
		if not p.has_node("HeroLight"):
			var hl := OmniLight3D.new()
			hl.name = "HeroLight"
			hl.light_color = Color(0.87, 0.84, 0.76)
			hl.light_energy = 0.55
			hl.omni_range = 3.2
			hl.shadow_enabled = false
			hl.position = Vector3(0, 1.6, 0.4)
			p.add_child(hl)
		# Face the colossus.
		if "camera_rotation" in p:
			var to_boss: Vector3 = boss.global_position - p.global_position
			p.camera_rotation.x = atan2(-to_boss.x, -to_boss.z)
			p._camera_pivot.rotation.y = p.camera_rotation.x
	if _human.has_signal("player_died"):
		pass


# ============================================================== the loop ====

func _physics_process(delta: float) -> void:
	if _over:
		return
	_tick_contact_probe(delta)
	_tick_grab_debug(delta)
	# Downs and revives are party events the boss never sees.
	for p in party():
		var was: bool = p.get_meta("was_dead", false)
		if p.is_dead != was:
			p.set_meta("was_dead", p.is_dead)
			_on_boss_event("party_down" if p.is_dead else "party_revived", {"who": p.name})
			if p.is_dead:
				call_deferred("_shrink_beacon", p.name)
		# A flask lifted is on screen: name it, so a heal has a cause.
		var drinking: bool = bool(p.get("is_drinking"))
		if drinking and not bool(p.get_meta("was_drinking", false)):
			_on_boss_event("flask", {"who": p.name})
		p.set_meta("was_drinking", drinking)
		# Heals (a flask, the rite) are on screen too: say so in the timeline.
		var hp_now: float = p.current_health / p.max_health
		var hp_low: float = p.get_meta("hp_low", hp_now)
		if hp_now < hp_low:
			p.set_meta("hp_low", hp_now)
		elif hp_now - hp_low >= 0.15 and not p.is_dead:
			p.set_meta("hp_low", hp_now)
			_on_boss_event("party_heal", {"who": p.name})
	_match_t += delta
	_trace_t -= delta
	for p in party():
		if p.is_on_floor():
			p.set_meta("last_ground", p.global_position)
		if _trace_t <= 0.0:
			var tr: Array = p.get_meta("trace", [])
			tr.append([snappedf(_match_t, 0.01), snappedf(p.global_position.x, 0.01),
					snappedf(p.global_position.y, 0.01), snappedf(p.global_position.z, 0.01),
					_tactic_of(p), p._is_stunned, p.is_rolling])
			if tr.size() > 16:
				tr.pop_front()
			p.set_meta("trace", tr)
	if _trace_t <= 0.0:
		_trace_t = 0.2
	# Climbing: jump beside a pinned fist (the human's key, the bot's flag).
	for p in party():
		var wants: bool = p._ai_climb if p.ai_driven else Input.is_action_just_pressed(&"jump")
		p._ai_climb = false
		if wants and not _down(p):
			boss.try_climb(p)
	for p in party():
		if p.global_position.y < floor_y + FALL_Y:
			_cam_focus = p
			var cause: Dictionary = _last_hit.get(p.name, {})
			var recent: bool = not cause.is_empty() and _match_t - float(cause.t) < 3.0
			_end_match("FALL", "%s FELL INTO THE ABYSS" % _label(p), {"who": _class_key(p),
					"boss_model": boss.model_kind,
					"fall_from": str((p.get_meta("last_ground", Vector3.ZERO) as Vector3).snapped(Vector3.ONE * 0.1)),
					"fall_cause": String(cause.kind) if recent else "misstep",
					"fall_tactic": _tactic_of(p), "fall_trace": p.get_meta("trace", [])})
			return
	# Down = is_dead OR out of health: the last player to fall never gets
	# is_dead (Player hands the match straight to its game-over path), and a
	# wipe check on is_dead alone left a 0-HP archer fighting for ten minutes.
	var alive := party().filter(func(p: Player) -> bool: return not _down(p))
	if alive.is_empty():
		_end_match("WIPE", "", {})   # Player already shows its own caption
		return
	if _match_t >= MATCH_TIMEOUT:
		_end_match("TIMEOUT", "THE %s ENDURES" % _boss_word(), {})


func _process(delta: float) -> void:
	_tick_lightning(delta)
	_update_hud(delta)
	_update_climb_prompt()
	_update_broadcast_cam(delta)
	_maybe_capture(delta)


## LOB_BOSS_SHOTS=<dir>: a frame every LOB_BOSS_SHOT_EVERY seconds (and on
## every banner), named attempt_time.png — the raw material for playtest
## contact sheets. Windowed runs only; a headless build renders nothing.
var _shot_left := 0.0
func _maybe_capture(delta: float) -> void:
	var dir := OS.get_environment("LOB_BOSS_SHOTS")
	if dir == "" or DisplayServer.get_name() == "headless":
		return
	if _match_t < 1.5 and not _over:
		return   # the first frames show characters before their animations start
	_shot_left -= delta
	if _shot_left > 0.0:
		return
	var every := OS.get_environment("LOB_BOSS_SHOT_EVERY")
	_shot_left = float(every) if every != "" else 2.0
	_capture(dir, "")


func _capture(dir: String, tag: String) -> void:
	if dir == "" or DisplayServer.get_name() == "headless":
		return
	DirAccess.make_dir_recursive_absolute(dir)
	var gs := get_node_or_null("/root/GameSettings")
	var img := get_viewport().get_texture().get_image()
	img.resize(img.get_width() / 2, img.get_height() / 2)
	img.save_jpg("%s/a%02d_t%05.1f%s.jpg" % [dir, gs.arena_round if gs else 0, _match_t,
			("_" + tag) if tag != "" else ""], 0.8)


func _on_boss_died() -> void:
	_end_match("WIN", "%s FELLED" % _boss_word(), {})


# ======================================================== contact probe =====
## LOB_CONTACT_PROBE=1: every 0.1 s, test each hero against the boss's
## VISIBLE skin (SkinProbe) and its solid hitboxes; log every stretch spent
## inside either to the match report ("contact": [...]) and count them in
## events (inside_skin / inside_collider). Sims read it with boss_report.py.
var _skin_probe: SkinProbe
var _probe_t := 0.0
var _probe_on := OS.get_environment("LOB_CONTACT_PROBE") != ""
var _contact_open := {}   # "who:kind" -> episode


## While someone is held: where is the partner, doing what, every 0.5 s.
var _gdbg_t := 0.0


func _tick_grab_debug(delta: float) -> void:
	if boss == null or boss.grab_victim() == null:
		return
	_gdbg_t -= delta
	if _gdbg_t > 0.0:
		return
	_gdbg_t = 0.5
	if not _report.has("grab_debug"):
		_report.grab_debug = []
	var brace: Vector3 = boss.brace_hand_pos()
	for p in party():
		if p == boss.grab_victim():
			continue
		var role = p.get_node("CompanionAI").get("_role") if p.has_node("CompanionAI") else null
		_report.grab_debug.append({"t": snappedf(_match_t, 0.1), "e": "hold", "who": _class_key(p),
				"tactic": String(role.get("tactic")) if role else "?",
				"dist": snappedf(Vector2(p.global_position.x - brace.x, p.global_position.z - brace.z).length(), 0.1),
				"brace_r": snappedf(Vector2(brace.x - center.x, brace.z - center.z).length(), 0.1),
				"brace_y": snappedf(brace.y - floor_y, 0.1), "rescue": snappedf(float(boss.get("_rescue_dmg")), 1.0),
				# Distance to the claw's struck SURFACE, the rescuer's own radius,
				# and whether the blade is actually moving.
				"mdist": snappedf(p.global_position.distance_to(boss.claw_melee_pos(brace, p.global_position)), 0.1),
				"pr": snappedf(Vector2(p.global_position.x - center.x, p.global_position.z - center.z).length(), 0.1),
				"atk": bool(p.get("is_attacking")),
				"v": snappedf(Vector2(p.velocity.x, p.velocity.z).length(), 0.1),
				"stun": bool(p.get("_is_stunned")), "blk": bool(p.get("is_blocking")),
				"floor": p.is_on_floor()})


func _tick_contact_probe(delta: float) -> void:
	if not _probe_on or boss == null or boss.reptile == null:
		return
	_probe_t -= delta
	if _probe_t > 0.0:
		return
	_probe_t = 0.1
	if _skin_probe == null:
		_skin_probe = SkinProbe.new()
		var mis := boss.reptile.model.find_children("*", "MeshInstance3D", true, false)
		if mis.is_empty() or not _skin_probe.build(mis[0], boss.reptile.skel):
			_probe_on = false
			return
	# Its own probe, re-skinned now: what the player SEES this frame, not
	# the boss's 40 Hz copy the separation works from.
	_skin_probe.update()
	for p: Player in party():
		var key := _class_key(p)
		var state := "riding" if boss.on_pad(p) else ("climbing" if boss.is_climbing(p) else
				("held" if boss.grab_victim() == p else ("down" if p.is_dead else "free")))
		# The skin: the deepest of three points up the body.
		var deepest := -1.0
		var bone := ""
		for h: float in [0.35, 0.95, 1.55]:
			var r := _skin_probe.inside(p.global_position + Vector3(0, h, 0))
			if float(r.depth) > deepest:
				deepest = float(r.depth)
				bone = String(r.bone)
		_contact_step(key, "skin", deepest > 0.25, deepest, bone, state, p)
		# The solid hitboxes the player is supposed to be kept out of.
		var hit := ""
		var cs := p.get_node_or_null("CollisionCapsule") as CollisionShape3D
		if cs and state == "free":
			var q := PhysicsShapeQueryParameters3D.new()
			q.shape = cs.shape
			q.transform = cs.global_transform
			q.collision_mask = 2
			var ex: Array[RID] = [p.get_rid()]
			for o in p.get_collision_exceptions():
				ex.append(o.get_rid())
			q.exclude = ex
			var res := get_world_3d().direct_space_state.intersect_shape(q, 1)
			if not res.is_empty():
				hit = String((res[0].collider as Node).name) + "/" + String((res[0].collider as Node).get_parent().name)
		_contact_step(key, "collider", hit != "", 0.0, hit, state, p)


func _contact_step(who: String, kind: String, inside: bool, depth: float, where: String,
		state: String, p: Player) -> void:
	var k := who + ":" + kind
	if inside:
		if not _contact_open.has(k):
			var role = p.get_node("CompanionAI").get("_role") if p.has_node("CompanionAI") else null
			_contact_open[k] = {"who": who, "kind": kind, "t": snappedf(_match_t, 0.1), "dur": 0.0,
					"depth": 0.0, "where": where, "state": state, "act": boss.act_name(),
					"tactic": String(role.get("tactic")) if role else "?",
					"pos": [snappedf(p.global_position.x, 0.1), snappedf(p.global_position.y, 0.1), snappedf(p.global_position.z, 0.1)]}
		var e: Dictionary = _contact_open[k]
		e.dur = snappedf(float(e.dur) + 0.1, 0.1)
		if depth > float(e.depth):
			e.depth = snappedf(depth, 0.01)
			e.where = where
	elif _contact_open.has(k):
		_close_contact(k)


func _close_contact(k: String) -> void:
	var e: Dictionary = _contact_open[k]
	_contact_open.erase(k)
	if not _report.has("contact"):
		_report.contact = []
	_report.contact.append(e)
	var ev: Dictionary = _report.events
	var key := "inside_" + String(e.kind)
	ev[key] = int(ev.get(key, 0)) + 1


func _close_contacts() -> void:
	for k in _contact_open.keys():
		_close_contact(k)


func _end_match(outcome: String, banner: String, extra: Dictionary) -> void:
	if _over:
		return
	_close_contacts()
	_over = true
	_report.outcome = outcome
	_report.duration = snappedf(_match_t, 0.1)
	_report.boss_hp = snappedf(boss.hp, 1.0)
	_report.boss_hp_frac = snappedf(boss.hp_frac(), 0.001)
	_report.phase = boss.phase
	_report.merge(extra)
	for p in party():
		_report["hp_" + _class_key(p)] = snappedf(p.current_health / p.max_health, 0.01)
		_report["dead_" + _class_key(p)] = p.is_dead
	_report.ai_mode = OS.get_environment("LOB_BOSS_AI") if OS.get_environment("LOB_BOSS_AI") != "" else "coop"
	if OS.get_environment("LOB_BOSS_SOLO") != "":
		_report.ai_mode = "solo_" + OS.get_environment("LOB_BOSS_SOLO")
	_report.skill = AIRole.skill
	_write_report()
	print("[BossArena] MATCH %s in %.1fs boss_hp=%.0f phase=%d events=%s" % [
			outcome, _match_t, boss.hp, boss.phase, JSON.stringify(_report.events)])
	if banner != "":
		_banner_text(banner, RESULT_HOLD + 1.0)
	var wait := RESULT_HOLD if outcome != "FALL" else 2.5
	if outcome == "WIN":
		wait = 7.5   # let it fall: the slide into the mist is the payoff
	get_tree().create_timer(wait, true, false, true).timeout.connect(_next_match)


func _next_match() -> void:
	var gs := get_node_or_null("/root/GameSettings")
	var target := int(OS.get_environment("LOB_BOSS_MATCHES")) if OS.get_environment("LOB_BOSS_MATCHES") != "" else 0
	if target > 0 and gs and gs.arena_round >= target:
		print("[BossArena] %d matches done — quitting" % gs.arena_round)
		get_tree().quit()
		return
	get_tree().reload_current_scene()


func _on_boss_event(kind: String, data: Dictionary) -> void:
	var ev: Dictionary = _report.events
	if data.has("victim"):
		_last_hit[String(data.victim)] = {"kind": kind, "t": _match_t}
	var key := kind
	if kind == "hit":
		key = "hit_" + String(data.part)
		var by := String(data.by)
		var cls := _class_of_name(by)
		_report.dealt[cls] = snappedf(float(_report.dealt.get(cls, 0.0)) + float(data.dealt), 0.1)
		if data.weak:
			_report.weak_dealt[cls] = snappedf(float(_report.weak_dealt.get(cls, 0.0)) + float(data.dealt), 0.1)
		key += "_" + cls
		if not data.weak and data.has("on"):
			var on_key := "glance_%s_%s" % [String(data.on), cls]
			ev[on_key] = int(ev.get(on_key, 0)) + 1
	ev[key] = int(ev.get(key, 0)) + 1
	# A timeline the playtest packets are built from (player-perceivable only).
	if not _report.has("timeline"):
		_report.timeline = []
	if kind != "hit" or data.weak:
		var line := {"t": snappedf(_match_t, 0.1), "e": kind}
		for k in ["victim", "who", "by", "target", "part", "why", "how", "blocked"]:
			if data.has(k):
				line[k] = _class_of_name(String(data[k])) if k in ["victim", "who", "by", "target"] else data[k]
		# What the health bars showed at that moment.
		# Round UP while it lives: "0%" on a boss that is still fighting read as a bug.
		line["boss"] = ceilf(boss.hp_frac() * 100.0) / 100.0
		for p in party():
			# Alive reads as at least 1%: a captive held at 1 HP showed "0%" and
			# looked like a body that should have gone down.
			line[_class_key(p)] = 0.0 if p.is_dead else maxf(0.01, ceilf(p.current_health / p.max_health * 100.0) / 100.0)
		_report.timeline.append(line)
	if kind == "grabbed" or kind == "rescued" or kind == "thrown":
		if not _report.has("grab_debug"):
			_report.grab_debug = []
		for p in party():
			var role = p.get_node("CompanionAI").get("_role") if p.has_node("CompanionAI") else null
			_report.grab_debug.append({"t": snappedf(_match_t, 0.1), "e": kind, "who": _class_key(p),
					"tactic": String(role.get("tactic")) if role else "?",
					"pos": [snappedf(p.global_position.x, 0.1), snappedf(p.global_position.y, 0.1), snappedf(p.global_position.z, 0.1)],
					"brace": [snappedf(boss.brace_hand_pos().x, 0.1), snappedf(boss.brace_hand_pos().z, 0.1)] if boss.grab_victim() else []})
	match kind:
		"stagger":
			_banner_text(("THE %s STAGGERS" % _boss_word()) if data.why == "poise" else "IT RECOILS", 1.6)
		"phase2":
			_banner_text("THE CHAINS BREAK", 2.5)
		"grabbed":
			var held := _class_of_name(String(data.get("victim", "")))
			_banner_text("THE KNIGHT IS SEIZED — SHOOT ITS BRACED CLAW!" if held == "paladin"
					else "THE ARCHER IS SEIZED — STRIKE ITS BRACED CLAW!", 2.0)
		"punch_open":
			_banner_text("FIST DOWN — STRIKE OR CLIMB!", 2.0)
		"head_slam":
			_banner_text("IT REARS — GET OUT OF THE RING!", 1.4)
		"head_hit", "head_miss":
			_banner_text("SKULL ON THE STONE — STRIKE THE HEAD!", 2.0)
		"brazier_out":
			if not braziers.any(func(b: ArenaBrazier) -> bool: return b.lit):
				_banner_text("THE LAST FIRE IS OUT — RELIGHT THEM WITH ARROWS!", 2.4)
			else:
				_banner_text("A FIRE GOES OUT", 1.0)
		"rescued":
			_banner_text("FREED", 1.2)


func _write_report() -> void:
	var path := OS.get_environment("LOB_BOSS_LOG")
	if path == "":
		path = "user://boss_matches.ndjson"
	var f := FileAccess.open(path, FileAccess.READ_WRITE) if FileAccess.file_exists(path) \
			else FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("BossArena: cannot write %s" % path)
		return
	f.seek_end()
	f.store_line(JSON.stringify(_report))
	f.close()


var _climb_prompt: Label3D
## "[SPACE] CLIMB" over a pinned fist the human could scramble up right now.
func _update_climb_prompt() -> void:
	if _human == null or _human.ai_driven or boss == null:
		return
	if _climb_prompt == null:
		_climb_prompt = Label3D.new()
		_climb_prompt.text = "[SPACE] CLIMB"
		_climb_prompt.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_climb_prompt.no_depth_test = true
		_climb_prompt.fixed_size = true
		_climb_prompt.pixel_size = 0.0016
		_climb_prompt.font_size = 48
		_climb_prompt.outline_size = 10
		_climb_prompt.modulate = Color(1.0, 0.85, 0.5)
		add_child(_climb_prompt)
	_climb_prompt.text = "[A] CLIMB" if not Input.get_connected_joypads().is_empty() else "[SPACE] CLIMB"
	if boss.is_climbing(_human):
		_climb_prompt.visible = true
		_climb_prompt.text = "MOVE: CLIMB   CROUCH: CLING   JUMP: LET GO"
		_climb_prompt.global_position = _human.global_position + Vector3.UP * 2.5
		return
	var fist: Vector3 = boss.climbable_fist(_human)
	_climb_prompt.visible = fist != Vector3.INF
	if _climb_prompt.visible:
		_climb_prompt.global_position = fist + Vector3(0, 2.2, 0)


## The main game's revive beacon is sized to be found across a whole map;
## on a 12 m platform it covered the screen. Same beacon, arena-sized.
func _shrink_beacon(who: String) -> void:
	var marker := get_tree().current_scene.get_node_or_null(who + "DeathMarker")
	if marker == null:
		return
	for l in marker.find_children("*", "Label3D", true, false):
		(l as Label3D).pixel_size = 0.006
		(l as Label3D).position.y = 2.0


## Things the giant attacks besides the party (the archer's spirit hounds).
func lures() -> Array:
	var out: Array = []
	for n in get_tree().get_nodes_in_group("lures"):
		if is_instance_valid(n) and not n.is_dead:
			out.append(n)
	return out


func spawn_decoys(at: Vector3, count: int) -> void:
	for k in count:
		var d := SpiritDecoy.new()
		d.arena = self
		d.name = "SpiritHound"
		add_child(d, true)   # readable names in the match log
		d.global_position = at + Vector3(randf_range(-1.5, 1.5), 0.6, randf_range(-1.5, 1.5))


func _boss_word() -> String:
	if boss and boss.model_kind == "dragon":
		return "DRAGON"
	return "LIZARD-KING" if boss and boss.model_kind == "lizard" else "COLOSSUS"


func _down(p: Player) -> bool:
	return p.is_dead or p.current_health <= 0.0


func _tactic_of(p: Player) -> String:
	var ai := p.get_node_or_null("CompanionAI")
	if ai and ai._role:
		return ai._role.tactic
	return "human"


func _class_key(p: Player) -> String:
	return "paladin" if p.is_paladin() else "archer"


func _class_of_name(n: String) -> String:
	for p in party():
		if p.name == n:
			return _class_key(p)
	return n


func _label(p: Player) -> String:
	return "THE KNIGHT" if p.is_paladin() else "THE ARCHER"


# ============================================================ building ======

func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.026, 0.032, 0.038)
	sky_mat.sky_horizon_color = Color(0.21, 0.225, 0.235)
	sky_mat.ground_bottom_color = Color(0.025, 0.028, 0.03)
	sky_mat.ground_horizon_color = Color(0.16, 0.18, 0.19)
	sky.sky_material = sky_mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	var we := WorldEnvironment.new()
	we.name = "WorldEnvironment"
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.name = "DirectionalLight3D"
	sun.light_energy = 0.0
	add_child(sun)
	var moon := Node3D.new()
	moon.name = "Moon"
	moon.set_script(load("res://stage/moon.gd"))
	add_child(moon)
	# The main game's own night preset: same fog, same wet moonlight, same rain.
	var lm := Node.new()
	lm.name = "LightingManager"
	lm.set_script(load("res://stage/lighting_manager.gd"))
	lm.set("time_of_day", 1)
	add_child(lm)
	call_deferred("_tune_night", env)
	_add_rain()
	# A faint cold rim behind the colossus, just enough to find its outline in
	# the mist. No moon fill any more: the braziers are the light, and when the
	# boss knocks them out the party fights by the archer's fire.
	var rim := DirectionalLight3D.new()
	rim.name = "ColossusRim"
	rim.light_color = Color(0.62, 0.7, 0.8)
	rim.light_energy = 0.28
	rim.shadow_enabled = false
	rim.rotation_degrees = Vector3(-24.0, -28.0, 0.0)
	add_child(rim)


## Rain over the arena: streaks in the light, so the night reads as wet.
func _add_rain() -> void:
	var p := GPUParticles3D.new()
	p.name = "Rain"
	p.amount = int(1400 * sqrt(area_factor))
	p.lifetime = 1.2
	p.visibility_aabb = AABB(Vector3(-radius - 10, -20, -radius - 10), Vector3(radius * 2 + 20, 50, radius * 2 + 20))
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(radius + 8.0, 0.5, radius + 8.0)
	pm.direction = Vector3(0.15, -1, 0)
	pm.spread = 3.0
	pm.initial_velocity_min = 22.0
	pm.initial_velocity_max = 26.0
	pm.gravity = Vector3(0, -9.8, 0)
	p.process_material = pm
	var q := QuadMesh.new()
	q.size = Vector2(0.012, 0.45)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(0.7, 0.8, 1.0, 0.12)
	m.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
	q.material = m
	p.draw_pass_1 = q
	p.position = Vector3(0, 18.0, 0)
	add_child(p)


## After LightingManager's night preset: lift the abyss into a moonlit mist
## the colossus stands out against, instead of a black void.
func _tune_night(env: Environment) -> void:
	# Fire-lit night: the sky and ambient are nearly gone, the fog is thick
	# and dark, and the braziers' light scatters in it as warm halos.
	env.background_energy_multiplier = 0.12
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.3, 0.33, 0.38)
	env.ambient_light_energy = 0.07
	env.fog_enabled = true
	env.fog_light_color = Color(0.045, 0.05, 0.058)
	env.fog_light_energy = 0.5
	env.fog_density = 0.028
	env.fog_height = -2.0
	env.fog_height_density = 0.12   # thick below the rim: the abyss is a sea of mist
	env.volumetric_fog_enabled = RenderingServer.get_current_rendering_method() == "forward_plus"
	env.volumetric_fog_density = 0.028
	env.volumetric_fog_albedo = Color(0.82, 0.82, 0.84)
	env.volumetric_fog_length = 70.0
	env.volumetric_fog_ambient_inject = 0.05
	#Broad, slow fog needs fewer froxels than detailed smoke. Retain the
	#boss's local volume while reducing compute and shared-memory traffic.
	if env.volumetric_fog_enabled:
		RenderingServer.environment_set_volumetric_fog_volume_size(64, 64)
	# SSAO cost ~24 ms a frame here on an iGPU, for contact shadows the
	# dragon already has baked into its vertex colour: off.
	env.ssao_enabled = false
	# 2x anisotropy: the 4x project default measured ~14 ms here (wide wet
	# floors at grazing angles), for detail nobody sees at night.
	get_viewport().anisotropic_filtering_level = Viewport.ANISOTROPY_2X
	# Fire and the dragon's throat should bloom; the rest of the night stays low.
	env.glow_enabled = true
	env.glow_intensity = 0.3
	env.glow_bloom = 0.0
	env.glow_hdr_threshold = 1.8
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 1.1
	env.adjustment_enabled = true
	env.adjustment_saturation = 0.72
	env.adjustment_contrast = 1.06
	var moon := get_node("Moon/MoonLight") as DirectionalLight3D
	moon.light_color = Color(0.62, 0.7, 0.8)
	moon.light_energy = 0.14
	moon.rotation_degrees = Vector3(-32, -55, 0)
	moon.shadow_normal_bias = 0.8


func _primitive_collision(visual: CSGShape3D) -> void:
	#CSG made these simple solids into concave triangle meshes. Primitive
	#shapes give Jolt exact cylinders/boxes and avoid per-triangle contacts.
	var shape: Shape3D
	if visual is CSGCylinder3D:
		shape = CylinderShape3D.new()
		shape.radius = visual.radius
		shape.height = visual.height
	else:
		shape = BoxShape3D.new()
		shape.size = visual.size
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	cs.name = visual.name + "Shape"
	cs.shape = shape
	body.add_child(cs)
	visual.add_child(body)


func _build_platform() -> void:
	var rock := _wet_stone(Color(0.8, 0.8, 0.82), true)   # rain-slick flagstones
	var top := CSGCylinder3D.new()
	top.name = "Platform"
	top.radius = radius
	top.height = 2.0
	top.sides = 96
	top.position = Vector3(0, floor_y - 1.0, 0)
	top.visible = false   # The Blender dais supplies the visible floor and cornice.
	top.material = rock
	add_child(top)
	_primitive_collision(top)
	# The stone root of the platform, tapering into the dark below.
	var root := MeshInstance3D.new()
	var cone := CylinderMesh.new()
	cone.top_radius = radius * 0.82
	cone.bottom_radius = radius * 0.2
	cone.height = 26.0
	cone.radial_segments = 14
	root.mesh = cone
	root.position = Vector3(0, floor_y - 15.0, 0)
	# The underside: the castle-wall scan, dark and dry under the overhang.
	var dark := _wet_stone(Color(0.3, 0.28, 0.27), false)
	if dark is ShaderMaterial:
		(dark as ShaderMaterial).set_shader_parameter("wetness", 0.15)
	root.material_override = dark
	add_child(root)
	# A rim of broken stones so the edge reads at night.
	var rim_n := int(22 * sqrt(area_factor))
	var stones := MultiMesh.new()
	stones.transform_format = MultiMesh.TRANSFORM_3D
	stones.mesh = BoxMesh.new()
	stones.mesh.size = Vector3.ONE
	stones.instance_count = rim_n
	for k in rim_n:
		var a := TAU * k / rim_n + randf_range(-0.05, 0.05)
		var size := Vector3(randf_range(0.5, 0.9), randf_range(0.15, 0.35), randf_range(0.4, 0.7))
		var at := Vector3(sin(a) * (radius - 0.25), floor_y + size.y * 0.5, cos(a) * (radius - 0.25))
		var basis := Basis(Vector3.UP, a + randf_range(-0.3, 0.3)) * Basis.from_scale(size)
		stones.set_instance_transform(k, Transform3D(basis, at))
	var rim := MultiMeshInstance3D.new()
	rim.name = "RimStones"
	rim.multimesh = stones
	rim.material_override = rock
	add_child(rim)


## The fires are most of the light this fight has (the moon is a smear in
## the mist): a ring of braziers near the rim, clear of the perches and ramps.
## The boss's blows knock them out; the archer's arrows light them again.
var braziers: Array[ArenaBrazier] = []


func _build_braziers() -> void:
	var stone := _wet_stone(Color(0.7, 0.68, 0.66), false)
	var spots: Array[Vector3] = []
	if area_factor > 1.0:
		var want := 6
		for k in 24:
			if spots.size() >= want:
				break
			# Six slots, nudged off any perch or ramp they would sit on.
			var slot := k % want
			var nudge: float = [0.0, 12.0, -12.0, 24.0][k / want]
			var a := deg_to_rad(30.0 + slot * 60.0 + nudge)
			var at := Vector3(sin(a), 0, -cos(a)) * radius * 0.84
			if _near_perch(at, 3.2) or spots.any(func(o: Vector3) -> bool: return o.distance_to(at) < radius * 0.6):
				continue
			spots.append(at)
	else:
		spots = [Vector3(-2.2, 0, 4.4), Vector3(2.2, 0, 4.4), Vector3(-4.6, 0, -1.4), Vector3(4.6, 0, -1.4)]
	for at0 in spots:
		var b := ArenaBrazier.new()
		b.build(Vector3(at0.x, floor_y, at0.z), 6.5, 13.0 if area_factor > 1.0 else 8.5, stone)
		add_child(b)
		braziers.append(b)
		# The boss reports what knocked a fire out; a relight is counted here.
		b.changed.connect(func(lit: bool) -> void:
			if lit:
				_on_boss_event("brazier_lit", {}))


## How much fire light falls on `p`: 1 beside a lit brazier, 0 in the dark.
func light_at(p: Vector3) -> float:
	var best := 0.0
	for b in braziers:
		if b.lit:
			var d := Vector2(b.global_position.x - p.x, b.global_position.z - p.z).length()
			best = maxf(best, clampf(1.0 - d / (b.reach * 0.75), 0.0, 1.0))
	return best


## The high ground. Each perch is a rock column at the rim reached by a
## Ramps lead to raised firing positions with a clear view of the boss's head.
func _build_perches() -> void:
	var rock := _wet_stone(Color(0.7, 0.68, 0.66), false)
	if area_factor <= 1.0:
		for side: float in [-1.0, 1.0]:
			_add_perch(deg_to_rad(132.0) * side, 4.6, 3.6, rock, 62.0 * side, 4.3)
		_add_stump(Vector3(0, floor_y, 4.7), rock)
		return
	# The big field: two low perches by the far rim, two TOWERS level with the
	# giant's heart-gem nearer its side (a long ramp up each), ruined pillars to
	# provide cover, with hop-up stumps scattered over the open stone.
	var perch_h := 4.3 * boss_size - 1.5
	for side: float in [-1.0, 1.0]:
		_add_perch(deg_to_rad(140.0) * side, radius * 0.72, 3.6, rock, 0.0, 0.0)
		_add_perch(deg_to_rad(62.0) * side, radius * 0.66, perch_h, rock, 0.0, 0.0)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	# Fewer, bigger ruins: a forest of pillars blocked every camera.
	var n_pil := int(1 + area_factor * 0.35)
	for k in n_pil:
		var a := TAU * (k + 0.5) / n_pil + rng.randf_range(-0.3, 0.3)
		var d := radius * rng.randf_range(0.3, 0.55)
		var at := Vector3(sin(a) * d, floor_y, -cos(a) * d)
		if _near_perch(at, 3.5):
			continue
		var pr := rng.randf_range(0.75, 1.0)
		var ph := rng.randf_range(2.8, 4.4)
		_add_ruin_column(at, pr, ph, rng)
		obstacles.append({"at": Vector2(at.x, at.z), "r": pr * 1.1})
	for k in int(area_factor * 0.6):
		var a := rng.randf() * TAU
		var at := Vector3(sin(a), 0, -cos(a)) * radius * rng.randf_range(0.2, 0.8)
		if not _near_perch(at, 3.0):
			_add_stump(Vector3(at.x, floor_y, at.z), rock)


## A rock column `h` tall at angle `ang` (0 = toward the giant), `dist` out,
## with a ramp along the rim's tangent down to the open floor.
## Worked stone, not grey boxes: the game's flagstone texture, mapped
## triplanar so towers, ramps and pillars all take it without UVs.
## Scanned, rain-soaked stone (Poly Haven CC0, wet_stone.gdshader); `floor`
## picks the slate flagstones, otherwise the castle-wall blocks.
func _wet_stone(tint: Color, flags: bool) -> Material:
	var id := "slate_floor_02" if flags else "castle_wall_varriation"
	var base := "res://assets/textures/arena/%s_%%s_2k.jpg" % id
	if not ResourceLoader.exists(base % "diff"):
		return _stone(tint, 0.45)
	var m := ShaderMaterial.new()
	m.shader = preload("res://tests/boss_arena/wet_stone.gdshader")
	m.set_shader_parameter("albedo_tex", load(base % "diff"))
	m.set_shader_parameter("normal_tex", load(base % "nor_gl"))
	m.set_shader_parameter("rough_tex", load(base % "rough"))
	m.set_shader_parameter("ao_tex", load(base % "ao"))
	m.set_shader_parameter("tile_m", 3.5 if flags else 3.0)
	m.set_shader_parameter("tint", tint)
	m.set_shader_parameter("normal_strength", 0.65 if flags else 0.6)
	m.set_shader_parameter("puddles", 0.32 if flags else 0.0)
	return m


func _stone(tint: Color, rough: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = tint
	m.albedo_texture = load("res://stage/tiles_albedo.webp")
	m.roughness_texture = load("res://stage/tiles_rough.webp")
	m.roughness = rough
	m.uv1_triplanar = true
	m.uv1_scale = Vector3(0.35, 0.35, 0.35)
	m.uv1_world_triplanar = true
	return m


## A broken fluted column from the ruin kit (tools/build_ruins.py) over a
## plain cylinder collider, with rubble at its foot that nothing trips on.
var _ruins: Node3D


func _add_ruin_column(at: Vector3, r: float, h: float, rng: RandomNumberGenerator) -> void:
	var body := StaticBody3D.new()
	body.name = "Pillar%d" % obstacles.size()
	var cs := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = r
	cyl.height = h
	cs.shape = cyl
	cs.position = Vector3(0, h * 0.5, 0)
	body.add_child(cs)
	body.position = at
	add_child(body)
	if _ruins == null and ResourceLoader.exists("res://assets/environment/ruins/ruins.glb"):
		_ruins = (load("res://assets/environment/ruins/ruins.glb") as PackedScene).instantiate()
		_ruins.name = "RuinKitSource"
		_ruins.visible = false
		add_child(_ruins)
	if _ruins == null:
		var m := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = r
		cm.bottom_radius = r
		cm.height = h
		m.mesh = cm
		m.position = Vector3(0, h * 0.5, 0)
		body.add_child(m)
		return
	var cols := _ruins.find_children("Ruin_Column_*", "MeshInstance3D", true, false)
	var src := cols[rng.randi() % cols.size()] as MeshInstance3D
	var mi := MeshInstance3D.new()
	mi.mesh = src.mesh
	mi.material_override = _wet_stone(Color(0.52, 0.51, 0.47), false)
	var nominal: float = float(src.get_meta("extras", {}).get("collider_height", 3.6)) if src.has_meta("extras") else 3.6
	mi.scale = Vector3(r / 0.9, h / nominal, r / 0.9)
	mi.rotation.y = rng.randf() * TAU
	body.add_child(mi)
	var rubs := _ruins.find_children("Ruin_Rubble_*", "MeshInstance3D", true, false)
	if not rubs.is_empty():
		var rb := MeshInstance3D.new()
		rb.mesh = (rubs[rng.randi() % rubs.size()] as MeshInstance3D).mesh
		rb.material_override = mi.material_override
		rb.scale = Vector3.ONE * rng.randf_range(0.5, 0.8)
		rb.position = at + Vector3(rng.randf_range(-1.6, 1.6), 0, rng.randf_range(-1.6, 1.6))
		rb.rotation.y = rng.randf() * TAU
		add_child(rb)


func _add_perch(ang: float, dist: float, h: float, rock: Material, base_deg: float,
		base_dist: float) -> void:
	var top := Vector3(sin(ang) * dist, floor_y + h, -cos(ang) * dist)
	var col := CSGCylinder3D.new()
	col.name = "Perch%d" % perches.size()
	col.radius = 1.35 if h < 4.0 else 1.6
	col.height = h + 1.0
	col.sides = 9
	col.position = Vector3(top.x, floor_y + (h - 1.0) * 0.5, top.z)
	col.material = rock
	add_child(col)
	_primitive_collision(col)
	var base: Vector3
	if base_deg != 0.0:
		var base_ang: float = ang - deg_to_rad(base_deg)
		base = Vector3(sin(base_ang) * base_dist, floor_y, -cos(base_ang) * base_dist)
	else:
		# Tangent to the rim, toward the giant's side, 32° of slope.
		var radial := Vector3(top.x, 0, top.z).normalized()
		var tangent := radial.cross(Vector3.UP) * (1.0 if ang > 0.0 else -1.0)
		var run := h / tan(deg_to_rad(32.0)) + col.radius
		base = Vector3(top.x, floor_y, top.z) - tangent * run
		var r := Vector3(base.x, 0, base.z)
		if r.length() > radius - 1.5:
			base = r.normalized() * (radius - 1.5) + Vector3(0, floor_y, 0)
	var top_edge := top + (Vector3(base.x, top.y, base.z) - top).normalized() * (col.radius - 0.15)
	top_edge.y = floor_y + h
	var run_v := Vector3(top_edge.x - base.x, 0, top_edge.z - base.z)
	var length := sqrt(run_v.length_squared() + h * h)
	var ramp := CSGBox3D.new()
	ramp.name = col.name + "Ramp"
	ramp.size = Vector3(1.6, 0.4, length)
	ramp.material = rock
	ramp.position = (base + top_edge) * 0.5 + Vector3(0, -0.2, 0)
	ramp.basis = Basis.looking_at(-(top_edge - base).normalized(), Vector3.UP)
	add_child(ramp)
	_primitive_collision(ramp)
	obstacles.append({"at": Vector2(top.x, top.z), "r": col.radius})
	perches.append({"top": top, "radius": col.radius - 0.25, "ramp_base": base,
			"ramp_top": top_edge, "name": col.name, "height": h})


func _add_stump(at: Vector3, rock: Material) -> void:
	var st := CSGCylinder3D.new()
	st.name = "Stump"
	st.radius = 0.9
	st.height = 0.6
	st.sides = 8
	st.position = at + Vector3(0, 0.3, 0)
	st.material = rock
	add_child(st)
	_primitive_collision(st)
	stump = {"top": at + Vector3(0, 0.6, 0), "radius": 0.8}


func _near_perch(p: Vector3, d: float) -> bool:
	for perch in perches:
		var t: Vector3 = perch.top
		if Vector2(t.x - p.x, t.z - p.z).length() < d:
			return true
		var a: Vector3 = perch.ramp_base
		var b: Vector3 = perch.ramp_top
		var ab := Vector2(b.x - a.x, b.z - a.z)
		var ap := Vector2(p.x - a.x, p.z - a.z)
		var tt := clampf(ap.dot(ab) / maxf(ab.length_squared(), 0.001), 0.0, 1.0)
		if (ap - ab * tt).length() < d * 0.7:
			return true
	return false


func _build_backdrop() -> void:
	# Distant crags around the abyss: scanned cliff faces (Poly Haven CC0)
	# blown up into spires, their feet lost in a sea of mist.
	var backdrop := preload("res://tests/boss_arena/backdrop.gd").new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	for k in 11:
		var a := TAU * k / 11.0 + rng.randf_range(-0.12, 0.12)
		var d := rng.randf_range(160.0, 230.0)
		var sc := rng.randf_range(2.6, 4.2)
		var size := Vector3(sc, sc * rng.randf_range(2.0, 3.2), sc)
		rng.randf_range(-0.5, 0.5) #Keep the established skyline's random positions.
		var at := Vector3(sin(a) * d, floor_y - rng.randf_range(45.0, 70.0), cos(a) * d)
		backdrop.add(self, "cliff", at, size, a + PI)
	# The sea of mist below the rim, in drifting layers.
	var noise := NoiseTexture2D.new()
	noise.width = 512
	noise.height = 512
	noise.seamless = true
	var fn := FastNoiseLite.new()
	fn.frequency = 0.008
	fn.fractal_octaves = 4
	noise.noise = fn
	for k in 4:
		var sheet := MeshInstance3D.new()
		var pm := PlaneMesh.new()
		pm.size = Vector2(420, 420)
		sheet.mesh = pm
		var mat := ShaderMaterial.new()
		mat.shader = preload("res://tests/boss_arena/mist.gdshader")
		mat.set_shader_parameter("noise_tex", noise)
		mat.set_shader_parameter("density", 0.5 - 0.08 * k)
		mat.set_shader_parameter("drift", 0.004 + 0.002 * k)
		mat.set_shader_parameter("scale", 0.01 + 0.003 * k)
		mat.set_shader_parameter("tint", Color(0.14, 0.16, 0.17).lerp(Color(0.24, 0.26, 0.27), k / 3.0))
		sheet.material_override = mat
		sheet.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		sheet.position = Vector3(0, floor_y - 7.0 - 6.0 * k, 0)
		add_child(sheet)
	_lightning_in = randf_range(8.0, 14.0)


## Distant lightning: a cold double flash over the crags now and then, so the
## dragon's silhouette and wings cut out against the sky for a beat.
var _lightning_in := 10.0
var _flash: DirectionalLight3D


func _tick_lightning(delta: float) -> void:
	_lightning_in -= delta
	if _lightning_in > 0.0:
		return
	_lightning_in = randf_range(14.0, 26.0)
	if _flash == null:
		_flash = DirectionalLight3D.new()
		_flash.light_color = Color(0.7, 0.78, 1.0)
		_flash.shadow_enabled = false
		_flash.light_energy = 0.0
		add_child(_flash)
	# From behind the dragon, so it backlights the wings.
	if boss:
		var away := Vector3(boss.global_position.x - center.x, 0, boss.global_position.z - center.z).normalized()
		_flash.look_at_from_position(center + away * 60.0 + Vector3(0, 50, 0), center, Vector3.UP)
	var tw := create_tween()
	tw.tween_property(_flash, "light_energy", 2.2, 0.04)
	tw.tween_property(_flash, "light_energy", 0.2, 0.09)
	tw.tween_property(_flash, "light_energy", 1.6, 0.05)
	tw.tween_property(_flash, "light_energy", 0.0, 0.35)


func _spawn_boss() -> void:
	boss = ColossusBoss.new()
	boss.name = "Colossus"
	boss.arena = self
	boss.sz = boss_size * BOSS_SCALE
	boss_distance = radius + 5.0 * boss.sz
	boss_base_y = -4.0 * boss.sz
	add_child(boss)
	boss._anchor_angle = 0.0
	boss._place_on_anchor(true)
	boss.died.connect(_on_boss_died)
	boss.combat_event.connect(_on_boss_event)


## High behind the platform's far side, framing both players and the
## colossus, easing toward the action. For recordings and watching.
var _bcam: Camera3D
var _cam_focus: Node3D
func _add_broadcast_cam() -> void:
	_bcam = Camera3D.new()
	_bcam.fov = 62.0
	add_child(_bcam)
	_bcam.current = true
	_bcam.global_position = Vector3(0, 9.5, 14.0)
	_bcam.look_at(Vector3(0, 3.0, -3.0))


var _cam_side := 1.0
var _cam_flip_cd := 0.0
var _cam_lift := 0.0


## A director, not a crane: three-quarter on the dragon from the far side of
## the platform, low enough to look UP at it, swinging to the other side
## when a pillar hides the players; in close on the chest when it reels; the
## dragon (not the empty stone) when it falls.
func _update_broadcast_cam(delta: float) -> void:
	if _bcam == null or boss == null:
		return
	_bcam.current = true
	var mid := Vector3.ZERO
	var n := 0
	for p in party():
		mid += p.global_position
		n += 1
	mid = mid / maxf(n, 1)
	var away := Vector3(center.x - boss.global_position.x, 0, center.z - boss.global_position.z).normalized()
	var side := away.cross(Vector3.UP)
	var look := mid.lerp(boss.core_pos(), 0.4)
	var want := center + (away * cos(0.55) + side * _cam_side * sin(0.55)) * (radius + 3.0) \
			+ Vector3(0, 4.5 + radius * 0.18, 0)
	var rate := 1.2
	if boss.is_dead():
		# From the stone near the edge it loses, looking down after it as it
		# slides into the mist (the lens stays on the platform, the dragon in frame).
		look = boss.head_pos().lerp(boss.core_pos(), 0.5)
		want = center - away * (radius * 0.55) + side * _cam_side * (radius * 0.3) + Vector3(0, 5.0, 0)
		rate = 1.2
	elif _match_t < 3.5:
		# The reveal: low, looking up at its face.
		look = boss.head_pos()
		want = center + away * (radius * 0.2) + side * _cam_side * 5.0 + Vector3(0, 2.2, 0)
	elif boss.core_open() or boss.head_open():
		# It reels, chest open: closer on the fire — but from the platform,
		# never inside its wing.
		look = boss.head_pos() if boss.reptile else boss.core_pos()
		want = center + away * (radius * 0.25) + side * _cam_side * (radius * 0.45) + Vector3(0, 4.5, 0)
		rate = 1.6
	elif _cam_focus != null and is_instance_valid(_cam_focus):
		look = _cam_focus.global_position
	# Swing to the other side when stone stands between the lens and the party.
	_cam_flip_cd -= delta
	if _cam_flip_cd <= 0.0 and n > 0 and not boss.is_dead():
		var q := PhysicsRayQueryParameters3D.create(_bcam.global_position, mid + Vector3(0, 1.0, 0), 1)
		var hit := get_world_3d().direct_space_state.intersect_ray(q)
		if not hit.is_empty() and (hit.position as Vector3).distance_to(mid) > 2.5:
			_cam_side = -_cam_side
			_cam_lift = 4.0   # and over the stone while it swings
			_cam_flip_cd = 5.0
	_cam_lift = maxf(0.0, _cam_lift - delta * 1.2)
	want.y += _cam_lift
	# Never inside stone or under the floor: pull in toward the subject —
	# but only along a line that starts above the stone (a dragon sinking
	# below the rim put the probe under the platform and the lens in rock).
	want.y = maxf(want.y, floor_y + 1.2)
	if not boss.is_dead():
		look.y = maxf(look.y, floor_y + 1.5)
	var probe_from := Vector3(look.x, maxf(look.y, floor_y + 1.5), look.z)
	var cq := PhysicsRayQueryParameters3D.create(probe_from, want, 1)
	var chit := get_world_3d().direct_space_state.intersect_ray(cq)
	if not chit.is_empty():
		want = (chit.position as Vector3) + (probe_from - want).normalized() * 0.8
	_bcam.global_position = _bcam.global_position.lerp(want, 1.0 - exp(-rate * delta))
	var t := _bcam.global_transform.looking_at(look, Vector3.UP)
	_bcam.global_basis = _bcam.global_basis.slerp(t.basis, 1.0 - exp(-2.5 * delta))


# ================================================================== HUD =====

func _build_hud() -> void:
	_hud = CanvasLayer.new()
	_hud.layer = 40
	add_child(_hud)
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	box.offset_left = -360
	box.offset_right = 360
	box.offset_top = -92
	box.offset_bottom = -40
	_hud.add_child(box)
	_boss_name = Label.new()
	_boss_name.text = boss.display_name
	_boss_name.add_theme_font_size_override("font_size", 18)
	_boss_name.add_theme_color_override("font_color", Color(0.92, 0.86, 0.72))
	_boss_name.add_theme_color_override("font_outline_color", Color.BLACK)
	_boss_name.add_theme_constant_override("outline_size", 4)
	box.add_child(_boss_name)
	var bars := Control.new()
	bars.custom_minimum_size = Vector2(720, 14)
	box.add_child(bars)
	_boss_bar_ghost = _bar(Color(0.95, 0.75, 0.3, 0.9))
	bars.add_child(_boss_bar_ghost)
	_boss_bar = _bar(Color(0.65, 0.08, 0.06))
	bars.add_child(_boss_bar)
	_banner = Label.new()
	# The lower third, above the boss bar: centre-screen banners sat on the
	# dragon's face and over the action.
	_banner.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_banner.offset_left = -500
	_banner.offset_right = 500
	_banner.offset_top = -240
	_banner.offset_bottom = -185   # clear of the revive bar (-166..-122)
	_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner.add_theme_font_size_override("font_size", 34)
	_banner.add_theme_color_override("font_color", Color(0.95, 0.88, 0.65))
	_banner.add_theme_color_override("font_outline_color", Color.BLACK)
	_banner.add_theme_constant_override("outline_size", 8)
	_hud.add_child(_banner)
	# What your hands can do, for the human seat (never shown to bots' cameras).
	var gs := get_node_or_null("/root/GameSettings")
	if gs == null or not gs.spectate:
		var help := Label.new()
		help.set_anchors_preset(Control.PRESET_TOP_WIDE)
		help.offset_top = 10
		help.offset_bottom = 30
		help.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		help.add_theme_font_size_override("font_size", 12)
		help.add_theme_color_override("font_color", Color(0.78, 0.72, 0.58))
		help.add_theme_color_override("font_outline_color", Color.BLACK)
		help.add_theme_constant_override("outline_size", 3)
		help.text = ("RMB hold/release: draw & shoot  ·  LMB: quick shot  ·  X: roll  ·  Space: jump  ·  Ctrl / LB: crawl  ·  H: flask  ·  C: fire ring  ·  hold E: revive"
				if int(_human.get_meta("want_class")) == 1 else
				"LMB: attack  ·  V: heavy  ·  RMB: shield  ·  G: parry  ·  X: roll  ·  Space: jump  ·  Ctrl / LB: crawl  ·  H: flask  ·  C: healing rite  ·  hold E: revive")
		_hud.add_child(help)
	# Both players' health, always: in a fight built on rescues you have to
	# see your partner's bar as clearly as your own.
	_party_box = VBoxContainer.new()
	_party_box.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_party_box.offset_left = 18
	_party_box.offset_top = 40
	_party_box.offset_right = 250
	_party_box.offset_bottom = 90
	_hud.add_child(_party_box)
	_clock = Label.new()
	_clock.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_clock.offset_left = -220
	_clock.offset_right = -16
	_clock.offset_top = 12
	_clock.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_clock.add_theme_color_override("font_color", Color(0.8, 0.75, 0.6))
	_hud.add_child(_clock)


func _bar(c: Color) -> ProgressBar:
	var b := ProgressBar.new()
	b.set_anchors_preset(Control.PRESET_FULL_RECT)
	b.show_percentage = false
	b.max_value = 1.0
	b.value = 1.0
	var fill := StyleBoxFlat.new()
	fill.bg_color = c
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0, 0, 0, 0.0) if c.a < 1.0 else Color(0.05, 0.04, 0.04, 0.8)
	bg.border_color = Color(0.5, 0.45, 0.35, 0.8)
	bg.set_border_width_all(1)
	b.add_theme_stylebox_override("fill", fill)
	b.add_theme_stylebox_override("background", bg)
	return b


func _update_hud(delta: float) -> void:
	if boss == null:
		return
	for p in party():
		if not _party_bars.has(p.name):
			var row := HBoxContainer.new()
			var l := Label.new()
			l.text = "KNIGHT" if int(p.get_meta("want_class")) == 0 else "ARCHER"
			l.custom_minimum_size = Vector2(64, 0)
			l.add_theme_font_size_override("font_size", 13)
			l.add_theme_color_override("font_color", Color(0.9, 0.85, 0.7))
			l.add_theme_color_override("font_outline_color", Color.BLACK)
			l.add_theme_constant_override("outline_size", 3)
			row.add_child(l)
			var b := _bar(Color(0.55, 0.12, 0.1))
			b.set_anchors_preset(Control.PRESET_TOP_LEFT)
			b.custom_minimum_size = Vector2(160, 12)
			row.add_child(b)
			_party_box.add_child(row)
			_party_bars[p.name] = b
		var bar: ProgressBar = _party_bars[p.name]
		bar.value = 0.0 if _down(p) else p.current_health / p.max_health
		var sp := p.get_node_or_null("BossSpells") as BossSpells
		if sp and not p.ai_driven:
			var lab := (bar.get_parent() as HBoxContainer).get_child(0) as Label
			var base := "KNIGHT" if int(p.get_meta("want_class")) == 0 else "ARCHER"
			lab.text = "%s  [Z] %s %s" % [base, sp.kind.to_upper(),
					"READY" if sp.ready_now() else "%ds" % int(ceil(sp.cd))]
			lab.custom_minimum_size = Vector2(190, 0)
	_boss_bar.value = boss.hp_frac()
	# The pale "damage just dealt" chunk drains after the red one, souls-style.
	_boss_bar_ghost.value = maxf(_boss_bar.value, move_toward(_boss_bar_ghost.value, _boss_bar.value, 0.25 * delta))
	var gs := get_node_or_null("/root/GameSettings")
	_clock.text = "ATTEMPT %d   %d:%02d" % [gs.arena_round if gs else 1, int(_match_t) / 60, int(_match_t) % 60]
	if _banner_left > 0.0:
		_banner_left -= delta
		_banner.modulate.a = clampf(_banner_left, 0.0, 1.0)


func _banner_text(text: String, seconds: float) -> void:
	if _banner == null:
		call_deferred("_banner_text", text, seconds)
		return
	_banner.text = text
	_banner_left = seconds
	_banner.modulate.a = 1.0
