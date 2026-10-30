class_name ArcherRole
extends AIRole

#The paladin leads. Stay close enough to light his approach and interrupt
#the boss, then use his attention to line up the next shot.
const KITE_DIST := 12.0
const SLOT_BEHIND := 7.0
const TETHER := 22.0
const SPELL_COOLDOWN := 22.0
const FIRE_BUDGET := 5
const LIT_ENOUGH := 12.0
const ARROW_SPEED := 50.0

var _spell_cd := 8.0
var _arrow_cd := 0.5
var _shot_point := Vector3.ZERO
var _shot_pending := false
var _shot_contact: SquadBrain.Contact = null
var _shot_cadence := 2.5
var _plant_time := 0.0
var _last_shot_kind := ""
var _pull_time := 0.0
var _comb_step := 0
var _nav_left := 0.0
var _steer := Vector3.ZERO
var _flank := 1.0
var shots_fired := 0


func _init() -> void:
	role_name = "archer"


func choose_tactic() -> String:
	if boss_fight():
		return _boss_choose()
	var mate := brain.neediest_ally(body)
	var threat := brain.threat_on(body)
	var dist: float = pos().distance_to(threat.pos) if threat else INF
	if mate and mate.is_dead:
		return "revive"
	if dist < 7.0 or (retreating() and body.estus_charges > 0):
		return "fallback"
	if mate and pos().distance_to(mate.pos) > TETHER:
		return "regroup"
	if mate and _spell_cd <= 0 and mate.is_paladin and mate.pressure >= 2 \
			and mate.hp_frac < 0.65 and pos().distance_to(mate.pos) < 12.0:
		return "buff_run"
	if not _top_request().is_empty():
		return "illuminate"
	if _suppress_target(mate) != null:
		return "suppress"
	return "sweep" if brain.blind() else "kite"


func run_tactic(delta: float) -> void:
	_spell_cd -= delta
	_arrow_cd -= delta
	_nav_left -= delta
	if tactic.begins_with("b_"):
		_boss_run(delta)
		return
	var mate := brain.neediest_ally(body)
	body._ai_revive_intent = false
	body._ai_crouch = false
	if defend():
		_cancel_shot()
		return
	if tactic in ["fallback", "regroup"] \
			or (tactic == "revive" and _last_shot_kind != "revive-light"):
		_cancel_shot()
	elif _serve_shot(delta):
		return
	match tactic:
		"revive": _revive(mate, delta)
		"fallback": _fall_back(mate)
		"regroup": go_to(mate.pos, SLOT_BEHIND, 12.0)
		"buff_run": _buff_run(mate, delta)
		"illuminate": _illuminate(mate)
		"suppress": _suppress(mate)
		"sweep": _sweep(mate, delta)
		_: _hold_station(mate)


func _cancel_shot() -> void:
	_shot_pending = false
	_shot_contact = null
	if body.is_drawing_bow or body.is_holding_bow:
		body._cancel_bow_draw()


func _order_shot(point: Vector3, cadence: float, kind: String,
		contact: SquadBrain.Contact = null) -> void:
	if _arrow_cd > 0.0 or _shot_pending or body.is_attacking or body.is_casting:
		return
	if not _clear_arc(point):
		_flank = -_flank
		_arrow_cd = 0.7
		return
	_shot_point = point
	_shot_contact = contact
	_shot_pending = true
	_shot_cadence = cadence
	_plant_time = 0.0
	_last_shot_kind = kind


