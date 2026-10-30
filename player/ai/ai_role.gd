class_name AIRole
extends RefCounted

## What every co-op AI can do REGARDLESS OF CLASS: read the party's shared
## picture ([[SquadBrain]]), steer the body through the same control surface a
## human uses, and survive a swing.
##
## WHERE THE LINE IS. Nothing in this file may know that a paladin carries a
## shield or that an archer carries a bow. It knows only that a body can move,
## look, guard, roll and be hit. Everything a CLASS does lives in exactly one
## file — player/ai/paladin_role.gd, player/ai/archer_role.gd — so a third one
## can be added, or one of these lifted into another project, without reading
## or touching the other two.
##
## SHAPE OF A ROLE. Deciding is expensive and slow-changing; steering is cheap
## and must be smooth. So a role RE-DECIDES on a fixed ~8 Hz beat — pick the
## highest-utility tactic from the brain's snapshot — and RUNS the chosen
## tactic every physics frame with nothing but vector arithmetic. No AI in this
## game walks a scene group in a per-frame path.
##
## WHAT A SUBCLASS PROVIDES:
##   choose_tactic()          REQUIRED — the name of the plan, scored from the
##                            brain's snapshot. Called on the decision beat.
##   run_tactic(delta)        REQUIRED — drive the body for the current plan.
##                            Called every physics frame.
##   special_defence(eta)     optional — a class answer to an incoming hit,
##                            tried before the roll (the paladin parries).
##   roll_dir(away)           optional — which way this class rolls out of one.
##   role_name                a label for the logs.

const Proto = preload("res://multiplayer/protocol.gd")

const DECIDE_INTERVAL := 0.12
## How long a chosen tactic is protected from being replaced. Long enough to
## take a few steps and see whether it is working; short enough that the AI
## still reads as reacting rather than committing to mistakes.
const MIN_DWELL := 0.8
const RETREAT_HP := 0.35        # break off below this fraction of max HP
## ...and rejoin once back above this. 0.6 was too high to ever come back
## from: Bobba hits for 65-95 against a 150 hp knight, so two blows put him
## under the break-off line, and the only ways up are a 40 hp flask and a 5%/s
## aura. He spent 53 of 85 samples disengaged and the boss never dropped below
## 428 hp. Half health is still two of Bobba's hits — enough to be worth
## something to the party, which a knight hiding at 59% is not.
const REENGAGE_HP := 0.5
const ESTUS_SAFE_DIST := 9.0    # a hit mid-drink wastes the charge
## Minimum gap between committed reactions. It used to be 0.9 s, which is
## longer than the gap between the steps of Bobba's own three-hit chain
## (~0.7 s at the tightest): one roll and the next two blows arrived while the
## AI was still on cooldown, unable to answer either.
const DEFENSE_COOLDOWN := 0.5
## An eta that sits inside a class's own parry window — handed to
## special_defence when the boss has already judged the instant is right.
const PARRY_TIMING_ETA := 0.2

var body: Player = null
var brain: SquadBrain = null
var tactic := "idle"
var tactic_age := 0.0
var role_name := "role"

var _decide_left := 0.0
var _defense_cd := 0.0
var _retreating := false
var _explore_dir := Vector3.ZERO
var _explore_left := 0.0
## The world's own gravity, read once. Part of the base API: a class that
## throws something (the archer) solves its arc with this.
var world_gravity := 9.8

## BOSS ARENAS (tests/boss_arena): the colossus and the platform, found once
## and re-checked every second. Class-neutral like everything here: what is
## coming, how long until it lands, where the edge is. What to DO about the
## fight is each role's business (paladin_role / archer_role "b_" tactics).
var boss: ColossusBoss = null
var arena: Node = null
var _boss_scan := 0.0
var _strike_kind := ""
var _strike_from := Vector3.ZERO


func setup(p_body: Player, p_brain: SquadBrain) -> void:
	body = p_body
	brain = p_brain
	world_gravity = float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
	# Stagger the decision beat so two companions never think on the same
	# frame — the cost is invisible either way, but it keeps frame times flat.
	_decide_left = randf() * DECIDE_INTERVAL


