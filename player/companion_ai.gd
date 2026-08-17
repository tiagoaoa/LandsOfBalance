class_name CompanionAI
extends Node

## Drives the co-op AI companion (a second player.tscn instance with
## `is_ai_companion = true`). It fights through the SAME control surface a
## human uses: it steers the character's camera pivot, writes
## `_ai_move_vec` / `_ai_run` (read where player.gd would poll Input), and
## calls the same action methods the combat harness does (_do_attack,
## _try_dodge, _try_parry, _try_estus, _do_spell_cast, _shoot_arrow).
##
## Intelligence model — every game rule feeds the decisions:
## - PERCEPTION: blind-in-the-dark rules ([[Perception.can_see]] —
##   moonlight silhouettes ~25 m, fire-lit enemies visible across the
##   field), plus "hearing" a roaring Bobba who is already hunting the
##   party at close range.
## - DEFENSE: when Bobba winds up an attack on the companion it attempts a
##   timed parry (paladin — parry fully cancels, block only chips) or
##   dodge-rolls through the strike (i-frames).
## - SPELLS, by their real effects: the paladin's lightning spell spawns a
##   party HEAL aura (knight 5%/s, archer 10%/s) → cast when the party is
##   wounded and no strike is inbound. The archer's fire circle spawns a
##   paladin DAMAGE-BUFF aura and a burning ring that lights the area
##   (revealing enemies, walling off Bobba, exposing the caster — all
##   real tradeoffs handled by the shared fire rules) → cast when the
##   melee fighter is brawling close by.
## - RETREAT: below 35% HP the companion disengages along a SCORED escape
##   route (away from Bobba, biased toward the human player, never through
##   burning fires, on-map), drinks estus once it breaks contact, and only
##   re-engages above 60% HP. The archer instead KITES: keeps ~16 m and
##   keeps firing while falling back.
##
## ROLES (the two AIs are complements, not bodyguards):
## - AI PALADIN is the HUNTER: the moment an enemy is uncovered he goes to
##   it — however far — and fights. When the enemy slips back into the
##   dark he loses the live track but keeps hunting from the LAST KNOWN
##   POSITION (investigates the spot, then gives up and patrols). He does
##   NOT hug the archer: only when idle and very far does he loosely
##   drift back toward the party.
## - AI ARCHER is the SPOTTER: it stays at range and spends its arrows on
##   UNCOVERING (lighting the paladin's surroundings and suspect ground)
##   and on DETERRENCE — anything that hunts the paladin gets fire arrows
##   walked onto it (the hits reveal, burn, and drive enemies off).

const Proto = preload("res://multiplayer/protocol.gd")

const ENGAGE_RANGE := 90.0        # fire-lit enemies are visible across the field
const HEAR_HUNTER_RANGE := 18.0   # a charging, roaring enemy is audible
const MELEE_RANGE := 2.4
const FOLLOW_NEAR := 3.5          # stop approaching the leader here
const FOLLOW_RUN := 12.0          # run to catch up beyond this
const REGROUP_DIST := 32.0        # idle paladin drifts back only beyond this
const ARCHER_SUPPORT_DIST := 30.0 # archer holds this loose tether to the leader
const INVESTIGATE_TIME := 5.0     # seconds poking at a cold last-known spot
const ARCHER_MIN_DIST := 10.0     # archer stops short of the leader when regrouping
const KITE_DIST := 16.0           # archer's preferred distance from a hunter
const RETREAT_HP := 0.35          # break off below this fraction
const REENGAGE_HP := 0.6          # rejoin the fight above this
const SAFE_DRINK_DIST := 9.0      # estus only with this much room
const DEFENSE_COOLDOWN := 1.1     # min seconds between parry/roll reactions
const SPELL_COOLDOWN := 24.0

var body: Node3D = null           # the companion player instance

