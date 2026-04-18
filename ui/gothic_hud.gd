extends CanvasLayer

## Dark-fantasy gothic HUD for Douglass the Keeper.
##
## Four regions, all built from nested Panels + StyleBoxFlat frames so we
## stay asset-free and moddable without a texture atlas:
##   • Top-left: circular emblem + HP/Stamina bar pair (primary stats).
##   • Top-right: COMBATANTS panel with enemy HP rows (restyled from
##     ui/combat_hud.gd).
##   • Bottom-left: three ornate ability slots with rune glyphs.
##   • Bottom-right: small horizontal "buff" frame showing an "S" rune
##     and the current damage-buff percent (feeds off Player.damage_buff_pct).
##
## Style is hand-crafted StyleBoxes — dark near-black backgrounds, double
## bronze borders, corner diamonds, and parchment-tinted text. The look
## targets the Dark Souls / Elder-Scroll UI reference the user pinned.

const COL_BG := Color(0.04, 0.035, 0.03, 0.90)
const COL_BG_DEEP := Color(0.02, 0.015, 0.01, 0.94)
const COL_BORDER_OUTER := Color(0.52, 0.40, 0.18)  # tarnished bronze
const COL_BORDER_INNER := Color(0.14, 0.11, 0.08)  # near-black metal
const COL_CORNER_GEM := Color(0.75, 0.58, 0.22)  # brighter gold accent
const COL_TEXT := Color(0.88, 0.80, 0.60)         # aged parchment
const COL_TEXT_DIM := Color(0.58, 0.48, 0.30)
const COL_TEXT_DEEP := Color(0.95, 0.88, 0.68)
const COL_HP := Color(0.72, 0.12, 0.10)
const COL_HP_DARK := Color(0.28, 0.04, 0.03)
const COL_STAMINA := Color(0.32, 0.56, 0.18)
const COL_STAMINA_DARK := Color(0.08, 0.16, 0.04)
const COL_RED_BAR := Color(0.48, 0.10, 0.08, 0.85)  # the red bar items sit on

const WOOD_SHADER: Shader = preload("res://ui/woodgrain_frame.gdshader")

var _player: Node = null
var _hp_bar: ProgressBar
var _stamina_bar: ProgressBar
var _hp_text: Label
var _stamina_text: Label
var _buff_text: Label


func _ready() -> void:
	layer = 20
	_player = _find_local_player()
	_build_top_left_stats()
	_build_top_right_combatants()
	_build_bottom_left_slots()
	_build_bottom_right_buff()


func _process(_delta: float) -> void:
	if _player == null or not is_instance_valid(_player):
		_player = _find_local_player()
	_sync_player_stats()


func _find_local_player() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	for n in tree.get_nodes_in_group("player"):
		if is_instance_valid(n):
			return n
	return null


# ─── Frame builders ─────────────────────────────────────────────────────

## Dark wooden frame — base of every HUD island. Transparent StyleBox
## so the wood-shader ColorRect rendered as a child shows through; this
## box only provides the drop shadow and a hair-thin outer bronze line.
static func _ornate_frame(deep: bool = false) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0)  # let the wood shader do the painting
	sb.border_width_top = 1
	sb.border_width_bottom = 1
	sb.border_width_left = 1
	sb.border_width_right = 1
	sb.border_color = Color(0, 0, 0, 0.85)
	sb.expand_margin_top = 1
	sb.expand_margin_bottom = 1
	sb.expand_margin_left = 1
	sb.expand_margin_right = 1
	sb.shadow_color = Color(0, 0, 0, 0.75)
	sb.shadow_size = 8
	sb.shadow_offset = Vector2(0, 3)
	return sb


