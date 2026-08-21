class_name ArcherRole
extends AIRole

## THE AI ARCHER — the party's LANTERN.
##
## In a rainy black field where an AI can read a silhouette at eight metres and
## a fire-lit body at ninety (Perception), the archer is not "the ranged DPS".
## He is the reason the paladin can find anything at all. Every arrow he looses
## is a decision about WHERE THE PARTY CAN SEE, and damage is the side effect.
##
## What makes him a teammate rather than a turret:
##
## 1. HE SHOOTS WHERE THE PARTY IS BLIND, not where he personally is annoyed.
##    The brain keeps a ranked queue of illumination requests — anything known
##    and unlit near an ally, topped by whatever is currently hitting one — and
##    he serves it. A punch out of the dark posts a bearing; his arrow turns
##    that bearing into a target the whole party can fight.
##
## 1b. AND WHEN NOTHING IS KNOWN AT ALL, HE GOES LOOKING. This is the half that
##    makes him the party's eyes rather than its floodlight operator: with no
##    contact anywhere, he COMBS the dark — fire ahead of the party's advance,
##    fanned across their heading, and around the search circle of whatever
##    they last lost. Anything standing within 18 m of a fire is visible to the
##    whole party from ninety metres away (Perception), so each arrow is a
##    question asked of a patch of field, and the comb makes sure the questions
##    do not all get asked about the same patch. Waiting for an enemy to
##    announce itself before lighting anything is how two bots spend a night
##    walking around an empty map with a boss healing somewhere in the dark.
##
## 2. HE AIMS THE FIRE, NOT THE ARROW. Fire does two opposite things to the
##    enemies in this game: it REVEALS them (18 m of reveal radius) and it
##    SCARES them (Bobba panics inside 2.5 m and aborts his swing, skeletons
##    steer 7 m clear and burn). So when an ally is in trouble the fire goes ON
##    the enemy — burn it, blind-side it, drive it off him — and when the
##    paladin is winning it goes BESIDE the enemy instead, close enough to
##    light it, far enough not to chase it out of the paladin's reach.
##
## 3. HE PLANTS HIS FEET, AND HE SOLVES THE ARC. A loose taken while moving
##    leaves at half force (Arrow.shot_power) — a quarter of the range — so the
##    illumination lands short and the paladin stays blind. He stops, lets his
##    stance settle, and fires on a real ballistic solution
##    ([[arrow_dir_to]], below).
##
## 3b. HE TAKES THE HIGH GROUND TO SEARCH FROM. A fire arrow is a thrown
##    object: from a rise, the same loose travels further, because the ground
##    it is falling toward is lower than the bow (the arc solver already knows
##    this — `arrow_dir_to` takes the height difference). So when the party is
##    blind he walks to a local high point and combs the dark from up there,
##    which lights more field per arrow and keeps him out of arm's reach while
##    he does it. He moves along the ridge every so often rather than perching
##    forever, because the point is to see NEW ground.
##
## 4. HE STANDS OUTSIDE HIS OWN LIGHT. Anything lit is visible across the field
##    to every AI in the game, himself included. So he holds station in the
##    dark behind the paladin — the enemy between them, the paladin between him
##    and the enemy — and steps into the light only to save someone.
##
## 5. HE HOLDS HIS SHOT WHEN THE PALADIN HAS IT PINNED. There is no plain
##    arrow in this game: every landed shot lights a thirty-second fire at the
##    point of impact, and fire MOVES enemies — Bobba aborts his swing and
##    bolts inside 2.5 m, skeletons steer 7 m clear. That is a rescue when the
##    paladin is losing and sabotage when he is winning, because a boss shoved
##    out of reach heals 3% of his health a second while the party chases him.
##    So the archer shoots what his ally is NOT holding, keeps one fire on the
##    fight for light, and otherwise waits — which is also why a co-op field
##    does not end up carrying twenty shadow-casting fire lights.
##
## 6. THE FIRE CIRCLE IS A RESCUE, NOT A ROTATION. His spell buffs a knight
##    within ~3.75 m and lays a burning ring for 4 s. Both halves say the same
##    thing: use it when the paladin is being swarmed. It buys him a damage
##    buff and clears the bodies off him at the same time — and it costs the
##    archer his darkness for those seconds, which is why it is not spammed.