func _serve_shot(delta: float) -> bool:
	if not _shot_pending:
		return false
	if body._is_stunned or body.is_rolling or body.is_casting or body.is_drinking:
		_cancel_shot()
		return false
	stop()
	_plant_time += delta
	if _shot_contact != null:
		if not _shot_contact.alive() or not _shot_contact.seen_now:
			_cancel_shot()
			return false
		_shot_point = _lead_target(_shot_contact)
	var dir := arrow_dir_to(_shot_point)
	aim_at(_shot_point, asin(clampf(dir.y, -1.0, 1.0)))
	var settled := Vector2(body.velocity.x, body.velocity.z).length() < 0.5
	if settled and body.is_on_floor() and not body.is_attacking:
		body._start_bow_draw(false, true)
		if body.is_holding_bow and _clear_arc(_shot_point):
			#Keep the bow ready briefly for the next tell instead of spending
			#every arrow during recovery, when it cannot break the windup.
			if _shot_contact and _shot_contact.node is Bobba:
				var boss := _shot_contact.node as Bobba
				if boss._fire_break_cd <= 0.0 and not boss.fire_interrupt_ready() and _plant_time < 1.4:
					return true
			body._release_bow(dir)
			_shot_pending = false
			_shot_contact = null
			_arrow_cd = _shot_cadence
			shots_fired += 1
			print("CompanionAI[archer]: %s shot at %s" % [
					_last_shot_kind, str(_shot_point.snapped(Vector3.ONE))])
	if _plant_time > 2.5:
		_cancel_shot()
		_arrow_cd = 0.5
	return true


func _lead_target(c: SquadBrain.Contact) -> Vector3:
	var flight := pos().distance_to(c.pos) / ARROW_SPEED
	return c.pos + Vector3.UP * 1.4 + c.vel.limit_length(8.0) * flight


func _suppress_target(mate: SquadBrain.Ally) -> SquadBrain.Contact:
	var best: SquadBrain.Contact = null
	var score := -INF
	for c in brain.contacts:
		if not c.alive() or not c.seen_now or c.confidence(brain.now) < 0.6:
			continue
		if c.pos.distance_to(pos()) > 42.0:
			continue
		var value: float = c.threat
		if mate and c.hunting == mate.node:
			value += 12.0
		if c.node is Bobba and c.node.fire_interrupt_ready():
			value += 20.0
		if value > score:
			score = value
			best = c
	return best


func _top_request() -> Dictionary:
	for req in brain.light_requests:
		if pos().distance_to(req.pos) > 45.0:
			continue
		if brain.fire_dist(req.pos) < LIT_ENOUGH:
			continue
		if brain.ground_fires.size() >= FIRE_BUDGET and req.priority < 2.5:
			continue
		return req
	return {}


func _illuminate(mate: SquadBrain.Ally) -> void:
	_hold_station(mate)
	var req := _top_request()
	if req.is_empty():
		return
	var point: Vector3 = req.pos
	#Light beside the melee so tall flames do not mask the axe's windup.
	var side := (point - (mate.pos if mate else pos())).cross(Vector3.UP)
	if side.length_squared() > 0.01:
		point += side.normalized() * 5.0
	var ground := _ground_at(point.x, point.z)
	if ground > -9000:
		point.y = ground + 0.05
	_order_shot(point, 2.0, "light the fight")


func _suppress(mate: SquadBrain.Ally) -> void:
	_hold_station(mate)
	var contact := _suppress_target(mate)
	if contact == null:
		return
	var cadence := 2.4
	var kind := "cover the paladin"
	if contact.node is Bobba and contact.node.fire_interrupt_ready():
		kind = "break the windup"
		cadence = 1.8
	_order_shot(_lead_target(contact), cadence, kind, contact)


func _buff_run(mate: SquadBrain.Ally, _delta: float) -> void:
	if mate == null or mate.is_dead:
		return
	if body.is_casting:
		stop()
		return
	if go_to(mate.pos, 3.0, 10.0):
		body._do_spell_cast()
		_spell_cd = SPELL_COOLDOWN if body.is_casting else 3.0


func _sweep(mate: SquadBrain.Ally, delta: float) -> void:
	if mate:
		_hold_station(mate)
	else:
		explore(delta)
	if _arrow_cd > 0 or brain.ground_fires.size() >= FIRE_BUDGET:
		return
	var point := _search_point(mate)
	if point != Vector3.ZERO:
		_order_shot(point, 4.0, "light your path")
	else:
		_arrow_cd = 1.0


func _scout(mate: SquadBrain.Ally, delta: float) -> void:
	_sweep(mate, delta)