## Drop a wood-grain ColorRect behind every other child of `panel` so the
## frame reads as a carved plank. Updates the shader's `panel_size`
## uniform to match the panel's current size and whenever it resizes.
static func _apply_wood_backing(panel: Control, deep: bool = false,
		is_circle: bool = false) -> void:
	var bg := ColorRect.new()
	bg.name = "WoodBacking"
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var mat := ShaderMaterial.new()
	mat.shader = WOOD_SHADER
	if deep:
		mat.set_shader_parameter("wood_light", Color(0.36, 0.22, 0.10, 1.0))
		mat.set_shader_parameter("wood_dark", Color(0.12, 0.06, 0.02, 1.0))
	else:
		mat.set_shader_parameter("wood_light", Color(0.44, 0.28, 0.14, 1.0))
		mat.set_shader_parameter("wood_dark", Color(0.15, 0.08, 0.04, 1.0))
	mat.set_shader_parameter("rim_color", COL_BORDER_OUTER)
	mat.set_shader_parameter("grain_scale", 0.18 if deep else 0.22)
	mat.set_shader_parameter("grain_warp", 1.7)
	if is_circle:
		# Medallion — pull the bevel inward so the whole face reads as
		# a raised disc, with extra carve distance for the inner ring.
		mat.set_shader_parameter("bevel_size", 10.0)
		mat.set_shader_parameter("carve_offset", 9.0)
	bg.material = mat

	panel.add_child(bg)
	panel.move_child(bg, 0)  # behind all other children

	_push_panel_size(bg, panel.size)
	# Keep the uniform in sync if layout changes.
	panel.resized.connect(func() -> void:
		_push_panel_size(bg, panel.size))


static func _push_panel_size(rect: ColorRect, s: Vector2) -> void:
	if rect.material is ShaderMaterial:
		(rect.material as ShaderMaterial).set_shader_parameter("panel_size", s)


## A thin translucent strip along one edge of `panel` — used as an extra
## highlight (top) or shadow (bottom) for 3D depth on top of the wood.
static func _edge_strip(panel: Control, side: String, thickness: float,
		color: Color) -> void:
	var strip := ColorRect.new()
	strip.color = color
	strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	match side:
		"top":
			strip.anchor_left = 0.0
			strip.anchor_right = 1.0
			strip.anchor_top = 0.0
			strip.anchor_bottom = 0.0
			strip.offset_top = 2
			strip.offset_bottom = 2 + thickness
			strip.offset_left = 4
			strip.offset_right = -4
		"bottom":
			strip.anchor_left = 0.0
			strip.anchor_right = 1.0
			strip.anchor_top = 1.0
			strip.anchor_bottom = 1.0
			strip.offset_top = -2 - thickness
			strip.offset_bottom = -2
			strip.offset_left = 4
			strip.offset_right = -4
	panel.add_child(strip)


## Small gold diamond at each corner of a frame — the "ornate" trick.
## Safe to parent on any Control; uses a 10×10 rotated square.
static func _attach_corner_gems(frame: Control) -> void:
	for ix in 2:
		for iz in 2:
			var gem := ColorRect.new()
			gem.color = COL_CORNER_GEM
			gem.custom_minimum_size = Vector2(6, 6)
			gem.rotation = deg_to_rad(45.0)
			gem.size = Vector2(6, 6)
			# Anchor to each corner; offset inward by the border + a bit.
			gem.anchor_left = float(ix)
			gem.anchor_right = float(ix)
			gem.anchor_top = float(iz)
			gem.anchor_bottom = float(iz)
			gem.offset_left = -3 + (ix * -2)
			gem.offset_right = 3 + (ix * -2)
			gem.offset_top = -3 + (iz * -2)
			gem.offset_bottom = 3 + (iz * -2)
			frame.add_child(gem)


## Standard HUD ProgressBar: dark recessed bg with coloured fill.
static func _build_bar(fill_color: Color, dark_color: Color) -> ProgressBar:
	var bar := ProgressBar.new()
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(200, 14)
	bar.min_value = 0.0
	bar.max_value = 1.0
	bar.value = 1.0

	var bg := StyleBoxFlat.new()
	bg.bg_color = dark_color
	bg.border_width_top = 1
	bg.border_width_bottom = 1
	bg.border_width_left = 1
	bg.border_width_right = 1
	bg.border_color = Color(0.0, 0.0, 0.0, 0.7)
	bg.corner_radius_top_left = 1
	bg.corner_radius_top_right = 1
	bg.corner_radius_bottom_left = 1
	bg.corner_radius_bottom_right = 1
	bar.add_theme_stylebox_override("background", bg)

	var fill := StyleBoxFlat.new()
	fill.bg_color = fill_color
	fill.corner_radius_top_left = 1
	fill.corner_radius_top_right = 1
	fill.corner_radius_bottom_left = 1
	fill.corner_radius_bottom_right = 1
	bar.add_theme_stylebox_override("fill", fill)

	return bar


