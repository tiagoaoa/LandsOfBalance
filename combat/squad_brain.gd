class_name SquadBrain
extends Node

## The party's shared tactical picture: ONE scan of the world, ten times a
## second, that every co-op AI reads instead of scanning for itself.
##
## WHY IT EXISTS — PERFORMANCE. Every companion used to answer "where is the
## enemy / which fires are burning / who is hunting whom" by walking the scene
## groups inside its own _physics_process, sixty times a second, and
## Perception re-walked the fire groups again inside every can_see() on top of
## that. One shared 10 Hz snapshot collapses all of it into a single pass whose
## cost does not grow when a second, third or fourth companion joins. After the
## snapshot the AIs do nothing per frame but read floats and steer.
##
## WHY IT EXISTS — INTELLIGENCE. A squad is not two loners standing near each
## other. Anything ONE member perceives, the party knows: that is a shout in
## the dark, and it is the only reason the archer's fire arrow can serve a
## paladin fighting fifty metres away. Shared, though, is not FREE — every
## contact carries a CONFIDENCE that decays, and the whole co-op loop is what
## the party does about the difference:
##
##   fresh + lit   → fight it            (the archer already did his job)
##   known + dark  → LIGHT IT, then fight it
##   felt, unseen  → a bearing from a punch that goes stale in seconds
##   cold          → search the last known ground, then admit the dark won
##
## Nothing here decides anything. It answers questions; player/ai/*_role.gd
## decides.

const TICK := 0.1                 # 10 Hz — tactics do not need frame rate
const MEM_FRESH := 3.0            # a sighting is a FACT for this long
const MEM_FADE := 10.0            # ...then a fading guess, until this long
const PARTY_SIGHT := 40.0         # allies keep voice contact this far apart
const HEAR_RANGE := 18.0          # a charging, roaring enemy is audible
const LIGHT_WANT_RANGE := 32.0    # dark enemies this near an ally want light
const MELEE_RANGE := 3.2
const ROAR_HEARING := 140.0       # a roar in a night field carries this far
const ROAR_SCATTER := 12.0        # ...and places him only this accurately
const ROAR_CIRCLE := 25.0         # the search circle a roar opens
const LEAD_FADE := 75.0           # how long a lost enemy stays worth searching for
const LEAD_SPREAD := 3.0          # m/s the search circle grows once he is loose
const LEAD_RADIUS_MAX := 45.0

## Enemy groups the party can meet. Bobba leads: he is the boss, and the
## tie-break when everything else scores level.
const ENEMY_GROUPS: Array[String] = ["bobba", "skeletons", "dragon"]


## One enemy, as the PARTY knows it — which is not the same as where it is.
class Contact extends RefCounted:
	const MEM_FRESH := 3.0
	const MEM_FADE := 10.0
	const BLIND_FADE := 2.5       # a bearing felt through a fist, not seen

	var node: Node3D = null
	var pos := Vector3.ZERO       # LAST KNOWN position — never the live one
	var last_seen := -999.0
	var blind := false            # known by touch/sound only: decays fast
	var lit := false              # standing in firelight this instant
	var seen_now := false         # a party member has eyes on it right now
	var hunting: Node3D = null    # the ally it is chasing, if any
	var hp_frac := 1.0
	var boss := false
	var threat := 0.0
	var ally_dist := INF          # to the nearest living party member
	var vel := Vector3.ZERO       # which way it was going when last seen

	## 1.0 = we know where it is. 0.0 = we are guessing about a ghost.
	func confidence(now: float) -> float:
		var age := now - last_seen
		if blind:
			return clampf(1.0 - age / BLIND_FADE, 0.0, 1.0)
		if age <= MEM_FRESH:
			return 1.0
		return clampf(1.0 - (age - MEM_FRESH) / (MEM_FADE - MEM_FRESH), 0.0, 1.0)

	func alive() -> bool:
		return node != null and is_instance_valid(node)


