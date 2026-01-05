extends CharacterBody3D
class_name RemotePlayer

## Represents another player in the multiplayer game
## Receives position updates from the server and interpolates movement
## Supports Archer and Paladin character classes with proper animations

@export var player_id: int = 0
@export var interpolation_speed: float = 20.0

var target_position: Vector3 = Vector3.ZERO
var target_rotation_y: float = 0.0
var current_state: int = 0
var combat_mode: int = 1
var character_class: int = 1  # 0 = Paladin, 1 = Archer
var health: float = 100.0
var current_anim_name: String = "Idle"

var _character_model: Node3D
var _anim_player: AnimationPlayer
var _name_label: Label3D
var _current_playing_anim: StringName = &""
var _setup_complete: bool = false
var _current_class: int = -1  # Track which class model is loaded

# Spell VFX for remote players
var _spell_effects: Node3D
var _spell_light: OmniLight3D
var _spell_particles: GPUParticles3D
var _magic_circle: MeshInstance3D
var _force_field_sphere: MeshInstance3D  # Bubble shield for Paladin
var _force_field_light: OmniLight3D
var _force_field_material: ShaderMaterial
var _is_casting: bool = false
# Fire circle VFX for Archer
var _fire_circle_node: Node3D
var _fire_circle_particles: Array[GPUParticles3D] = []
var _fire_circle_light: OmniLight3D
var _fire_circle_time: float = 0.0  # Track elapsed time for intensity reduction
var _fire_circle_active: bool = false  # Track if fire circle is active
const FIRE_CIRCLE_RADIUS: float = 2.5
const FIRE_CIRCLE_EMITTERS: int = 8
const FIRE_CIRCLE_DURATION: float = 4.0  # 4 seconds with 1/time intensity decay

# Use Protocol.PlayerState for network sync compatibility
const Proto = preload("res://multiplayer/protocol.gd")
const STATE_IDLE = Proto.PlayerState.STATE_IDLE
const STATE_WALKING = Proto.PlayerState.STATE_WALKING
const STATE_RUNNING = Proto.PlayerState.STATE_RUNNING
const STATE_ATTACKING = Proto.PlayerState.STATE_ATTACKING
const STATE_BLOCKING = Proto.PlayerState.STATE_BLOCKING
const STATE_JUMPING = Proto.PlayerState.STATE_JUMPING
const STATE_CASTING = Proto.PlayerState.STATE_CASTING
const STATE_DRAWING_BOW = Proto.PlayerState.STATE_DRAWING_BOW
const STATE_HOLDING_BOW = Proto.PlayerState.STATE_HOLDING_BOW

# Archer character and animations (default)
const ARCHER_CHARACTER_PATH = "res://player/character/archer/Archer.fbx"
var ArcherScene: PackedScene = preload("res://player/character/archer/Archer.fbx")
const ARCHER_ANIM_PATHS: Dictionary = {
	"Idle": "res://player/character/archer/Idle.fbx",
	"Walk": "res://player/character/archer/Walk.fbx",
	"Run": "res://player/character/archer/Run.fbx",
	"Jump": "res://player/character/archer/Jump.fbx",
	"Attack": "res://player/character/archer/Attack.fbx",
	"Block": "res://player/character/archer/Block.fbx",
	"Sprint": "res://player/character/archer/Sprint.fbx",
	"SpellCast": "res://player/character/archer/Archer_Spell.fbx",
}

# Paladin character and animations
const PALADIN_CHARACTER_PATH = "res://player/character/armed/Paladin.fbx"
var PaladinScene: PackedScene = preload("res://player/character/armed/Paladin.fbx")
const PALADIN_ANIM_PATHS: Dictionary = {
	"Idle": "res://player/character/armed/Idle.fbx",
	"Walk": "res://player/character/armed/Walk.fbx",
	"Run": "res://player/character/armed/Run.fbx",
	"Jump": "res://player/character/armed/Jump.fbx",
	"Attack": "res://player/character/armed/Attack1.fbx",
	"Block": "res://player/character/armed/Block.fbx",
	"SpellCast": "res://player/character/armed/SpellCast.fbx",
}