# ─── Regions ────────────────────────────────────────────────────────────

## Top-left: round emblem + stacked HP/Stamina bar pair.
func _build_top_left_stats() -> void:
	var root := Control.new()
	root.name = "StatsCluster"
	root.set_anchors_preset(Control.PRESET_TOP_LEFT)
	root.position = Vector2(18, 18)
	root.custom_minimum_size = Vector2(330, 92)
	add_child(root)

	# Circular emblem (acts like a status sigil).
	var emblem := Panel.new()
	emblem.name = "Emblem"
	emblem.position = Vector2(0, 8)
	emblem.custom_minimum_size = Vector2(76, 76)
	emblem.size = Vector2(76, 76)
	var circ := _ornate_frame(true)
	circ.corner_radius_top_left = 38
	circ.corner_radius_top_right = 38
	circ.corner_radius_bottom_left = 38
	circ.corner_radius_bottom_right = 38
	emblem.add_theme_stylebox_override("panel", circ)
	root.add_child(emblem)
	_apply_wood_backing(emblem, true, true)

	# Inner ring (inset darker rim) so it reads as a medallion not a puck.
	var emblem_inner := Panel.new()
	emblem_inner.set_anchors_preset(Control.PRESET_FULL_RECT)
	emblem_inner.offset_left = 8
	emblem_inner.offset_top = 8
	emblem_inner.offset_right = -8
	emblem_inner.offset_bottom = -8
	var inner_sb := StyleBoxFlat.new()
	inner_sb.bg_color = Color(0.02, 0.015, 0.012, 0.95)
	inner_sb.corner_radius_top_left = 30
	inner_sb.corner_radius_top_right = 30
	inner_sb.corner_radius_bottom_left = 30
	inner_sb.corner_radius_bottom_right = 30
	inner_sb.border_width_top = 1
	inner_sb.border_width_bottom = 1
	inner_sb.border_width_left = 1
	inner_sb.border_width_right = 1
	inner_sb.border_color = COL_BORDER_OUTER
	emblem_inner.add_theme_stylebox_override("panel", inner_sb)
	emblem.add_child(emblem_inner)

	# Rune glyph (Unicode sword cross — reads as dark-fantasy sigil).
	var rune := Label.new()
	rune.text = "✝"
	rune.set_anchors_preset(Control.PRESET_FULL_RECT)
	rune.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	rune.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	rune.add_theme_font_size_override("font_size", 28)
	rune.add_theme_color_override("font_color", COL_CORNER_GEM)
	emblem.add_child(rune)

	# Bars panel to the right of the emblem.
	var bars_panel := Panel.new()
	bars_panel.name = "BarsPanel"
	bars_panel.position = Vector2(84, 14)
	bars_panel.custom_minimum_size = Vector2(240, 64)
	bars_panel.size = Vector2(240, 64)
	bars_panel.add_theme_stylebox_override("panel", _ornate_frame())
	root.add_child(bars_panel)
	_apply_wood_backing(bars_panel)
	_edge_strip(bars_panel, "top", 1.0, Color(1.0, 0.85, 0.55, 0.22))
	_edge_strip(bars_panel, "bottom", 2.0, Color(0.0, 0.0, 0.0, 0.4))
	_attach_corner_gems(bars_panel)

	var bars_margin := MarginContainer.new()
	bars_margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	bars_margin.add_theme_constant_override("margin_left", 10)
	bars_margin.add_theme_constant_override("margin_right", 10)
	bars_margin.add_theme_constant_override("margin_top", 6)
	bars_margin.add_theme_constant_override("margin_bottom", 6)
	bars_panel.add_child(bars_margin)

	var bars_vbox := VBoxContainer.new()
	bars_vbox.add_theme_constant_override("separation", 3)
	bars_margin.add_child(bars_vbox)

	# HP row
	var hp_header := HBoxContainer.new()
	bars_vbox.add_child(hp_header)
	var hp_label := Label.new()
	hp_label.text = "HP"
	hp_label.add_theme_color_override("font_color", COL_TEXT_DIM)
	hp_label.add_theme_font_size_override("font_size", 10)
	hp_label.custom_minimum_size = Vector2(20, 0)
	hp_header.add_child(hp_label)
	_hp_text = Label.new()
	_hp_text.text = "100 / 100"
	_hp_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_hp_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hp_text.add_theme_color_override("font_color", COL_TEXT)
	_hp_text.add_theme_font_size_override("font_size", 10)
	hp_header.add_child(_hp_text)

	_hp_bar = _build_bar(COL_HP, COL_HP_DARK)
	_hp_bar.custom_minimum_size = Vector2(0, 12)
	bars_vbox.add_child(_hp_bar)

	# Stamina row
	var sta_header := HBoxContainer.new()
	bars_vbox.add_child(sta_header)
	var sta_label := Label.new()
	sta_label.text = "STA"
	sta_label.add_theme_color_override("font_color", COL_TEXT_DIM)
	sta_label.add_theme_font_size_override("font_size", 10)
	sta_label.custom_minimum_size = Vector2(20, 0)
	sta_header.add_child(sta_label)
	_stamina_text = Label.new()
	_stamina_text.text = "100 / 100"
	_stamina_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_stamina_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_stamina_text.add_theme_color_override("font_color", COL_TEXT)
	_stamina_text.add_theme_font_size_override("font_size", 10)
	sta_header.add_child(_stamina_text)

	_stamina_bar = _build_bar(COL_STAMINA, COL_STAMINA_DARK)
	_stamina_bar.custom_minimum_size = Vector2(0, 12)
	bars_vbox.add_child(_stamina_bar)


