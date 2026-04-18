extends VBoxContainer

## Top-right combat HUD — lists HP for every other combatant besides the
## local player: nearby NPCs (Bobba, Dragon) and all remote players.
##
## The panel auto-refreshes every REFRESH_INTERVAL seconds: it scans for
## live targets and updates their row; rows for targets that have left the
## scene (or died) are removed.
##
## Each row looks like:
##   Name #id           120 / 150
##   ████████░░░░░░░░
##
## Kept intentionally simple — no animation, no sorting beyond discovery
## order. Add sorting / distance-based filtering later if the list gets long.

const REFRESH_INTERVAL: float = 0.25

var _rows: Dictionary = {}  # Node key → row dict { container, label, bar, hp_text }
var _refresh_timer: float = REFRESH_INTERVAL  # Fire once immediately


func _ready() -> void:
	add_theme_constant_override("separation", 6)


func _process(delta: float) -> void:
	_refresh_timer += delta
	if _refresh_timer < REFRESH_INTERVAL:
		return
	_refresh_timer = 0.0
	_refresh()


func _refresh() -> void:
	var targets: Array = _collect_targets()

	# Remove stale rows
	var active_keys := {}
	for t in targets:
		active_keys[t.node] = true
	var to_remove: Array = []
	for key in _rows.keys():
		if not active_keys.has(key):
			to_remove.append(key)
	for key in to_remove:
		if is_instance_valid(_rows[key].container):
			_rows[key].container.queue_free()
		_rows.erase(key)

	# Create / update rows
	for t in targets:
		var row = _rows.get(t.node)
		if row == null:
			row = _create_row(t.color)
			_rows[t.node] = row
		_update_row(row, t.name, t.hp, t.max_hp, t.color)


func _collect_targets() -> Array:
	var out: Array = []

	# NPCs
	for b in get_tree().get_nodes_in_group("bobba"):
		if not is_instance_valid(b):
			continue
		var hp: float = float(b.health) if "health" in b else 0.0
		var mx: float = float(b.MAX_HEALTH) if "MAX_HEALTH" in b else 1000.0
		if hp <= 0.0:
			continue
		out.append({
			"node": b,
			"name": "Bobba",
			"hp": hp,
			"max_hp": mx,
			"color": Color(1.0, 0.35, 0.25),
		})
	for d in get_tree().get_nodes_in_group("dragon"):
		if not is_instance_valid(d):
			continue
		var hp: float = float(d.health) if "health" in d else 0.0
		var mx: float = float(d.MAX_HEALTH) if "MAX_HEALTH" in d else 500.0
		if hp <= 0.0:
			continue
		out.append({
			"node": d,
			"name": "Dragon",
			"hp": hp,
			"max_hp": mx,
			"color": Color(0.85, 0.15, 0.15),
		})

	# Remote players (other clients connected to the server)
	var nm := get_node_or_null("/root/NetworkManager")
	if nm and "remote_players" in nm:
		for pid in nm.remote_players.keys():
			var remote = nm.remote_players[pid]
			if not is_instance_valid(remote):
				continue
			var cls: int = int(remote.character_class) if "character_class" in remote else 1
			var class_name_str: String = "Paladin" if cls == 0 else "Archer"
			var mx: float = 150.0 if cls == 0 else 100.0
			var hp: float = float(remote.health) if "health" in remote else mx
			if hp <= 0.0:
				continue
			out.append({
				"node": remote,
				"name": "%s #%d" % [class_name_str, pid],
				"hp": hp,
				"max_hp": mx,
				"color": Color(0.4, 0.6, 1.0) if cls == 0 else Color(0.4, 1.0, 0.6),
			})

	return out


func _create_row(color: Color) -> Dictionary:
	var container := VBoxContainer.new()
	container.add_theme_constant_override("separation", 1)
	add_child(container)

	var label := Label.new()
	label.add_theme_color_override("font_color", Color(1.0, 0.95, 0.85))
	label.add_theme_font_size_override("font_size", 14)
	container.add_child(label)

	var bar := ProgressBar.new()
	bar.custom_minimum_size = Vector2(200, 12)
	bar.min_value = 0.0
	bar.max_value = 1.0
	bar.show_percentage = false
	var style_bg := StyleBoxFlat.new()
	style_bg.bg_color = Color(0.12, 0.06, 0.06, 0.9)
	style_bg.corner_radius_top_left = 3
	style_bg.corner_radius_top_right = 3
	style_bg.corner_radius_bottom_left = 3
	style_bg.corner_radius_bottom_right = 3
	bar.add_theme_stylebox_override("background", style_bg)
	var style_fill := StyleBoxFlat.new()
	style_fill.bg_color = color
	style_fill.corner_radius_top_left = 3
	style_fill.corner_radius_top_right = 3
	style_fill.corner_radius_bottom_left = 3
	style_fill.corner_radius_bottom_right = 3
	bar.add_theme_stylebox_override("fill", style_fill)
	container.add_child(bar)

	return {
		"container": container,
		"label": label,
		"bar": bar,
		"style_fill": style_fill,
	}


func _update_row(row: Dictionary, display_name: String, hp: float, max_hp: float, color: Color) -> void:
	var label: Label = row.label
	var bar: ProgressBar = row.bar
	var style: StyleBoxFlat = row.style_fill

	label.text = "%s   %d / %d" % [display_name, int(round(hp)), int(round(max_hp))]
	bar.max_value = max_hp
	bar.value = clampf(hp, 0.0, max_hp)

	# Tint the fill redder as HP drops
	var ratio: float = bar.value / max_hp if max_hp > 0 else 0.0
	if ratio < 0.33:
		style.bg_color = Color(0.9, 0.15, 0.15)
	elif ratio < 0.66:
		style.bg_color = color.lerp(Color(0.9, 0.4, 0.15), 0.5)
	else:
		style.bg_color = color
