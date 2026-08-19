extends RigidBody3D
class_name Arrow

## Fire arrow projectile with parabolic trajectory
## Network-synchronized across all players

const DamageAuraAreaClass := preload("res://combat/damage_aura_area.gd")

const ARROW_SPEED: float = 50.0
const GRAVITY: float = 9.8
const LIFETIME: float = 10.0
## Direct-hit damage, expressed as a percentage of the target's max HP.
## Fully negated when the target is blocking.
const DIRECT_HIT_DAMAGE_PCT: float = 0.05
# A shot loosed mid-air has no planted stance behind it: its flame runs
# at half brightness and the hit carries only this fraction of the damage.
const AIRBORNE_SHOT_DAMAGE_MULT: float = 0.5
var airborne_shot: bool = false
# Launch force multiplier: 1.0 for a planted loose, 0.5 when shot on the
# move (half force → ~quarter ballistic range; damage scales with it).
var shot_power: float = 1.0
## Ground fire DoT: 5% max HP per second to any character inside the radius,
## for as long as the fire burns.
const GROUND_FIRE_DAMAGE_PCT_PER_SEC: float = 0.05
const GROUND_FIRE_RADIUS: float = 5.0
const GROUND_FIRE_LIFETIME: float = 30.0

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
	add_to_group("fire_arrows")  # burning tip reveals characters to AI eyes
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

	# Set collision layer (projectile) and mask (detect world/enemies/remote players)
	collision_layer = 4  # Layer 3 (projectiles)
	collision_mask = 1 | 2 | 8  # Detect layer 1 (world), layer 2 (enemies), layer 4 (remote players)


func _physics_process(delta: float) -> void:
	_lifetime_timer += delta

	if _lifetime_timer > LIFETIME:
		queue_free()
		return

	# Rotate arrow to face velocity direction
	if linear_velocity.length() > 0.1 and not _has_hit:
		look_at(global_position + linear_velocity.normalized(), Vector3.UP)


func launch(direction: Vector3) -> void:
	# Apply initial velocity (a moving loose leaves the string at half force)
	linear_velocity = direction.normalized() * ARROW_SPEED * shot_power
	# No gravity tricks needed: ballistic range goes with v², so half the
	# launch force by itself caps the MAXIMUM (arced) flight at one quarter.


func _setup_arrow_mesh() -> void:
	# Proper fletched war arrow, built procedurally: tapered cedar shaft,
	# forged bodkin head with a metal collar, horn nock, three swept feather
	# vanes (two off-white + the traditional single "cock feather" accent).
	# Forward is -Z (matches look_at in _physics_process).
	var wood := StandardMaterial3D.new()
	wood.albedo_color = Color(0.38, 0.27, 0.16)  # oiled cedar
	wood.roughness = 0.7

	var metal := StandardMaterial3D.new()
	metal.albedo_color = Color(0.62, 0.63, 0.68)
	metal.metallic = 1.0
	metal.roughness = 0.35

	# Shaft — slightly tapered toward the nock.
	_mesh = MeshInstance3D.new()
	_mesh.name = "ArrowShaft"
	var shaft_mesh := CylinderMesh.new()
	shaft_mesh.top_radius = 0.010   # nock end (cylinder +Y maps to +Z after rotation)
	shaft_mesh.bottom_radius = 0.013
	shaft_mesh.height = 0.92
	shaft_mesh.radial_segments = 8
	_mesh.mesh = shaft_mesh
	_mesh.material_override = wood
	_mesh.rotation.x = deg_to_rad(-90)  # -Y (thick end) points forward (-Z)
	add_child(_mesh)

	# Bodkin head — a slim forged spike (cone), far more arrow-like than
	# the old two-prism "V".
	var head := MeshInstance3D.new()
	head.name = "ArrowHead"
	var head_mesh := CylinderMesh.new()
	head_mesh.top_radius = 0.0
	head_mesh.bottom_radius = 0.024
	head_mesh.height = 0.14
	head_mesh.radial_segments = 6  # faceted like hammered steel
	head.mesh = head_mesh
	head.material_override = metal
	head.rotation.x = deg_to_rad(-90)
	head.position = Vector3(0, 0, -0.53)
	add_child(head)

	# Collar where the head is socketed onto the shaft.
	var collar := MeshInstance3D.new()
	collar.name = "HeadCollar"
	var collar_mesh := CylinderMesh.new()
	collar_mesh.top_radius = 0.016
	collar_mesh.bottom_radius = 0.018
	collar_mesh.height = 0.05
	collar_mesh.radial_segments = 8
	collar.mesh = collar_mesh
	collar.material_override = metal
	collar.rotation.x = deg_to_rad(-90)
	collar.position = Vector3(0, 0, -0.44)
	add_child(collar)

	# Horn nock at the tail.
	var nock := MeshInstance3D.new()
	nock.name = "Nock"
	var nock_mesh := CylinderMesh.new()
	nock_mesh.top_radius = 0.014
	nock_mesh.bottom_radius = 0.011
	nock_mesh.height = 0.035
	nock_mesh.radial_segments = 8
	var horn := StandardMaterial3D.new()
	horn.albedo_color = Color(0.15, 0.13, 0.11)
	horn.roughness = 0.4
	nock.mesh = nock_mesh
	nock.material_override = horn
	nock.rotation.x = deg_to_rad(-90)
	nock.position = Vector3(0, 0, 0.465)
	add_child(nock)

	# Fletching — three thin vanes with a slight helical cant (real fletch
	# spin). Goose-grey pair + one red cock feather.
	var vane_mesh := BoxMesh.new()
	vane_mesh.size = Vector3(0.003, 0.042, 0.14)  # thin, low, swept back
	for i in range(3):
		var vane := MeshInstance3D.new()
		vane.name = "Vane%d" % i
		vane.mesh = vane_mesh
		var vane_mat := StandardMaterial3D.new()
		# Muted parchment — bright white blooms next to the tip flame's light.
		vane_mat.albedo_color = Color(0.68, 0.18, 0.10) if i == 0 else Color(0.72, 0.69, 0.60)
		vane_mat.roughness = 0.9
		vane.material_override = vane_mat
		var angle: float = (TAU / 3.0) * i
		# Sit the vane against the shaft, fanned outward, canted 6° for spin.
		vane.position = Vector3(cos(angle) * 0.013, sin(angle) * 0.013, 0.38)
		vane.rotation = Vector3(0, deg_to_rad(6.0), angle + PI / 2.0)
		vane.position += Vector3(cos(angle), sin(angle), 0) * 0.026
		add_child(vane)