func update(delta: float) -> void:
	_defense_cd -= delta
	tactic_age += delta
	# The guard is re-derived every frame like the human's: whatever raises it
	# this frame (defend(), a fall-back) raises it again next frame or it comes
	# down on its own. A tactic that forgets to lower it cannot strand the
	# shield up, walking slowly and burning stamina for a swing that never came.
	guard(false)
	_refresh_boss(delta)
	_update_retreat_state()
	_decide_left -= delta
	if _decide_left <= 0.0:
		_decide_left = DECIDE_INTERVAL
		var next := choose_tactic()
		# A PLAN GETS LONG ENOUGH TO BE A PLAN. Two tactics scoring within a
		# few points of each other used to swap on every 0.12 s beat — measured
		# at 45 swaps between peel and fallback in one run — and a paladin
		# alternating "go to him" with "get away" walks nowhere at all while
		# being hit. The per-class commitment bonus cannot fix this on its own,
		# because the scores themselves move as the fight moves.
		#
		# This costs no reaction speed: defence is not a tactic. defend() runs
		# every frame underneath whichever plan is active, so parries, rolls
		# and the shield are untouched by how long the plan has been held.
		# A body on the ground is the one thing that cannot wait its turn.
		if next != tactic and (tactic_age >= MIN_DWELL or next == "revive"):
			print("CompanionAI[%s]: %s → %s" % [role_name, tactic, next])
			tactic = next
			tactic_age = 0.0
	run_tactic(delta)


# --------------------------------------------------------- extension points --

## REQUIRED. The plan for the next beat, scored from the brain's snapshot.
func choose_tactic() -> String:
	return "idle"


## REQUIRED. Drive the body for the current plan, once per physics frame.
func run_tactic(_delta: float) -> void:
	pass


## The class's own answer to a hit that is `eta` seconds from landing, tried
## BEFORE the roll because a class answer is usually the better one (a paladin's
## parry cancels the hit outright; a roll only avoids it). Return true if it
## fired — the base then spends the defence cooldown and the rest of the frame.
func special_defence(_eta: float) -> bool:
	return false


## Which way this class rolls out of a swing. `away` points straight from the
## attacker to us — the default is to take it.
func roll_dir(away: Vector3) -> Vector3:
	return away


## Is this blow worth WAITING on rather than rolling away from it now?
##
## The two reactions do not open at the same moment: the roll is live from
## 0.45 s out, the paladin's parry only from 0.34. So an unconditional roll
## always fires first, spends the reaction cooldown, and the better answer
## never gets its turn — which is exactly why the AI paladin parried zero
## times in a 112 s fight. A class that has something better coming says so
## here, and the base sits on its hands for those hundred milliseconds.
func hold_for_special(_eta: float) -> bool:
	return false


# ------------------------------------------------------------------- state --

func pos() -> Vector3:
	return body.global_position


func hp_frac() -> float:
	return float(body.current_health) / maxf(float(body.max_health), 1.0)


func stamina() -> float:
	if body._stamina != null:
		return body._stamina.ratio()
	return 1.0


## Retreat hysteresis: break off badly wounded, rejoin only once healed. Kept
## in the base so "am I in trouble" means the same thing to both classes.
func _update_retreat_state() -> void:
	var hp := hp_frac()
	if not _retreating and hp < RETREAT_HP:
		_retreating = true
		print("CompanionAI[%s]: breaking off at %.0f%% hp" % [role_name, hp * 100.0])
	elif _retreating and hp > REENGAGE_HP:
		_retreating = false
		print("CompanionAI[%s]: healed — back in" % role_name)


func retreating() -> bool:
	return _retreating


# -------------------------------------------------------------- the senses --

## Seconds until the next blade/fist lands on US, and what is throwing it.
## Read from the attacker's OWN clip timing, not guessed: a skeleton's blade
## falls at ATTACK_HIT_TIME into its swing, and Bobba's fist or axe lands at
## the start of whichever damage window the clip he is actually playing
## declares. That is what lets the AI parry on time instead of flipping a coin
## and hoping.
## How long before a boss blow lands a body standing in the dark notices it.
const DARK_SEE_ETA := 0.45


## Standing outside every lit brazier's glow on the fire-lit boss platform.
func in_dark() -> bool:
	return boss_fight() and arena != null and arena.has_method("light_at") \
			and float(arena.light_at(pos())) < 0.12


func soonest_strike() -> Dictionary:
	var best := INF
	var who: Node3D = null
	for c in brain.contacts:
		if not c.alive() or c.hunting != body:
			continue
		var reach := 9.0 if c.node is Bobba and c.node._gap_close else 5.5
		if c.pos.distance_to(pos()) > reach:
			continue
		var eta := strike_eta(c.node)
		if eta < best:
			best = eta
			who = c.node
	_strike_kind = ""
	if boss_fight():
		var s: Dictionary = boss.strike_eta_for(body)
		# In the dark the windup goes unseen: only the last instant of the
		# blow registers. Light is what the archer's arrows buy back.
		if in_dark() and float(s.eta) > DARK_SEE_ETA:
			s = {"eta": INF, "kind": "", "from": s.from}
		if float(s.eta) < best:
			best = s.eta
			who = boss
			_strike_kind = s.kind
			_strike_from = s.from
	return {"eta": best, "enemy": who}


