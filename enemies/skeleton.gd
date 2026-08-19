class_name SkeletonWarrior
extends CharacterBody3D

## Undead axe-wielding skeleton (draugr-style "skeleton man with axe"
## model supplied by the user — see assets/skeleton/CREDITS.md), animated
## procedurally by [[SkeletonAnim]] and spawned in packs by
## [[SkeletonCrew]].
##
## Behaviour:
## - DARK VISION: unlike every living AI, skeletons need no moonlight and
##   no fire — they always know where the characters are.
## - Within AGGRO_RANGE (50 m) they RUN at the closest character and CROWD
##   him: each skeleton approaches on its own bearing around the target
##   (spread by crowd_slot) with separation from its brothers, so a pack
##   surrounds instead of forming a conga line.
## - FIRE is anathema: standing near burning ground fire deals damage, so
##   their pathing swerves around flames — the archer's fire walls work.
## - Killed skeletons collapse and RISE AGAIN elsewhere after 10 s
##   (handled by the crew).

signal died(skeleton: Node)

const SkeletonAnimClass := preload("res://enemies/skeleton_anim.gd")

const MAX_HP := 180.0            # two paladin combo hits, or ~5 arrows
const ATTACK_DAMAGE := 16.0
const AGGRO_RANGE := 50.0
const WALK_SPEED := 2.0
const RUN_SPEED := 4.6
const ATTACK_RANGE := 1.9
const ATTACK_HIT_RANGE := 2.4    # reach checked when the blade falls
const ATTACK_LEN := 1.0
const ATTACK_HIT_TIME := 0.5     # blade-fall moment inside the clip
const CROWD_RING := 1.5          # preferred striking distance in the ring
const SEPARATION_DIST := 1.6     # personal space between brothers
const FIRE_AVOID_DIST := 7.0
const FIRE_HURT_DIST := 4.0
const FIRE_DPS := 26.0
const BURN_DPS := 14.0           # arrow-fire clinging to the bones
const MODEL_SCALE := 0.53  # rig is ~3.5 units tall

var hp: float = MAX_HP
var crowd_slot: int = 0          # pack index (names/logs only)
# Ragged crowd: every skeleton keeps its OWN drifting approach bearing and
# striking distance, re-rolled every few seconds — the pack surrounds prey
# as a loose mob, never as an evenly-spaced honour guard.
var _ring_angle: float = 0.0
var _ring_dist: float = 1.5
var _ring_reroll: float = 0.0
var _gait_scale: float = 1.0     # per-bone-bag stride/speed desync
var _phase_offset: float = 0.0   # personal gait phase — clip switches keep it
var _burn_left: float = 0.0      # seconds of arrow-fire still burning on the bones
## Firelight caught on the bones — see combat/fire_glow.gd.
var _fire_glow := FireGlow.new()
var _burn_fx: Node3D = null
var home_post: Vector3           # where it haunts when nothing is near
var is_dead_skeleton: bool = false

var _model: Node3D
var _skel: Skeleton3D
var _anim: AnimationPlayer
var _target: Node3D = null
var _attack_left: float = 0.0
var _attack_cooldown: float = 0.0
var _attack_dealt: bool = false
var _stagger_left: float = 0.0
var _hp_label: Label3D

@onready var _gravity: Vector3 = ProjectSettings.get_setting("physics/3d/default_gravity") * \
		ProjectSettings.get_setting("physics/3d/default_gravity_vector")