## Top-right: ornate-framed panel holding the enemy-HP roster (Bobba,
## dragon, remote players). The ui/combat_hud.gd script spawns its rows
## inside our panel so styling stays coherent.
func _build_top_right_combatants() -> void:
	var panel := Panel.new()
	panel.name = "CombatantsPanel"
	panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	panel.position = Vector2(-260, 18)
	panel.custom_minimum_size = Vector2(240, 160)
	panel.size = Vector2(240, 160)
	panel.add_theme_stylebox_override("panel", _ornate_frame())
	add_child(panel)
	_apply_wood_backing(panel)
	_edge_strip(panel, "top", 1.0, Color(1.0, 0.85, 0.55, 0.20))
	_edge_strip(panel, "bottom", 2.0, Color(0.0, 0.0, 0.0, 0.40))
	_attach_corner_gems(panel)

	var inner := MarginContainer.new()
	inner.set_anchors_preset(Control.PRESET_FULL_RECT)
	inner.add_theme_constant_override("margin_left", 12)
	inner.add_theme_constant_override("margin_right", 12)
	inner.add_theme_constant_override("margin_top", 6)
	inner.add_theme_constant_override("margin_bottom", 8)
	panel.add_child(inner)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 5)
	inner.add_child(vbox)

	var header := Label.new()
	header.text = "COMBATANTS"
	header.add_theme_font_size_override("font_size", 10)
	header.add_theme_color_override("font_color", COL_CORNER_GEM)
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(header)

	var divider := ColorRect.new()
	divider.color = COL_BORDER_OUTER
	divider.custom_minimum_size = Vector2(0, 1)
	vbox.add_child(divider)

	var combat_hud_script := preload("res://ui/combat_hud.gd")
	var combat_hud: VBoxContainer = combat_hud_script.new()
	combat_hud.name = "CombatHUD"
	vbox.add_child(combat_hud)


