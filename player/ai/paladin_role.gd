class_name PaladinRole
extends AIRole

## THE AI PALADIN — the party's ANCHOR.
##
## He owns everything that has to happen at arm's length: he takes the hits
## meant for the archer, he holds the ground the light falls on, and he is the
## only one who can put a wounded ally back on his feet. He is not a bodyguard
## who trails the human around, and he is not a berserker who runs at every
## noise — he is the member of the party whose job is to be BETWEEN things.
##
## The four ideas that make him read as a teammate rather than a chase script:
##
## 1. PEEL. An enemy that turns on the archer is the paladin's problem, not the
##    archer's. He breaks off whatever he is doing and goes for it — and
##    because that enemy is by definition facing away from him, the approach is
##    a backstab (BACKSTAB_CONE_DOT / BACKSTAB_DAMAGE_MULT). Co-op geometry
##    pays for itself.
##
## 2. FIGHT IN THE LIGHT. Charging into darkness after something he cannot see
##    is how the paladin dies alone. When his target is unlit and still coming
##    for him, he gives ground toward the nearest fire instead and takes the
##    fight there: the archer's work becomes his advantage, and everything
##    hostile either follows him into the light or gives up the chase.
##
## 3. THE RITE IS A DECISION, NOT A COOLDOWN. His lightning circle is a party
##    HEAL aura of only 3 m (HEAL_AREA_RADIUS) that the game refuses to let him
##    start inside 8 m of a live enemy, and any landed hit shatters it. So
##    casting it is a small plan: disengage, get to the wounded ally, then
##    channel — and he values it most when the ARCHER is the one bleeding,
##    because the aura heals an archer at twice a knight's rate.
##
## 4. A DOWNED ALLY OUTRANKS EVERYTHING. Clear the bodies off him first, then
##    kneel and hold the channel.
##
## 5. HE WALKS INTO THE ARCHER'S LIGHT. A fire burning out in the dark is not
##    scenery — it is the archer saying "look here", and the paladin is the one
##    with the eyes to go and look. With nothing known he advances beacon to
##    beacon rather than wandering, and when the party has LOST something he
##    walks down the lead: the ground where it went dark, widening as the trail
##    cools. Between them that is a search, which is the only way anything gets
##    found on a night field.

const MELEE_RANGE := 2.4
const PEEL_RANGE := 26.0       # how far he will run to pull something off an ally
const REGROUP_DIST := 32.0     # idle drift back toward the party
const INVESTIGATE_TIME := 5.0
const SPELL_COOLDOWN := 24.0
const LIGHT_FIGHT_RANGE := 26.0  # a fire this close is worth backing into
## The parry window opens 0.05 s after the button and shuts at 0.38 s
## (Player.PARRY_WINDOW_START/END); these are the ETAs that land inside it.
const PARRY_OPEN := 0.10
const PARRY_SHUT := 0.34
const PARRY_STAMINA := 0.15
## Stop swinging this long before a blow lands, so the hands are free to
## parry it. Wide enough to cover the parry window (0.10-0.34 s) plus the
## fraction of a second it takes a click to become a raised shield.
const PARRY_HOLD_ETA := 0.55

var _spell_cd := 6.0
var _rite_left := 0.0          # seconds left in a rite attempt before giving up
var _attack_timer := 0.0
var _combo_left := 0
var _click_gap := 0.0
var _investigate_left := 0.0
var _target_id := 0            # who "brawl"/"peel" settled on, for stability
var _chase_prev := INF         # last frame's distance to the thing we are chasing
var _chase_stall := 0.0        # ...and how long that distance has refused to shrink
var _giveup_left := 0.0        # cooling-off after abandoning an uncatchable runner
var _checked: Array = []       # beacons already walked to (Vector3), newest last
var _sweep_goal := Vector3.ZERO
var _sweep_left := 0.0         # how long to keep walking at the current goal
## The search pattern. A random wander re-walks the same ground and misses the
## rest; an outward spiral covers it once, in rings, from wherever the party
## started looking.
const SPIRAL_R0 := 26.0        # the first ring
const SPIRAL_GROWTH := 34.0    # metres added per full turn
const SPIRAL_ARC := 22.0       # ...and how far along the ring each leg goes
const SPIRAL_MAX_R := 150.0    # past this the pattern restarts where he stands
var _spiral_centre := Vector3.ZERO
var _spiral_theta := 0.0