func _ready() -> void:
	# Setup collision
	collision_layer = 8  # Layer 4 for remote players
	collision_mask = 1   # Collide with world

	_setup_collision()
	_setup_name_label()
	_setup_spell_vfx()
	# Defer character model setup to avoid initialization issues
	call_deferred("_setup_character_model")


func _physics_process(delta: float) -> void:
	# Skip processing until character setup is complete
	if not _setup_complete:
		return

	# Interpolate position (only if we have a target)
	if target_position != Vector3.ZERO:
		global_position = global_position.lerp(target_position, interpolation_speed * delta)

	# Interpolate rotation - apply to model, not body
	if _character_model and is_instance_valid(_character_model):
		_character_model.rotation.y = lerp_angle(_character_model.rotation.y, target_rotation_y, interpolation_speed * delta)

	# Apply gravity and move
	if not is_on_floor():
		velocity.y -= 22.0 * delta
	else:
		velocity.y = 0

	move_and_slide()

	# Update animation based on state
	if _anim_player and is_instance_valid(_anim_player):
		_update_animation()

	# Update spell VFX based on casting state
	_update_spell_vfx(delta)


func update_from_network(data: Dictionary) -> void:
	target_position = data.get("position", target_position)
	target_rotation_y = data.get("rotation_y", target_rotation_y)
	current_state = data.get("state", current_state)
	combat_mode = data.get("combat_mode", combat_mode)
	health = data.get("health", health)
	current_anim_name = data.get("anim_name", current_anim_name)

	# Check if character class changed
	var new_class = data.get("character_class", character_class)
	if new_class != character_class:
		character_class = new_class
		if _setup_complete and _current_class != character_class:
			# Reload character model for new class
			call_deferred("_switch_character_class")


func _setup_character_model() -> void:
	# Load character based on class
	var character_scene: PackedScene
	var class_name_str: String

	if character_class == 0:  # Paladin
		character_scene = PaladinScene
		class_name_str = "Paladin"
	else:  # Archer (default)
		character_scene = ArcherScene
		class_name_str = "Archer"

	_current_class = character_class
	print("RemotePlayer [%d]: Loading %s character" % [player_id, class_name_str])
	print("RemotePlayer [%d]: Preloaded scene = %s" % [player_id, character_scene])

	if character_scene == null:
		push_error("RemotePlayer [%d]: ArcherScene preload FAILED!" % player_id)
		_create_fallback_model()
		call_deferred("_finalize_setup")
		return

	_character_model = character_scene.instantiate()
	if _character_model == null:
		push_error("RemotePlayer [%d]: Failed to instantiate character!" % player_id)
		_create_fallback_model()
		call_deferred("_finalize_setup")
		return

	_character_model.name = "Model"
	add_child(_character_model)
	print("RemotePlayer [%d]: Character model instantiated and added" % player_id)

	# Scale character appropriately (same as player.gd)
	var skeleton = _find_skeleton(_character_model)
	print("RemotePlayer [%d]: Found skeleton = %s" % [player_id, skeleton])
	if skeleton and skeleton.get_bone_count() > 0:
		var hips_idx: int = skeleton.find_bone("mixamorig_Hips")
		if hips_idx >= 0:
			var hips_pos: Vector3 = skeleton.get_bone_global_rest(hips_idx).origin
			print("RemotePlayer [%d]: Hips position Y = %f" % [player_id, hips_pos.y])
			if hips_pos.y > 50:
				_character_model.scale = Vector3(0.01, 0.01, 0.01)
			else:
				_character_model.scale = Vector3(1.0, 1.0, 1.0)
		else:
			print("RemotePlayer [%d]: Hips bone not found, using 0.01 scale" % player_id)
			_character_model.scale = Vector3(0.01, 0.01, 0.01)
	else:
		print("RemotePlayer [%d]: No skeleton or no bones, using 0.01 scale" % player_id)
		_character_model.scale = Vector3(0.01, 0.01, 0.01)
	print("RemotePlayer [%d]: Final scale = %s" % [player_id, _character_model.scale])

	# Find existing AnimationPlayer in the model
	_anim_player = _find_animation_player(_character_model)

	if _anim_player == null:
		# Create AnimationPlayer if not found
		_anim_player = AnimationPlayer.new()
		_anim_player.name = "AnimationPlayer"
		_character_model.add_child(_anim_player)

	# Load animations in deferred call
	if skeleton:
		call_deferred("_safe_load_animations", skeleton)

	# Defer animation playback and setup completion to avoid race conditions
	call_deferred("_finalize_setup")