const KITE_DIST := 16.0        # preferred distance from a live threat
const SLOT_BEHIND := 7.0       # station-keeping distance behind the anchor
const TETHER := 30.0           # loose leash to the rest of the party
const SPELL_COOLDOWN := 22.0
const SWARM_PRESSURE := 2      # enemies on the paladin that count as "swarmed"
const PLANT_TIMEOUT := 0.7     # give up waiting for a perfect stance
const PINNED_RANGE := 6.0      # the ally is in contact with it — do not scatter it
const FIRE_BUDGET := 8         # burning at once before only urgent shots are taken
const LIT_ENOUGH := 14.0       # ground with a fire this close needs no more
const SWEEP_NEAR := 20.0       # closest a search arrow is thrown
const SWEEP_FAR := 34.0        # ...and furthest, ahead of the party's advance
const SWEEP_FAN := deg_to_rad(42.0)   # half-angle of the comb across the heading
const GOLDEN := 2.39996        # radians per step: fills a disc without repeating
const ARROW_SPEED := 50.0      # = Arrow.ARROW_SPEED, for the firing solution
const VANTAGE_MIN_R := 14.0    # how far he will walk for a better view
const VANTAGE_MAX_R := 26.0
const VANTAGE_SAMPLES := 10    # candidate points probed per look-around
const VANTAGE_MIN_GAIN := 2.5  # metres of height that make the walk worth it
const VANTAGE_HOLD := 14.0     # ...then move along the ridge for new ground
const VANTAGE_REACH_BONUS := 2.0  # extra throw distance per metre of height

var _spell_cd := 8.0
var _arrow_cd := 2.0
var _shot_point := Vector3.ZERO
var _shot_pending := false
var _plant_time := 0.0
var _last_shot_kind := ""
var _pull_time := 0.0
var _comb_step := 0            # which tooth of the comb the next arrow is
var _vantage := Vector3.ZERO   # the rise he is shooting the search from
var _vantage_gain := 0.0       # how much higher it is than where he found it
var _vantage_left := 0.0


func _init() -> void:
	role_name = "archer"


func choose_tactic() -> String:
	var mate := brain.neediest_ally(body)
	var threat := brain.threat_on(body)
	var threat_dist: float = threat.pos.distance_to(pos()) if threat != null else INF

	if mate != null and mate.is_dead:
		return "revive"

	var scores := {"scout": 6.0}

	if _retreating or threat_dist < KITE_DIST * 0.75:
		scores["fallback"] = 55.0 + (25.0 if threat_dist < 8.0 else 0.0)

	# The queue of dark places the party needs lit. This is the archer's
	# reason to exist, so it outbids ordinary shooting whenever it is not empty.
	var req := _top_request()
	if not req.is_empty():
		scores["illuminate"] = 45.0 + float(req["priority"]) * 12.0

	var shootable := _suppress_target(mate)
	if shootable != null:
		scores["suppress"] = 38.0 + shootable.threat * 4.0

	# The rescue ring: the paladin is swarmed or bleeding, and we can reach him.
	if _spell_cd <= 0.0 and mate != null and not mate.is_dead and mate.is_paladin \
			and body.has_method("_do_spell_cast"):
		var d: float = pos().distance_to(mate.pos)
		var swarmed: bool = mate.pressure >= SWARM_PRESSURE or mate.hp_frac < 0.65
		if swarmed and d < 22.0 and mate.threat_dist < 8.0:
			scores["buff_run"] = 60.0 + float(mate.pressure) * 8.0 \
					+ (1.0 - mate.hp_frac) * 30.0 - d

	# Cover an ally who is running: fire dropped between him and his pursuer is
	# a wall neither Bobba nor a skeleton will cross.
	if mate != null and not mate.is_dead and mate.hp_frac < 0.4 and mate.pressure > 0:
		scores["cover"] = 44.0

	if mate != null and not mate.is_dead:
		var d: float = pos().distance_to(mate.anchor)
		if d > TETHER:
			scores["scout"] = 20.0 + (d - TETHER) * 0.5
		else:
			scores["kite"] = 20.0

	# NOTHING IS KNOWN. Standing in the dark beside the paladin waiting for
	# something to hit one of them is not a plan — it is the absence of one.
	# Light the field and go and find it. This has to clear station-keeping
	# plus its commitment bonus (20 + 8), or the archer never starts looking.
	if brain.blind() and not _retreating:
		var sweep := 30.0
		var lead := brain.best_lead()
		if lead != null:
			# A trail we can still follow beats combing open ground, and the
			# colder it gets the more urgent it is to look before it is gone.
			sweep += 8.0 if lead.boss else 4.0
		scores["sweep"] = sweep

	# A buff run is a COMMITTED manoeuvre, not a preference. Half-way in is the
	# worst place on the field to change your mind: inside the enemy's reach,
	# out of the dark, with nothing cast. Once it starts it finishes, unless
	# the reason for it (a living knight, a ready spell, our own legs) is gone.
	if tactic == "buff_run" and _spell_cd <= 0.0 and not _retreating \
			and mate != null and not mate.is_dead and hp_frac() > 0.3:
		scores["buff_run"] = maxf(float(scores.get("buff_run", 0.0)), 88.0)
	if scores.has(tactic):
		scores[tactic] += 8.0
	var best := "scout"
	var best_score := -INF
	for key in scores:
		if float(scores[key]) > best_score:
			best_score = float(scores[key])
			best = key
	return best