func _search_point(mate: SquadBrain.Ally) -> Vector3:
	var anchor := mate.pos if mate else pos()
	var heading := _advance_heading(mate)
	var lead := brain.best_lead()
	for attempt in 5:
		var step := _comb_step
		_comb_step += 1
		var angle := [-0.32, 0.0, 0.32][step % 3] as float
		var point := anchor + heading.rotated(Vector3.UP, angle) * (16.0 + (step % 2) * 8.0)
		if lead and lead.pos.distance_to(anchor) < 30.0 and step % 3 == 0:
			point = lead.pos
		if brain.fire_dist(point) < LIT_ENOUGH:
			continue
		var ground := _ground_at(point.x, point.z)
		if ground > -9000 and absf(ground - anchor.y) < 5.0:
			point.y = ground + 0.05
			return point
	return Vector3.ZERO


func _advance_heading(mate: SquadBrain.Ally) -> Vector3:
	if mate == null or mate.is_dead:
		return explore_heading()
	var v: Vector3 = mate.node.velocity if "velocity" in mate.node else Vector3.ZERO
	v.y = 0.0
	if v.length() > 0.6:
		return v.normalized()
	var pivot := mate.node.get_node_or_null("CameraPivot") as Node3D
	if pivot:
		var forward := -pivot.global_basis.z
		forward.y = 0.0
		return forward.normalized()
	return Vector3.FORWARD


func _hold_station(mate: SquadBrain.Ally) -> void:
	var focus := brain.focus
	var heading := _advance_heading(mate)
	var anchor := mate.pos if mate else pos()
	if focus:
		heading = (focus.pos - anchor).normalized()
		heading.y = 0.0
	var side := heading.cross(Vector3.UP) * _flank
	var spot := anchor - heading * SLOT_BEHIND + side * 4.0
	if focus:
		aim_at(focus.pos)
	else:
		aim_at(anchor + heading * 20.0)
	go_to(spot, 2.0, 9.0, false)


func _fall_back(mate: SquadBrain.Ally) -> void:
	var threat := brain.threat_on(body)
	if threat == null:
		threat = brain.focus
	if threat == null:
		stop()
		drink_if_safe(INF)
		return
	var dist := pos().distance_to(threat.pos)
	if dist > ESTUS_SAFE_DIST:
		stop()
		drink_if_safe(dist)
		return
	var anchor := mate.pos if mate else pos()
	#Pass behind the knight instead of leading the boss away across the map.
	var away := (anchor - threat.pos).normalized()
	var spot := anchor + away * 6.0 + away.cross(Vector3.UP) * 4.0
	go_to(spot, 1.5, 2.0)


func _excluded() -> Array[RID]:
	var ids: Array[RID] = [body.get_rid()]
	for ally in brain.allies:
		if ally.node is CollisionObject3D and ally.node != body:
			ids.append(ally.node.get_rid())
	return ids


func _ground_at(x: float, z: float) -> float:
	var ray := PhysicsRayQueryParameters3D.create(
			Vector3(x, pos().y + 4.0, z), Vector3(x, pos().y - 6.0, z), 1, _excluded())
	var hit := body.get_world_3d().direct_space_state.intersect_ray(ray)
	return hit.position.y if not hit.is_empty() else -9999.0


func _clear_arc(point: Vector3) -> bool:
	var start := pos() + Vector3.UP * 1.5
	var vel := arrow_dir_to(point) * ARROW_SPEED
	var flat := Vector2(vel.x, vel.z).length()
	var flight := Vector2(point.x - start.x, point.z - start.z).length() / maxf(flat, 0.1)
	var previous := start
	for i in range(1, 9):
		var t := flight * i / 8.0
		var next := start + vel * t - Vector3.UP * world_gravity * t * t * 0.5
		var ray := PhysicsRayQueryParameters3D.create(previous, next, 1, _excluded())
		var hit := body.get_world_3d().direct_space_state.intersect_ray(ray)
		if not hit.is_empty():
			return hit.position.distance_to(point) < 1.5 or _part_holds(hit.collider, point)
		previous = next
	return true