func _ready() -> void:
	add_to_group("skeletons")
	collision_layer = 2   # enemies layer — the player's sword hitbox scans it
	collision_mask = 3    # world + other enemies

	var shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.35
	capsule.height = 1.8
	shape.shape = capsule
	shape.position = Vector3(0, 0.95, 0)
	add_child(shape)

	_model = load("res://assets/skeleton/skeleton_axe.fbx").instantiate()
	_model.scale = Vector3.ONE * MODEL_SCALE
	# Bind-pose soles sit slightly above the rig origin.
	_model.position = Vector3(0, -0.28 * MODEL_SCALE, 0)
	add_child(_model)
	# Strip the FBX's editor baggage: the C4D camera, helper null and the
	# baked taunt animation player — the game drives everything itself.
	for junk_name in ["CINEMA_4D_Editor", "Null", "AnimationPlayer"]:
		var junk := _model.get_node_or_null(NodePath(junk_name))
		if junk:
			junk.queue_free()
	_skel = _model.find_child("Skeleton3D", true, false) as Skeleton3D

	_anim = AnimationPlayer.new()
	_anim.name = "ProcAnim"
	_model.add_child(_anim)
	SkeletonAnimClass.add_all(_anim, _skel)
	_anim.play(&"Idle")

	_hp_label = Label3D.new()
	_hp_label.font_size = 48
	_hp_label.pixel_size = 0.01
	_hp_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_hp_label.position = Vector3(0, 2.1, 0)
	_hp_label.modulate = Color(0.7, 0.9, 0.7)
	_hp_label.visible = false
	add_child(_hp_label)

	_ring_angle = randf() * TAU
	_ring_dist = randf_range(1.2, 1.7)  # never beyond ATTACK_RANGE — a slot
	                                    # you cannot strike from stalls the AI
	_phase_offset = randf()
	_gait_scale = randf_range(0.85, 1.15)
	_anim.speed_scale = _gait_scale
	_anim.seek(randf() * 2.0, true)  # desync the loops across the pack
	_apply_grave_tone()
	# Must follow _apply_grave_tone — it is what installs the surface
	# overrides the glow writes to.
	_fire_glow.collect(_model)

	if home_post == Vector3.ZERO:
		home_post = global_position