func _init() -> void:
	role_name = "paladin"


# ------------------------------------------------------- the shield and feet --

## THE PARRY IS THE PALADIN'S ANSWER, and it is his alone: a timed shield flick
## cancels the hit outright and opens the riposte, where a roll only avoids it
## and a block still chips. He is the only class holding the shield that can do
## it, so the timing lives here rather than in the shared base.
func special_defence(eta: float) -> bool:
	if eta < PARRY_OPEN or eta > PARRY_SHUT:
		return false
	if int(body.combat_mode) != int(Player.CombatMode.ARMED) \
			or stamina() <= PARRY_STAMINA or not body.has_method("_try_parry"):
		return false
	body._try_parry()
	# The game can still refuse it (mid-swing, mid-roll, stunned, airborne).
	# Reporting a refusal as a parry would spend the defence cooldown on
	# nothing AND skip the roll that was the fallback — so ask the body what
	# actually happened rather than assuming the button worked.
	return body.is_parrying


## A blow he can still parry is not a blow to roll away from. The parry cancels
## it outright and opens the riposte; the roll only avoids it and gives up the
## ground. So between 0.34 s and 0.55 s out he stands his ground and waits for
## the window — provided the parry is actually available when it opens.
func hold_for_special(eta: float) -> bool:
	if eta <= PARRY_SHUT or eta > PARRY_HOLD_ETA:
		return false
	return int(body.combat_mode) == int(Player.CombatMode.ARMED) \
			and stamina() > PARRY_STAMINA and not body.is_attacking \
			and body.has_method("_try_parry")


## He rolls THROUGH the swing rather than out of the fight: he comes up beside
## the enemy, still in reach, still able to punish. Backing off would hand a
## fleeing boss the distance he needs to start regenerating.
func roll_dir(away: Vector3) -> Vector3:
	return away.cross(Vector3.UP).normalized() * (1.0 if randf() < 0.5 else -1.0)


