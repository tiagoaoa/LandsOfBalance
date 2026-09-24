extends Area3D


var taken: bool = false


func _ready() -> void:
	$Sound.stream = Sfx._get_stream("coin")
	$Sound.bus = &"Foley"
	$Sound.volume_db = -5.0
	$Sound.max_distance = 18.0
	$Sound.unit_size = 4.0


func _on_coin_body_enter(body: Node) -> void:
	if not taken and body is Player:
		$Animation.play(&"take")
		taken = true
		# We've already checked whether the colliding body is a Player, which has a `coins` property.
		# As a result, we can safely increment its `coins` property.
		body.coins += 1
