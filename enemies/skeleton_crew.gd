class_name SkeletonCrew
extends Node3D

## Spawns and shepherds the pack of five skeleton warriors.
##
## The pack rises GROUPED at a random dark spot not far from Bobba's
## spawn (25-40 m out, random bearing — the whole field is night, so any
## spot away from fires is "dark"). Each killed skeleton lies where it
## fell and RISES AGAIN 10 seconds later somewhere else inside the haunt.

const SkeletonScript := preload("res://enemies/skeleton.gd")

const PACK_SIZE := 5
## Phones get a smaller pack rather than no pack. The crew was switched off
## outright on Android/iOS "pending a perf pass", which cost the platform the
## one encounter the co-op design is built around — a crowd you cannot see.
## Three still reads as a crowd, and the fire scan they share is now cached
## (skeleton.gd) instead of walking the scene tree per skeleton per frame,
## which was the other half of what made five expensive.
const PACK_SIZE_PERF := 3
const HAUNT_MIN_DIST := 25.0     # from Bobba's spawn
const HAUNT_MAX_DIST := 40.0
const CLUSTER_RADIUS := 5.0      # how tightly the pack rises together
const REVIVE_SECONDS := 20.0
const REVIVE_SCATTER_MIN := 8.0  # "somewhere else": new spot in the haunt
const REVIVE_SCATTER_MAX := 22.0

var haunt_center: Vector3


func _ready() -> void:
	# A CONTROL SWITCH, for asking whether the pack is what is tipping a fight.
	# The co-op scenarios are balance experiments as much as they are tests, and
	# the only honest way to read one is against the same run with the variable
	# taken out of it:
	#   LOB_NO_SKELETONS=1 tools/run_combat_scenario.sh WATCH
	if OS.get_environment("LOB_NO_SKELETONS") == "1":
		print("SkeletonCrew: standing down — LOB_NO_SKELETONS=1 (control run)")
		return
	# Scripted combat scenarios (SOULS/COMBO/PARRY...) measure exact duel
	# numbers — a wandering pack 30 m away would crash every assertion.
	# The crew rises only in real play modes and its own test scenario.
	var gs := get_node_or_null("/root/GameSettings")
	if gs and "combat_scenario" in gs:
		var sc := String(gs.combat_scenario)
		# WATCH belongs on this list: it is a real night session that happens
		# to have bots on both sides, and a search with nothing in the dark to
		# find is not a test of anything.
		if sc != "" and sc not in ["SKEL", "DARKSIM", "COOP", "PLAY", "ARCHER",
				"POSTER", "WATCH"]:
			print("SkeletonCrew: standing down for scenario '%s'" % sc)
			return
	# Wait for the stage (terrain collision) before ground-probing spawns.
	await get_tree().create_timer(1.0).timeout
	var bobba := get_tree().get_first_node_in_group("bobba")
	var origin: Vector3 = bobba.global_position if bobba else Vector3(3, 1, 13)
	var ang := randf() * TAU
	var dist := randf_range(HAUNT_MIN_DIST, HAUNT_MAX_DIST)
	haunt_center = _on_ground(origin + Vector3(cos(ang) * dist, 0.0, sin(ang) * dist))
	var pack: int = PACK_SIZE_PERF if _is_performance_mode() else PACK_SIZE
	print("SkeletonCrew: %d rising at %s (%.0fm from Bobba's spawn)" % [
			pack, str(haunt_center.snapped(Vector3.ONE)), dist])
	for i in pack:
		var sk: CharacterBody3D = SkeletonScript.new()
		sk.name = "Skeleton%d" % i
		sk.crowd_slot = i
		# Ragged scatter — a risen pack, not a formation.
		var off_ang := randf() * TAU
		var off := Vector3(cos(off_ang), 0.0, sin(off_ang)) * randf_range(1.0, CLUSTER_RADIUS + 2.0)
		var pos := _on_ground(haunt_center + off)
		sk.home_post = pos
		add_child(sk)
		sk.global_position = pos + Vector3(0, 0.3, 0)
		sk.died.connect(_on_skeleton_died)


func _on_skeleton_died(skeleton: Node) -> void:
	print("SkeletonCrew: %s destroyed — rises again in %.0fs" % [skeleton.name, REVIVE_SECONDS])
	var tw := create_tween()
	tw.tween_interval(REVIVE_SECONDS)
	tw.tween_callback(func() -> void:
		if not is_instance_valid(skeleton):
			return
		var ang := randf() * TAU
		var pos := _on_ground(haunt_center + Vector3(cos(ang), 0.0, sin(ang)) \
				* randf_range(REVIVE_SCATTER_MIN, REVIVE_SCATTER_MAX))
		skeleton.revive_at(pos + Vector3(0, 0.3, 0)))


## Same test the stage uses for grass and shadows, rather than a second
## hardcoded platform list — one answer to "is this a weak device", so
## --performance-mode on a desktop reproduces what the phone gets.
func _is_performance_mode() -> bool:
	if OS.has_feature("mobile"):
		return true
	var gs := get_node_or_null("/root/GameSettings")
	return gs != null and "performance_mode" in gs and bool(gs.performance_mode)


func _on_ground(pos: Vector3) -> Vector3:
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(
			pos + Vector3(0, 60, 0), pos + Vector3(0, -60, 0), 1)
	var hit: Dictionary = space.intersect_ray(query)
	if hit.has("position"):
		return hit.position
	return Vector3(pos.x, 1.0, pos.z)