func choose_tactic() -> String:
	var mate := brain.neediest_ally(body)
	var threat := brain.threat_on(body)
	var threat_dist: float = threat.pos.distance_to(pos()) if threat != null else INF

	# A body on the ground beats every other consideration in the game.
	if mate != null and mate.is_dead:
		return "revive"

	var scores := {"patrol": 5.0}

	if _retreating:
		scores["fallback"] = 60.0 + (30.0 if threat_dist < 14.0 else 0.0)

	var focus := brain.focus
	if focus != null and focus.confidence(brain.now) > 0.35:
		var d: float = focus.pos.distance_to(pos())
		# A boss below 22% HP FLEES, and he is faster than a chase. Running him
		# across the map alone hands him his 3%/s regeneration and drags the
		# paladin out of the party's light — so once the gap stops closing,
		# let him go and rejoin the archer, who can still reach him.
		if _giveup_left <= 0.0 or d < 8.0:
			scores["brawl"] = 40.0 + focus.threat * 6.0 - d * 0.25

	# PEEL: something is hunting the other member of the party.
	if mate != null and not mate.is_dead:
		var mate_threat := brain.threat_on(mate.node)
		if mate_threat != null and mate_threat.confidence(brain.now) > 0.25:
			var d: float = mate_threat.pos.distance_to(pos())
			if d < PEEL_RANGE and (_giveup_left <= 0.0 or d < 8.0):
				# Worth more when the ally is fragile and being closed on, and
				# more still when the ally is the archer, who cannot trade.
				var urgency: float = 1.0 + (1.0 - mate.hp_frac) * 1.5
				if not mate.is_paladin:
					urgency += 0.4
				scores["peel"] = (52.0 + 12.0 * float(mate.pressure)) * urgency - d * 0.4

	# THE RITE. Worth the disengage only when someone is actually hurt, and
	# worth twice as much when that someone is the archer.
	if _spell_cd <= 0.0 and body.has_method("_do_spell_cast"):
		var worst_missing: float = 1.0 - hp_frac()
		var bonus := 0.0
		if mate != null and not mate.is_dead and (1.0 - mate.hp_frac) > worst_missing:
			worst_missing = 1.0 - mate.hp_frac
			bonus = 25.0 if not mate.is_paladin else 10.0
		if worst_missing > 0.35:
			scores["rite"] = 30.0 + worst_missing * 70.0 + bonus

	# A contact that has gone dark is still a lead worth walking down.
	if focus != null and focus.confidence(brain.now) <= 0.35 \
			and focus.confidence(brain.now) > 0.0:
		scores["hunt"] = 25.0

	# THE SEARCH. Nothing is known, so the party goes and finds it instead of
	# waiting to be found: down the trail if there is one, otherwise beacon to
	# beacon through the archer's light and outward on the spiral. Must clear
	# patrol's 5 + 8 commitment.
	if not brain.blind():
		_spiral_centre = Vector3.ZERO   # found something — the pattern is done
	if brain.blind() and _giveup_left <= 0.0:
		var sweep := 20.0
		if brain.best_lead() != null:
			sweep += 6.0
		scores["sweep"] = sweep

	# Drift back to the party when the leash stretches. This has to CLEAR the
	# commitment bonus below (patrol 5 + 8 = 13) or a patrol once started could
	# never be interrupted by anything short of an enemy — the two bots would
	# wander the map separately all night, which is exactly what happened.
	if mate != null and not mate.is_dead:
		var mate_d: float = pos().distance_to(mate.anchor)
		if mate_d > REGROUP_DIST:
			scores["regroup"] = 15.0 + minf((mate_d - REGROUP_DIST) * 0.3, 10.0)

	# The rite is the same kind of commitment: he has already walked out of the
	# fight for it, and turning round half-way spends the disengage for nothing.
	if tactic == "rite" and _rite_left > 0.0 and _spell_cd <= 0.0:
		scores["rite"] = maxf(float(scores.get("rite", 0.0)), 85.0)

	# Commitment: the current plan gets a head start, so the paladin does not
	# flicker between two tactics that score within a hair of each other.
	if scores.has(tactic):
		scores[tactic] += 8.0
	var best := "patrol"
	var best_score := -INF
	for key in scores:
		if float(scores[key]) > best_score:
			best_score = float(scores[key])
			best = key
	return best


func run_tactic(delta: float) -> void:
	_spell_cd -= delta
	_attack_timer -= delta
	_click_gap -= delta
	_giveup_left -= delta
	var mate := brain.neediest_ally(body)

	if tactic != "revive":
		body._ai_revive_intent = false
		body._ai_crouch = false

	match tactic:
		"revive":
			_revive(mate, delta)
		"fallback":
			_fall_back()
		"peel":
			var mate_threat: SquadBrain.Contact = brain.threat_on(mate.node) \
					if mate != null and not mate.is_dead else null
			if mate_threat == null:
				_brawl(brain.focus, delta)
			else:
				_brawl(mate_threat, delta)
		"brawl":
			_brawl(brain.focus, delta)
		"rite":
			_rite(mate, delta)
		"hunt":
			_hunt(brain.focus, delta)
		"regroup":
			if mate != null:
				go_to(mate.anchor, 4.0, 12.0)
			else:
				explore(delta)
		"sweep":
			_sweep(delta)
		_:
			explore(delta)


# ------------------------------------------------------------------ tactics --