func _finalize_setup() -> void:
	# Play idle animation if available
	var anim_prefix = "paladin" if character_class == 0 else "archer"
	if _anim_player and is_instance_valid(_anim_player) and _anim_player.is_inside_tree():
		var idle_anim = anim_prefix + "/Idle"
		if _anim_player.has_animation(idle_anim):
			_anim_player.play(idle_anim)
			_current_playing_anim = StringName(idle_anim)
			print("RemotePlayer [%d]: Playing %s" % [player_id, idle_anim])
	_setup_complete = true
	print("RemotePlayer: Setup complete for player %d (class=%d) at position %s" % [player_id, character_class, global_position])


func _switch_character_class() -> void:
	# Remove old character model
	if _character_model and is_instance_valid(_character_model):
		_character_model.queue_free()
		_character_model = null
		_anim_player = null

	_setup_complete = false
	_current_playing_anim = &""

	# Setup new character
	_setup_character_model()


func _create_fallback_model() -> void:
	print("RemotePlayer [%d]: CREATING FALLBACK BLUE CAPSULE!" % player_id)
	push_warning("RemotePlayer: Using fallback capsule mesh for player %d" % player_id)
	var mesh_instance = MeshInstance3D.new()
	var capsule = CapsuleMesh.new()
	capsule.radius = 0.4
	capsule.height = 1.8
	mesh_instance.mesh = capsule
	mesh_instance.position.y = 0.9

	var material = StandardMaterial3D.new()
	material.albedo_color = Color(0.2, 0.6, 1.0)  # Blue tint for remote players
	mesh_instance.material_override = material

	add_child(mesh_instance)
	_character_model = mesh_instance


func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node
	for child in node.get_children():
		var result = _find_skeleton(child)
		if result:
			return result
	return null


func _safe_load_animations(skeleton: Skeleton3D) -> void:
	# Safely load animations with error handling
	if not is_instance_valid(_anim_player) or not is_instance_valid(skeleton):
		print("RemotePlayer [%d]: Cannot load animations - invalid references" % player_id)
		return
	if not _anim_player.is_inside_tree() or not skeleton.is_inside_tree():
		print("RemotePlayer [%d]: Cannot load animations - nodes not in tree" % player_id)
		return

	print("RemotePlayer [%d]: Starting deferred animation load" % player_id)
	_load_animations(skeleton)
	print("RemotePlayer [%d]: Animation load complete" % player_id)