var _fire_trail: SlashTrail = null

func _setup_fire_effect() -> void:
	# Burning tip: small additive flame + drifting embers hugging the head.
	# The particles emit in world space, so the arrow's speed naturally
	# stretches them into a comet tail behind the tip.
	var flame_scale: float = 0.5 if airborne_shot else 1.0
	_fire_particles = FireFX.add_flames(self, Vector3(0, 0, -0.45),
			0.35 * (0.7 if airborne_shot else 1.0), int(24 * flame_scale))
	_trail_particles = FireFX.add_embers(self, Vector3(0, 0, -0.4),
			0.4 * (0.7 if airborne_shot else 1.0), int(14 * flame_scale))

	# Ribbon streak along the flight path — the readable "fire arrow" arc.
	_fire_trail = SlashTrail.attach(self, self,
			Vector3(0, 0, -0.15), Vector3(0, 0, -0.5), Color(1.0, 0.55, 0.15, 0.85))
	_fire_trail.lifetime = 0.3
	_fire_trail.emitting = true

	# Warm glow riding the arrow — bright enough to trace the arc through
	# the dark night and glance off the grass it passes over.
	var light = OmniLight3D.new()
	light.name = "FireLight"
	light.light_color = Color(1.0, 0.55, 0.18)
	light.light_energy = 3.0 * (0.5 if airborne_shot else 1.0)
	light.omni_range = 6.0
	light.omni_attenuation = 1.2
	light.position = Vector3(0, 0, -0.4)
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


## Return the arrow's 5%-of-max-HP damage converted to flat HP, for the
## network damage message and for routing through the Player's take_hit path
## (which takes a flat amount). Falls back to 5.0 if the target exposes no
## recognizable max-HP field.
func _compute_flat_arrow_damage(body: Node) -> float:
	if "max_health" in body:
		return float(body.max_health) * DIRECT_HIT_DAMAGE_PCT
	if "MAX_HEALTH" in body:
		return float(body.MAX_HEALTH) * DIRECT_HIT_DAMAGE_PCT
	return 5.0  # Fallback for unknown bodies