func strike_eta(enemy: Node3D) -> float:
	if enemy is SkeletonWarrior:
		var sk := enemy as SkeletonWarrior
		if sk._attack_left <= 0.0 or sk._attack_dealt:
			return INF
		return maxf(0.0, sk._attack_left - (SkeletonWarrior.ATTACK_LEN
				- SkeletonWarrior.ATTACK_HIT_TIME))
	if enemy is Bobba:
		var b := enemy as Bobba
		if int(b.state) != int(Proto.BobbaState.ATTACKING):
			return INF
		# Off the CLIP, like the skeleton above — not a constant. Bobba has two
		# weapons with contact points nearly half a second apart (the fist
		# chain lands at 0.30 of its clip, the axe at 0.34 of a clip that is
		# twice as long), and he now jitters his playback speed on every swing.
		# The old flat 0.45 s guess was early by 300-500 ms against the axe,
		# which is a parry window and a half: the shield went up and came down
		# before the blade arrived, every single time.
		var ap: AnimationPlayer = b._anim_player
		if ap == null or ap.current_animation_length <= 0.0:
			return INF
		var speed: float = ap.get_playing_speed()
		if speed <= 0.01:
			return INF   # the swing is being HELD at the top: no contact to time yet
		var win: Vector2 = b._current_attack_data()["window"]
		return maxf(0.0, (win.x * ap.current_animation_length
				- ap.current_animation_position) / speed)
	return INF


## Defence, in priority order: raise the shield the moment anything is about
## to land (a block only chips — that is still far better than eating it),
## parry when the timing is exact enough to cancel the hit outright, roll when
## it is not. Returns true when a committed reaction (parry/roll) fired, which
## costs the rest of the frame.
func defend() -> bool:
	var strike := soonest_strike()
	var eta: float = strike.eta
	if eta == INF:
		guard(false)
		return false
	if _strike_kind != "":
		return _defend_boss(eta)
	guard(eta < 0.8)
	if _defense_cd > 0.0:
		return false
	# Whatever this class can do better than rolling, it does here.
	if special_defence(eta):
		_defense_cd = DEFENSE_COOLDOWN
		return true
	# ...and if it is still COMING, wait for it instead of rolling it away.
	if hold_for_special(eta):
		return false
	# Roll i-frames run 0.09–0.51 s into the roll.
	if eta >= 0.12 and eta <= 0.45 and stamina() > 0.3 and body.has_method("_try_dodge"):
		var enemy: Node3D = strike.enemy
		var away := Vector3.FORWARD
		if enemy != null and is_instance_valid(enemy):
			away = pos() - enemy.global_position
			away.y = 0.0
		if away.length_squared() < 0.01:
			away = Vector3.FORWARD
		# The roll takes its direction from _ai_move_vec, so steer first.
		move_world(roll_dir(away.normalized()), true)
		_defense_cd = DEFENSE_COOLDOWN
		body._try_dodge()
		return true
	return false