## Melee on one contact. Defence first — a swing landing on us this frame is
## worth more than a swing we might land.
func _brawl(c: SquadBrain.Contact, delta: float) -> void:
	if c == null or not c.alive():
		explore(delta)
		return
	if defend():
		return
	_target_id = c.node.get_instance_id()
	var target: Vector3 = c.pos
	var to_target: Vector3 = target - pos()
	to_target.y = 0.0
	var dist := to_target.length()
	aim_at(target)

	# FIGHT IN THE LIGHT: it is coming for us anyway, so meet it where we can
	# see it. Only while it is still closing — once it is on us, giving ground
	# just means being hit in the back.
	if dist > 6.0 and not c.lit and c.hunting == body:
		var fire_d := brain.fire_dist(pos())
		if fire_d < LIGHT_FIGHT_RANGE and fire_d > 5.0:
			# Stand in the GLOW, not on the coals — inside 5 m of a fire Bobba
			# panics and will not close, and a boss who refuses the fight just
			# regenerates 3% a second while the party chases him.
			var cover := escape_dir(target, _nearest_fire_pos(), true, 9.0)
			if cover.length_squared() > 0.01:
				move_world(cover, dist > 12.0)
				return

	if dist > MELEE_RANGE:
		# Is this chase getting anywhere? A gap that has not shrunk in six
		# seconds is a runner, not a fight.
		if dist > 6.0:
			_chase_stall += delta if dist > _chase_prev - 0.2 else -_chase_stall
			_chase_prev = dist
			if _chase_stall > 6.0:
				_chase_stall = 0.0
				_giveup_left = 12.0
				print("CompanionAI[paladin]: he is outrunning me — back to the party")
		else:
			_chase_stall = 0.0
			_chase_prev = INF
		move_world(to_target.normalized(), dist > 8.0)
		_combo_left = 0
		return

	_chase_stall = 0.0
	_chase_prev = INF
	stop()
	# HOLD THE SWING WHEN A BLOW IS COMING. _try_parry is refused outright
	# while is_attacking, and a paladin combo is up to 2.7 s long — so a swing
	# started here is precisely why the parry window never arrives. Measured:
	# zero parries in a 112 s live fight. Keeping his hands free for the last
	# half-second before contact is what gives him back the only defence in
	# the game that cancels a hit outright.
	var incoming: float = float(soonest_strike()["eta"])
	if incoming < PARRY_HOLD_ETA:
		guard(true)          # shield up meanwhile; a block only chips
		_combo_left = 0      # and drop the rest of the chain, not just this click
		return
	# The 3-hit chain: fast consecutive clicks bank combo steps (player.gd's
	# COMBO_CLICK_WINDOW), then a breather so stamina and poise recover.
	if _combo_left > 0:
		if _click_gap <= 0.0:
			body._do_attack()
			_combo_left -= 1
			_click_gap = 0.32
	elif _attack_timer <= 0.0 and stamina() > 0.25 and incoming == INF:
		# SWING IN HIS RECOVERY, NOT INTO HIS SWING. A paladin combo runs up to
		# 2.7 s and _try_parry is refused for every frame of it, so a chain
		# opened while the boss is already winding up costs the parry AND eats
		# the hit. `incoming == INF` means nothing is mid-swing at us right
		# now — the punish window, which is when a player attacks a boss too.
		_combo_left = 3
		_click_gap = 0.0
		_attack_timer = randf_range(2.0, 3.0)


## Break contact along a scored route, drinking once there is room. Fires are
## COVER on this route, not obstacles: nothing hostile follows us into them.
func _fall_back() -> void:
	guard(true)
	var threat := brain.threat_on(body)
	if threat == null:
		threat = brain.focus
	var mate := brain.neediest_ally(body)
	var toward: Vector3 = mate.anchor if mate != null else pos()
	var from: Vector3 = threat.pos if threat != null else pos() - Vector3.FORWARD * 10.0
	var threat_dist: float = from.distance_to(pos()) if threat != null else INF
	if threat_dist > ESTUS_SAFE_DIST:
		stop()
		drink_if_safe(threat_dist)
		return
	var dir := escape_dir(from, toward, true)
	if dir.length_squared() > 0.01:
		aim_at(pos() + dir * 10.0)
		move_world(dir, true)