var _retreating := false
# The party spawns separated and the companion does NOT magically know
# where the human is: it learns the leader's position only when the
# night-perception rules let it SEE them, remembers the last sighting,
# walks that trail, and explores when the trail goes cold. The archer's
# recon fire arrows double as beacons a human can spot from afar.
var _leader_known := false
var _leader_anchor := Vector3.ZERO
# Hunter memory: live enemy sightings decay into a last-known position the
# paladin keeps stalking before giving up.
var _enemy_known := false
var _enemy_last_pos := Vector3.ZERO
var _investigate_left := 0.0
var _explore_dir := Vector3.ZERO
var _explore_timer := 0.0
var _attack_timer := 0.0
var _combo_clicks_left := 0
var _click_gap := 0.0
var _arrow_timer := 4.0
var _defense_timer := 0.0
var _spell_timer := 6.0


func _ready() -> void:
	if body == null:
		body = get_parent()


func _physics_process(delta: float) -> void:
	if body == null or not is_instance_valid(body):
		return
	if "is_dead" in body and body.is_dead:
		body._ai_move_vec = Vector2.ZERO
		return
	var leader: Node3D = get_tree().get_first_node_in_group("player") as Node3D
	if leader == null:
		return
	_defense_timer -= delta
	_spell_timer -= delta

	# Leader tracking under the shared visibility rules.
	if Perception.can_see(body, leader):
		if not _leader_known:
			print("CompanionAI: leader spotted — regrouping")
		_leader_known = true
		_leader_anchor = leader.global_position
	elif _leader_known \
			and body.global_position.distance_to(_leader_anchor) < 5.0:
		# Reached the last sighting and the leader isn't here — trail cold.
		_leader_known = false
		print("CompanionAI: lost the leader's trail — exploring")

	var enemy: Node3D = _perceived_enemy(leader)
	var is_paladin: bool = body.character_class == body.CharacterClass.PALADIN
	var hp_frac: float = body.current_health / maxf(body.max_health, 1.0)

	# A fallen leader outranks every role: the blue beacon is visible from
	# anywhere, so the companion knows exactly where to go. It fights off
	# close threats first (a channel under attack just resets), then
	# kneels and holds the revive.
	if "is_dead" in leader and leader.is_dead:
		_revive_leader(leader, enemy, is_paladin, delta)
		return
	body._ai_revive_intent = false
	body._ai_crouch = false

	# Retreat hysteresis: break off badly wounded, rejoin only once healed.
	if not _retreating and hp_frac < RETREAT_HP:
		_retreating = true
		print("CompanionAI: retreating at %.0f%% hp" % (hp_frac * 100.0))
	elif _retreating and hp_frac > REENGAGE_HP:
		_retreating = false
		print("CompanionAI: healed — re-engaging")

	# Incoming strike? Defense beats everything else this frame.
	if enemy != null and _react_to_attack(enemy, is_paladin):
		return

	_consider_spell(leader, enemy, is_paladin, hp_frac)

	if _retreating and enemy != null:
		_retreat_move(leader, enemy)
		if not is_paladin:
			_archer_fire(enemy, delta)  # keeps shooting while falling back
		_try_drink(enemy)
		return

	# Sightings feed the hunter memory.
	if enemy != null:
		_enemy_known = true
		_enemy_last_pos = enemy.global_position
		_investigate_left = 0.0

	if enemy != null:
		if is_paladin:
			_engage_melee(enemy, delta)
		else:
			_archer_combat(leader, enemy, delta)
	elif is_paladin:
		if _enemy_known:
			_pursue_last_known(delta)
		elif _leader_known \
				and body.global_position.distance_to(_leader_anchor) > REGROUP_DIST:
			_follow(leader)  # loose regroup only when idle AND far
		else:
			_explore(delta)
	else:
		# Archer: hold a loose long tether to the leader, spend arrows on
		# reconnaissance around him.
		if _leader_known \
				and body.global_position.distance_to(_leader_anchor) > ARCHER_SUPPORT_DIST:
			_follow(leader)
		else:
			body._ai_move_vec = Vector2.ZERO
			if not _leader_known:
				_explore(delta)
		_archer_recon(leader, delta)
	if _retreating and enemy == null:
		_try_drink(null)