## A LEAD: the ground where the party lost something, and the direction it was
## travelling when it went dark.
##
## Without this, a contact whose confidence runs out simply VANISHES from the
## picture — and with it the party's last reason to go anywhere. That is not a
## theory: it is how a boss at 20% health walks into the dark, regenerates 3%
## a second, and leaves two bots patrolling an empty field for the rest of the
## night. A lead keeps the hunt alive: the archer combs its search circle with
## fire (which is the only way anything gets found out here) and the paladin
## walks in behind the light. The circle GROWS with the time he has had to
## move, because a minute-old lead is an area, not a point.
class Lead extends RefCounted:
	var node: Node3D = null
	var pos := Vector3.ZERO
	var dir := Vector3.ZERO       # unit, flat — his heading when we lost him
	var lost_at := -999.0
	var boss := false
	var swept := 0                # arrows already spent combing this circle

	## Where he probably is now, if he kept walking.
	func predict(now: float) -> Vector3:
		return pos + dir * minf((now - lost_at) * LEAD_SPREAD, LEAD_RADIUS_MAX)

	## How wide the party has to look. Six metres at the moment of losing him,
	## opening out as the trail cools.
	func radius(now: float) -> float:
		return clampf((now - lost_at) * LEAD_SPREAD, 6.0, LEAD_RADIUS_MAX)

	func fresh(now: float) -> bool:
		return node != null and is_instance_valid(node) and now - lost_at < LEAD_FADE


## One party member, as the party knows it.
class Ally extends RefCounted:
	var node: Node3D = null
	var pos := Vector3.ZERO
	var anchor := Vector3.ZERO    # last CONFIRMED position (call-outs included)
	var anchor_time := -999.0
	var hp_frac := 1.0
	var is_dead := false
	var is_paladin := false
	var pressure := 0             # how many enemies are hunting this member
	var threat_dist := INF        # ...and how close the nearest of them is


static var _instance: SquadBrain = null

var now := 0.0
var contacts: Array = []          # Array[Contact] — live AND remembered
var allies: Array = []            # Array[Ally]
var fires := PackedVector3Array()        # every flame burning, wherever it is
## The subset burning ON THE GROUND. A fire stuck to an enemy (player/arrow.gd
## sets one alight for thirty seconds) still LIGHTS him — it belongs in
## `fires`, and a burning enemy being visible to the whole party is the point
## of it — but it is not a place, so it can never be cover, a wall, or a patch
## of ground that already has light on it. Those questions ask this list.
var ground_fires := PackedVector3Array()
var arrow_fires := PackedVector3Array()  # fire arrows still in flight
var focus: Contact = null         # what the party should be killing
var light_requests: Array = []    # [{pos, priority, contact}] — the archer's queue
var leads: Array = []             # Array[Lead] — where we lost them, and when
var last_tick_usec := 0           # self-measured cost, printed by COOPSIM

var _by_id := {}                  # instance id -> Contact
var _ally_by_id := {}             # instance id -> Ally
var _accum := 0.0


## The one brain, created on demand by whoever needs it first. Freed with the
## scene; a stale static handle after a reload is detected and replaced.
static func get_brain(node: Node) -> SquadBrain:
	if _instance != null and is_instance_valid(_instance):
		return _instance
	if node == null or not is_instance_valid(node):
		return null
	var tree := node.get_tree()
	if tree == null or tree.current_scene == null:
		return null
	var brain := SquadBrain.new()
	brain.name = "SquadBrain"
	tree.current_scene.add_child(brain)
	_instance = brain
	return brain


## "Something hit me and I never saw it." The single most important call in
## the co-op loop: a party member taking damage in the dark posts a BEARING,
## which becomes the archer's top-priority illumination request. The paladin
## can swing at it; only fire turns it into a target the party can fight.
static func note_attack(victim: Node, attacker: Node) -> void:
	if _instance == null or not is_instance_valid(_instance):
		return
	if attacker == null or not is_instance_valid(attacker) or not (attacker is Node3D):
		return
	if not Factions.is_party(victim) or Factions.is_party(attacker):
		return
	_instance._felt(attacker as Node3D, victim as Node3D)


