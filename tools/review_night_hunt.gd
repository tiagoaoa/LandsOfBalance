extends Node3D


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	var game: Node3D = load("res://game.tscn").instantiate()
	add_child(game)
	await get_tree().create_timer(3.0).timeout
	var player := get_tree().get_first_node_in_group("player") as Player
	player.ai_driven = true
	var archer := get_tree().get_first_node_in_group("companion") as Player
	var boss := get_tree().get_first_node_in_group("bobba") as Bobba
	print("[NightHuntReview] companion spawn distance=%.1f" % player.global_position.distance_to(archer.global_position))
	await _capture("spawn")
	player.global_position = Vector3(120, 0.8, -140)
	player.camera_rotation = Vector2(0, -0.12)
	player._camera_pivot.rotation = Vector3(-0.12, 0, 0)
	player._character_model.rotation.y = PI
	archer.global_position = Vector3(124, 0.8, -138)
	archer.get_node("CompanionAI").set_physics_process(false)
	archer._ai_move_vec = Vector2.ZERO
	boss.global_position = Vector3(120, 0.8, -158)
	boss.set_physics_process(false)
	await get_tree().create_timer(3.0).timeout
	await _capture("dark")
	archer.get_node("CompanionAI").set_physics_process(true)
	await get_tree().create_timer(7.0).timeout
	#The before/after comparison holds the boss still. Apply the same
	#fire fill his physics tick normally owns before taking that frame.
	boss._fire_glow.update(Perception.fire_lit_amount(boss), 0.5, 0.18, true)
	await _capture("fire")
	boss.set_physics_process(true)
	await get_tree().create_timer(4.0).timeout
	await _capture("combat")
	print("[NightHuntReview] captures complete")
	get_tree().quit()


func _capture(label: String) -> void:
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute("res://docs/presentation/night-hunt")
	get_viewport().get_texture().get_image().save_png("res://docs/presentation/night-hunt/" + label + ".png")
