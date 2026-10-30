## Still frames of the boss for art and animation review: the boss arena,
## the party frozen, the boss forced through each act, a fixed set of camera
## angles per beat. REVIEW_OUT=<dir> (default user://dragon_review).
## godot --path . --scene res://tools/review_dragon.tscn -- --singleplayer --spectate
extends Node3D

var arena: Node3D
var boss: Node3D
var cam: Camera3D
var out := ""


func _ready() -> void:
	seed(301)
	out = OS.get_environment("REVIEW_OUT")
	if out == "":
		out = ProjectSettings.globalize_path("user://dragon_review")
	DirAccess.make_dir_recursive_absolute(out)
	_run.call_deferred()


func _run() -> void:
	arena = load("res://tests/boss_arena/boss_arena.tscn").instantiate()
	add_child(arena)
	await get_tree().create_timer(2.5).timeout
	boss = get_tree().get_first_node_in_group("colossus") as Node3D
	boss.died.disconnect(arena._on_boss_died)
	# Freeze the party where it stands (no falls, no restarts) and hide the HUD.
	if OS.get_environment("REVIEW_GRAB") == "":
		for p in _party():
			(p as Node).process_mode = Node.PROCESS_MODE_DISABLED
	for cl in arena.find_children("*", "CanvasLayer", true, false):
		(cl as CanvasLayer).visible = false
	for cl in get_tree().root.find_children("*", "CanvasLayer", true, false):
		(cl as CanvasLayer).visible = false
	if OS.get_environment("REVIEW_STUDIO") != "":
		_studio()
	cam = Camera3D.new()
	cam.far = 600.0
	cam.fov = 60.0
	add_child(cam)
	cam.make_current()
	if OS.get_environment("REVIEW_GRAB") != "":
		await _grab_probe()
		await _finish()
		return
	if OS.get_environment("REVIEW_BURST") != "":
		await _bursts()
		print("[DragonReview] done -> ", out)
		await _finish()
		return
	var only := OS.get_environment("REVIEW_ONLY")
	var beats := [
		["idle", -1, 0.0],
		["slam_windup", 1, 0.9],
		["slam_impact", 1, 1.45],
		["sweep", 2, 1.9],
		["roar", 4, 1.3],
		["gaze", 5, 1.8],
		["breath", 5, 2.7],
		["tail", 12, 1.9],
		["stagger", 6, 1.0],
		["head_slam_windup", 13, 1.2],
		["head_slam_down", 13, 2.2],
		["death_rear", 20, 0.9],
	]
	for beat in beats:
		if only != "" and not (beat[0] in only.split(",")):
			continue
		await _beat(beat[0], beat[1], beat[2])
	print("[DragonReview] done -> ", out)
	await _finish()


func _finish() -> void:
	for voice in Sfx._pool:
		voice.stop()
		voice.stream = null
	arena.queue_free()
	await get_tree().create_timer(0.3).timeout
	get_tree().quit()


## Neutral light to judge the sculpt and the motion, not the night.
func _studio() -> void:
	for we in get_tree().root.find_children("*", "WorldEnvironment", true, false):
		var env := (we as WorldEnvironment).environment
		env.fog_enabled = false
		env.volumetric_fog_enabled = false
		env.background_mode = Environment.BG_COLOR
		env.background_color = Color(0.32, 0.34, 0.38)
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		env.ambient_light_color = Color(0.55, 0.57, 0.62)
		env.ambient_light_energy = 1.0
		env.tonemap_exposure = 1.0
	var key := DirectionalLight3D.new()
	key.light_energy = 2.2
	key.shadow_enabled = true
	key.rotation_degrees = Vector3(-40, 35, 0)
	add_child(key)


## Motion review: a fixed camera, a frame every 0.15 s through each act.
func _bursts() -> void:
	var acts := [["slam", 1, 2.4], ["sweep", 2, 3.6], ["roar", 4, 2.4], ["tail", 12, 3.2],
			["stagger", 6, 3.0], ["breath", 5, 3.8], ["death", 20, 7.5]]
	var only := OS.get_environment("REVIEW_ONLY")
	for a in acts:
		if only != "" and not (a[0] in only.split(",")):
			continue
		boss.call("_start", 0, 30.0)
		await get_tree().create_timer(2.5).timeout
		for view in ["front", "side"]:
			_place("side" if view == "side" else "front")
			match a[1]:
				1: boss.call("_begin_slam", _party(), _party())
				2: boss.call("_begin_sweep")
				4: boss.call("_begin_roar")
				5: boss.call("_begin_gaze", _party())
				6: boss.call("_stagger", 4.0, "poise")
				12: boss.call("_begin_tail")
				20: boss.call("_die")
			var n := int(float(a[2]) / 0.15)
			for k in n:
				await get_tree().create_timer(0.15).timeout
				await RenderingServer.frame_post_draw
				get_viewport().get_texture().get_image().save_jpg("%s/burst_%s_%s_%02d.jpg" % [out, a[0], view, k], 0.85)
			boss.call("_start", 0, 30.0)
			await get_tree().create_timer(2.5).timeout


func _debug_joints(label: String) -> void:
	var rig = boss.get("rig")
	var inv: Transform3D = boss.global_transform.affine_inverse()
	print("--- ", label)
	for i in 2:
		var ua: Node3D = boss.get("_ua")[i]
		var fa: Node3D = boss.get("_fa")[i]
		var hd: Node3D = boss.get("_hand")[i]
		print("arm%d shoulder %s elbow %s wrist %s" % [i, inv * ua.global_position, inv * fa.global_position, inv * hd.global_position])
	var sk: Skeleton3D = rig.skel
	for bn in ["upperarm.L", "forearm.L", "hand.L", "f1a.L", "f1b.L", "f1t.L", "f2b.L", "f3b.L", "upperarm.R", "forearm.R", "hand.R", "f1b.R", "f1t.R"]:
		var t: Transform3D = rig.skel_local * sk.get_bone_global_pose(sk.find_bone(bn))
		print("  %s %s" % [bn, t.origin])