## "Something out there just made a noise." A roar is not a sighting — it does
## not say where he IS, it says roughly where he WAS and that he is out there
## at all. So it opens a LEAD with a wide circle rather than a contact: the
## archer combs it, the paladin walks it down, and neither of them can fight
## something they have not actually found yet.
##
## The player hears the same roar the AI does, from the same 3D source. This
## is information the boss gives away, not information the party is handed.
static func note_roar(source: Node3D) -> void:
	if _instance == null or not is_instance_valid(_instance):
		return
	if source == null or not is_instance_valid(source):
		return
	_instance._heard_roar(source)


func _heard_roar(source: Node3D) -> void:
	if pos_dist_to_party(source.global_position) > ROAR_HEARING:
		return   # nobody close enough to hear it
	var l: Lead = _lead_for(source)
	# A roar is worth less than actually having seen him: if the party already
	# holds a fresher trail, keep it.
	var implied_age: float = ROAR_CIRCLE / LEAD_SPREAD
	if l != null and l.lost_at > now - implied_age:
		return
	if l == null:
		l = Lead.new()
		l.node = source
		leads.append(l)
	var ang := randf() * TAU
	l.pos = source.global_position \
			+ Vector3(cos(ang), 0.0, sin(ang)) * randf_range(0.0, ROAR_SCATTER)
	l.dir = Vector3.ZERO          # a noise has no heading
	l.lost_at = now - implied_age  # ...so it starts as a circle, not a point
	l.boss = source.is_in_group("bobba") or source.is_in_group("dragon")
	l.swept = 0
	print("SquadBrain: a roar out of the dark — searching %.0fm of ground around %s" % [
			l.radius(now), str(l.pos.snapped(Vector3.ONE))])


func _ready() -> void:
	process_priority = -10  # snapshot first, then everyone reads it this frame


func _process(delta: float) -> void:
	_accum += delta
	if _accum < TICK:
		return
	var dt := _accum
	_accum = 0.0
	var started := Time.get_ticks_usec()
	now += dt
	_scan_fires()
	_scan_allies()
	_scan_enemies()
	_score()
	last_tick_usec = Time.get_ticks_usec() - started


# ---------------------------------------------------------------- snapshot --

func _scan_fires() -> void:
	fires.clear()
	ground_fires.clear()
	arrow_fires.clear()
	for fire in get_tree().get_nodes_in_group("ground_fire"):
		if fire is Node3D and is_instance_valid(fire):
			var at: Vector3 = (fire as Node3D).global_position
			fires.append(at)
			if not fire.is_in_group("body_fire"):
				ground_fires.append(at)
	for arrow in get_tree().get_nodes_in_group("fire_arrows"):
		if arrow is Node3D and is_instance_valid(arrow):
			arrow_fires.append((arrow as Node3D).global_position)


func _scan_allies() -> void:
	allies.clear()
	for node in Perception.all_characters(get_tree()):
		if not (node is Node3D):
			continue
		var n3 := node as Node3D
		var rec: Ally = _ally_by_id.get(n3.get_instance_id())
		if rec == null:
			rec = Ally.new()
			rec.node = n3
			rec.anchor = n3.global_position
			rec.anchor_time = now
			_ally_by_id[n3.get_instance_id()] = rec
		rec.pos = n3.global_position
		rec.is_dead = bool(n3.get("is_dead")) if "is_dead" in n3 else false
		if "current_health" in n3 and "max_health" in n3:
			rec.hp_frac = float(n3.current_health) / maxf(float(n3.max_health), 1.0)
		if "character_class" in n3:
			rec.is_paladin = int(n3.character_class) == 0  # CharacterClass.PALADIN
		rec.pressure = 0
		rec.threat_dist = INF
		allies.append(rec)
	# Call-outs: a member is CONFIRMED when another member has voice contact
	# (PARTY_SIGHT) or actually sees him. Otherwise his anchor ages, and the
	# AIs walk to the last place they know he was.
	for a in allies:
		var a_lit: bool = lit_amount(a.pos) > 0.0
		for b in allies:
			if a == b:
				continue
			var d: float = a.pos.distance_to(b.pos)
			# Same night rules as for enemies, asked against the fire list we
			# already hold rather than re-walking the scene per pair.
			if d <= PARTY_SIGHT or d <= Perception.moonlight_range(b.node) \
					or (a_lit and d <= Perception.FIRE_SIGHT_RADIUS):
				a.anchor = a.pos
				a.anchor_time = now
				break
	# Drop records for members that left the scene.
	for key in _ally_by_id.keys():
		var rec: Ally = _ally_by_id[key]
		if rec.node == null or not is_instance_valid(rec.node):
			_ally_by_id.erase(key)