func _on_body_entered(body: Node) -> void:
	if _has_hit:
		return

	# Don't hit the shooter
	if body == shooter:
		return

	# No friendly fire. An arrow PASSES THROUGH a teammate rather than
	# stopping dead in him: the archer shoots into a brawl constantly, and
	# an ally's back soaking arrows would make the class unplayable in the
	# one formation the game asks the party to hold.
	if Factions.is_ally(shooter, body):
		return

	_has_hit = true
	Sfx.play3d("arrow_impact", global_position, -4.0)

	# Stop movement
	freeze = true

	# Deal damage. Arrow direct hit = 5% of target max HP.
	# * Players: route through take_hit so block fully negates the hit.
	# * NPCs: direct take_damage_pct (they don't block).
	# Also call take_arrow_hit on Bobba for its "flee from arrows" reaction.
	var hit_entity_id: int = 0
	if "entity_id" in body:
		hit_entity_id = body.entity_id

	var flat_damage_for_network: float = _compute_flat_arrow_damage(body)

	var shot_mult: float = (AIRBORNE_SHOT_DAMAGE_MULT if airborne_shot else 1.0) * shot_power
	var is_player: bool = "is_blocking" in body and body.has_method("take_hit")
	if is_player:
		# Player hit — honor block state (blocks fully negate arrows).
		var impulse: Vector3 = linear_velocity.normalized() * 3.0
		impulse.y = 0.1
		var blocked: bool = bool(body.is_blocking)
		body.take_hit(flat_damage_for_network * shot_mult, impulse, blocked, shooter, true)
	elif body.has_method("take_damage_pct"):
		# NPC — percent-based damage, doesn't block.
		body.take_damage_pct(DIRECT_HIT_DAMAGE_PCT * shot_mult)
		# Dry bones catch: a landed fire arrow sets skeletons alight —
		# a weaker mid-air shot clings for a shorter burn.
		if body.has_method("ignite"):
			body.ignite(4.0 * shot_mult if airborne_shot else 4.0)

	# Keep the legacy arrow-retreat reaction for Bobba (runs in addition
	# to the damage above).
	if body.has_method("take_arrow_hit"):
		body.take_arrow_hit(global_position, self)

	# Stop fire effect but keep some embers
	_fire_particles.emitting = false
	_trail_particles.emitting = false
	if _fire_trail != null:
		_fire_trail.emitting = false

	# Broadcast hit event to network (only for local arrows)
	if is_local and has_node("/root/NetworkManager"):
		var network_manager = get_node("/root/NetworkManager")
		network_manager.send_arrow_hit(arrow_id, global_position, hit_entity_id)
		# Also send entity damage to server if we hit an entity.
		if hit_entity_id > 0:
			network_manager.send_entity_damage(hit_entity_id, flat_damage_for_network, shooter_id)

	# Create ground fire illumination (5m range fireplace light)
	_create_ground_fire()

	# Queue free after a delay
	var timer = get_tree().create_timer(3.0)
	timer.timeout.connect(queue_free)


func _create_ground_fire() -> void:
	# Full fire composition (lights + flames + embers + smoke + scorch,
	# with burn-down and auto-free) comes from the shared FireFX factory.
	# Node name must keep "GroundFire" — Bobba's fire avoidance scans for it.
	var fire_node: Node3D = FireFX.create_ground_fire(
			get_tree().current_scene, global_position,
			"ArrowGroundFire", GROUND_FIRE_LIFETIME, true)

	print("Arrow ground fire created at: ", global_position)

	# Damage-over-time aura — anything (Bobba, Dragon, enemy players) that
	# stands inside the 5m fire takes 5% of max HP per second until the fire
	# expires. The shooter is excluded so the archer can't damage themselves.
	# In multiplayer, only the host/server ticks damage to keep NPC HP
	# authoritative; remote-controlled Bobbas/Dragons on other clients still
	# SEE the fire (visual) but their HP is driven by server state sync.
	var is_multiplayer_client: bool = false
	if has_node("/root/NetworkManager"):
		var nm = get_node("/root/NetworkManager")
		if nm.has_method("is_network_connected") and nm.is_network_connected():
			# Any non-local arrow was already filtered above — but we also
			# avoid ticking damage on non-host peers. For simplicity while
			# the server-authority story settles, only arrows spawned by
			# the local shooter run the DoT here; other arrows handle
			# damage via their own local fire aura on each client.
			is_multiplayer_client = not is_local
	if not is_multiplayer_client:
		var aura: DamageAuraAreaClass = DamageAuraAreaClass.new()
		aura.name = "GroundFireAura"
		aura.radius = GROUND_FIRE_RADIUS
		aura.damage_pct_per_sec = GROUND_FIRE_DAMAGE_PCT_PER_SEC
		aura.tick_interval = 1.0
		aura.lifetime = GROUND_FIRE_LIFETIME
		# Excludes the shooter AND everyone on his side — this is the fire the
		# paladin is being asked to stand next to so he can see.
		aura.source_node = shooter
		aura.ticked.connect(func(damaged: Array) -> void:
			for b in damaged:
				print("Arrow fire DoT tick: %s took %.1f%% of max HP" % [
					b.name, GROUND_FIRE_DAMAGE_PCT_PER_SEC * 100.0
				]))
		fire_node.add_child(aura)
	# (FireFX.create_ground_fire owns the burn-down and auto-free.)