func _physics_process(delta: float) -> void:
	if is_dead_skeleton:
		# A corpse still cools in the firelight; it just does nothing else.
		_fire_glow.update(Perception.fire_lit_amount(self), delta)
		return
	# Firelight on the bones. This is the archer's whole contribution made
	# visible: without it a revealed skeleton is a dark shape behind waist-
	# high grass, which is no revelation at all on a phone.
	_fire_glow.update(Perception.fire_lit_amount(self), delta)
	velocity += _gravity * delta
	_attack_cooldown -= delta

	if _stagger_left > 0.0:
		_stagger_left -= delta
		velocity.x = move_toward(velocity.x, 0.0, 20.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, 20.0 * delta)
		move_and_slide()
		return

	# Fire burns the unliving.
	var burn_fire := _nearest_fire(FIRE_HURT_DIST)
	if burn_fire != Vector3.INF:
		hp -= FIRE_DPS * delta
		_show_hp()
		if hp <= 0.0:
			_die()
			return
	# Caught fire from an arrow: burn down until the flames gutter out.
	if _burn_left > 0.0:
		_burn_left -= delta
		hp -= BURN_DPS * delta
		if _burn_left <= 0.0:
			_extinguish()
		if hp <= 0.0:
			_show_hp()
			_die()
			return

	if _attack_left > 0.0:
		_attack_left -= delta
		# The blade falls mid-clip: deal damage exactly once, on contact.
		if not _attack_dealt and _attack_left <= ATTACK_LEN - ATTACK_HIT_TIME:
			_attack_dealt = true
			_strike()
		velocity.x = move_toward(velocity.x, 0.0, 14.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, 14.0 * delta)
		move_and_slide()
		return

	_target = _closest_character()
	var move := Vector3.ZERO
	var running := false
	if _target != null:
		var to_t: Vector3 = _target.global_position - global_position
		to_t.y = 0.0
		var dist := to_t.length()
		if dist <= ATTACK_RANGE and _attack_cooldown <= 0.0:
			_start_attack()
			return
		# Crowd the prey from MY current bearing; the bearing and striking
		# distance drift every few seconds so the mob stays ragged.
		_ring_reroll -= delta
		if _ring_reroll <= 0.0:
			_ring_reroll = randf_range(3.0, 7.0)
			_ring_angle += randf_range(-1.2, 1.2)
			_ring_dist = randf_range(1.2, 1.7)
		var ring_point: Vector3 = _target.global_position \
				+ Vector3(cos(_ring_angle), 0.0, sin(_ring_angle)) * _ring_dist
		move = ring_point - global_position
		move.y = 0.0
		if move.length() > 0.2:
			move = move.normalized()
		running = dist > 4.0
	else:
		# Nothing within 50 m: haunt the post.
		var to_home: Vector3 = home_post - global_position
		to_home.y = 0.0
		if to_home.length() > 3.0:
			move = to_home.normalized()

	# Personal space from the brothers.
	for other in get_tree().get_nodes_in_group("skeletons"):
		if other == self or not is_instance_valid(other):
			continue
		var away: Vector3 = global_position - (other as Node3D).global_position
		away.y = 0.0
		if away.length() < SEPARATION_DIST and away.length() > 0.01:
			move += away.normalized() * 0.8
	# Flames are walls: swerve hard around any fire on the path.
	var fire_pos := _nearest_fire(FIRE_AVOID_DIST)
	if fire_pos != Vector3.INF:
		var from_fire: Vector3 = global_position - fire_pos
		from_fire.y = 0.0
		if from_fire.length() > 0.01:
			move += from_fire.normalized() * 1.6
	if move.length() > 0.1:
		move = move.normalized()
		var speed := (RUN_SPEED if running else WALK_SPEED) * _gait_scale
		velocity.x = move.x * speed
		velocity.z = move.z * speed
		# Close to prey the eyes stay ON the prey — ring maneuvering and
		# separation shoves must not turn a skeleton's back on its target.
		var face_vec := move
		if _target != null:
			var to_prey: Vector3 = _target.global_position - global_position
			to_prey.y = 0.0
			if to_prey.length() < 7.0 and to_prey.length() > 0.1:
				face_vec = to_prey.normalized()
		_face(face_vec, delta)
		_play(&"Run" if running else &"Walk")
	else:
		velocity.x = move_toward(velocity.x, 0.0, 12.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, 12.0 * delta)
		if _target != null:
			var face_dir: Vector3 = _target.global_position - global_position
			face_dir.y = 0.0
			if face_dir.length() > 0.1:
				_face(face_dir.normalized(), delta)
		_play(&"Idle")
	move_and_slide()


## Dark vision: every character is always known — no light rules apply.
func _closest_character() -> Node3D:
	var best: Node3D = null
	var best_dist := AGGRO_RANGE
	for c in Perception.all_characters(get_tree()):
		if "is_dead" in c and c.is_dead:
			continue
		var d: float = global_position.distance_to((c as Node3D).global_position)
		if d < best_dist:
			best = c
			best_dist = d
	return best


## Where the flames are, gathered ONCE per physics frame for the whole pack.
##
## Every skeleton asks about fire twice a frame — once for burn damage, once
## for pathing — and each ask used to walk two scene-tree groups. Five
## skeletons at 120 Hz physics is 1200 group walks a second to answer a
## question that has one answer per frame. Positions only, so nothing here
## outlives a freed node.
static var _fire_cache: PackedVector3Array = PackedVector3Array()
static var _fire_cache_frame: int = -1


static func _fire_positions(tree: SceneTree) -> PackedVector3Array:
	var frame: int = Engine.get_physics_frames()
	if frame == _fire_cache_frame:
		return _fire_cache
	_fire_cache_frame = frame
	var out := PackedVector3Array()
	# Ground fires plus burning arrows lying on the field — both are flame.
	for gname in ["ground_fire", "fire_arrows"]:
		for fire in tree.get_nodes_in_group(gname):
			if fire is Node3D and is_instance_valid(fire):
				out.append((fire as Node3D).global_position)
	_fire_cache = out
	return out