func run_tactic(delta: float) -> void:
	_spell_cd -= delta
	_arrow_cd -= delta
	var mate := brain.neediest_ally(body)

	if tactic != "revive":
		body._ai_revive_intent = false
		body._ai_crouch = false

	# Something about to land on us beats any shot we were about to take — and
	# it SPOILS that shot: an archer who rolls does not also loose cleanly.
	if defend():
		_shot_pending = false
		return
	# Otherwise a shot already ordered finishes first: the whole point of
	# planting is that nothing jogs the bow between the decision and the loose.
	if _serve_shot(delta):
		return

	match tactic:
		"revive":
			_revive(mate, delta)
		"fallback":
			_fall_back(mate)
		"illuminate":
			_illuminate(mate, delta)
		"suppress":
			_suppress(mate, delta)
		"buff_run":
			_buff_run(mate, delta)
		"cover":
			_cover(mate, delta)
		"kite":
			_hold_station(mate)
		"sweep":
			_sweep(mate, delta)
		_:
			_scout(mate, delta)


# ------------------------------------------------------------------ shooting --

## Order a shot. It is not loosed this frame: the archer stops, lets the
## stance settle (a moving loose is half force) and fires from _serve_shot.
func _order_shot(point: Vector3, cadence: float, kind: String) -> void:
	if _arrow_cd > 0.0 or _shot_pending:
		return
	_shot_point = point
	_shot_pending = true
	_plant_time = 0.0
	_arrow_cd = cadence
	_last_shot_kind = kind


## Returns true while the archer is committed to a shot.
func _serve_shot(delta: float) -> bool:
	if not _shot_pending:
		return false
	stop()
	var dir := arrow_dir_to(_shot_point)
	aim_at(_shot_point, asin(clampf(dir.y, -1.0, 1.0)))
	_plant_time += delta
	var settled: bool = Vector2(body.velocity.x, body.velocity.z).length() < 1.0
	if settled or _plant_time > PLANT_TIMEOUT:
		_shot_pending = false
		if body.has_method("_shoot_arrow"):
			body._shoot_arrow(dir)
			print("CompanionAI[archer]: %s shot at %s (%.0fm)" % [
					_last_shot_kind, str(_shot_point.snapped(Vector3.ONE)),
					pos().distance_to(_shot_point)])
	return true


## Would this arrow HELP? The fire it lights is the question, not the 35 damage.
##
## It helps when the party cannot see the thing, when the thing is chasing
## someone, or when nobody is holding it in place. It hurts when the paladin
## already has it lit and pinned in melee: dropping fire at its feet ends his
## fight, and the boss walks away and heals.
func _shot_would_help(c: SquadBrain.Contact, mate: SquadBrain.Ally) -> bool:
	if c == null or not c.alive():
		return false
	if not c.lit:
		return true          # it is dark: light beats everything
	if mate != null and not mate.is_dead and mate.is_paladin \
			and mate.pos.distance_to(c.pos) < PINNED_RANGE:
		return false         # he has it — do not shove it off him
	if c.hunting != null:
		return true          # it is hurting one of us: burn it and drive it off
	# Lit, unengaged, and the field is already alight — an extra fire buys the
	# party nothing it does not already have. Save the arrow.
	return brain.fires.size() < FIRE_BUDGET