func _load_animations(skeleton: Skeleton3D) -> void:
	if _anim_player == null or skeleton == null:
		print("RemotePlayer: Cannot load animations - missing AnimationPlayer or skeleton")
		return

	# Get animation root and skeleton path for retargeting
	var root_path = _anim_player.root_node
	if root_path.is_empty():
		root_path = NodePath("..")
	var anim_root: Node = _anim_player.get_node_or_null(root_path)
	if anim_root == null:
		anim_root = _character_model
	var skel_path: String = str(anim_root.get_path_to(skeleton))

	# Determine which animations to load based on class
	var anim_paths: Dictionary
	var anim_prefix: StringName
	if character_class == 0:  # Paladin
		anim_paths = PALADIN_ANIM_PATHS
		anim_prefix = &"paladin"
	else:  # Archer
		anim_paths = ARCHER_ANIM_PATHS
		anim_prefix = &"archer"

	print("RemotePlayer: Loading %s animations - skeleton path: %s" % [anim_prefix, skel_path])

	# Animation configs: name -> [display_name, loop]
	var anim_configs: Dictionary = {
		"Idle": ["Idle", true],
		"Walk": ["Walk", true],
		"Run": ["Run", true],
		"Jump": ["Jump", false],
		"Attack": ["Attack", false],
		"Block": ["Block", true],
		"Sprint": ["Sprint", true],
		"SpellCast": ["SpellCast", false],
	}

	for anim_name in anim_paths:
		var anim_path = anim_paths[anim_name]
		var anim_scene = load(anim_path)
		if anim_scene == null:
			print("RemotePlayer: Failed to load animation: ", anim_path)
			continue

		var anim_instance = anim_scene.instantiate()
		var source_anim_player = _find_animation_player(anim_instance)

		if source_anim_player == null:
			print("RemotePlayer: No AnimationPlayer in: ", anim_path)
			anim_instance.queue_free()
			continue

		# Find best animation (most keyframes)
		var best_anim: Animation = null
		var best_key_count: int = 0

		for lib_name in source_anim_player.get_animation_library_list():
			var lib: AnimationLibrary = source_anim_player.get_animation_library(lib_name)
			for src_anim_name in lib.get_animation_list():
				var anim: Animation = lib.get_animation(src_anim_name)
				var total_keys: int = 0
				for t in range(anim.get_track_count()):
					total_keys += anim.track_get_key_count(t)
				var keys_per_track: float = float(total_keys) / max(anim.get_track_count(), 1)
				if total_keys > best_key_count and keys_per_track > 1.5:
					best_anim = anim
					best_key_count = total_keys

		if best_anim != null:
			var new_anim: Animation = best_anim.duplicate()

			# Set loop mode
			var config = anim_configs.get(anim_name, [anim_name, false])
			new_anim.loop_mode = Animation.LOOP_LINEAR if config[1] else Animation.LOOP_NONE

			# Retarget animation tracks to our skeleton
			_retarget_animation(new_anim, skel_path, skeleton)

			# Add to library with correct prefix
			if not _anim_player.has_animation_library(anim_prefix):
				_anim_player.add_animation_library(anim_prefix, AnimationLibrary.new())
			_anim_player.get_animation_library(anim_prefix).add_animation(StringName(anim_name), new_anim)
			print("RemotePlayer: Loaded animation: %s/%s" % [anim_prefix, anim_name])

		anim_instance.queue_free()

	print("RemotePlayer: Animation library has: ", _anim_player.get_animation_list())


func _retarget_animation(anim: Animation, target_skeleton_path: String, skeleton: Skeleton3D) -> void:
	# Match player.gd's retargeting approach exactly
	var tracks_to_remove: Array[int] = []

	for i in range(anim.get_track_count()):
		var track_path: NodePath = anim.track_get_path(i)
		var path_str: String = str(track_path)

		var colon_pos: int = path_str.find(":")
		if colon_pos == -1:
			continue

		var bone_name: String = path_str.substr(colon_pos + 1)

		# Remove root motion from Hips
		if bone_name == "mixamorig_Hips" and anim.track_get_type(i) == Animation.TYPE_POSITION_3D:
			tracks_to_remove.append(i)
			continue

		# Verify bone exists (with alternative name check like player.gd)
		if skeleton.find_bone(bone_name) == -1:
			var alt_bone_name: String = bone_name.replace("mixamorig:", "mixamorig_")
			if skeleton.find_bone(alt_bone_name) == -1:
				continue  # Skip unknown bones instead of removing
			bone_name = alt_bone_name

		# Retarget to our skeleton path
		var new_path: String = target_skeleton_path + ":" + bone_name
		if path_str != new_path:
			anim.track_set_path(i, NodePath(new_path))

	# Remove only the hips position tracks
	tracks_to_remove.reverse()
	for idx in tracks_to_remove:
		anim.remove_track(idx)


func _setup_collision() -> void:
	var collision = CollisionShape3D.new()
	var capsule = CapsuleShape3D.new()
	capsule.radius = 0.4
	capsule.height = 1.8
	collision.shape = capsule
	collision.position.y = 0.9
	add_child(collision)