## Fight off anything close, then channel the revive beside the body.
func _revive_leader(leader: Node3D, enemy: Node3D, is_paladin: bool, delta: float) -> void:
	if enemy != null \
			and body.global_position.distance_to(enemy.global_position) < 14.0:
		body._ai_revive_intent = false
		body._ai_crouch = false
		if _react_to_attack(enemy, is_paladin):
			return
		if is_paladin:
			_engage_melee(enemy, delta)
		else:
			_archer_combat(leader, enemy, delta)
		return
	var to_body: Vector3 = leader.global_position - body.global_position
	to_body.y = 0.0
	if to_body.length() > 2.2:
		body._ai_revive_intent = false
		body._ai_crouch = false
		_aim_at(leader.global_position)
		_move_world(to_body.normalized(), to_body.length() > 8.0)
	else:
		body._ai_move_vec = Vector2.ZERO
		_aim_at(leader.global_position)
		body._ai_revive_intent = true
		body._ai_crouch = true  # braced kneel while channelling


## The one enemy this companion is allowed to know about, under the shared
## night rules: seen (moonlight / fire glow), or heard hunting the party.
func _perceived_enemy(leader: Node3D) -> Node3D:
	var bobba: Node3D = get_tree().get_first_node_in_group("bobba") as Node3D
	if bobba != null and is_instance_valid(bobba) \
			and not ("health" in bobba and float(bobba.health) <= 0.0):
		var dist: float = body.global_position.distance_to(bobba.global_position)
		if dist <= ENGAGE_RANGE:
			if Perception.can_see(body, bobba):
				return bobba
			if "target" in bobba and (bobba.target == body or bobba.target == leader) \
					and dist <= HEAR_HUNTER_RANGE:
				return bobba
	# Skeletons crowd in silently — engage the nearest VISIBLE one.
	var best: Node3D = null
	var best_d: float = ENGAGE_RANGE
	for sk in get_tree().get_nodes_in_group("skeletons"):
		if sk is Node3D and is_instance_valid(sk) \
				and not ("is_dead_skeleton" in sk and sk.is_dead_skeleton):
			var d: float = body.global_position.distance_to((sk as Node3D).global_position)
			if d < best_d and Perception.can_see(body, sk):
				best = sk
				best_d = d
	return best


## Bobba is winding up on US: parry the hit (full cancel + riposte window)
## or roll through it (i-frames). Returns true when a reaction fired.
func _react_to_attack(enemy: Node3D, is_paladin: bool) -> bool:
	var attacking: bool = "state" in enemy and int(enemy.state) == Proto.BobbaState.ATTACKING
	var on_me: bool = "target" in enemy and enemy.target == body
	var dist: float = body.global_position.distance_to(enemy.global_position)
	if not (attacking and on_me and dist < 4.5):
		return false
	if _defense_timer > 0.0:
		return false
	_defense_timer = DEFENSE_COOLDOWN
	if is_paladin and randf() < 0.6 and body.has_method("_try_parry"):
		# Bobba's fist lands ~0.5 s after the wind-up at arm's reach — the
		# parry commitment window (deflect 0.05–0.38 s) covers it.
		body._try_parry()
		return true
	# Otherwise roll away from the strike.
	var away: Vector3 = body.global_position - enemy.global_position
	away.y = 0.0
	if away.length_squared() > 0.01:
		_move_world(away.normalized(), true)
	# _try_dodge, not _do_roll — there has never been a _do_roll, so this
	# branch quietly did nothing but consume the defence reaction: the
	# companion stepped away from the swing and ate it. _move_world above
	# has already set _ai_move_vec, which is where the roll takes its
	# direction from for an AI body.
	if body.has_method("_try_dodge"):
		body._try_dodge()
	return true