## The colossus's blows, each with the answer any body has. A class can
## pre-empt any of them through special_defence (the paladin parries the
## slam) or sweep_answer (the paladin takes a sweep on his shield for both).
func _defend_boss(eta: float) -> bool:
	var kind := _strike_kind
	var high := on_high_ground()
	if boss.act_serial != _react_serial:
		_react_serial = boss.act_serial
		_react_late = randfn(0.0, 0.09 * (1.2 - skill))
		_react_blank = randf() < 0.35 * (1.0 - skill)
	if _react_blank:
		guard(eta < 0.5)
		return false
	eta += _react_late
	match kind:
		"roar":
			# Brace: a crouch takes the shockwave without being thrown.
			body._ai_crouch = eta < 0.6
			guard(eta < 0.6)
			return false
		"gaze":
			guard(eta < 1.0)
			return false
		"shake":
			# Riding it: crouch and cling, or be flung off.
			body._ai_crouch = eta < 0.65
			return false
		"sweep_high":
			# Chest height: a hop or a perch does not escape it — duck.
			body._ai_crouch = eta < 0.7
			return false
		"sweep":
			if high:
				return false
			if sweep_answer(eta):
				return false
	guard(eta < 0.8 and kind != "grab")
	if eta < 0.8 and kind != "grab":
		aim_at(_strike_from)   # a shield only blocks what it faces
	if _defense_cd > 0.0:
		return false
	# Up on a perch there is nowhere to roll but down — or over the rim. Stand
	# it: a grab up here is the partner's to answer.
	if high and kind != "slam":
		return false
	if high and kind == "slam" and not special_defence(PARRY_TIMING_ETA):
		return false
	# THE COLOSSUS LANDS IN AN INSTANT. Bobba's eta points at the START of a
	# damage window that then stays open; a slam, a sweep or a grab connects
	# on one frame. So the answers are timed to that frame: a parry is live
	# 0.05-0.22 s after the press, roll i-frames 0.09-0.34 s, and a jump
	# carries the feet over a sweep 0.27-0.95 s after takeoff.
	if kind == "slam":
		if eta >= 0.07 and eta <= 0.19 and special_defence(PARRY_TIMING_ETA):
			_defense_cd = DEFENSE_COOLDOWN
			return true
		if eta > 0.19 and eta < 0.6 and hold_for_special(PARRY_TIMING_ETA + 0.15):
			return false
	if kind == "sweep" and eta >= 0.16 and eta <= 0.36 and body.is_on_floor() \
			and (stamina() < 0.35 or randf() < 0.5):
		body._ai_jump = true
		_defense_cd = DEFENSE_COOLDOWN
		return true
	if eta >= 0.1 and eta <= 0.3 and stamina() > 0.25 and body.has_method("_try_dodge"):
		var away := pos() - _strike_from
		away.y = 0.0
		if kind == "sweep" or away.length_squared() < 0.04:
			away = toward_center()
		away = safe_roll_dir(away.normalized())
		move_world(away, true)
		_defense_cd = DEFENSE_COOLDOWN
		body._try_dodge()
		return true
	return false


## A class's own answer to a sweep that is `eta` out (true = handled, the base
## stays out of it). The paladin raises his shield for the archer behind him.
func sweep_answer(_eta: float) -> bool:
	return false


func _refresh_boss(delta: float) -> void:
	_boss_scan -= delta
	if _boss_scan > 0.0:
		return
	_boss_scan = 1.0
	var tree := body.get_tree()
	boss = tree.get_first_node_in_group("colossus") as ColossusBoss
	arena = tree.get_first_node_in_group("boss_arena")


## LOB_BOSS_AI=naive: the same bodies with the co-op plays switched off — no
## rescues, no shield cover, an archer who never climbs. The control group
## that says whether the fight actually asks for co-operation.
static var naive: bool = OS.get_environment("LOB_BOSS_AI") == "naive"

## How good a pair of hands the bot has, 0..1 (LOB_BOT_SKILL, default 0.7).
## Frame-perfect bots parried every slam and made the fight look easy; a
## human reads late, sometimes not at all. Each of the colossus's swings
## gets one reaction error and one chance of being missed outright.
static var skill: float = clampf(float(OS.get_environment("LOB_BOT_SKILL")) \
		if OS.get_environment("LOB_BOT_SKILL") != "" else 0.7, 0.0, 1.0)
var _react_serial := -1
var _react_late := 0.0
var _react_blank := false


## The other half of the party, in a boss arena.
func partner() -> Player:
	if arena == null:
		return null
	for p in arena.party():
		if p != body:
			return p
	return null


func boss_fight() -> bool:
	return boss != null and is_instance_valid(boss) and not boss.is_dead() and arena != null


func toward_center() -> Vector3:
	if arena == null:
		return Vector3.ZERO
	var d: Vector3 = arena.center - pos()
	d.y = 0.0
	return d.normalized() if d.length_squared() > 0.01 else Vector3.FORWARD


## 0 in the middle of the platform, 1 at its rim.
func edge_risk() -> float:
	if arena == null:
		return 0.0
	var off: Vector3 = pos() - arena.center
	off.y = 0.0
	return clampf((off.length() - (arena.radius - 2.5)) / 2.5, 0.0, 1.0)


## A roll carries ~4.5 m: choose it by where it ENDS. Of the headings that
## land well inside the rim, the one closest to what we wanted.
func safe_roll_dir(want: Vector3) -> Vector3:
	if arena == null:
		return want
	var best := toward_center()
	var best_dot := -INF
	for k in 16:
		var d := Vector3(cos(TAU * k / 16.0), 0.0, sin(TAU * k / 16.0))
		var land: Vector3 = pos() + d * 4.8 - arena.center
		land.y = 0.0
		if land.length() > float(arena.radius) - 1.0:
			continue
		var score := d.dot(want)
		if score > best_dot:
			best_dot = score
			best = d
	return best


