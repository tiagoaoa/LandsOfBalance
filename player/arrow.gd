extends RigidBody3D
class_name Arrow

## Fire arrow projectile with parabolic trajectory
## Network-synchronized across all players

const ARROW_SPEED: float = 50.0
const GRAVITY: float = 9.8
const LIFETIME: float = 10.0
const DAMAGE: float = 25.0

var shooter: Node3D = null
var shooter_id: int = 0  # Network player ID of shooter
var arrow_id: int = 0    # Unique network ID for this arrow
var is_local: bool = true  # True if spawned locally, false if from network
var _lifetime_timer: float = 0.0
var _has_hit: bool = false

@onready var _fire_particles: GPUParticles3D
@onready var _trail_particles: GPUParticles3D
@onready var _mesh: MeshInstance3D
@onready var _collision: CollisionShape3D


func _ready() -> void:
	_setup_arrow_mesh()
	_setup_fire_effect()
	_setup_collision()

	# Enable contact monitoring for body_entered signal
	contact_monitor = true
	max_contacts_reported = 4

	# Connect body entered signal
	body_entered.connect(_on_body_entered)

	# Set physics properties
	gravity_scale = 1.0
	linear_damp = 0.0
	angular_damp = 0.0

	# Set collision layer (projectile) and mask (detect world/enemies)
	collision_layer = 4  # Layer 3 (projectiles)
	collision_mask = 1 | 2  # Detect layer 1 (world) and layer 2 (enemies)


func _physics_process(delta: float) -> void:
	_lifetime_timer += delta

	if _lifetime_timer > LIFETIME:
		queue_free()
		return

	# Rotate arrow to face velocity direction
	if linear_velocity.length() > 0.1 and not _has_hit:
		look_at(global_position + linear_velocity.normalized(), Vector3.UP)


func launch(direction: Vector3) -> void:
	# Apply initial velocity
	linear_velocity = direction.normalized() * ARROW_SPEED


func _setup_arrow_mesh() -> void:
	# Create arrow shaft (straight wooden stick)
	_mesh = MeshInstance3D.new()
	_mesh.name = "ArrowShaft"

	var shaft_mesh = CylinderMesh.new()
	shaft_mesh.top_radius = 0.015
	shaft_mesh.bottom_radius = 0.015
	shaft_mesh.height = 1.0
	_mesh.mesh = shaft_mesh

	# Brown wood material
	var shaft_material = StandardMaterial3D.new()
	shaft_material.albedo_color = Color(0.5, 0.3, 0.15)  # Brown wood
	shaft_material.roughness = 0.8
	_mesh.material_override = shaft_material

	# Rotate to point forward (-Z direction)
	_mesh.rotation.x = deg_to_rad(90)

	add_child(_mesh)

	# Create V-shaped arrowhead using two angled planes
	var tip_material = StandardMaterial3D.new()
	tip_material.albedo_color = Color(0.4, 0.4, 0.45)  # Metal gray
	tip_material.metallic = 0.9
	tip_material.roughness = 0.3

	# Left blade of V
	var left_blade = MeshInstance3D.new()
	left_blade.name = "LeftBlade"
	var left_mesh = PrismMesh.new()
	left_mesh.size = Vector3(0.08, 0.15, 0.02)
	left_blade.mesh = left_mesh
	left_blade.material_override = tip_material
	left_blade.position = Vector3(-0.025, 0, -0.55)
	left_blade.rotation.x = deg_to_rad(90)
	left_blade.rotation.z = deg_to_rad(-15)
	add_child(left_blade)

	# Right blade of V
	var right_blade = MeshInstance3D.new()
	right_blade.name = "RightBlade"
	var right_mesh = PrismMesh.new()
	right_mesh.size = Vector3(0.08, 0.15, 0.02)
	right_blade.mesh = right_mesh
	right_blade.material_override = tip_material
	right_blade.position = Vector3(0.025, 0, -0.55)
	right_blade.rotation.x = deg_to_rad(90)
	right_blade.rotation.z = deg_to_rad(15)
	add_child(right_blade)

	# Add fletching (feathers) at the back
	var feather_material = StandardMaterial3D.new()
	feather_material.albedo_color = Color(0.8, 0.2, 0.1)  # Red feathers
	feather_material.roughness = 0.9

	for i in range(3):
		var feather = MeshInstance3D.new()
		feather.name = "Feather%d" % i
		var feather_mesh = BoxMesh.new()
		feather_mesh.size = Vector3(0.06, 0.12, 0.005)
		feather.mesh = feather_mesh
		feather.material_override = feather_material

		var angle = (TAU / 3.0) * i
		feather.position = Vector3(cos(angle) * 0.025, sin(angle) * 0.025, 0.45)
		feather.rotation.z = angle
		add_child(feather)