## Spell strategy, by the spells' REAL effects:
## paladin lightning = party heal aura → cast when wounded and unpressed;
## archer fire circle = paladin damage buff + burning reveal ring → cast
## when the melee fighter brawls beside us.
func _consider_spell(leader: Node3D, enemy: Node3D, is_paladin: bool, hp_frac: float) -> void:
	if _spell_timer > 0.0 or not body.has_method("_do_spell_cast"):
		return
	var enemy_dist: float = INF
	if enemy != null:
		enemy_dist = body.global_position.distance_to(enemy.global_position)
	var leader_hp: float = 1.0
	if "current_health" in leader and "max_health" in leader:
		leader_hp = float(leader.current_health) / maxf(float(leader.max_health), 1.0)
	if is_paladin:
		# Heal circle when the party needs it and no fist is inbound.
		var party_wounded: bool = hp_frac < 0.65 \
				or (leader_hp < 0.65 and body.global_position.distance_to(leader.global_position) < 10.0)
		if party_wounded and enemy_dist > 5.0:
			_spell_timer = SPELL_COOLDOWN
			body._do_spell_cast()
			print("CompanionAI: casting heal circle")
	else:
		# Buff ring when the paladin (the human) fights right next to us —
		# it also floodlights the brawl, revealing Bobba to everyone.
		var leader_fighting: bool = enemy != null \
				and leader.global_position.distance_to(enemy.global_position) < 8.0
		if leader_fighting and body.global_position.distance_to(leader.global_position) < 7.0:
			_spell_timer = SPELL_COOLDOWN
			body._do_spell_cast()
			print("CompanionAI: casting fire-circle buff ring")


func _engage_melee(enemy: Node3D, delta: float) -> void:
	var to_enemy: Vector3 = enemy.global_position - body.global_position
	to_enemy.y = 0.0
	var dist := to_enemy.length()
	_aim_at(enemy.global_position)

	if dist > MELEE_RANGE:
		_move_world(to_enemy.normalized(), dist > 8.0)
		_combo_clicks_left = 0
		return

	body._ai_move_vec = Vector2.ZERO
	# Fast triple-clicks chain the combo (player.gd's 0.5 s click window),
	# then a breather — the same rhythm the COMBO scenario drives.
	_attack_timer -= delta
	_click_gap -= delta
	if _combo_clicks_left > 0:
		if _click_gap <= 0.0:
			body._do_attack()
			_combo_clicks_left -= 1
			_click_gap = 0.32
	elif _attack_timer <= 0.0:
		_combo_clicks_left = 3
		_click_gap = 0.0
		_attack_timer = randf_range(2.2, 3.2)


## Archer in a fight: kite — hold ~16 m from the enemy (fall back when he
## closes, creep up when he breaks off) and keep the fire arrows coming.
func _archer_combat(leader: Node3D, enemy: Node3D, delta: float) -> void:
	var to_enemy: Vector3 = enemy.global_position - body.global_position
	to_enemy.y = 0.0
	var dist := to_enemy.length()
	var hunted: bool = "target" in enemy and enemy.target == body
	if dist < KITE_DIST or (hunted and dist < KITE_DIST * 1.4):
		_retreat_move(leader, enemy)
	elif dist > KITE_DIST * 2.0:
		_aim_at(enemy.global_position)
		_move_world(to_enemy.normalized(), false)
	else:
		body._ai_move_vec = Vector2.ZERO
	_archer_fire(enemy, delta)


func _archer_fire(enemy: Node3D, delta: float) -> void:
	_arrow_timer -= delta
	if _arrow_timer > 0.0:
		return
	_arrow_timer = randf_range(2.5, 4.0)
	_aim_at(enemy.global_position, true)
	if body.has_method("_shoot_arrow"):
		body._shoot_arrow()