func spells() -> BossSpells:
	return body.get_node_or_null("BossSpells") as BossSpells


func on_high_ground() -> bool:
	return arena != null and pos().y - float(arena.floor_y) > 1.2


## Never step where the ground falls away: a probe ahead must find footing
## no more than a short drop below. Ramps (ground ahead HIGHER) pass. Only in
## a boss arena — the open world has its own route checks.
func _ledge_safe(world_dir: Vector3) -> Vector3:
	if arena == null or world_dir.length_squared() < 0.01:
		return world_dir
	var dir := Vector3(world_dir.x, 0.0, world_dir.z).normalized()
	# THE RIM FENCE. The probe below judges the step we ask for, not where a
	# collision slide takes us — sliding round a perch column carried the
	# archer straight over the rim. Inside the last 0.7 m nothing goes outward.
	var off: Vector3 = pos() - arena.center
	off.y = 0.0
	var out := off.normalized() if off.length_squared() > 0.01 else Vector3.ZERO
	# A body at a run needs ~v²/2a to stop (ACCEL 12 m/s²): the fence starts
	# that far in, so momentum cannot carry anyone over after the turn.
	var v_out := maxf(0.0, Vector3(body.velocity.x, 0, body.velocity.z).dot(out))
	var margin := 0.7 + v_out * v_out / 24.0
	if not on_high_ground() and off.length() > float(arena.radius) - margin:
		if dir.dot(out) > -0.2:
			dir = (dir - out * (dir.dot(out) + 0.6)).normalized()
	var space := body.get_world_3d().direct_space_state
	for ang in [0.0, 0.6, -0.6, 1.2, -1.2, 1.8, -1.8]:
		var d: Vector3 = dir.rotated(Vector3.UP, ang)
		var probe := pos() + d * 1.0
		var q := PhysicsRayQueryParameters3D.create(probe + Vector3(0, 1.2, 0),
				probe + Vector3(0, -2.6, 0), 1)
		q.exclude = [body.get_rid()]
		var hit := space.intersect_ray(q)
		if not hit.is_empty() and float(hit.position.y) > pos().y - 2.2:
			return d
	return Vector3.ZERO


## Hold or drop the shield. Guarding drains stamina regeneration, so it goes
## up for an incoming swing and comes straight back down.
func guard(on: bool) -> void:
	body._ai_block = on


## Estus with room to swallow. `threat_dist` is how close the nearest enemy is.
func drink_if_safe(threat_dist: float) -> void:
	if threat_dist > ESTUS_SAFE_DIST and hp_frac() < 0.7 and body.has_method("_try_estus"):
		body._try_estus()


# ------------------------------------------------------------------ moving --

## Point the camera pivot at a world position — swings, arrows and
## camera-relative movement all key off the pivot, exactly like a human's mouse.
func aim_at(world_pos: Vector3, pitch: float = 0.0) -> void:
	var pivot: Node3D = body.get_node_or_null("CameraPivot") as Node3D
	if pivot == null:
		return
	var to_target: Vector3 = world_pos - pos()
	if Vector2(to_target.x, to_target.z).length_squared() > 0.01:
		pivot.rotation.y = atan2(-to_target.x, -to_target.z)
	pivot.rotation.x = clampf(pitch, -0.6, 0.6)


## World direction → the camera-relative input vector player.gd expects.
## A waypoint around whatever solid thing stands between here and `goal` on
## the arena floor (a perch, a broken pillar, a fallen capital), on the side
## nearer the straight line; `goal` itself when the way is clear.
func detour(goal: Vector3) -> Vector3:
	if arena == null or not ("obstacles" in arena):
		return goal
	var here := Vector2(pos().x, pos().z)
	var g := Vector2(goal.x, goal.z)
	var seg := g - here
	var best_t := INF
	var way := goal
	for o in arena.obstacles:
		var c: Vector2 = o.at
		var r: float = float(o.r) + 0.7
		if g.distance_to(c) < r:
			continue
		if here.distance_to(c) < r:
			# Pressed against it already: slide along its edge, on the side
			# that turns toward the goal.
			var into := c - here
			if into.dot(seg) > 0.0:
				var tan := Vector2(-into.y, into.x).normalized()
				if tan.dot(seg) < 0.0:
					tan = -tan
				var w2 := here + tan * 2.0 - into.normalized() * 0.4
				return Vector3(w2.x, pos().y, w2.y)
			continue
		var t := clampf((c - here).dot(seg) / maxf(seg.length_squared(), 0.001), 0.0, 1.0)
		var closest := here + seg * t
		if closest.distance_to(c) < r and t < best_t:
			best_t = t
			var side := closest - c
			if side.length_squared() < 1e-4:
				side = Vector2(-seg.y, seg.x)
			var w := c + side.normalized() * (r + 0.8)
			way = Vector3(w.x, pos().y, w.y)
	return way


