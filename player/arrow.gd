extends RigidBody3D
class_name Arrow

## Fire arrow projectile with parabolic trajectory
## Network-synchronized across all players

const DamageAuraAreaClass := preload("res://combat/damage_aura_area.gd")

const ARROW_SPEED: float = 50.0
const LIFETIME: float = 10.0
## Direct-hit damage, in HP. Fully negated when the target is blocking.
##
## ABSOLUTE, not a percentage of the target's max HP, which is what this was.
## Percent damage quietly made every health bar in the game meaningless to
## archery: an arrow did 5 to the archer and 50 to Bobba, and EVERY enemy died
## in exactly twenty arrows however its HP was tuned. Raising a boss's health
## bought it nothing against a bow. 35 restores the intent already written
## into SkeletonWarrior.MAX_HP ("~5 arrows") and makes a boss's 1500 HP mean
## what it says.
const DIRECT_HIT_DAMAGE: float = 35.0
# A shot loosed mid-air has no planted stance behind it: its flame runs
# at half brightness and the hit carries only this fraction of the damage.
const AIRBORNE_SHOT_DAMAGE_MULT: float = 0.5
var airborne_shot: bool = false
#Launch speed: quick 1.0, sighted 1.5; moving halves either shot.
var shot_power: float = 1.0
var _flight_velocity := Vector3.ZERO
## Ground fire DoT, in HP per second, to any character inside the radius for
## as long as the fire burns. Also absolute now, and deliberately modest: at
## 5% of max HP it was doing 50 a second to Bobba, which made a patch of
## burning grass the strongest weapon in the game against bosses. Fire is
## area denial and light - see combat/fire_glow.gd - not a damage race.
const GROUND_FIRE_DAMAGE_PER_SEC: float = 18.0
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
	continuous_cd = true

	# Connect body entered signal
	body_entered.connect(_on_body_entered)

	# Set physics properties
	gravity_scale = 1.0
	# DRAG-FREE, and it has to be said twice. `linear_damp = 0.0` alone does
	# not mean zero: the default damp mode COMBINES the body's value with the
	# space's, and the project ships Godot's 0.1 default there — which quietly
	# bled ~7% of an arrow's speed over a 35 m flight. The companion solves
	# its trajectory from speed and gravity alone; hidden drag invalidates it.
	linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
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
		#Keep the incoming velocity: contact response can stop the body
		#before body_entered reports the hit.
		_flight_velocity = linear_velocity
		var dir := linear_velocity.normalized()
		var up := Vector3.RIGHT if absf(dir.y) > .99 else Vector3.UP
		look_at(global_position + dir, up)


func launch(direction: Vector3) -> void:
	# Apply initial velocity (a moving loose leaves the string at half force)
	var dir := direction.normalized()
	linear_velocity = dir * ARROW_SPEED * shot_power
	_flight_velocity = linear_velocity
	var up := Vector3.RIGHT if absf(dir.dot(Vector3.UP)) > .99 else Vector3.UP
	look_at(global_position + dir, up)
	# No gravity tricks needed: ballistic range goes with v², so half the
	# launch force by itself caps the MAXIMUM (arced) flight at one quarter.


func _setup_arrow_mesh() -> void:
	var visual := create_visual()
	add_child(visual)
	_mesh = visual.get_node("ArrowShaft")


static func create_visual() -> Node3D:
	var visual := Node3D.new()
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
	var shaft := MeshInstance3D.new()
	shaft.name = "ArrowShaft"
	var shaft_mesh := CylinderMesh.new()
	shaft_mesh.top_radius = 0.010   # nock end (cylinder +Y maps to +Z after rotation)
	shaft_mesh.bottom_radius = 0.013
	shaft_mesh.height = 0.92
	shaft_mesh.radial_segments = 8
	shaft.mesh = shaft_mesh
	shaft.material_override = wood
	shaft.rotation.x = deg_to_rad(-90)  # -Y (thick end) points forward (-Z)
	visual.add_child(shaft)

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
	visual.add_child(head)

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
	visual.add_child(collar)

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
	visual.add_child(nock)

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
		visual.add_child(vane)

	return visual


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


