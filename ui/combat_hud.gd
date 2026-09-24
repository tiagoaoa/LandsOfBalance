extends VBoxContainer

# Party health and nearby threats. Locked targets include their posture
# so the player can see when committing another attack might break guard.

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
		var title: String = t.name
		var me := get_tree().get_first_node_in_group("player")
		if me and me._lock_target == t.node:
			title = "◆ " + title
		if t.node.has_method("is_riposte_ready") and t.node.is_riposte_ready():
			title += "  ·  OPEN"
		_update_row(row, title, t.hp, t.max_hp, t.color)
		var poise: Node = t.node.get("_poise") if "_poise" in t.node else null
		row.poise.visible = poise != null
		if poise:
			row.poise.max_value = poise.max_poise
			row.poise.value = poise.current_poise


func _collect_targets() -> Array:
	var out: Array = []

	# PARTY first — the energy of both players lives in this corner.
	var me := get_tree().get_first_node_in_group("player")
	if me and is_instance_valid(me):
		var my_hp: float = float(me.current_health) if "current_health" in me else 0.0
		var my_mx: float = float(me.max_health) if "max_health" in me else 100.0
		out.append({
			"node": me,
			"name": "You (%s)" % ("Paladin" if int(me.character_class) == 0 else "Archer"),
			"hp": maxf(my_hp, 0.0),
			"max_hp": my_mx,
			"color": Color(0.35, 0.85, 0.45),
		})
	var comp := get_tree().get_first_node_in_group("companion")
	if comp and is_instance_valid(comp):
		var c_hp: float = float(comp.current_health) if "current_health" in comp else 0.0
		var c_mx: float = float(comp.max_health) if "max_health" in comp else 100.0
		if "is_dead" in comp and comp.is_dead:
			c_hp = 0.0
		out.append({
			"node": comp,
			"name": "Ally (%s)" % ("Paladin" if int(comp.character_class) == 0 else "Archer"),
			"hp": maxf(c_hp, 0.0),
			"max_hp": c_mx,
			"color": Color(0.4, 0.7, 1.0),
		})

	for group in ["bobba", "dragon", "skeletons"]:
		for enemy in get_tree().get_nodes_in_group(group):
			if not is_instance_valid(enemy) or me == null:
				continue
			var selected: bool = me._lock_target == enemy
			if not selected and me.global_position.distance_to(enemy.global_position) > 18.0:
				continue
			if group == "skeletons" and not selected:
				continue
			var hp: float = enemy.hp if group == "skeletons" else enemy.health
			if hp <= 0.0:
				continue
			out.append({"node": enemy,
				"name": "Skeleton" if group == "skeletons" else ("Bobba" if group == "bobba" else "Dragon"),
				"hp": hp,
				"max_hp": enemy.MAX_HP if group == "skeletons" else enemy.MAX_HEALTH,
				"color": Color(0.82, 0.25, 0.17)})

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
	var poise := ProgressBar.new()
	poise.custom_minimum_size = Vector2(200, 4)
	poise.show_percentage = false
	poise.mouse_filter = Control.MOUSE_FILTER_IGNORE
	poise.tooltip_text = "Posture: break this bar to open a critical attack"
	poise.add_theme_stylebox_override("background", style_bg.duplicate())
	var posture_fill := StyleBoxFlat.new()
	posture_fill.bg_color = Color(0.82, 0.66, 0.32)
	poise.add_theme_stylebox_override("fill", posture_fill)
	container.add_child(poise)

	return {
		"container": container,
		"label": label,
		"bar": bar,
		"poise": poise,
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
