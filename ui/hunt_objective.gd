extends VBoxContainer

var _goal: Label
var _hint: Label
var _ally: Label
var _left := 0.0
var _found := false
var _had_boss := false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	offset_left = -245
	offset_right = 245
	offset_top = 18
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_goal = _line(20, Color(0.92, 0.79, 0.53))
	_hint = _line(15, Color(0.83, 0.85, 0.89))
	_ally = _line(14, Color(0.68, 0.78, 0.89))
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint.custom_minimum_size.x = 490


func _line(size: int, color: Color) -> Label:
	var label := Label.new()
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_outline_color", Color(0.015, 0.02, 0.03, 0.95))
	label.add_theme_constant_override("outline_size", 4)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(label)
	return label


func _process(delta: float) -> void:
	_left -= delta
	if _left > 0.0:
		return
	_left = 0.25
	var player := get_tree().get_first_node_in_group("player") as Node3D
	var boss := get_tree().get_first_node_in_group("bobba") as Bobba
	visible = player != null and (boss != null or _had_boss)
	if not visible:
		return
	_had_boss = _had_boss or boss != null
	var seen := boss != null and Perception.can_see(player, boss)
	_found = _found or seen
	_goal.text = "HUNT BOBBA" if not _found else "BRING BOBBA DOWN"
	_hint.text = "Stay together. Light the grass with fire arrows."
	if _found:
		_hint.text = "Fire breaks his windup. Strike while he is open."
	if seen and boss.is_riposte_ready():
		_hint.text = "His guard is broken. Close in and strike!"
	elif seen and boss.kindled_left > 0.0:
		_hint.text = "Kindled: follow the fire with a sword strike."
	if boss == null or boss.health <= 0.0:
		_goal.text = "HUNT COMPLETE"
		_hint.text = "Bobba is defeated."
	_update_ally()


func _update_ally() -> void:
	_ally.text = ""
	var companion := get_tree().get_first_node_in_group("companion")
	if companion == null:
		return
	if companion.is_dead:
		_ally.text = "Ally down: clear space and hold Y to revive."
		return
	var ai := companion.get_node_or_null("CompanionAI") as CompanionAI
	if ai == null or not (ai._role is ArcherRole):
		return
	var role := ai._role as ArcherRole
	var words := {"regroup": "Coming back to you", "sweep": "Lighting your path",
		"illuminate": "Lighting the fight", "suppress": "Covering you",
		"buff_run": "Bringing the fire circle", "fallback": "Falling back to you",
		"revive": "Making room to revive you", "kite": "Watching your flank"}
	_ally.text = "Archer: " + str(words.get(role.tactic, "At your side"))
