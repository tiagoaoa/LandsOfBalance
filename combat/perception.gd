class_name Perception
extends RefCounted

## Night-vision rules shared by every AI in the game.
##
## The world is a rainy NIGHT — AI characters cannot see other characters
## in the dark. A character only becomes visible to an AI when FIRE reveals
## them: standing inside the glow of a burning ground fire (the archer's
## fire arrows are the reveal tool) or right next to a fire arrow in
## flight. Smell/touch exceptions live with the specific AI (Bobba smells
## characters that come too close; anyone who HITS an AI reveals himself).

## THE INVARIANT THIS FILE EXISTS FOR: MOON_REVEAL_RADIUS < FIRE_REVEAL_RADIUS.
##
## It was the other way round — moon 25 m against fire 12 m — which quietly
## cancelled the entire mechanic. Free moonlight sight completely contained
## fire's, so lighting a fire could never show an AI anything it could not
## already see; the archer's fires only added sight beyond 25 m, which is past
## where any fight happens. Everything downstream of this file behaved as
## designed. The design just could not reach the numbers.
##
## The radii now match the lights that are actually RENDERED, so what an AI
## knows and what a player can see are the same claim (fire_fx.gd builds the
## ground-fire glow at range 18, arrow.gd the in-flight one at 6):
const FIRE_REVEAL_RADIUS := 18.0   # = the ground fire's own light range
const ARROW_REVEAL_RADIUS := 6.0   # = the burning arrow's light range in flight
## Moonlight shows you a shape, not a threat, and only right on top of you.
## Deliberately shorter than Bobba's 10 m sense of smell: he finds you in the
## dark by scent BEFORE he can make you out, which is the intended order.
const MOON_REVEAL_RADIUS := 8.0
const DAY_REVEAL_RADIUS := 120.0   # daylight (GRASS/MOVE test presets)
const FIRE_SIGHT_RADIUS := 90.0    # a fire-LIT character is visible across the field

static var _lighting_mgr: Node = null


## Moonlight visibility range: the rainy night has a full moon, so nearby
## silhouettes ARE visible without fire; the day presets see much further.
static func moonlight_range(node: Node3D) -> float:
	if _lighting_mgr == null or not is_instance_valid(_lighting_mgr):
		var scene := node.get_tree().current_scene if node.get_tree() else null
		_lighting_mgr = scene.find_child("LightingManager", true, false) if scene else null
	if _lighting_mgr and "time_of_day" in _lighting_mgr \
			and int(_lighting_mgr.time_of_day) == 0:  # TimeOfDay.DAY
		return DAY_REVEAL_RADIUS
	return MOON_REVEAL_RADIUS


## The one question every AI asks: can `observer` see `target` right now?
## Yes if the target is close enough to read under the moonlight, or if it
## stands in a fire's glow (then it is visible from far across the dark).
static func can_see(observer: Node3D, target: Node3D) -> bool:
	if observer == null or target == null \
			or not is_instance_valid(observer) or not is_instance_valid(target):
		return false
	var dist := observer.global_position.distance_to(target.global_position)
	if dist <= moonlight_range(observer):
		return true
	return dist <= FIRE_SIGHT_RADIUS and is_lit_by_fire(target)


## How strongly fire falls on `node`: 1.0 standing in the flames, easing to
## 0.0 at the edge of the reveal. `is_lit_by_fire` is the same question asked
## as a yes/no, which is all an AI needs; a renderer needs the gradient, so
## that a body walking out of the light dims instead of switching off.
static func fire_lit_amount(node: Node3D) -> float:
	if node == null or not is_instance_valid(node):
		return 0.0
	var tree := node.get_tree()
	if tree == null:
		return 0.0
	var pos := node.global_position
	var best := 0.0
	for spec in [["ground_fire", FIRE_REVEAL_RADIUS], ["fire_arrows", ARROW_REVEAL_RADIUS]]:
		var radius: float = spec[1]
		for fire in tree.get_nodes_in_group(spec[0]):
			if fire is Node3D and is_instance_valid(fire):
				var d: float = pos.distance_to((fire as Node3D).global_position)
				if d < radius:
					# Falls off toward the edge rather than at it — a hard
					# ring of light moving over a body reads as a bug.
					best = maxf(best, 1.0 - (d / radius) * (d / radius))
	return best


## True when `node` stands in the light of any burning fire.
static func is_lit_by_fire(node: Node3D) -> bool:
	if node == null or not is_instance_valid(node):
		return false
	var tree := node.get_tree()
	if tree == null:
		return false
	var pos := node.global_position
	for fire in tree.get_nodes_in_group("ground_fire"):
		if fire is Node3D and is_instance_valid(fire):
			if pos.distance_to((fire as Node3D).global_position) <= FIRE_REVEAL_RADIUS:
				return true
	for arrow in tree.get_nodes_in_group("fire_arrows"):
		if arrow is Node3D and is_instance_valid(arrow):
			if pos.distance_to((arrow as Node3D).global_position) <= ARROW_REVEAL_RADIUS:
				return true
	return false


## Every character an AI could care about: the human player, the AI
## companion, and any remote players.
static func all_characters(tree: SceneTree) -> Array:
	var result: Array = []
	for gname in ["player", "companion", "remote_players"]:
		for n in tree.get_nodes_in_group(gname):
			if is_instance_valid(n) and not result.has(n):
				result.append(n)
	return result