## Bottom-left: three small ornate ability slots sitting above a crimson
## "shelf" bar, mirroring the inventory strip in the reference.
func _build_bottom_left_slots() -> void:
	var root := Control.new()
	root.name = "AbilityCluster"
	root.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	root.position = Vector2(20, -130)  # offset upward from bottom
	root.custom_minimum_size = Vector2(240, 120)
	add_child(root)

	var slot_size: Vector2 = Vector2(66, 86)
	var slot_gap: float = 10.0
	var icons := ["⚔", "🛡", "✦"]  # sword, shield, arcane mark
	for i in 3:
		var slot := Panel.new()
		slot.name = "Slot%d" % i
		slot.position = Vector2(i * (slot_size.x + slot_gap), 0)
		slot.custom_minimum_size = slot_size
		slot.size = slot_size
		slot.add_theme_stylebox_override("panel", _ornate_frame(true))
		root.add_child(slot)
		_apply_wood_backing(slot, true)
		_edge_strip(slot, "top", 1.0, Color(1.0, 0.85, 0.55, 0.22))
		_edge_strip(slot, "bottom", 2.0, Color(0.0, 0.0, 0.0, 0.45))
		_attach_corner_gems(slot)

		# Crimson "shelf" bar at the bottom of the slot, ~10px tall.
		var shelf := ColorRect.new()
		shelf.color = COL_RED_BAR
		shelf.anchor_top = 1.0
		shelf.anchor_bottom = 1.0
		shelf.anchor_left = 0.0
		shelf.anchor_right = 1.0
		shelf.offset_top = -14
		shelf.offset_bottom = -4
		shelf.offset_left = 6
		shelf.offset_right = -6
		slot.add_child(shelf)

		# Glyph centered above the shelf.
		var glyph := Label.new()
		glyph.text = icons[i]
		glyph.add_theme_font_size_override("font_size", 30)
		glyph.add_theme_color_override("font_color", COL_TEXT_DEEP)
		glyph.set_anchors_preset(Control.PRESET_FULL_RECT)
		glyph.offset_bottom = -16  # sit above the shelf
		glyph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		glyph.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		slot.add_child(glyph)


## Bottom-right: small horizontal frame with an "S" rune on the left and
## a number on the right (currently shows the damage-buff %).
func _build_bottom_right_buff() -> void:
	var panel := Panel.new()
	panel.name = "BuffCounter"
	panel.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	panel.position = Vector2(-160, -64)
	panel.custom_minimum_size = Vector2(140, 38)
	panel.size = Vector2(140, 38)
	panel.add_theme_stylebox_override("panel", _ornate_frame())
	add_child(panel)
	_apply_wood_backing(panel)
	_edge_strip(panel, "top", 1.0, Color(1.0, 0.85, 0.55, 0.22))
	_edge_strip(panel, "bottom", 2.0, Color(0.0, 0.0, 0.0, 0.4))
	_attach_corner_gems(panel)

	var hbox := HBoxContainer.new()
	hbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	hbox.add_theme_constant_override("separation", 10)
	hbox.offset_left = 10
	hbox.offset_right = -10
	hbox.offset_top = 4
	hbox.offset_bottom = -4
	panel.add_child(hbox)

	var rune := Label.new()
	rune.text = "ᛋ"  # Elder Futhark "sowilo"
	rune.add_theme_font_size_override("font_size", 22)
	rune.add_theme_color_override("font_color", COL_CORNER_GEM)
	rune.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hbox.add_child(rune)

	var sep := VSeparator.new()
	hbox.add_child(sep)

	_buff_text = Label.new()
	_buff_text.text = "0"
	_buff_text.add_theme_font_size_override("font_size", 18)
	_buff_text.add_theme_color_override("font_color", COL_TEXT_DEEP)
	_buff_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_buff_text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_buff_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(_buff_text)


# ─── Live stat sync ─────────────────────────────────────────────────────

func _sync_player_stats() -> void:
	if _player == null:
		return
	# HP
	if _hp_bar and "current_health" in _player and "max_health" in _player:
		var cur: float = float(_player.current_health)
		var mx: float = float(_player.max_health)
		_hp_bar.max_value = mx
		_hp_bar.value = cur
		if _hp_text:
			_hp_text.text = "%d / %d" % [int(round(cur)), int(round(mx))]
	# Stamina
	if _stamina_bar and "_stamina" in _player and _player._stamina != null:
		var sta = _player._stamina
		_stamina_bar.max_value = sta.max_stamina
		_stamina_bar.value = sta.current_stamina
		if _stamina_text:
			_stamina_text.text = "%d / %d" % [int(round(sta.current_stamina)), int(round(sta.max_stamina))]
	# Damage buff → S rune counter (shown as 0-50%)
	if _buff_text and "damage_buff_pct" in _player:
		var pct: float = clampf(float(_player.damage_buff_pct), 0.0, 0.5)
		_buff_text.text = "%d" % int(round(pct * 100.0))
