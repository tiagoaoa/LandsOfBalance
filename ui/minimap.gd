extends Control
## Minimap UI showing the Lands of Balance with player location

# Map bounds (matching the expanded 3D world)
const MAP_MIN := Vector2(-150, -150)
const MAP_MAX := Vector2(150, 150)

# Location data matching the expanded lands_of_balance.tscn
const LOCATIONS := {
	"Village of Eights": Vector2(0, 0),
	"Common Ground": Vector2(0, 70),
	"Tower of Hakutnas": Vector2(-80, -60),
	"Realm of Hudson": Vector2(80, -50),
	"The Hills": Vector2(-30, 20),
	"The Burning Peaks": Vector2(-120, 0),
	"The Silent Woods": Vector2(120, 0),
	"Fire Creature Lair": Vector2(-115, 5),
	"Silent Creature Lair": Vector2(120, 1),
	"Fields": Vector2(60, -35),
}

var player: Node3D

@onready var map_panel := $MapPanel as Panel
@onready var player_marker := $MapPanel/PlayerMarker as Control
@onready var location_label := $LocationLabel as Label


func _ready() -> void:
	# Find player in scene
	await get_tree().process_frame
	player = get_node_or_null("/root/Game/Player")


func _process(_delta: float) -> void:
	if not is_instance_valid(player):
		return

	var player_pos := Vector2(player.global_position.x, player.global_position.z)

	# Update player marker position on minimap
	var map_size := map_panel.size
	var normalized_pos := (player_pos - MAP_MIN) / (MAP_MAX - MAP_MIN)
	normalized_pos.y = 1.0 - normalized_pos.y  # Flip Y for screen coordinates
	player_marker.position = normalized_pos * map_size - player_marker.size / 2

	# Update location label based on proximity
	var closest_location := ""
	var closest_distance := 999999.0
	for loc_name: String in LOCATIONS:
		var loc_pos: Vector2 = LOCATIONS[loc_name]
		var dist := player_pos.distance_to(loc_pos)
		if dist < closest_distance:
			closest_distance = dist
			closest_location = loc_name

	if closest_distance < 50:
		location_label.text = closest_location
	else:
		location_label.text = "The Lands of Balance"