## The best thing to put an arrow into right now, or null if the right move is
## to hold. Deliberately not always the focus: the focus is often exactly the
## enemy the paladin is holding.
func _suppress_target(mate: SquadBrain.Ally) -> SquadBrain.Contact:
	var best: SquadBrain.Contact = null
	for c in brain.contacts:
		if not c.alive() or not c.seen_now or c.confidence(brain.now) < 0.6:
			continue
		if c.pos.distance_to(pos()) > 60.0:
			continue
		if not _shot_would_help(c, mate):
			continue
		if best == null or c.threat > best.threat:
			best = c
	return best


func _top_request() -> Dictionary:
	for r in brain.light_requests:
		var p: Vector3 = r["pos"]
		# Do not spend an arrow on ground that is already burning, and do not
		# throw one past the horizon.
		if brain.fire_dist(p) < Perception.FIRE_REVEAL_RADIUS:
			continue
		if pos().distance_to(p) > arrow_max_range() * 0.9:
			continue
		# A field can only carry so much fire before the light stops meaning
		# anything (and starts costing frames). Past the budget, only the
		# requests that are actually about someone getting hurt get served.
		if brain.fires.size() >= FIRE_BUDGET and float(r["priority"]) < 2.5:
			continue
		# Never ring a fallen ally with fire: enemies avoid it, and one that
		# cannot walk away from the body cannot be pulled off it either.
		var down := _downed_ally()
		if down != null and down.pos.distance_to(p) < 14.0 \
				and brain.fires_near(down.pos, 14.0) > 0:
			continue
		return r
	return {}


# ------------------------------------------------------------------ tactics --

## Put fire where the party cannot see. The choice of AIM POINT is the tactic:
## on the enemy when an ally needs it driven off, beside it when the paladin
## wants it to stay and fight in the light.
func _illuminate(mate: SquadBrain.Ally, delta: float) -> void:
	var req := _top_request()
	if req.is_empty():
		_hold_station(mate)
		return
	var c: SquadBrain.Contact = req["contact"]
	var enemy_pos: Vector3 = req["pos"]
	# ON or BESIDE — the whole judgement. Fire at an enemy's feet drives it
	# off; that is a RESCUE when someone is losing and sabotage when the
	# paladin is mid-combo on it. So "in danger" means losing, not fighting:
	# it is coming for the archer himself, or it is on an ally who is hurt,
	# outnumbered, or already down.
	var in_danger: bool = c.hunting == body
	if mate != null and not mate.is_dead and c.hunting == mate.node \
			and (mate.hp_frac < 0.45 or mate.pressure >= 2 or not mate.is_paladin):
		in_danger = true
	if mate != null and mate.is_dead and c.hunting == mate.node:
		in_danger = true
	var aim_point := enemy_pos
	if not in_danger:
		# Light it without chasing it out of the fight: 8 m to the far side
		# leaves the enemy well inside the 18 m reveal but outside the radius
		# it will flee from.
		var away := Vector3.FORWARD
		if mate != null:
			away = enemy_pos - mate.pos
		else:
			away = enemy_pos - pos()
		away.y = 0.0
		if away.length_squared() > 0.01:
			aim_point = enemy_pos + away.normalized() * 8.0
	_hold_station(mate)
	# A ground fire burns for thirty seconds. Relighting the same fight every
	# two seconds does not make it brighter — it makes a bonfire field and a
	# boss that never stands still.
	var cadence: float = randf_range(2.2, 3.2) if float(req["priority"]) >= 2.5 \
			else randf_range(5.0, 7.5)
	_order_shot(aim_point + Vector3(0, 0.2, 0), cadence,
			"illuminate-on" if in_danger else "illuminate-beside")


## Damage on a target the party can already see. Led by the arrow's flight
## time, because a walking Bobba covers three metres while it is in the air.
func _suppress(mate: SquadBrain.Ally, _delta: float) -> void:
	var c := _suppress_target(mate)
	if c == null or not c.alive():
		_hold_station(mate)
		return
	var target: Vector3 = c.node.global_position + Vector3(0, 1.0, 0)
	var flight: float = pos().distance_to(target) / ARROW_SPEED
	if "velocity" in c.node:
		var v: Vector3 = c.node.velocity
		v.y = 0.0
		target += v * flight
	_hold_station(mate)
	_order_shot(target, randf_range(1.8, 2.6), "suppress")


