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
const RETREAT_HP := 0.35        # break off below this fraction of max HP
const REENGAGE_HP := 0.6        # ...and rejoin only once back above this
const ESTUS_SAFE_DIST := 9.0    # a hit mid-drink wastes the charge
const DEFENSE_COOLDOWN := 0.9   # min seconds between parry/roll reactions
## Bobba's fist connects roughly this far into a swing. The parry commitment
## window is 0.33 s wide (PARRY_WINDOW_START..END), so an estimate this coarse
## is still comfortably inside it.
const BOBBA_CONTACT_TIME := 0.45

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
	_update_retreat_state()
	_decide_left -= delta
	if _decide_left <= 0.0:
		_decide_left = DECIDE_INTERVAL
		var next := choose_tactic()
		if next != tactic:
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
## falls at ATTACK_HIT_TIME into its swing, Bobba's fist about
## BOBBA_CONTACT_TIME in. That is what lets the AI parry on time instead of
## flipping a coin and hoping.
func soonest_strike() -> Dictionary:
	var best := INF
	var who: Node3D = null
	for c in brain.contacts:
		if not c.alive() or c.hunting != body:
			continue
		if c.pos.distance_to(pos()) > 5.5:
			continue
		var eta := strike_eta(c.node)
		if eta < best:
			best = eta
			who = c.node
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
		return maxf(0.0, BOBBA_CONTACT_TIME - float(b._attack_state_time))
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
	guard(eta < 0.8)
	if _defense_cd > 0.0:
		return false
	# Whatever this class can do better than rolling, it does here.
	if special_defence(eta):
		_defense_cd = DEFENSE_COOLDOWN
		return true
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
func move_world(world_dir: Vector3, run: bool) -> void:
	var pivot: Node3D = body.get_node_or_null("CameraPivot") as Node3D
	if pivot == null:
		return
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