## The spotter's trade: every volley either DETERS (walks fire onto
## whatever is hunting the paladin — the hit reveals, ignites and drives
## it back) or UNCOVERS (lights the ground around the paladin and the
## suspect dark beyond him).
func _archer_recon(leader: Node3D, delta: float) -> void:
	_arrow_timer -= delta
	if _arrow_timer > 0.0:
		return
	var aim_point: Vector3
	var hunter := _enemy_hunting_ally(leader)
	if hunter != null:
		# Deterrence fire: fast cadence at the paladin's attacker.
		aim_point = hunter.global_position + Vector3(0, 1.0, 0)
		_arrow_timer = randf_range(2.2, 3.5)
		print("CompanionAI: deterrence volley at %s" % hunter.name)
	elif _enemy_known:
		# Keep the last known enemy ground lit.
		aim_point = _enemy_last_pos
		_arrow_timer = randf_range(4.0, 6.0)
	elif _leader_known:
		# Light the paladin's surroundings — a moving pool of firelight
		# around the melee fighter so nothing reaches him unseen.
		var ang := randf() * TAU
		aim_point = _leader_anchor + Vector3(cos(ang), 0.0, sin(ang)) * randf_range(8.0, 20.0)
		_arrow_timer = randf_range(4.5, 7.0)
	else:
		# Alone in the dark: light the path ahead — the burning arrows are
		# also beacons the human can steer toward.
		var dir := _explore_dir if _explore_dir.length_squared() > 0.01 else Vector3.FORWARD
		aim_point = body.global_position + dir * 24.0
		_arrow_timer = randf_range(6.0, 9.0)
	_aim_at(aim_point, true)
	if body.has_method("_shoot_arrow"):
		body._shoot_arrow()


## Whatever is actively hunting the leader or this companion — Bobba mid-
## chase roars, a skeleton pack rattles: the archer knows WHERE from the
## noise even without seeing them clearly.
func _enemy_hunting_ally(leader: Node3D) -> Node3D:
	var bobba: Node3D = get_tree().get_first_node_in_group("bobba") as Node3D
	if bobba != null and is_instance_valid(bobba) \
			and "target" in bobba and (bobba.target == leader or bobba.target == body) \
			and not ("health" in bobba and float(bobba.health) <= 0.0):
		return bobba
	for sk in get_tree().get_nodes_in_group("skeletons"):
		if sk is Node3D and is_instance_valid(sk) \
				and not ("is_dead_skeleton" in sk and sk.is_dead_skeleton) \
				and "_target" in sk and (sk._target == leader or sk._target == body):
			return sk
	return null


## Scored escape route: gain distance from the enemy, lean toward the
## human player (regrouping beats scattering), never run through a burning
## fire, stay on the map. 12 headings, best one wins.
func _retreat_move(leader: Node3D, enemy: Node3D) -> void:
	var best_dir := Vector3.ZERO
	var best_score: float = -INF
	var fires: Array = get_tree().get_nodes_in_group("ground_fire")
	# Regroup bias only toward a leader we actually know about.
	var anchor: Vector3 = _leader_anchor if _leader_known else body.global_position
	for i in range(12):
		var ang := TAU * float(i) / 12.0
		var dir := Vector3(cos(ang), 0.0, sin(ang))
		var probe: Vector3 = body.global_position + dir * 14.0
		var score: float = probe.distance_to(enemy.global_position)
		score -= probe.distance_to(anchor) * 0.35
		for fire in fires:
			if fire is Node3D and is_instance_valid(fire):
				for d in [5.0, 10.0, 14.0]:
					if (body.global_position + dir * d).distance_to(
							(fire as Node3D).global_position) < 6.0:
						score -= 40.0
		if absf(probe.x) > 220.0 or absf(probe.z) > 220.0:
			score -= 100.0
		if score > best_score:
			best_score = score
			best_dir = dir
	if best_dir.length_squared() > 0.01:
		_aim_at(body.global_position + best_dir * 10.0)
		_move_world(best_dir, true)


## Drink estus only with room to swallow — a hit mid-drink wastes the charge.
func _try_drink(enemy: Node3D) -> void:
	var enemy_dist: float = INF
	if enemy != null:
		enemy_dist = body.global_position.distance_to(enemy.global_position)
	if enemy_dist > SAFE_DRINK_DIST and body.has_method("_try_estus"):
		body._try_estus()