func _setup_name_label() -> void:
	_name_label = Label3D.new()
	_name_label.text = "Player %d" % player_id
	_name_label.position = Vector3(0, 2.5, 0)
	_name_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_name_label.no_depth_test = true
	_name_label.font_size = 20
	_name_label.modulate = Color(0.8, 0.9, 1.0)
	add_child(_name_label)


func _apply_remote_player_tint() -> void:
	# Apply a slight blue-ish emission to distinguish remote players
	print("RemotePlayer: Applying tint to character model: %s" % _character_model)
	_apply_tint_recursive(_character_model)


func _apply_tint_recursive(node: Node) -> void:
	if node is MeshInstance3D:
		var mesh_instance = node as MeshInstance3D
		# Create a bright tinted material to make remote player visible
		var mat = StandardMaterial3D.new()
		mat.albedo_color = Color(0.5, 0.8, 1.0)  # Cyan/blue tint
		mat.emission_enabled = true
		mat.emission = Color(0.2, 0.5, 1.0)  # Bright blue glow
		mat.emission_energy_multiplier = 1.0
		mesh_instance.material_override = mat
		print("RemotePlayer: Applied bright tint to mesh: %s" % mesh_instance.name)

	for child in node.get_children():
		_apply_tint_recursive(child)


func _find_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for child in node.get_children():
		var result = _find_animation_player(child)
		if result:
			return result
	return null


func _update_animation() -> void:
	if _anim_player == null or not is_instance_valid(_anim_player):
		return

	# Safety check - ensure animation player is inside tree
	if not _anim_player.is_inside_tree():
		return

	# Determine animation prefix based on character class
	var anim_prefix = "paladin" if character_class == 0 else "archer"

	# Use the animation name received from network
	var anim_name = current_anim_name

	# Extract just the animation name (e.g., "archer/Idle" -> "Idle")
	if "/" in anim_name:
		anim_name = anim_name.split("/")[-1]

	# Capitalize first letter if needed
	if not anim_name.is_empty():
		anim_name = anim_name[0].to_upper() + anim_name.substr(1)

	# Build full animation path with correct prefix
	var full_anim_name = anim_prefix + "/" + anim_name

	# Fallback to state-based animation if name not found
	if not _anim_player.has_animation(full_anim_name):
		match current_state:
			STATE_IDLE:
				full_anim_name = anim_prefix + "/Idle"
			STATE_WALKING:
				full_anim_name = anim_prefix + "/Walk"
			STATE_RUNNING:
				full_anim_name = anim_prefix + "/Run"
			STATE_ATTACKING:
				full_anim_name = anim_prefix + "/Attack"
			STATE_BLOCKING:
				full_anim_name = anim_prefix + "/Block"
			STATE_JUMPING:
				full_anim_name = anim_prefix + "/Jump"
			STATE_CASTING:
				full_anim_name = anim_prefix + "/SpellCast"
			STATE_DRAWING_BOW, STATE_HOLDING_BOW:
				full_anim_name = anim_prefix + "/Attack"

	# Try to play the animation if it exists and different from current
	if _anim_player.has_animation(full_anim_name):
		if _current_playing_anim != full_anim_name:
			_anim_player.play(full_anim_name)
			_current_playing_anim = full_anim_name


# =============================================================================
# SPELL VFX
# =============================================================================