## The arc ends on the very part being aimed at: a giant's claw or skull is
## metres across, so its surface lies well beyond 1.5 m of the centre aimed
## at, and every rescue shot at a braced claw used to read as "blocked".
func _part_holds(collider: Object, point: Vector3) -> bool:
	if not collider is ColossusPart:
		return false
	var part := collider as ColossusPart
	for c in part.get_children():
		if c is CollisionShape3D:
			var cs := c as CollisionShape3D
			var box := cs.shape.get_debug_mesh().get_aabb().grow(0.5)
			return box.has_point(cs.global_transform.affine_inverse() * point)
	return false


func move_world(direction: Vector3, run: bool) -> void:
	if arena != null:
		# The boss platform has ramps this probe reads as walls; the base
		# ledge guard is the one that knows the arena.
		super.move_world(direction, run)
		return
	if _nav_left <= 0.0 or direction.normalized().dot(_steer) < 0.5:
		_nav_left = 0.15
		_steer = _safe_heading(direction)
	super.move_world(_steer, run)


func _safe_heading(direction: Vector3) -> Vector3:
	if direction.length_squared() < 0.01:
		return Vector3.ZERO
	for angle in [0.0, 0.5, -0.5, 1.0, -1.0, 1.45, -1.45]:
		var dir := direction.normalized().rotated(Vector3.UP, angle)
		var probe := pos() + dir * 2.0
		var ray := PhysicsRayQueryParameters3D.create(pos() + Vector3.UP,
				probe + Vector3.UP, 1, _excluded())
		if not body.get_world_3d().direct_space_state.intersect_ray(ray).is_empty():
			continue
		var y := _ground_at(probe.x, probe.z)
		if y > pos().y - 1.8 and y < pos().y + 0.9:
			return dir
	return Vector3.ZERO


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


# ============================================================ the colossus ==
# The archer's half of the boss fight. His arrows barely scratch the stone,
# Keep the braziers lit, shoot the braced hand to release a grabbed
# partner; exploit the lowered head after the paladin breaks poise.

const CORE_CADENCE := 0.35
const CHIP_CADENCE := 1.1

func _boss_choose() -> String:
	var mate := partner()
	# Before anything returns: the spell's best moments (core open, a grab)
	# are exactly the moments the shot decisions below grab first.
	_maybe_spell(mate)
	if mate != null and mate.is_dead:
		return "revive"
	var victim := boss.grab_victim()
	if victim == body or boss.is_climbing(body):
		return "b_held"
	if boss.on_pad(body):
		return "b_ride"
	if not naive and boss.punch_open() and not on_high_ground():
		var f := boss.climbable_fist(body)
		if f != Vector3.INF or pos().distance_to(boss.fist_pos(boss._hand_i)) < 5.5:
			return "b_climb"
	if naive:
		return "b_body"
	if victim != null:
		return "b_rescue"
	# The braziers are the party's light: in the dark the knight reads the
	# boss's blows late. A dead one gets an arrow as soon as nothing is
	# coming at the archer.
	if _dark_brazier() != null and float(boss.strike_eta_for(body).eta) > 1.2:
		return "b_kindle"
	if boss.core_open():
		return "b_core"
	if boss.eye_charging():
		return "b_eye"
	if not boss.marks().is_empty():
		return "b_mark"
	var sw := boss.sweep_incoming()
	if float(sw.eta) < 1.5 and not on_high_ground() and mate != null and not mate.is_dead \
			and mate.is_paladin() and mate.global_position.distance_to(pos()) < 5.0:
		return "b_shelter"
	if hp_frac() < 0.35 and body.estus_charges > 0 and not on_high_ground():
		return "b_drink"
	if not _on_perch():
		return "b_perch"
	return "b_snipe"


