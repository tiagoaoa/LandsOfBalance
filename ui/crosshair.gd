extends Control

## The archer's sight: a small white ring with a cross inside it, drawn at the
## exact centre of the screen.
##
#The ring sets launch direction. Gravity bends the flight after release.
##
## Everything is drawn rather than textured: at this size a bitmap would need
## one asset per DPI, and the ring has to stay a couple of pixels wide on a
## phone and on a 4K monitor alike.

## Ring radius in pixels at a 1080p-tall viewport; scaled with the window so a
## phone does not get a dot and a big screen does not get a hoop.
const RADIUS: float = 9.0
const REF_HEIGHT: float = 1080.0
## Ring/tick thickness, and the gap the ticks leave open around the centre.
const LINE_W: float = 1.6
const TICK_LEN: float = 4.0
const TICK_GAP: float = 3.0
## A black pass under the white one. Without it the sight vanishes against
## snow, fire and the moon — the three things an archer aims at most.
const SHADOW_W: float = 3.2
const WHITE := Color(1.0, 1.0, 1.0, 0.92)
const SHADOW := Color(0.0, 0.0, 0.0, 0.45)


func _ready() -> void:
	name = "Crosshair"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	get_viewport().size_changed.connect(_on_viewport_resized)
	_on_viewport_resized()


func _on_viewport_resized() -> void:
	# Take the viewport rect by hand. Anchoring a Control straight under a
	# CanvasLayer left `size` at (0, 0) here, and a sight drawn at half of
	# nothing lands in the top-left corner of the screen — which is exactly
	# where it was, 14 white pixels from the edge, until this was measured.
	size = get_viewport_rect().size
	queue_redraw()


func _draw() -> void:
	var vp: Vector2 = get_viewport_rect().size
	var c: Vector2 = vp * 0.5
	var s: float = maxf(vp.y, 1.0) / REF_HEIGHT
	# Below ~720p the ring would round down into mush; keep a floor.
	var scale_f: float = maxf(s, 0.6)
	var r: float = RADIUS * scale_f
	var tick: float = TICK_LEN * scale_f
	var gap: float = TICK_GAP * scale_f

	# Two passes: the dark outline first, the white sight over it.
	for pass_idx in 2:
		var col: Color = SHADOW if pass_idx == 0 else WHITE
		var w: float = (SHADOW_W if pass_idx == 0 else LINE_W) * scale_f
		draw_arc(c, r, 0.0, TAU, 48, col, w, true)
		# Four ticks reaching in from the ring, stopping short of the middle
		# so the target itself is never covered.
		for dir in [Vector2.RIGHT, Vector2.LEFT, Vector2.UP, Vector2.DOWN]:
			draw_line(c + dir * gap, c + dir * (gap + tick), col, w, true)