## The heal rite: a plan, not a button. Walk out of the fight, get inside the
## 3 m aura of whoever is bleeding, then channel — and abandon the attempt if
## the fight follows us, rather than standing there being interrupted forever.
func _rite(mate: SquadBrain.Ally, delta: float) -> void:
	if tactic_age < delta * 2.0:
		_rite_left = 6.0
	_rite_left -= delta
	guard(false)
	var spot: Vector3 = pos()
	if mate != null and not mate.is_dead and (1.0 - mate.hp_frac) > (1.0 - hp_frac()):
		spot = mate.pos
	var threat := brain.focus
	var threat_pos: Vector3 = threat.pos if threat != null else pos() + Vector3(999, 0, 999)
	var threat_dist: float = threat_pos.distance_to(pos())

	# The game refuses the rite inside 8 m of anything alive — so put real
	# distance between us and it first, moving toward the ally as we go.
	if threat_dist < 11.0 and threat != null:
		var dir := escape_dir(threat_pos, spot, true)
		if dir.length_squared() > 0.01:
			aim_at(pos() + dir * 10.0)
			move_world(dir, true)
		return
	if pos().distance_to(spot) > 2.5:
		go_to(spot, 2.5, 10.0)
		return
	stop()
	if body.is_casting:
		return
	if _rite_left <= 0.0:
		_spell_cd = 4.0   # short retry — the situation, not the spell, refused
		return
	body._do_spell_cast()
	if body.is_casting:
		_spell_cd = SPELL_COOLDOWN
		print("CompanionAI[paladin]: rite of healing at the ally's side")


## Walk down a cold lead, search the ground, then admit the dark won.
func _hunt(c: SquadBrain.Contact, delta: float) -> void:
	if c == null:
		explore(delta)
		return
	var to_spot: Vector3 = c.pos - pos()
	to_spot.y = 0.0
	if to_spot.length() > 3.0 and _investigate_left <= 0.0:
		aim_at(c.pos)
		move_world(to_spot.normalized(), to_spot.length() > 8.0)
		return
	if _investigate_left <= 0.0:
		_investigate_left = INVESTIGATE_TIME
		print("CompanionAI[paladin]: at the last known position — searching")
	_investigate_left -= delta
	var sweep := Vector3(cos(_investigate_left * 1.3), 0.0, sin(_investigate_left * 1.3))
	aim_at(pos() + sweep * 8.0)
	move_world(sweep, false)


## SEARCH. Two things to walk at, in order:
##
##   THE TRAIL — where the party lost something, pushed along its heading and
##     widening as it cools. This is what stops a boss from breaking contact at
##     20% health, healing 3% a second in the dark, and simply never being
##     found again.
##
##   THE LIGHT — every fire the archer drops out in the dark is a question he
##     cannot answer himself: anything within 18 m of it becomes visible to the
##     whole party, but only if somebody is looking that way. The paladin walks
##     to the beacons he has not checked yet, newest first, and marks them off.
##
## He holds a goal for a few seconds at a time — re-picking one every frame
## turns a search into a shuffle between two fires.
func _sweep(delta: float) -> void:
	_sweep_left -= delta
	if _sweep_left <= 0.0 or _sweep_goal == Vector3.ZERO \
			or pos().distance_to(_sweep_goal) < 5.0:
		if _sweep_goal != Vector3.ZERO and pos().distance_to(_sweep_goal) < 8.0:
			_mark_checked(_sweep_goal)
		_sweep_goal = _pick_sweep_goal()
		# COMMIT TO THE WALK. A fixed 4-7 s leg is fine for stepping between
		# beacons 20 m apart and useless for a trail 120 m away: the timer
		# expired, the goal was recomputed against a boss who had roamed on,
		# and the party spent five minutes re-aiming instead of arriving.
		# Long goals get the time they actually take (~6 m/s), short ones keep
		# the old cadence so a stale beacon is never walked to forever.
		var leg: float = pos().distance_to(_sweep_goal) / 6.0
		_sweep_left = clampf(leg, 4.0, 30.0)
	if _sweep_goal == Vector3.ZERO:
		explore(delta)
		return
	# Sweep the head around while walking: the whole point is to be LOOKING,
	# and in this game facing is what the camera pivot — and so perception —
	# is pointed at.
	var to_goal: Vector3 = _sweep_goal - pos()
	to_goal.y = 0.0
	if to_goal.length() < 2.0:
		_sweep_left = 0.0
		stop()
		return
	aim_at(_sweep_goal)
	move_world(to_goal.normalized(), to_goal.length() > 12.0)