func _setup_spell_vfx() -> void:
	# Container for spell effects
	_spell_effects = Node3D.new()
	_spell_effects.name = "SpellEffects"
	add_child(_spell_effects)

	# Spell light (blue glow)
	_spell_light = OmniLight3D.new()
	_spell_light.name = "SpellLight"
	_spell_light.light_color = Color(0.3, 0.5, 1.0)
	_spell_light.light_energy = 0.0  # Start off
	_spell_light.omni_range = 8.0
	_spell_light.omni_attenuation = 1.5
	_spell_light.position = Vector3(0, 1.5, 0)
	_spell_effects.add_child(_spell_light)

	# Spark particles
	_spell_particles = GPUParticles3D.new()
	_spell_particles.name = "SpellParticles"
	_spell_particles.emitting = false
	_spell_particles.amount = 100
	_spell_particles.lifetime = 0.8
	_spell_particles.explosiveness = 0.2
	_spell_particles.position = Vector3(0, 1.0, 0)

	var particle_mat = ParticleProcessMaterial.new()
	particle_mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	particle_mat.emission_sphere_radius = 0.5
	particle_mat.direction = Vector3(0, 1, 0)
	particle_mat.spread = 180.0
	particle_mat.initial_velocity_min = 2.0
	particle_mat.initial_velocity_max = 5.0
	particle_mat.gravity = Vector3(0, -2, 0)
	particle_mat.scale_min = 0.05
	particle_mat.scale_max = 0.15
	particle_mat.color = Color(0.5, 0.7, 1.0)
	_spell_particles.process_material = particle_mat

	# Simple quad mesh for particles
	var quad = QuadMesh.new()
	quad.size = Vector2(0.1, 0.1)
	var quad_mat = StandardMaterial3D.new()
	quad_mat.albedo_color = Color(0.6, 0.8, 1.0)
	quad_mat.emission_enabled = true
	quad_mat.emission = Color(0.4, 0.6, 1.0)
	quad_mat.emission_energy_multiplier = 3.0
	quad_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	quad_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	quad.material = quad_mat
	_spell_particles.draw_pass_1 = quad
	_spell_effects.add_child(_spell_particles)

	# Magic circle on ground
	_magic_circle = MeshInstance3D.new()
	_magic_circle.name = "MagicCircle"
	var circle_mesh = PlaneMesh.new()
	circle_mesh.size = Vector2(3.0, 3.0)
	_magic_circle.mesh = circle_mesh
	_magic_circle.position = Vector3(0, 0.05, 0)
	_magic_circle.visible = false

	var circle_mat = StandardMaterial3D.new()
	circle_mat.albedo_color = Color(0.3, 0.5, 1.0, 0.5)
	circle_mat.emission_enabled = true
	circle_mat.emission = Color(0.2, 0.4, 1.0)
	circle_mat.emission_energy_multiplier = 2.0
	circle_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	circle_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_magic_circle.material_override = circle_mat
	_spell_effects.add_child(_magic_circle)

	# Force field bubble sphere for Paladin
	_force_field_sphere = MeshInstance3D.new()
	_force_field_sphere.name = "ForceFieldSphere"
	var sphere = SphereMesh.new()
	sphere.radius = 1.8
	sphere.height = 3.6
	sphere.radial_segments = 32
	sphere.rings = 16
	_force_field_sphere.mesh = sphere

	# Create bubble shader with Fresnel edge glow
	var shader = Shader.new()
	shader.code = """
shader_type spatial;
render_mode blend_add, depth_draw_opaque, cull_front, unshaded;

uniform vec4 bubble_color : source_color = vec4(0.0, 0.8, 1.0, 0.3);
uniform float fresnel_power : hint_range(0.5, 10.0) = 3.0;
uniform float edge_intensity : hint_range(0.0, 5.0) = 2.0;
uniform float pulse_speed : hint_range(0.0, 10.0) = 3.0;

void fragment() {
	float fresnel = pow(1.0 - dot(NORMAL, VIEW), fresnel_power);
	float pulse = sin(TIME * pulse_speed) * 0.15 + 0.85;
	float intensity = fresnel * edge_intensity * pulse;
	ALBEDO = bubble_color.rgb * intensity;
	ALPHA = bubble_color.a * intensity * 0.8;
	EMISSION = bubble_color.rgb * intensity * 1.5;
}
"""
	_force_field_material = ShaderMaterial.new()
	_force_field_material.shader = shader
	_force_field_material.set_shader_parameter("bubble_color", Color(0.0, 0.9, 1.0, 0.4))
	_force_field_material.set_shader_parameter("fresnel_power", 3.0)
	_force_field_material.set_shader_parameter("edge_intensity", 2.5)
	_force_field_material.set_shader_parameter("pulse_speed", 3.0)
	_force_field_sphere.material_override = _force_field_material

	_force_field_sphere.position = Vector3(0, 1.0, 0)
	_force_field_sphere.scale = Vector3(0.01, 0.01, 0.01)
	_force_field_sphere.visible = false
	_spell_effects.add_child(_force_field_sphere)

	# Force field light
	_force_field_light = OmniLight3D.new()
	_force_field_light.name = "ForceFieldLight"
	_force_field_light.light_color = Color(0.0, 1.0, 1.0)
	_force_field_light.light_energy = 0.0
	_force_field_light.omni_range = 4.0
	_force_field_light.omni_attenuation = 1.2
	_force_field_light.position = Vector3(0, 1.0, 0)
	_spell_effects.add_child(_force_field_light)

	# Setup fire circle for Archer
	_setup_fire_circle_vfx()