func _nearest_fire(radius: float) -> Vector3:
	var best := Vector3.INF
	var best_d := radius
	for pos in _fire_positions(get_tree()):
		var d: float = global_position.distance_to(pos)
		if d < best_d:
			best_d = d
			best = pos
	return best


func _start_attack() -> void:
	_attack_left = ATTACK_LEN
	_attack_dealt = false
	_attack_cooldown = ATTACK_LEN + randf_range(0.9, 1.7)
	if _target:
		var face_dir: Vector3 = _target.global_position - global_position
		face_dir.y = 0.0
		if face_dir.length() > 0.1:
			_face(face_dir.normalized(), 10.0, true)
	# Two distinct swings — an overhead chop and a cross-body slash.
	_play(&"AttackOverhead" if randf() < 0.5 else &"AttackSlash")
	Sfx.play3d("sword_whoosh_%d" % (randi_range(1, 2)), global_position + Vector3(0, 1.3, 0), -8.0, 0.15)


func _strike() -> void:
	if _target == null or not is_instance_valid(_target):
		return
	var to_t: Vector3 = _target.global_position - global_position
	if to_t.length() > ATTACK_HIT_RANGE:
		return
	if _target.has_method("take_hit"):
		var kb: Vector3 = to_t.normalized() * 4.0
		kb.y = 0.2
		# Rusty blade: fully blockable — a raised shield chips, a parry cancels.
		# The defender is the authority on whether the contact counted:
		# take_hit returns false when the hit was negated outright (spawn
		# immunity, roll i-frames, timed parry) — no impact SFX then.
		# Legacy targets whose take_hit returns void report null → landed.
		var hit_applied: Variant = _target.take_hit(ATTACK_DAMAGE, kb, false, self, true)
		if hit_applied != false:
			Sfx.play3d("hit_flesh", _target.global_position + Vector3(0, 1.2, 0), -6.0)


## An arrow's flame catches on the dry bones: burn for `duration`
## seconds (stacking hits refresh, not stack), with flames, embers and a
## small light riding the ribcage. Pure FireFX visuals + BURN_DPS damage.
func ignite(duration: float = 4.0) -> void:
	if is_dead_skeleton:
		return
	_burn_left = maxf(_burn_left, duration)
	if _burn_fx == null:
		_burn_fx = Node3D.new()
		_burn_fx.name = "BoneFire"
		add_child(_burn_fx)
		FireFX.add_flames(_burn_fx, Vector3(0, 0.9, 0), 0.55, 18)
		FireFX.add_embers(_burn_fx, Vector3(0, 1.1, 0), 0.6, 12)
		FireFX.add_fire_light(_burn_fx, Vector3(0, 1.2, 0), 8.0, 7.0, false)
	print("%s: caught fire (%.0fs)" % [name, _burn_left])


func _extinguish() -> void:
	_burn_left = 0.0
	if _burn_fx != null:
		_burn_fx.queue_free()
		_burn_fx = null


## Player sword / companion hits.
func take_hit(damage: float, knockback: Vector3, _blocked: bool = false,
		_attacker: Node3D = null, _fully_blockable: bool = false) -> void:
	if is_dead_skeleton:
		return
	hp -= damage
	_show_hp()
	Sfx.play3d("hit_metal", global_position + Vector3(0, 1.3, 0), -8.0, 0.2)
	velocity += Vector3(knockback.x, 0.0, knockback.z) * 0.8
	_stagger_left = 0.3
	if hp <= 0.0:
		_die()


## Arrows and DoT auras. Flat HP, so MAX_HP's own comment - "two paladin
## combo hits, or ~5 arrows" - is finally true; under percent damage it took
## twenty, and raising MAX_HP would not have changed that by one arrow.
func take_damage_flat(amount: float) -> void:
	if is_dead_skeleton:
		return
	hp -= amount
	_show_hp()
	if hp <= 0.0:
		_die()