## The hunter's cold trail: run to where the enemy was LAST SEEN, poke
## around the spot for a few seconds, then admit the dark won and go back
## to patrolling.
func _pursue_last_known(delta: float) -> void:
	var to_spot: Vector3 = _enemy_last_pos - body.global_position
	to_spot.y = 0.0
	if to_spot.length() > 3.0 and _investigate_left <= 0.0:
		_aim_at(_enemy_last_pos)
		_move_world(to_spot.normalized(), to_spot.length() > 8.0)
		return
	if _investigate_left <= 0.0:
		_investigate_left = INVESTIGATE_TIME
		print("CompanionAI: reached last known enemy position — searching")
	_investigate_left -= delta
	# Slow sweep around the cold spot.
	var sweep := Vector3(cos(_investigate_left * 1.3), 0.0, sin(_investigate_left * 1.3))
	_aim_at(body.global_position + sweep * 8.0)
	_move_world(sweep, false)
	if _investigate_left <= 0.0:
		_enemy_known = false
		print("CompanionAI: trail is cold — the dark keeps its secrets")


## Wander the dark looking for the leader: a new heading every several
## seconds, at a walk (running blind into Bobba's scent range is how you
## die alone).
func _explore(delta: float) -> void:
	_explore_timer -= delta
	if _explore_timer <= 0.0 or _explore_dir.length_squared() < 0.01:
		_explore_timer = randf_range(5.0, 9.0)
		var ang := randf() * TAU
		_explore_dir = Vector3(cos(ang), 0.0, sin(ang))
		# Stay on the map — steer back toward the centre when out far.
		var from_center := body.global_position
		from_center.y = 0.0
		if from_center.length() > 180.0:
			_explore_dir = -from_center.normalized()
	_aim_at(body.global_position + _explore_dir * 10.0)
	_move_world(_explore_dir, false)


func _follow(leader: Node3D) -> void:
	# Walk the trail to the last SIGHTING, not to a mind-read position.
	var to_leader: Vector3 = _leader_anchor - body.global_position
	to_leader.y = 0.0
	var dist := to_leader.length()
	var near := FOLLOW_NEAR if body.character_class == body.CharacterClass.PALADIN else ARCHER_MIN_DIST
	if dist > near:
		_aim_at(_leader_anchor)
		_move_world(to_leader.normalized(), dist > FOLLOW_RUN)
	else:
		body._ai_move_vec = Vector2.ZERO


## Point the companion's camera pivot at a world position — swings, arrows
## and camera-relative movement all key off the pivot, exactly like the
## human's mouse steering.
func _aim_at(world_pos: Vector3, arc_for_arrow: bool = false) -> void:
	var pivot: Node3D = body.get_node_or_null("CameraPivot") as Node3D
	if pivot == null:
		return
	var to_target: Vector3 = world_pos - body.global_position
	var flat := Vector2(to_target.x, to_target.z)
	if flat.length_squared() > 0.01:
		pivot.rotation.y = atan2(-to_target.x, -to_target.z)
	if arc_for_arrow:
		# Loft: aim slightly above the flat line so the arrow arcs onto it.
		pivot.rotation.x = clampf(atan2(to_target.y + 2.0, flat.length()), -0.5, 0.5)


## Convert a world-space move direction into the camera-relative input
## vector player.gd expects (same math as its own input handling).
func _move_world(world_dir: Vector3, run: bool) -> void:
	var pivot: Node3D = body.get_node_or_null("CameraPivot") as Node3D
	if pivot == null:
		return
	var yaw: float = pivot.rotation.y
	var fwd := Vector3.FORWARD.rotated(Vector3.UP, yaw)
	var rt := Vector3.RIGHT.rotated(Vector3.UP, yaw)
	body._ai_move_vec = Vector2(world_dir.dot(rt), -world_dir.dot(fwd))
	body._ai_run = run