func _setup_fire_effect() -> void:
	# Main fire particles
	_fire_particles = GPUParticles3D.new()
	_fire_particles.name = "FireParticles"
	_fire_particles.amount = 50
	_fire_particles.lifetime = 0.5
	_fire_particles.explosiveness = 0.0
	_fire_particles.randomness = 0.5

	var fire_material = ParticleProcessMaterial.new()
	fire_material.direction = Vector3(0, 1, 0)
	fire_material.spread = 30.0
	fire_material.initial_velocity_min = 1.0
	fire_material.initial_velocity_max = 3.0
	fire_material.gravity = Vector3(0, 2, 0)
	fire_material.scale_min = 0.1
	fire_material.scale_max = 0.3

	# Fire color gradient
	var color_ramp = GradientTexture1D.new()
	var gradient = Gradient.new()
	gradient.set_color(0, Color(1.0, 0.8, 0.2, 1.0))  # Yellow
	gradient.set_color(1, Color(1.0, 0.3, 0.0, 0.0))  # Orange to transparent
	color_ramp.gradient = gradient
	fire_material.color_ramp = color_ramp

	# Emission color
	fire_material.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	fire_material.emission_sphere_radius = 0.1

	_fire_particles.process_material = fire_material

	# Fire mesh (billboard quad)
	var fire_mesh = QuadMesh.new()
	fire_mesh.size = Vector2(0.15, 0.15)

	var fire_mesh_material = StandardMaterial3D.new()
	fire_mesh_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	fire_mesh_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fire_mesh_material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	fire_mesh_material.albedo_color = Color(1.0, 0.6, 0.2, 0.8)
	fire_mesh_material.emission_enabled = true
	fire_mesh_material.emission = Color(1.0, 0.4, 0.0)
	fire_mesh_material.emission_energy_multiplier = 3.0
	fire_mesh.material = fire_mesh_material

	_fire_particles.draw_pass_1 = fire_mesh
	_fire_particles.position = Vector3(0, 0, 0.2)  # Behind the arrow

	add_child(_fire_particles)

	# Trail particles
	_trail_particles = GPUParticles3D.new()
	_trail_particles.name = "TrailParticles"
	_trail_particles.amount = 30
	_trail_particles.lifetime = 0.3
	_trail_particles.explosiveness = 0.0

	var trail_material = ParticleProcessMaterial.new()
	trail_material.direction = Vector3(0, 0, 1)
	trail_material.spread = 5.0
	trail_material.initial_velocity_min = 0.5
	trail_material.initial_velocity_max = 1.0
	trail_material.gravity = Vector3.ZERO
	trail_material.scale_min = 0.05
	trail_material.scale_max = 0.1

	var trail_color_ramp = GradientTexture1D.new()
	var trail_gradient = Gradient.new()
	trail_gradient.set_color(0, Color(1.0, 0.5, 0.0, 0.8))
	trail_gradient.set_color(1, Color(1.0, 0.2, 0.0, 0.0))
	trail_color_ramp.gradient = trail_gradient
	trail_material.color_ramp = trail_color_ramp

	_trail_particles.process_material = trail_material
	_trail_particles.draw_pass_1 = fire_mesh.duplicate()
	_trail_particles.position = Vector3(0, 0, 0.4)

	add_child(_trail_particles)

	# Add point light for fire glow
	var light = OmniLight3D.new()
	light.name = "FireLight"
	light.light_color = Color(1.0, 0.5, 0.1)
	light.light_energy = 2.0
	light.omni_range = 3.0
	light.omni_attenuation = 2.0
	add_child(light)