func _boss_run(delta: float) -> void:
	body._ai_revive_intent = false
	body._ai_crouch = false
	if defend():
		_cancel_shot()
		return
	match tactic:
		"b_climb":
			_cancel_shot()
			if boss.climbable_fist(body) != Vector3.INF:
				stop()
				body._ai_climb = true
			else:
				go_to(boss.fist_pos(boss._hand_i), 0.8, 0.0)
		"b_ride":
			stop()
			if body._ai_crouch:
				_cancel_shot()
			else:
				_boss_shot(boss.head_pos(), CORE_CADENCE, "b_head")
		"b_held":
			_cancel_shot()
			stop()
			return
		"b_rescue":
			_boss_shot(boss.brace_hand_pos(), CORE_CADENCE, tactic)
		"b_kindle":
			var dark := _dark_brazier()
			if dark == null:
				_snipe(delta)
			else:
				_boss_shot(dark.aim_point(), CORE_CADENCE, tactic)
		"b_core":
			_boss_shot(boss.core_pos(), CORE_CADENCE, tactic)
		"b_eye":
			_boss_shot(boss.eye_pos(), CORE_CADENCE, "b_eye")
		"b_mark":
			var ms := boss.marks()
			if ms.is_empty():
				_snipe(delta)
			else:
				_boss_shot(ms[0], 0.5, "b_mark")
		"b_body":
			_boss_shot(boss.core_pos() + Vector3(0, -2.0, 0), CHIP_CADENCE, "b_body")
		"b_shelter":
			_cancel_shot()
			_shelter()
		"b_drink":
			_cancel_shot()
			# Out of its reach first: a flask lifted under its claws was a
			# free grab, and a grab on a drinking archer usually ended in the
			# abyss. Drink where it cannot reach, or while its grab is spent.
			var exposed: bool = boss._in_reach(pos()) and float(boss.get("_grab_cd")) < 3.0
			if exposed and not body.is_drinking:
				var c: Vector3 = arena.center
				var away := Vector3(c.x - boss.global_position.x, 0, c.z - boss.global_position.z).normalized()
				go_to(detour(c + away * float(arena.radius) * 0.6), 1.0, 2.0)
			else:
				stop()
				if not body.is_drinking:
					body._try_estus()
		"b_perch":
			_cancel_shot()
			_climb_perch()
		_:
			_snipe(delta)


## The dead brazier worth lighting first: the one nearest the knight (his
## fight needs the light most), within a comfortable bow shot of the archer.
func _dark_brazier() -> ArenaBrazier:
	if arena == null or not ("braziers" in arena):
		return null
	var mate := partner()
	var near: Vector3 = mate.global_position if mate != null and not mate.is_dead else pos()
	var best: ArenaBrazier = null
	var best_d := INF
	for b: ArenaBrazier in arena.braziers:
		if b.lit or b.global_position.distance_to(pos()) > 34.0:
			continue
		var d := b.global_position.distance_to(near)
		if d < best_d:
			best_d = d
			best = b
	return best


func _boss_shot(point: Vector3, cadence: float, kind: String) -> void:
	if _shot_pending:
		if kind in ["b_kindle", "b_rescue"] and kind != _last_shot_kind:
			_cancel_shot()
			_arrow_cd = 0.0
		else:
			_shot_point = point
	if _serve_shot(body.get_physics_process_delta_time()):
		return
	stop()
	aim_at(point)
	_order_shot(point, cadence, kind)


## On the perch with nothing open: help crack a pinned fist (an arrow does a
## third of a blade's poise), otherwise stand ready, bow toward the socket.
func _snipe(_delta: float) -> void:
	var fists := boss.pinned_fists()
	if not fists.is_empty():
		_boss_shot(fists[0], CHIP_CADENCE, "b_fist")
		return
	if boss.reptile:
		_boss_shot(boss.head_pos(), CHIP_CADENCE, "b_head")
		return
	if _serve_shot(body.get_physics_process_delta_time()):
		return
	stop()
	aim_at(boss.core_pos())


## Caught on the floor by a sweep: get downstream of the paladin's shield.
func _shelter() -> void:
	var mate := partner()
	var sw := boss.sweep_incoming()
	if mate == null or float(sw.eta) == INF:
		stop()
		return
	var phi := boss.boss_angle_of(mate.global_position)
	var r := Vector2(mate.global_position.x - boss.global_position.x,
			mate.global_position.z - boss.global_position.z).length()
	var spot := boss.arc_point(phi + float(sw.dir) * 0.9 / maxf(r, 1.0), r, pos().y)
	if pos().distance_to(spot) > 0.4:
		go_to(spot, 0.3, 0.0, false)
	else:
		stop()
	body._ai_crouch = float(sw.eta) < 0.5