func _scan_enemies() -> void:
	for gname in ENEMY_GROUPS:
		for node in get_tree().get_nodes_in_group(gname):
			if not (node is Node3D) or not is_instance_valid(node):
				continue
			var enemy := node as Node3D
			if not _enemy_alive(enemy):
				_forget(enemy)
				continue
			var pos: Vector3 = enemy.global_position
			var lit: bool = lit_amount(pos) > 0.0
			var hunting: Node3D = _hunted_ally(enemy)
			var nearest_ally := INF
			var seen := false
			for a in allies:
				if a.is_dead:
					continue
				var d: float = a.pos.distance_to(pos)
				nearest_ally = minf(nearest_ally, d)
				if seen:
					continue
				# The shared night rules, asked with the fire list we already
				# have in hand instead of re-walking the scene per question.
				if d <= Perception.moonlight_range(a.node):
					seen = true
				elif lit and d <= Perception.FIRE_SIGHT_RADIUS:
					seen = true
			var c: Contact = _contact_for_node(enemy)
			c.lit = lit
			c.seen_now = seen
			c.hunting = hunting
			c.ally_dist = nearest_ally
			c.boss = enemy.is_in_group("bobba") or enemy.is_in_group("dragon")
			c.hp_frac = _enemy_hp_frac(enemy)
			if seen:
				c.pos = pos
				c.last_seen = now
				c.blind = false
				if "velocity" in enemy:
					c.vel = Vector3(enemy.velocity.x, 0.0, enemy.velocity.z)
				# Found again: the search that was aimed at him is over.
				_drop_lead(enemy)
			elif hunting != null and nearest_ally <= HEAR_RANGE:
				# Heard, not seen: a charging enemy at close range gives away
				# roughly where it is, and nothing else.
				c.pos = pos
				c.last_seen = now
				c.blind = true
	# Forget what has faded out of the party's memory entirely. The index is
	# rebuilt from the survivors rather than erased key by key: a contact
	# whose node was freed can no longer tell us the key it was filed under.
	var kept: Array = []
	_by_id.clear()
	for c in contacts:
		if not c.alive() or c.confidence(now) <= 0.0:
			# Gone cold — but a living enemy that walked off into the dark is
			# not gone, he is SOMEWHERE, and the party has a bearing on where
			# he was headed. That bearing is the whole search.
			# ...but only for something the party ACTUALLY had. Every enemy in
			# the world gets a Contact record the first time it is scanned,
			# seen or not; opening leads on those would hand the party a free
			# trail to things nobody has ever laid eyes on (and, since an
			# unseen contact has no last known position, send them to the
			# world origin to look for it).
			if c.alive() and c.last_seen > 0.0 and _enemy_alive(c.node):
				_open_lead(c)
			continue
		kept.append(c)
		_by_id[c.node.get_instance_id()] = c
	contacts = kept
	# Leads go stale too: past LEAD_FADE the trail says nothing the party
	# cannot work out by walking around with a torch.
	var live_leads: Array = []
	for l in leads:
		if l.fresh(now):
			live_leads.append(l)
	leads = live_leads