func _setup_fire_circle_vfx() -> void:
	# Container for fire circle effects
	_fire_circle_node = Node3D.new()
	_fire_circle_node.name = "FireCircleSpell"
	add_child(_fire_circle_node)

	# Fire circle light (orange glow)
	_fire_circle_light = OmniLight3D.new()
	_fire_circle_light.name = "FireCircleLight"
	_fire_circle_light.light_color = Color(1.0, 0.6, 0.2)
	_fire_circle_light.light_energy = 0.0  # Start off
	_fire_circle_light.omni_range = 6.0
	_fire_circle_light.omni_attenuation = 1.5
	_fire_circle_light.position = Vector3(0, 0.5, 0)
	_fire_circle_node.add_child(_fire_circle_light)

	# Create fire emitters in a circle
	_fire_circle_particles.clear()
	for i in range(FIRE_CIRCLE_EMITTERS):
		var angle = (float(i) / FIRE_CIRCLE_EMITTERS) * TAU
		var x = cos(angle) * FIRE_CIRCLE_RADIUS
		var z = sin(angle) * FIRE_CIRCLE_RADIUS

		var fire = GPUParticles3D.new()
		fire.name = "FireEmitter_%d" % i
		fire.emitting = false
		fire.amount = 80  # More particles for smoother look
		fire.lifetime = 1.2  # Longer lifetime
		fire.explosiveness = 0.05  # More gradual emission
		fire.randomness = 0.5
		fire.position = Vector3(x, 0.1, z)

		var fire_mat = ParticleProcessMaterial.new()
		fire_mat.direction = Vector3(0, 1, 0)
		fire_mat.spread = 20.0
		fire_mat.initial_velocity_min = 1.0
		fire_mat.initial_velocity_max = 2.5
		fire_mat.gravity = Vector3(0, 0.5, 0)  # Fire rises gently
		fire_mat.damping_min = 0.5
		fire_mat.damping_max = 1.5

		# Color gradient: white core -> yellow -> orange -> red -> dark red
		var color_gradient = Gradient.new()
		color_gradient.offsets = PackedFloat32Array([0.0, 0.15, 0.35, 0.55, 0.75, 1.0])
		color_gradient.colors = PackedColorArray([
			Color(1.0, 1.0, 0.9, 0.9),   # White-yellow core
			Color(1.0, 0.85, 0.3, 1.0),  # Bright yellow
			Color(1.0, 0.5, 0.1, 1.0),   # Orange
			Color(0.95, 0.25, 0.05, 0.9), # Bright red
			Color(0.7, 0.1, 0.02, 0.6),  # Deep red
			Color(0.3, 0.05, 0.01, 0.0)  # Dark red fade out
		])
		var color_tex = GradientTexture1D.new()
		color_tex.gradient = color_gradient
		color_tex.width = 256  # Smoother gradient
		fire_mat.color_ramp = color_tex

		# Scale curve: grow then shrink for organic flame shape
		var scale_curve = Curve.new()
		scale_curve.add_point(Vector2(0.0, 0.3))
		scale_curve.add_point(Vector2(0.2, 1.0))
		scale_curve.add_point(Vector2(0.6, 0.7))
		scale_curve.add_point(Vector2(1.0, 0.1))
		var scale_tex = CurveTexture.new()
		scale_tex.curve = scale_curve
		fire_mat.scale_curve = scale_tex
		fire_mat.scale_min = 0.4
		fire_mat.scale_max = 0.8

		fire_mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
		fire_mat.emission_sphere_radius = 0.25
		fire.process_material = fire_mat

		# Larger, softer fire mesh
		var fire_mesh = QuadMesh.new()
		fire_mesh.size = Vector2(0.6, 0.8)  # Taller flame shape
		var mesh_mat = StandardMaterial3D.new()
		mesh_mat.albedo_color = Color(1.0, 0.8, 0.5, 0.9)
		mesh_mat.emission_enabled = true
		mesh_mat.emission = Color(1.0, 0.4, 0.1)
		mesh_mat.emission_energy_multiplier = 3.0
		mesh_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		mesh_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mesh_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD  # Additive blending for glow
		mesh_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mesh_mat.vertex_color_use_as_albedo = true  # Use particle color
		fire_mesh.material = mesh_mat
		fire.draw_pass_1 = fire_mesh

		_fire_circle_node.add_child(fire)
		_fire_circle_particles.append(fire)