## Live bots: seize the archer and log what the knight does about it.
func _grab_probe() -> void:
	await get_tree().create_timer(4.0).timeout
	var archer: Node3D = null
	var knight: Node3D = null
	for p in _party():
		if (p as Player).is_paladin():
			knight = p
		else:
			archer = p
	_place("front")
	var c: Vector3 = arena.get("center")
	var to_boss := (boss.global_position - c)
	to_boss.y = 0.0
	archer.global_position = c + to_boss.normalized() * 6.0 + Vector3(0, 0.2, 0)
	archer.process_mode = Node.PROCESS_MODE_DISABLED   # stays put: no dodge
	boss.set("_grab_cd", 0.0)
	boss.call("_begin_grab", [archer])
	for k in 40:
		await get_tree().create_timer(0.25).timeout
		var role = knight.get_node("CompanionAI").get("_role") if knight.has_node("CompanionAI") else null
		var tac: String = String(role.get("tactic")) if role else "?"
		var bh: Vector3 = boss.call("brace_hand_pos")
		var hb: Node3D = boss.get("_hand_body")[1 - int(boss.get("_hand_i"))]
		var cc: Vector3 = arena.get("center")
		if bh != Vector3.INF:
			print("   brace from centre %.1f (radius %.1f), height %.2f; brace_point=%s" % [
				Vector2(bh.x - cc.x, bh.z - cc.z).length(), float(arena.get("radius")), bh.y - float(arena.get("floor_y")), boss.get("_brace_point")])
		print("   move=%s vel=%s crouch=%s stun=%s" % [knight.get("_ai_move_vec"), knight.velocity, knight.get("is_crouching"), knight.get("_is_stunned")])
		print("t=%.2f act=%s victim=%s knight=%s tac=%s brace=%s handbody=%s flat=%.2f rescue_dmg=%.0f" % [
			k * 0.25, boss.call("act_name"), boss.call("grab_victim"), knight.global_position, tac, bh,
			hb.global_position, Vector2(bh.x - knight.global_position.x, bh.z - knight.global_position.z).length(),
			float(boss.get("_rescue_dmg"))])
		if k % 4 == 0:
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_jpg("%s/grab_%02d.jpg" % [out, k], 0.85)


func _party() -> Array:
	return get_tree().get_nodes_in_group("player").filter(func(p: Node) -> bool:
			return p is Node3D)


func _beat(label: String, act: int, at: float) -> void:
	boss.set("_grab_cd", 999.0)
	match act:
		1:
			boss.call("_begin_slam", _party(), _party())
		2:
			boss.call("_begin_sweep")
		4:
			boss.call("_begin_roar")
		5:
			boss.call("_begin_gaze", _party())
		6:
			boss.call("_stagger", 4.0, "poise")
		13:
			boss.call("_begin_head_slam", _party())
		12:
			boss.call("_begin_tail")
		20:
			boss.call("_die")
		_:
			boss.call("_start", 0, 30.0)
	await get_tree().create_timer(at).timeout
	boss.set_physics_process(false)
	arena.set_process(false)
	if OS.get_environment("REVIEW_DEBUG") != "":
		_debug_joints(label)
	for view in ["player", "side", "close", "front"]:
		_place(view)
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_jpg("%s/%s_%s.jpg" % [out, label, view], 0.9)
	boss.set_physics_process(true)
	arena.set_process(true)
	if act == 20:
		await get_tree().create_timer(3.5).timeout
		_place("front")
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_jpg("%s/death_fall_front.jpg" % out, 0.9)
		return
	boss.call("_start", 0, 3.0)
	await get_tree().create_timer(2.0).timeout


func _place(view: String) -> void:
	var c: Vector3 = arena.get("center")
	var bp := boss.global_position
	var fwd := Vector3(c.x - bp.x, 0, c.z - bp.z).normalized()
	var right := fwd.cross(Vector3.UP)
	var head: Vector3 = boss.call("head_pos")
	var core: Vector3 = boss.call("core_pos")
	var floor_y: float = arena.get("floor_y")
	match view:
		"player":
			# A player near the centre of the platform, looking up at it.
			cam.global_position = Vector3(c.x, floor_y + 1.7, c.z) - fwd * 3.0
			cam.look_at(head.lerp(core, 0.45), Vector3.UP)
			cam.fov = 75.0
		"side":
			var mid := core.lerp(head, 0.3)
			cam.global_position = mid + right * 36.0 + fwd * 8.0 + Vector3(0, 2.0, 0)
			cam.look_at(mid + Vector3(0, -3.0, 0), Vector3.UP)
			cam.fov = 50.0
		"front":
			# From the far side of the platform, high: the whole animal.
			cam.global_position = Vector3(c.x, floor_y + 9.0, c.z) + fwd * (float(arena.get("radius")) + 10.0)
			cam.look_at(core.lerp(head, 0.3) + Vector3(0, -4.0, 0), Vector3.UP)
			cam.fov = 62.0
		"close":
			cam.global_position = head + fwd * 12.0 + right * 8.0 + Vector3(0, 0.5, 0)
			cam.look_at(head + Vector3(0, -2.0, 0), Vector3.UP)
			cam.fov = 50.0
