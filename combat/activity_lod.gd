class_name ActivityLOD
extends Node

## Puts an enemy to sleep while nothing it does could matter to anyone.
##
## Asleep means its whole subtree stops processing: AI, physics step,
## AnimationPlayer, skeleton, capes, particles' bookkeeping. It just holds its
## pose. Godot already skips DRAWING what the camera can't see; this skips
## the rest of the cost of an enemy nobody can see or reach.
##
## An enemy may only sleep when all three hold:
##   - it is not engaged (no target, not fighting, not network-driven),
##   - no character and no camera is within `wake_radius`, which covers the
##     farthest it can perceive anyone (Perception's fire sight is 90 m; by
##     day 120 m), so a sleeper never misses someone it would have noticed,
##   - it is not on screen (a frozen pose must never be what you look at).
## Waking has hysteresis (`wake_radius` in, `wake_radius + SLEEP_MARGIN` out)
## so an enemy on the edge doesn't flicker between the two.
##
##   ActivityLOD.attach(self, func() -> bool: return target != null)

const CHECK_INTERVAL := 0.25
const SLEEP_MARGIN := 15.0
## Beyond the widest perception range in the game (Perception.DAY_REVEAL_RADIUS
## = 120, FIRE_SIGHT_RADIUS = 90) plus room to wake before it matters.
const DEFAULT_WAKE_RADIUS := Perception.DAY_REVEAL_RADIUS + 15.0

## Set LOB_NO_ACTIVITY_LOD=1 to keep every enemy awake (A/B runs, debugging).
static var disabled: bool = OS.get_environment("LOB_NO_ACTIVITY_LOD") == "1"

var actor: Node3D
var engaged: Callable
var wake_radius := DEFAULT_WAKE_RADIUS
var asleep := false

var _notifier: VisibleOnScreenNotifier3D
var _timer := 0.0


static func attach(to: Node3D, is_engaged: Callable, radius: float = DEFAULT_WAKE_RADIUS,
		bounds: AABB = AABB(Vector3(-1, 0, -1), Vector3(2, 2.5, 2))) -> ActivityLOD:
	var lod := ActivityLOD.new()
	lod.name = "ActivityLOD"
	lod.actor = to
	lod.engaged = is_engaged
	lod.wake_radius = radius
	lod._notifier = VisibleOnScreenNotifier3D.new()
	lod._notifier.aabb = bounds
	to.add_child(lod._notifier)
	to.add_child(lod)
	# Coming into view wakes at once, not on the next check: nothing should
	# ever be caught holding a frozen pose on camera.
	lod._notifier.screen_entered.connect(lod.wake)
	return lod


func _ready() -> void:
	# Explicit mode: keeps ticking while the actor it put to sleep is DISABLED.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_timer = randf() * CHECK_INTERVAL   # a pack doesn't all check on one frame


func _process(delta: float) -> void:
	_timer -= delta
	if _timer > 0.0:
		return
	_timer = CHECK_INTERVAL
	if disabled or not is_instance_valid(actor):
		if asleep:
			_set_asleep(false)
		return
	_set_asleep(_should_sleep())


func _should_sleep() -> bool:
	if _notifier.is_on_screen():
		return false
	if engaged.is_valid() and engaged.call():
		return false
	var reach := wake_radius + (SLEEP_MARGIN if asleep else 0.0)
	var reach_sq := reach * reach
	var here := actor.global_position
	var cam := get_viewport().get_camera_3d()
	if cam and cam.global_position.distance_squared_to(here) < reach_sq:
		return false
	for group in [&"characters", &"remote_players"]:
		for c in get_tree().get_nodes_in_group(group):
			if c is Node3D and (c as Node3D).global_position.distance_squared_to(here) < reach_sq:
				return false
	return true


func _set_asleep(value: bool) -> void:
	if value == asleep:
		return
	asleep = value
	actor.process_mode = Node.PROCESS_MODE_DISABLED if asleep else Node.PROCESS_MODE_INHERIT


## Wake immediately (a hit, a scripted event) instead of on the next check.
func wake() -> void:
	_timer = CHECK_INTERVAL
	_set_asleep(false)