## Run in, lay the ring, hold it while it burns. Costs the archer his darkness
## for four seconds — which is the price of pulling three skeletons off the
## paladin at once.
func _buff_run(mate: SquadBrain.Ally, delta: float) -> void:
	if mate == null or mate.is_dead:
		_scout(mate, delta)
		return
	if body.is_casting:
		stop()
		aim_at(mate.pos)
		return
	if go_to(mate.pos, 3.0, 10.0):
		aim_at(mate.pos)
		body._do_spell_cast()
		if body.is_casting:
			_spell_cd = SPELL_COOLDOWN
			print("CompanionAI[archer]: fire circle on the paladin — buff + burn ring")
		else:
			_spell_cd = 3.0   # refused (mid-draw, cooldown) — try again shortly


## A burning wall between a fleeing ally and whatever is chasing him.
func _cover(mate: SquadBrain.Ally, delta: float) -> void:
	if mate == null or mate.is_dead:
		_scout(mate, delta)
		return
	var chaser := brain.threat_on(mate.node)
	if chaser == null:
		_hold_station(mate)
		return
	var to_chaser: Vector3 = chaser.pos - mate.pos
	to_chaser.y = 0.0
	if to_chaser.length() < 1.0:
		_hold_station(mate)
		return
	var wall: Vector3 = mate.pos + to_chaser.normalized() * clampf(to_chaser.length() * 0.5, 3.0, 7.0)
	_hold_station(mate)
	_order_shot(wall, randf_range(2.5, 3.5), "cover-wall")


## THE SEARCH LIGHT. No contact anywhere, so the archer stops waiting and goes
## looking: he keeps station with the paladin and combs the dark ahead of them
## with fire. Each arrow asks "is it here?" of one patch of field — anything
## within 18 m of the fire it lights is visible to the whole party from ninety
## metres — and the comb makes sure two arrows never ask about the same patch.
func _sweep(mate: SquadBrain.Ally, delta: float) -> void:
	# Move like the lantern-bearer he is: to the highest thing near the party,
	# and out of his own light once he is on it.
	_update_vantage(delta, mate)
	var perched: bool = _vantage != Vector3.ZERO and pos().distance_to(_vantage) < 3.0
	if mate != null and not mate.is_dead and pos().distance_to(mate.anchor) > TETHER * 1.6:
		# The hill is not worth losing the party over.
		_vantage = Vector3.ZERO
		go_to(mate.anchor, TETHER * 0.6, 14.0)
	elif _vantage != Vector3.ZERO and not perched:
		go_to(_vantage, 2.5, 10.0)
	elif mate != null and not mate.is_dead:
		_hold_station(mate)
	else:
		explore(delta)
	if _arrow_cd > 0.0 or brain.fires.size() >= FIRE_BUDGET:
		return
	var point := _search_point(mate, _vantage_gain if perched else 0.0)
	if point == Vector3.ZERO:
		# Everything in reach is already burning: nothing here, walk on.
		_arrow_cd = 1.5
		return
	# Fast cadence — a dark field is a problem the party cannot solve any other
	# way, and every fire burns for thirty seconds regardless.
	_order_shot(point + Vector3(0, 0.2, 0), randf_range(2.0, 3.0),
			"search" if brain.best_lead() == null else "search-trail")