func _on_perch() -> bool:
	if not on_high_ground():
		return false
	for p in arena.perches:
		var top: Vector3 = p.top
		# Within reach of the top, at its height — the ramp's last step counts.
		if Vector2(top.x - pos().x, top.z - pos().z).length() < float(p.radius) + 0.8 \
				and pos().y > top.y - 0.6:
			return true
	return false


## The perch to take: the nearer one, unless a slam is coming down on it —
## and on the big field, a tower level with the heart-gem beats a low perch.
func _pick_perch() -> Dictionary:
	var best := {}
	var best_d := INF
	for p in arena.perches:
		var top: Vector3 = p.top
		var d := pos().distance_to(top)
		if float(p.get("height", 3.6)) < 4.0 and arena.perches.size() > 2:
			d += 12.0
		# The gem faces where the giant faces: a perch off to its side sees
		# the socket's rim, not the gem. It wades, so this changes all fight.
		var to_p := Vector3(top.x - boss.global_position.x, 0, top.z - boss.global_position.z).normalized()
		var fwd := Vector3(boss.global_basis.z.x, 0, boss.global_basis.z.z).normalized()
		d += rad_to_deg(acos(clampf(to_p.dot(fwd), -1.0, 1.0))) * 0.35
		if boss.act == ColossusBoss.Act.SLAM and top.distance_to(boss._target) < 3.0:
			d += 50.0
		if d < best_d:
			best_d = d
			best = p
	return best


## Walking across the platform, pass the perch columns on their INNER side:
## a capsule that grazes one slides round the outside, toward the rim.
func _around_columns(goal: Vector3) -> Vector3:
	var here := Vector2(pos().x, pos().z)
	var g := Vector2(goal.x, goal.z)
	for p in arena.perches:
		var top: Vector3 = p.top
		var c := Vector2(top.x, top.z)
		var seg := g - here
		var t := clampf((c - here).dot(seg) / maxf(seg.length_squared(), 0.001), 0.0, 1.0)
		if (here + seg * t).distance_to(c) < 2.3 and here.distance_to(c) > 2.0:
			var center := Vector2(arena.center.x, arena.center.z)
			var w := c + (center - c).normalized() * 2.9
			return Vector3(w.x, pos().y, w.y)
	return goal


func _climb_perch() -> void:
	var p := _pick_perch()
	if p.is_empty():
		stop()
		return
	var top: Vector3 = p.top
	var base: Vector3 = p.ramp_base
	var ramp_top: Vector3 = p.ramp_top
	var height := pos().y - float(arena.floor_y)
	var h: float = float(p.get("height", 3.6))
	if height < 0.3 and Vector2(base.x - pos().x, base.z - pos().z).length() > 0.7:
		go_to(_around_columns(base), 0.5, 4.0)
	elif Vector2(ramp_top.x - pos().x, ramp_top.z - pos().z).length() > 0.6 and height < h - 0.3:
		go_to(ramp_top, 0.4, 0.0)
	else:
		go_to(top, 0.4, 0.0)



## The archer's candidate spell, spent when it pays: marks from a perch,
## fire when the core is about to be shot, hounds when someone is in trouble.
func _maybe_spell(mate: Player) -> void:
	var sp := spells()
	if sp == null or not sp.ready_now() or naive:
		return
	match sp.kind:
		"mark":
			if _on_perch() and boss.act != ColossusBoss.Act.STAGGER:
				body._ai_spell2 = true
		"incendiary":
			if boss.core_open() or boss.grab_victim() != null:
				body._ai_spell2 = true
		"decoy":
			var trouble := hp_frac() < 0.5 or (mate != null and (mate.is_dead
					or mate.current_health / mate.max_health < 0.4))
			var aimed: float = float(boss.strike_eta_for(body).eta)
			if trouble or aimed < 1.2:
				body._ai_spell2 = true