func _setup_collision() -> void:
	_collision = CollisionShape3D.new()
	_collision.name = "ArrowCollision"

	var shape = CapsuleShape3D.new()
	shape.radius = 0.05
	shape.height = 0.8
	_collision.shape = shape
	_collision.rotation.x = deg_to_rad(90)

	add_child(_collision)


func _on_body_entered(body: Node) -> void:
	if _has_hit:
		return

	# Don't hit the shooter
	if body == shooter:
		return

	_has_hit = true

	# Stop movement
	freeze = true

	# Deal damage if applicable
	var hit_entity_id: int = 0
	if body.has_method("take_damage"):
		body.take_damage(DAMAGE, shooter)
		if "entity_id" in body:
			hit_entity_id = body.entity_id

	# Stop fire effect but keep some embers
	_fire_particles.emitting = false
	_trail_particles.emitting = false

	# Broadcast hit event to network (only for local arrows)
	if is_local and has_node("/root/NetworkManager"):
		var network_manager = get_node("/root/NetworkManager")
		network_manager.send_arrow_hit(arrow_id, global_position, hit_entity_id)

	# Create ground fire illumination (5m range fireplace light)
	_create_ground_fire()

	# Queue free after a delay
	var timer = get_tree().create_timer(3.0)
	timer.timeout.connect(queue_free)