## Look around for higher ground, every VANTAGE_HOLD seconds: ten candidate
## points on a ring, ground-probed, best rise wins. Ten raycasts every fourteen
## seconds is nothing next to what it buys — from a rise the same loose lands
## further out, so each arrow asks its question of more field.
func _update_vantage(delta: float, mate: SquadBrain.Ally) -> void:
	_vantage_left -= delta
	if _vantage != Vector3.ZERO and _vantage_left > 0.0:
		return
	_vantage_left = VANTAGE_HOLD
	_vantage = Vector3.ZERO
	_vantage_gain = 0.0
	var here: float = _ground_at(pos().x, pos().z)
	if here < -9000.0:
		return
	var radius: float = randf_range(VANTAGE_MIN_R, VANTAGE_MAX_R)
	var spin: float = randf() * TAU
	for i in VANTAGE_SAMPLES:
		var ang: float = spin + TAU * float(i) / float(VANTAGE_SAMPLES)
		var x: float = pos().x + cos(ang) * radius
		var z: float = pos().z + sin(ang) * radius
		var y: float = _ground_at(x, z)
		if y < -9000.0:
			continue
		var gain: float = y - here
		if gain < VANTAGE_MIN_GAIN or gain <= _vantage_gain:
			continue
		var spot := Vector3(x, y + 0.4, z)
		# A vantage inside his own firelight is a lit archer on a hill.
		if brain.lit_amount(spot) > 0.0:
			continue
		if mate != null and not mate.is_dead and spot.distance_to(mate.anchor) > TETHER * 1.5:
			continue
		_vantage = spot
		_vantage_gain = gain
	if _vantage != Vector3.ZERO:
		print("CompanionAI[archer]: taking the high ground at %s (+%.0fm, %.0fm away)" % [
				str(_vantage.snapped(Vector3.ONE)), _vantage_gain, pos().distance_to(_vantage)])


## Terrain height under a world x/z, or -9999 where there is no ground.
func _ground_at(x: float, z: float) -> float:
	var world := body.get_world_3d()
	if world == null:
		return -9999.0
	var space: PhysicsDirectSpaceState3D = world.direct_space_state
	if space == null:
		return -9999.0
	var query := PhysicsRayQueryParameters3D.create(
			Vector3(x, pos().y + 50.0, z), Vector3(x, pos().y - 40.0, z), 1)
	var hit: Dictionary = space.intersect_ray(query)
	return float(hit["position"].y) if hit.has("position") else -9999.0


## The next tooth of the comb, or ZERO when the ground in reach is already lit.
##
## Two patterns, because there are two kinds of "we cannot see anything":
##
##   TRAIL — we lost something specific. Its search circle is a disc centred on
##     where it probably walked to, widening as the trail cools, and the arrows
##     spiral out through it on the golden angle so the disc fills evenly
##     instead of the same arc being relit forever.
##
##   OPEN  — we never had anything. Then the useful ground is what the party is
##     WALKING INTO: a fan across their heading, thrown far enough ahead that
##     the light arrives before they do.
func _search_point(mate: SquadBrain.Ally, height_gain: float = 0.0) -> Vector3:
	var lead := brain.best_lead()
	for attempt in 6:
		var step := _comb_step
		_comb_step += 1
		var candidate: Vector3
		if lead != null:
			var centre: Vector3 = lead.predict(brain.now)
			if step % 5 == 0:
				candidate = centre     # the middle of the circle, first of every five
			else:
				var r: float = lead.radius(brain.now) * (0.45 + 0.5 * float(step % 3) / 2.0)
				var ang: float = GOLDEN * float(step)
				candidate = centre + Vector3(cos(ang), 0.0, sin(ang)) * r
			if lead.dir.length_squared() > 0.01 and step % 5 == 1:
				# Bias one tooth in five down the direction he was running.
				candidate = centre + lead.dir * lead.radius(brain.now) * 0.8
		else:
			var heading := _advance_heading(mate)
			var fan: float = SWEEP_FAN * sin(float(step) * 1.7)
			# Height is reach: the arrow is falling toward ground below the
			# bow, so from a rise the same loose covers more field.
			var dist: float = randf_range(SWEEP_NEAR,
					SWEEP_FAR + height_gain * VANTAGE_REACH_BONUS)
			var from: Vector3 = mate.pos if mate != null and not mate.is_dead else pos()
			candidate = from + heading.rotated(Vector3.UP, fan) * dist
		if pos().distance_to(candidate) > arrow_max_range() * 0.9:
			continue
		if brain.fire_dist(candidate) < LIT_ENOUGH:
			continue          # that patch has already been asked
		return candidate
	return Vector3.ZERO


## Which way the party is going: the paladin leads and the archer walks behind
## him, so the line between them IS the advance.
func _advance_heading(mate: SquadBrain.Ally) -> Vector3:
	if mate != null and not mate.is_dead:
		var h: Vector3 = mate.pos - pos()
		h.y = 0.0
		if h.length() > 3.0:
			return h.normalized()
		if "velocity" in mate.node:
			var v: Vector3 = mate.node.velocity
			v.y = 0.0
			if v.length() > 1.0:
				return v.normalized()
	return explore_heading()