func _update_spell_vfx(delta: float) -> void:
	var should_cast = (current_state == STATE_CASTING)

	if should_cast and not _is_casting:
		# Start casting VFX
		_is_casting = true
		_start_spell_vfx()
	elif not should_cast and _is_casting:
		# Stop casting VFX
		_is_casting = false
		_stop_spell_vfx()

	# Animate light flicker while casting
	if _is_casting:
		if character_class == 1:  # Archer - fire circle with 1/time intensity decay
			if _fire_circle_active and _fire_circle_light:
				_fire_circle_time += delta
				# 1/time intensity decay: starts at full, decays over duration
				var decay_rate := 1.0
				var intensity := 4.0 / (1.0 + _fire_circle_time * decay_rate)
				# Add subtle flicker
				var flicker := sin(_fire_circle_time * 15.0) * 0.3
				_fire_circle_light.light_energy = max(0.2, intensity + flicker)
		else:  # Paladin - blue lightning flicker
			if _spell_light:
				_spell_light.light_energy = 3.0 + sin(Time.get_ticks_msec() * 0.01) * 1.5


func _start_spell_vfx() -> void:
	if character_class == 1:  # Archer - fire circle
		_start_fire_circle_vfx()
	else:  # Paladin - lightning
		_start_lightning_vfx()


func _stop_spell_vfx() -> void:
	if character_class == 1:  # Archer - fire circle
		_stop_fire_circle_vfx()
	else:  # Paladin - lightning
		_stop_lightning_vfx()


func _start_lightning_vfx() -> void:
	if _spell_light:
		_spell_light.light_energy = 3.0
	if _spell_particles:
		_spell_particles.emitting = true
	if _magic_circle:
		_magic_circle.visible = true
	# Show and animate force field bubble
	if _force_field_sphere:
		_force_field_sphere.visible = true
		_force_field_sphere.scale = Vector3(1.0, 1.0, 1.0)
	if _force_field_light:
		_force_field_light.light_energy = 2.0


func _stop_lightning_vfx() -> void:
	if _spell_light:
		_spell_light.light_energy = 0.0
	if _spell_particles:
		_spell_particles.emitting = false
	if _magic_circle:
		_magic_circle.visible = false
	# Hide force field bubble
	if _force_field_sphere:
		_force_field_sphere.visible = false
		_force_field_sphere.scale = Vector3(0.01, 0.01, 0.01)
	if _force_field_light:
		_force_field_light.light_energy = 0.0


func _start_fire_circle_vfx() -> void:
	_fire_circle_active = true
	_fire_circle_time = 0.0
	if _fire_circle_light:
		_fire_circle_light.light_energy = 4.0
	for fire in _fire_circle_particles:
		fire.emitting = true


func _stop_fire_circle_vfx() -> void:
	_fire_circle_active = false
	if _fire_circle_light:
		_fire_circle_light.light_energy = 0.0
	for fire in _fire_circle_particles:
		fire.emitting = false