#Gravity trades vertical speed for height; horizontal speed carries through.
#Scale damage by arrival speed, not launch power a second time.
func _compute_flat_arrow_damage(_body: Node) -> float:
	var speed := _flight_velocity.length() / ARROW_SPEED
	var air := AIRBORNE_SHOT_DAMAGE_MULT if airborne_shot else 1.0
	return DIRECT_HIT_DAMAGE * speed * air


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
	var surface := "flesh" if body.has_method("take_hit") \
			or body.has_method("take_damage_flat") else Sfx.surface(body)
	if surface not in ["flesh", "wood"]:
		surface = "stone"
	Sfx.play3d("arrow_impact_" + surface, global_position, -4.0)

	# Stop movement
	freeze = true

	#Direct damage is in HP and includes the velocity at impact.
	# * Players: route through take_hit so block fully negates the hit.
	# * NPCs: direct take_damage_flat (they don't block).
	# Also call take_arrow_hit on Bobba for its "flee from arrows" reaction.
	var hit_entity_id: int = 0
	if "entity_id" in body:
		hit_entity_id = body.entity_id

	var flat_damage_for_network: float = _compute_flat_arrow_damage(body)

	var is_player: bool = "is_blocking" in body and body.has_method("take_hit")
	# Did this land in something that can WALK AWAY? A shaft frozen in world
	# space where a body used to be is left hanging in mid-air the moment that
	# body moves — so a hit on a character ends the arrow then and there and
	# the fire rides the victim instead of the spot they were standing on.
	var hit_body: bool = is_player or body.has_method("take_damage_flat") \
			or body.has_method("take_arrow_hit")
	if is_player:
		# Player hit — honor block state (blocks fully negate arrows).
		var impulse: Vector3 = _flight_velocity.normalized() * 3.0
		impulse.y = 0.1
		var blocked: bool = bool(body.is_blocking)
		body.take_hit(flat_damage_for_network, impulse, blocked, shooter, true)
	elif body.has_method("take_damage_flat"):
		body.take_damage_flat(flat_damage_for_network)
		# Dry bones catch: a landed fire arrow sets skeletons alight —
		# a weaker mid-air shot clings for a shorter burn.
		if body.has_method("ignite"):
			body.ignite(4.0 * AIRBORNE_SHOT_DAMAGE_MULT if airborne_shot else 4.0)

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

	if hit_body:
		# The fire goes ON him and burns for its full time while he runs
		# around wearing it — light the party can see by, and a target the
		# paladin can find. The arrow itself is done: gone this frame.
		_create_body_fire(body)
		queue_free()
		return

	# Landed in the world: the shaft stays put and lights the ground it hit,
	# which is the archer's whole contribution to a night fight.
	_create_ground_fire()

	# Queue free after a delay
	var timer = get_tree().create_timer(3.0)
	timer.timeout.connect(queue_free)


## Fire attached to whatever it hit, so it travels with him for the same
## GROUND_FIRE_LIFETIME. It joins "ground_fire" like any other flame — a
## burning enemy IS lit, and every AI in the game should be able to see him by
## it — and also "body_fire", which is how Bobba tells a fire he is wearing
## from a fire on the ground he ought to walk around (enemies/bobba.gd).
func _create_body_fire(body: Node) -> void:
	if body == null or not is_instance_valid(body) or not (body is Node3D):
		return
	var fire_node: Node3D = FireFX.create_ground_fire(
			body, global_position, "ArrowBodyFire", GROUND_FIRE_LIFETIME, true, false)
	fire_node.add_to_group("body_fire")
	# Sit it on the victim rather than at the exact impact point: an arrow in
	# the shoulder should not light a bonfire floating beside his ear.
	fire_node.position = Vector3(0.0, 0.9, 0.0)
	print("Arrow set %s alight for %.0fs" % [body.name, GROUND_FIRE_LIFETIME])
	_attach_fire_aura(fire_node)


func _create_ground_fire() -> void:
	# Full fire composition (lights + flames + embers + smoke + scorch,
	# with burn-down and auto-free) comes from the shared FireFX factory.
	# Named for the log; Bobba finds it through the "ground_fire" group.
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
	_attach_fire_aura(fire_node)


## Damage-over-time aura for a fire this arrow lit, ground or body.
func _attach_fire_aura(fire_node: Node3D) -> void:
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
		aura.damage_per_sec = GROUND_FIRE_DAMAGE_PER_SEC
		aura.tick_interval = 1.0
		aura.lifetime = GROUND_FIRE_LIFETIME
		# Excludes the shooter AND everyone on his side — this is the fire the
		# paladin is being asked to stand next to so he can see.
		aura.source_node = shooter
		aura.ticked.connect(func(damaged: Array) -> void:
			for b in damaged:
				print("Arrow fire DoT tick: %s took %.1f HP" % [
					b.name, GROUND_FIRE_DAMAGE_PER_SEC
				]))
		#Impacts arrive inside the physics contact callback.
		fire_node.add_child.call_deferred(aura)
	# (FireFX.create_ground_fire owns the burn-down and auto-free.)