func _score() -> void:
	focus = null
	light_requests.clear()
	var best := -INF
	for c in contacts:
		var conf: float = c.confidence(now)
		# Threat = what it is, what it is doing, and how close it has got.
		var t: float = 2.5 if c.boss else 1.0
		if c.hunting != null:
			t *= 1.9
		t *= 1.0 + clampf((36.0 - c.ally_dist) / 36.0, 0.0, 1.0) * 1.5
		t *= conf
		# A lit enemy is one the party can actually FIGHT; a dark one is a
		# problem to be solved with an arrow first.
		if c.lit:
			t *= 1.25
		c.threat = t
		if c.hunting != null:
			for a in allies:
				if a.node == c.hunting:
					a.pressure += 1
					a.threat_dist = minf(a.threat_dist, a.pos.distance_to(c.pos))
		if conf > 0.15 and t > best:
			best = t
			focus = c
		# ILLUMINATION QUEUE. Anything the party knows about but cannot see is
		# an arrow's worth of work, ranked by how badly it is hurting us.
		if not c.lit and conf > 0.1 and c.ally_dist <= LIGHT_WANT_RANGE:
			var prio: float = 1.0
			if c.hunting != null:
				prio = 3.5 if c.ally_dist <= MELEE_RANGE * 2.5 else 2.5
			if c.boss:
				prio += 0.5
			prio *= conf
			light_requests.append({"pos": c.pos, "priority": prio, "contact": c})
	light_requests.sort_custom(func(a, b): return float(a.priority) > float(b.priority))


# ------------------------------------------------------------------ asking --

## How strongly firelight falls on a world point (1.0 in the flames → 0.0 at
## the edge of the reveal), from the cached fire list. Same radii as
## Perception, which is the same claim as what the renderer draws.
func lit_amount(pos: Vector3) -> float:
	var best := 0.0
	for f in fires:
		var d: float = pos.distance_to(f)
		if d < Perception.FIRE_REVEAL_RADIUS:
			var k: float = d / Perception.FIRE_REVEAL_RADIUS
			best = maxf(best, 1.0 - k * k)
	for f in arrow_fires:
		var d: float = pos.distance_to(f)
		if d < Perception.ARROW_REVEAL_RADIUS:
			var k: float = d / Perception.ARROW_REVEAL_RADIUS
			best = maxf(best, 1.0 - k * k)
	return best


## Distance to the nearest burning ground fire, or INF. Fire is friendly to
## the party (Factions: no friendly fire) and feared by everything else, so
## this is read as COVER as often as it is read as a hazard.
func fire_dist(pos: Vector3) -> float:
	var best := INF
	for f in ground_fires:
		best = minf(best, pos.distance_to(f))
	return best


## How many fires are already burning within `radius` of a point. Every arrow
## that lands lights one for thirty seconds, so this is both a tactical
## question ("is that ground already covered?") and a budget one — a field
## full of fire lights is a field full of shadow-casting lights.
func fires_near(pos: Vector3, radius: float) -> int:
	var n := 0
	for f in ground_fires:
		if pos.distance_to(f) <= radius:
			n += 1
	return n


func ally_for(node: Node) -> Ally:
	for a in allies:
		if a.node == node:
			return a
	return null


func contact_for(node: Node) -> Contact:
	return _by_id.get(node.get_instance_id() if node != null else 0)


## The enemy hunting `ally_node` that has got closest to them.
func threat_on(ally_node: Node) -> Contact:
	var best: Contact = null
	var best_d := INF
	for c in contacts:
		if c.hunting != ally_node or c.confidence(now) <= 0.1:
			continue
		var d: float = c.pos.distance_to((ally_node as Node3D).global_position)
		if d < best_d:
			best_d = d
			best = c
	return best


## The party member other than `me` that is worst off — who to heal, who to
## peel for, whose body to run to.
func neediest_ally(me: Node) -> Ally:
	var worst: Ally = null
	for a in allies:
		if a.node == me or a.node == null or not is_instance_valid(a.node):
			continue
		if worst == null or a.is_dead and not worst.is_dead \
				or (a.is_dead == worst.is_dead and a.hp_frac < worst.hp_frac):
			worst = a
	return worst


func status_line() -> String:
	var lit_n := 0
	for c in contacts:
		if c.lit:
			lit_n += 1
	var f: String = "none"
	if focus != null:
		f = "%s(%s conf %.2f thr %.1f)" % [focus.node.name,
				"lit" if focus.lit else "dark", focus.confidence(now), focus.threat]
	var l := best_lead()
	var lead_s: String = "none"
	if l != null:
		lead_s = "%s %.0fm r%.0f" % [l.node.name, pos_dist_to_party(l.predict(now)), l.radius(now)]
	return "contacts=%d lit=%d fires=%d focus=%s lightq=%d lead=%s brain=%dus" % [
			contacts.size(), lit_n, fires.size(), f, light_requests.size(),
			lead_s, last_tick_usec]