func _die() -> void:
	if is_dead_skeleton:
		return
	is_dead_skeleton = true
	hp = 0.0
	_hp_label.visible = false
	collision_layer = 0
	collision_mask = 1
	Sfx.play3d("death_thud", global_position, -8.0)
	_extinguish()
	# Collapse: topple forward and settle — bones hold no pose in death.
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(_model, "rotation:x", -PI / 2.0, 0.5) \
			.set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)
	tw.tween_property(_model, "position:y", 0.35, 0.5).set_ease(Tween.EASE_IN)
	tw.chain().tween_property(_model, "position:y", -0.2, 6.0)
	died.emit(self)


## The crew raises it again somewhere else.
func revive_at(pos: Vector3) -> void:
	hp = MAX_HP
	is_dead_skeleton = false
	collision_layer = 2
	collision_mask = 3
	global_position = pos
	home_post = pos
	velocity = Vector3.ZERO
	_model.rotation = Vector3.ZERO
	_model.position = Vector3.ZERO
	_attack_left = 0.0
	_stagger_left = 0.0
	_extinguish()
	_play(&"Idle")
	print("Skeleton %d: risen again at %s" % [crowd_slot, str(pos.snapped(Vector3.ONE))])


func _face(dir: Vector3, delta_or_speed: float, instant: bool = false) -> void:
	# Model faces -Z: yaw so -Z points along dir.
	var target_yaw := atan2(-dir.x, -dir.z)
	if instant:
		_model.rotation.y = target_yaw
	else:
		_model.rotation.y = lerp_angle(_model.rotation.y, target_yaw, 8.0 * delta_or_speed)


func _play(anim_name: StringName) -> void:
	if _anim and _anim.current_animation != String(anim_name):
		_anim.play(anim_name, 0.25)
		# Every clip switch lands on this skeleton's PERSONAL phase — five
		# brothers switching Walk→Run together must not fall into lockstep.
		var clip := _anim.get_animation(anim_name)
		if clip and clip.loop_mode != Animation.LOOP_NONE:
			_anim.seek(_phase_offset * clip.length, false)


## Rebuild the materials from the asset's own texture set (the FBX ships
## with broken texture paths) and keep the aged-dark grading: old bones,
## dark rusted iron. Bone-part meshes get the skeleton diffuse+normal,
## the battleaxe gets its own pair.
func _apply_grave_tone() -> void:
	var bone_tex: Texture2D = load("res://assets/skeleton/textures/skeleton.jpeg")
	var bone_n: Texture2D = load("res://assets/skeleton/textures/skeleton_n.jpeg")
	var axe_tex: Texture2D = load("res://assets/skeleton/textures/draugrbattleaxe_m.jpeg")
	var axe_n: Texture2D = load("res://assets/skeleton/textures/draugrbattleaxe_n.jpeg")
	for mesh_inst in _model.find_children("*", "MeshInstance3D", true, false):
		var mi := mesh_inst as MeshInstance3D
		var is_axe := "Axe" in mi.name or "axe" in mi.name
		for si in mi.mesh.get_surface_count():
			var m := StandardMaterial3D.new()
			m.albedo_texture = axe_tex if is_axe else bone_tex
			m.normal_enabled = true
			m.normal_texture = axe_n if is_axe else bone_n
			# Grave tint: old bones / rusted dark metal under the night grade.
			m.albedo_color = Color(0.42, 0.38, 0.33) if is_axe else Color(0.55, 0.5, 0.42)
			m.roughness = 0.85 if is_axe else 0.92
			m.metallic = 0.35 if is_axe else 0.0
			mi.set_surface_override_material(si, m)


func _show_hp() -> void:
	if _hp_label == null:
		return
	_hp_label.text = "%d" % int(maxf(hp, 0.0))
	_hp_label.visible = true
	var tw := create_tween()
	tw.tween_interval(1.2)
	tw.tween_callback(func() -> void:
		if is_instance_valid(_hp_label):
			_hp_label.visible = false)