## Beyond the tether with nothing known: close the gap, lighting as he comes.
func _scout(mate: SquadBrain.Ally, delta: float) -> void:
	if mate != null and not mate.is_dead and pos().distance_to(mate.anchor) > TETHER:
		go_to(mate.anchor, TETHER * 0.6, 14.0)
	else:
		explore(delta)
	if _arrow_cd > 0.0 or brain.fires.size() >= FIRE_BUDGET:
		return
	var point := _search_point(mate)
	if point == Vector3.ZERO:
		_arrow_cd = 1.5
		return
	_order_shot(point, randf_range(4.0, 6.0), "scout-beacon")


## Station-keeping: in the dark, behind the anchor, out of melee. This is the
## archer's default posture and it runs underneath most of his other tactics.
func _hold_station(mate: SquadBrain.Ally) -> void:
	var focus := brain.focus
	var hunted: bool = brain.threat_on(body) != null
	var spot: Vector3 = pos()
	if mate != null and not mate.is_dead and focus != null:
		var from_enemy: Vector3 = mate.pos - focus.pos
		from_enemy.y = 0.0
		if from_enemy.length_squared() > 0.01:
			spot = mate.pos + from_enemy.normalized() * SLOT_BEHIND
		else:
			spot = mate.pos
	elif focus != null:
		var back: Vector3 = pos() - focus.pos
		back.y = 0.0
		if back.length_squared() > 0.01:
			spot = focus.pos + back.normalized() * KITE_DIST
	elif mate != null and not mate.is_dead:
		spot = mate.anchor
	if focus != null:
		# Never let the station drift inside knife range of the threat.
		var d: float = spot.distance_to(focus.pos)
		if d < KITE_DIST:
			var out: Vector3 = spot - focus.pos
			out.y = 0.0
			if out.length_squared() > 0.01:
				spot = focus.pos + out.normalized() * KITE_DIST
	# Stand outside our own light unless we are the one being chased, in which
	# case the fire is a wall and we want it at our back.
	if not hunted and brain.lit_amount(spot) > 0.0:
		var fire := _nearest_fire_pos(spot)
		var away: Vector3 = spot - fire
		away.y = 0.0
		if away.length_squared() > 0.01:
			spot = fire + away.normalized() * (Perception.FIRE_REVEAL_RADIUS + 2.0)
	var to_spot: Vector3 = spot - pos()
	to_spot.y = 0.0
	if focus != null:
		aim_at(focus.pos)
	elif mate != null:
		aim_at(mate.anchor)
	if to_spot.length() > 2.5:
		move_world(to_spot.normalized(), to_spot.length() > 9.0)
	else:
		stop()


func _fall_back(mate: SquadBrain.Ally) -> void:
	var threat := brain.threat_on(body)
	if threat == null:
		threat = brain.focus
	if threat == null:
		_hold_station(mate)
		return
	var toward: Vector3 = mate.anchor if mate != null else pos()
	var threat_dist: float = threat.pos.distance_to(pos())
	if threat_dist > ESTUS_SAFE_DIST:
		stop()
		aim_at(threat.pos)
		drink_if_safe(threat_dist)
		# Falling back is not the same as stopping work — keep the light on him.
		var aim: Vector3 = threat.pos
		var kind := "fallback-light"
		if threat.lit or brain.fire_dist(threat.pos) <= Perception.FIRE_REVEAL_RADIUS:
			kind = "fallback-shot"
			if threat.seen_now:
				aim = threat.node.global_position + Vector3(0, 1.0, 0)
		_order_shot(aim, randf_range(2.2, 3.0), kind)
		return
	var dir := escape_dir(threat.pos, toward, true)
	if dir.length_squared() > 0.01:
		aim_at(pos() + dir * 10.0)
		move_world(dir, true)