func move_world(world_dir: Vector3, run: bool) -> void:
	var pivot: Node3D = body.get_node_or_null("CameraPivot") as Node3D
	if pivot == null:
		return
	world_dir = _ledge_safe(world_dir)
	var yaw: float = pivot.rotation.y
	var fwd := Vector3.FORWARD.rotated(Vector3.UP, yaw)
	var rt := Vector3.RIGHT.rotated(Vector3.UP, yaw)
	body._ai_move_vec = Vector2(world_dir.dot(rt), -world_dir.dot(fwd))
	body._ai_run = run


func stop() -> void:
	body._ai_move_vec = Vector2.ZERO
	body._ai_run = false


## Walk to a point, running when it is far, stopping inside `arrive`.
## Returns true once we are there.
func go_to(point: Vector3, arrive: float, run_beyond: float = 8.0,
		face_point: bool = true) -> bool:
	var to_point: Vector3 = point - pos()
	to_point.y = 0.0
	var dist := to_point.length()
	if dist <= arrive:
		stop()
		return true
	if face_point:
		aim_at(point)
	move_world(to_point.normalized(), dist > run_beyond)
	return false


## A scored escape route: 12 headings, best one wins.
##
## FIRE IS COVER, NOT A HAZARD. There is no friendly fire in this game
## (Factions), so the party's own burning ground cannot hurt the party — while
## Bobba panics inside 2.5 m of it and skeletons steer 7 m clear and cook if
## they close. Running toward the archer's fires is therefore the single best
## thing a wounded companion can do, and the old route scorer, inherited from a
## time when fire burned everyone, was penalising exactly that.
## `fire_ideal` is how far from a fire the route wants to END UP, and it is the
## whole difference between two opposite uses of the same flames: ~4 m to break
## contact (inside the ring nothing hostile will follow you into), ~9 m to
## FIGHT in the light (well inside the 18 m reveal, well outside Bobba's 5 m
## avoidance, so he still comes to you — but now you can see him).
func escape_dir(from_enemy: Vector3, toward: Vector3, fire_is_cover: bool = true,
		fire_ideal: float = 4.0) -> Vector3:
	var best_dir := Vector3.ZERO
	var best_score := -INF
	var here := pos()
	for i in range(12):
		var ang := TAU * float(i) / 12.0
		var dir := Vector3(cos(ang), 0.0, sin(ang))
		var probe: Vector3 = here + dir * 14.0
		var score: float = probe.distance_to(from_enemy)
		score -= probe.distance_to(toward) * 0.35
		var fd: float = brain.fire_dist(probe)
		if fd < INF:
			# Sit just inside the light, not on the coals: close enough that
			# nothing hostile will follow, far enough to keep the fire between
			# us and the pursuer.
			score += (25.0 if fire_is_cover else -40.0) \
					* clampf(1.0 - absf(fd - fire_ideal) / 8.0, 0.0, 1.0)
		if absf(probe.x) > 220.0 or absf(probe.z) > 220.0:
			score -= 100.0
		if score > best_score:
			best_score = score
			best_dir = dir
	return best_dir


## Wander at a walk, re-picking a heading every several seconds. Running blind
## through the dark is how you find Bobba's nose with your throat.
func explore(delta: float) -> void:
	_explore_left -= delta
	if _explore_left <= 0.0 or _explore_dir.length_squared() < 0.01:
		_explore_left = randf_range(5.0, 9.0)
		var ang := randf() * TAU
		_explore_dir = Vector3(cos(ang), 0.0, sin(ang))
		var from_center := pos()
		from_center.y = 0.0
		if from_center.length() > 180.0:
			_explore_dir = -from_center.normalized()
	aim_at(pos() + _explore_dir * 10.0)
	move_world(_explore_dir, false)


func explore_heading() -> Vector3:
	return _explore_dir if _explore_dir.length_squared() > 0.01 else Vector3.FORWARD