func _create_ground_fire() -> void:
	# Create a persistent fire light at landing position
	var fire_node = Node3D.new()
	fire_node.name = "ArrowGroundFire"
	get_tree().current_scene.add_child(fire_node)
	fire_node.global_position = global_position

	print("Arrow ground fire created at: ", global_position)

	# Main fireplace light - intense warm glow with 5m radius
	var ground_light = OmniLight3D.new()
	ground_light.name = "FireplaceLight"
	ground_light.light_color = Color(1.0, 0.5, 0.1)  # Intense orange-red
	ground_light.light_energy = 500.0  # Very intense for clear visibility
	ground_light.omni_range = 5.0
	ground_light.omni_attenuation = 0.8  # Lower attenuation = more even light spread
	ground_light.shadow_enabled = true
	ground_light.position = Vector3(0, 0.5, 0)  # Above ground
	fire_node.add_child(ground_light)

	# Secondary fill light for broader illumination
	var fill_light = OmniLight3D.new()
	fill_light.name = "FillLight"
	fill_light.light_color = Color(1.0, 0.7, 0.3)
	fill_light.light_energy = 200.0
	fill_light.omni_range = 8.0
	fill_light.omni_attenuation = 1.5
	fill_light.shadow_enabled = false
	fill_light.position = Vector3(0, 1.0, 0)
	fire_node.add_child(fill_light)

	# Large intense fire particles
	var ground_fire = GPUParticles3D.new()
	ground_fire.name = "GroundFireParticles"
	ground_fire.amount = 80
	ground_fire.lifetime = 0.8
	ground_fire.explosiveness = 0.1
	ground_fire.randomness = 0.6

	var fire_mat = ParticleProcessMaterial.new()
	fire_mat.direction = Vector3(0, 1, 0)
	fire_mat.spread = 35.0
	fire_mat.initial_velocity_min = 1.0
	fire_mat.initial_velocity_max = 4.0
	fire_mat.gravity = Vector3(0, 3.0, 0)  # Fire rises
	fire_mat.scale_min = 0.3
	fire_mat.scale_max = 0.8

	var color_ramp = GradientTexture1D.new()
	var gradient = Gradient.new()
	gradient.add_point(0.0, Color(1.0, 1.0, 0.5, 1.0))  # Bright white-yellow core
	gradient.add_point(0.3, Color(1.0, 0.8, 0.2, 1.0))  # Yellow
	gradient.add_point(0.6, Color(1.0, 0.4, 0.0, 0.9))  # Orange
	gradient.add_point(1.0, Color(0.8, 0.1, 0.0, 0.0))  # Red fade out
	color_ramp.gradient = gradient
	fire_mat.color_ramp = color_ramp
	fire_mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	fire_mat.emission_sphere_radius = 0.4

	ground_fire.process_material = fire_mat

	var fire_mesh = QuadMesh.new()
	fire_mesh.size = Vector2(0.5, 0.5)
	var mesh_mat = StandardMaterial3D.new()
	mesh_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mesh_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mesh_mat.albedo_color = Color(1.0, 0.8, 0.3, 1.0)
	mesh_mat.emission_enabled = true
	mesh_mat.emission = Color(1.0, 0.6, 0.1)
	mesh_mat.emission_energy_multiplier = 5.0
	fire_mesh.material = mesh_mat

	ground_fire.draw_pass_1 = fire_mesh
	ground_fire.position = Vector3(0, 0.2, 0)
	fire_node.add_child(ground_fire)

	# Add smoke particles
	var smoke = GPUParticles3D.new()
	smoke.name = "SmokeParticles"
	smoke.amount = 20
	smoke.lifetime = 2.0

	var smoke_mat = ParticleProcessMaterial.new()
	smoke_mat.direction = Vector3(0, 1, 0)
	smoke_mat.spread = 20.0
	smoke_mat.initial_velocity_min = 0.5
	smoke_mat.initial_velocity_max = 1.5
	smoke_mat.gravity = Vector3(0, 0.5, 0)
	smoke_mat.scale_min = 0.5
	smoke_mat.scale_max = 1.5

	var smoke_gradient = Gradient.new()
	smoke_gradient.add_point(0.0, Color(0.3, 0.3, 0.3, 0.0))
	smoke_gradient.add_point(0.2, Color(0.3, 0.3, 0.3, 0.4))
	smoke_gradient.add_point(1.0, Color(0.2, 0.2, 0.2, 0.0))
	var smoke_ramp = GradientTexture1D.new()
	smoke_ramp.gradient = smoke_gradient
	smoke_mat.color_ramp = smoke_ramp

	smoke.process_material = smoke_mat
	var smoke_mesh = QuadMesh.new()
	smoke_mesh.size = Vector2(1.0, 1.0)
	var smoke_mesh_mat = StandardMaterial3D.new()
	smoke_mesh_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	smoke_mesh_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	smoke_mesh_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	smoke_mesh_mat.albedo_color = Color(0.4, 0.4, 0.4, 0.5)
	smoke_mesh.material = smoke_mesh_mat
	smoke.draw_pass_1 = smoke_mesh
	smoke.position = Vector3(0, 0.5, 0)
	fire_node.add_child(smoke)

	# Add light flickering effect
	_start_light_flicker(ground_light, fire_node)

	# Auto-destroy after 30 seconds
	var destroy_timer = get_tree().create_timer(30.0)
	destroy_timer.timeout.connect(fire_node.queue_free)


func _start_light_flicker(light: OmniLight3D, parent: Node3D) -> void:
	# Create a tween for realistic fire flicker
	var flicker_tween = parent.create_tween()
	flicker_tween.set_loops()
	flicker_tween.tween_property(light, "light_energy", 600.0, 0.1)
	flicker_tween.tween_property(light, "light_energy", 400.0, 0.15)
	flicker_tween.tween_property(light, "light_energy", 550.0, 0.08)
	flicker_tween.tween_property(light, "light_energy", 450.0, 0.12)