func _pick_sweep_goal() -> Vector3:
	var lead := brain.best_lead()
	if lead != null:
		# A trail — including one a roar opened — beats any pattern.
		_spiral_centre = Vector3.ZERO
		var aim: Vector3 = lead.predict(brain.now)
		# Prefer a fire burning inside the search circle: same search, but done
		# somewhere he can actually see when he gets there.
		var lit := _nearest_unchecked_fire(aim, lead.radius(brain.now) + 12.0)
		return lit if lit != Vector3.ZERO else aim
	var beacon := _nearest_unchecked_fire(pos(), 70.0)
	if beacon != Vector3.ZERO:
		return beacon
	return _spiral_next()


## The next leg of the outward spiral. Radius grows with the angle, and the
## angular step shrinks as it grows, so every leg walks about the same distance
## and no ring is skipped — a field gets covered rather than sampled.
func _spiral_next() -> Vector3:
	if _spiral_centre == Vector3.ZERO:
		_spiral_centre = pos()
		_spiral_theta = randf() * TAU   # start the sweep in a random quarter
		print("CompanionAI[paladin]: nothing known — searching outward from %s" % [
				str(_spiral_centre.snapped(Vector3.ONE))])
	for _attempt in 8:
		var r: float = SPIRAL_R0 + SPIRAL_GROWTH * (_spiral_theta / TAU)
		if r > SPIRAL_MAX_R:
			# The pattern is spent. Start a fresh one from where he stands.
			_spiral_centre = pos()
			_spiral_theta = randf() * TAU
			r = SPIRAL_R0
		var goal: Vector3 = _spiral_centre \
				+ Vector3(cos(_spiral_theta), 0.0, sin(_spiral_theta)) * r
		_spiral_theta += SPIRAL_ARC / maxf(r, 1.0)
		# Stay on the map: skip legs that would walk him off the edge of it.
		if absf(goal.x) < 190.0 and absf(goal.z) < 210.0:
			return goal
	return Vector3.ZERO


## The closest fire to `near` that the paladin has not already walked to.
func _nearest_unchecked_fire(near: Vector3, radius: float) -> Vector3:
	var best := Vector3.ZERO
	var best_d := INF
	for f in brain.fires:
		if near.distance_to(f) > radius:
			continue
		if _is_checked(f):
			continue
		var d: float = pos().distance_to(f)
		if d < best_d:
			best_d = d
			best = f
	return best


func _is_checked(p: Vector3) -> bool:
	for c in _checked:
		if c.distance_to(p) < 8.0:
			return true
	return false


func _mark_checked(p: Vector3) -> void:
	if _is_checked(p):
		return
	_checked.append(p)
	if _checked.size() > 16:
		_checked.remove_at(0)


## Clear the bodies off the fallen ally, then kneel and hold the channel.
func _revive(mate: SquadBrain.Ally, delta: float) -> void:
	if mate == null:
		explore(delta)
		return
	var threat := brain.focus
	if threat != null and threat.pos.distance_to(mate.pos) < 12.0 \
			and threat.confidence(brain.now) > 0.3:
		body._ai_revive_intent = false
		body._ai_crouch = false
		_brawl(threat, delta)
		return
	if go_to(mate.pos, 2.2, 8.0):
		aim_at(mate.pos)
		body._ai_revive_intent = true
		body._ai_crouch = true   # braced kneel while channelling
	else:
		body._ai_revive_intent = false
		body._ai_crouch = false


func _nearest_fire_pos() -> Vector3:
	var best := pos()
	var best_d := INF
	for f in brain.fires:
		var d: float = pos().distance_to(f)
		if d < best_d:
			best_d = d
			best = f
	return best