## Distance from a world point to the nearest living party member.
func pos_dist_to_party(p: Vector3) -> float:
	var best := INF
	for a in allies:
		if not a.is_dead:
			best = minf(best, a.pos.distance_to(p))
	return best


# ------------------------------------------------------------- bookkeeping --

func _felt(attacker: Node3D, victim: Node3D) -> void:
	var c: Contact = _contact_for_node(attacker)
	c.pos = attacker.global_position
	c.last_seen = now
	c.hunting = victim
	# Only downgrade to "blind" if nobody actually has eyes on it — a lit
	# enemy that punches you is still a lit enemy.
	if not c.seen_now:
		c.blind = true


func _contact_for_node(enemy: Node3D) -> Contact:
	var id := enemy.get_instance_id()
	var c: Contact = _by_id.get(id)
	if c == null:
		c = Contact.new()
		c.node = enemy
		_by_id[id] = c
		contacts.append(c)
	return c


## Remember where we lost him. One lead per enemy — a re-lost contact refreshes
## the trail rather than littering the field with ghosts of itself.
func _open_lead(c: Contact) -> void:
	var l: Lead = _lead_for(c.node)
	if l == null:
		l = Lead.new()
		l.node = c.node
		leads.append(l)
	l.pos = c.pos
	var d: Vector3 = c.vel
	d.y = 0.0
	l.dir = d.normalized() if d.length() > 0.5 else Vector3.ZERO
	l.lost_at = now
	l.boss = c.boss
	l.swept = 0


func _drop_lead(enemy: Node3D) -> void:
	var l: Lead = _lead_for(enemy)
	if l != null:
		leads.erase(l)


func _lead_for(enemy: Node3D) -> Lead:
	for l in leads:
		if l.node == enemy:
			return l
	return null


## The trail worth walking down: the boss first, then the freshest.
func best_lead() -> Lead:
	var best: Lead = null
	for l in leads:
		if not l.fresh(now):
			continue
		if best == null or (l.boss and not best.boss) \
				or (l.boss == best.boss and l.lost_at > best.lost_at):
			best = l
	return best


## True when the party has nothing solid to fight — nobody is confident about
## any enemy's position. This is the state the archer's search light exists for.
func blind() -> bool:
	for c in contacts:
		if c.confidence(now) > 0.35:
			return false
	return true


func _forget(enemy: Node3D) -> void:
	var id := enemy.get_instance_id()
	if not _by_id.has(id):
		return
	var c: Contact = _by_id[id]
	_by_id.erase(id)
	contacts.erase(c)
	_drop_lead(enemy)   # dead: nothing left to search for


func _enemy_alive(enemy: Node3D) -> bool:
	if "is_dead_skeleton" in enemy and bool(enemy.is_dead_skeleton):
		return false
	if "health" in enemy and float(enemy.health) <= 0.0:
		return false
	if "hp" in enemy and float(enemy.hp) <= 0.0:
		return false
	return true


func _enemy_hp_frac(enemy: Node3D) -> float:
	if "health" in enemy and "MAX_HEALTH" in enemy:
		return float(enemy.health) / maxf(float(enemy.MAX_HEALTH), 1.0)
	if "hp" in enemy and "MAX_HP" in enemy:
		return float(enemy.hp) / maxf(float(enemy.MAX_HP), 1.0)
	return 1.0


## Which party member this enemy is chasing. Bobba and the dragon expose
## `target`; a skeleton picks its prey into `_target`.
func _hunted_ally(enemy: Node3D) -> Node3D:
	var t: Variant = null
	if "target" in enemy:
		t = enemy.target
	elif "_target" in enemy:
		t = enemy._target
	if t is Node3D and is_instance_valid(t) and Factions.is_party(t):
		return t as Node3D
	return null