## Raising a fallen ally as the archer is a problem of GEOMETRY, not courage:
## he cannot trade with whatever put the ally down, and the channel takes five
## uninterrupted seconds within 2.6 m of the body.
##
## And it is emphatically NOT a shooting problem. Walking arrows onto a boss
## standing over a corpse lights a fire at his feet every time one connects,
## and a ring of fires around the body is a CAGE — his own avoidance keeps him
## pinned exactly where the archer needs him not to be, forever. (That is not
## hypothetical: it is what the first version of this did, for fifty seconds.)
##
## So the lure is the archer HIMSELF. He lights the spot once if it is dark,
## then walks around to the far side of the camper and stands just inside the
## range where he can be smelled or seen. The camper comes for him — away from
## the body, because the archer put himself on the far side — and the archer
## backs off, keeping the leash taut, until there is room to run in and kneel.
func _revive(mate: SquadBrain.Ally, delta: float) -> void:
	if mate == null:
		_scout(mate, delta)
		return
	var threat := brain.focus
	var camped: bool = threat != null and threat.confidence(brain.now) > 0.3 \
			and threat.pos.distance_to(mate.pos) < 10.0
	if camped:
		body._ai_revive_intent = false
		body._ai_crouch = false
		_pull_time += delta
		# One fire, so the party can see the ground it is fighting over — and
		# then no more, whatever happens.
		if not threat.lit and brain.fires_near(mate.pos, 14.0) == 0:
			_order_shot(threat.pos, 4.0, "revive-light")
			return
		var out: Vector3 = threat.pos - mate.pos
		out.y = 0.0
		if out.length_squared() < 0.01:
			out = Vector3.FORWARD
		out = out.normalized()
		aim_at(threat.pos)
		if threat.hunting == body:
			# He has taken the bait: walk him off the body, staying ahead of him.
			var lead: Vector3 = threat.pos + out * 14.0
			go_to(lead, 3.0, 5.0, false)
		else:
			# Stand where he will notice us, on the side that pulls him AWAY
			# from the body when he does.
			var bait: Vector3 = threat.pos + out * 8.0
			go_to(bait, 2.0, 8.0, false)
		return
	_pull_time = 0.0
	if go_to(mate.pos, 2.2, 8.0):
		aim_at(mate.pos)
		body._ai_revive_intent = true
		body._ai_crouch = true
	else:
		body._ai_revive_intent = false
		body._ai_crouch = false


func _downed_ally() -> SquadBrain.Ally:
	for a in brain.allies:
		if a.is_dead and a.node != body:
			return a
	return null


func _nearest_fire_pos(from: Vector3) -> Vector3:
	var best := from
	var best_d := INF
	for f in brain.fires:
		var d: float = from.distance_to(f)
		if d < best_d:
			best_d = d
			best = f
	return best


# ------------------------------------------------------------------ archery --
#
# The bow is the archer's, and so is the arithmetic behind it. Nothing else in
# the co-op AI throws anything, so nothing else needs to solve an arc.

## The firing solution for a fire arrow: the launch direction that actually
## LANDS on `target`, solved from the arrow's own speed and the world's gravity
## instead of a fixed upward fudge.
##
## This is not polish. The archer's entire contribution is putting fire on a
## chosen patch of ground; an arrow that falls short lights nothing, and the
## paladin stays blind. The flat root is taken (the lower of the two arcs) so
## the shot arrives fast and the light appears while the intelligence behind it
## is still true.
func arrow_dir_to(target: Vector3) -> Vector3:
	var origin: Vector3 = pos() + Vector3(0, 1.5, 0)
	var to_target: Vector3 = target - origin
	var flat := Vector2(to_target.x, to_target.z).length()
	var horiz := Vector3(to_target.x, 0.0, to_target.z)
	if flat < 0.5 or horiz.length_squared() < 0.01:
		return Vector3.UP
	horiz = horiz.normalized()
	var v2: float = ARROW_SPEED * ARROW_SPEED
	var g: float = world_gravity
	var disc: float = v2 * v2 - g * (g * flat * flat + 2.0 * to_target.y * v2)
	if disc < 0.0:
		# Out of range even at the ideal 45°: throw it as far as it will go.
		return (horiz * cos(PI / 4.0) + Vector3.UP * sin(PI / 4.0)).normalized()
	var theta: float = atan((v2 - sqrt(disc)) / (g * flat))
	return (horiz * cos(theta) + Vector3.UP * sin(theta)).normalized()


## Maximum ground a planted shot can cover, from the same physics.
func arrow_max_range() -> float:
	return ARROW_SPEED * ARROW_SPEED / world_gravity
