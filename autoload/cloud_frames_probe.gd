extends Node
## Feasibility probe for X-less cloud streaming: how fast can frames leave
## the engine? Inert unless LOB_FRAME_PROBE is set.
##
##   LOB_FRAME_PROBE=sync   — Viewport.get_texture().get_image() every frame
##                            (blocking GPU->CPU copy, the naive path)
##   LOB_FRAME_PROBE=async  — RenderingDevice.texture_get_data_async on the
##                            viewport RT (pipelined copy, 1-2 frames late)
##   LOB_FRAME_PROBE_PNG=/path.png — also save one frame as proof of pixels
##
## Samples 600 frames after a warmup, prints one FRAMEPROBE line, quits.

var frames := 0
var t_start := 0
var cost_ms := 0.0     #summed per-copy cost (sync) / completion latency (async)
var copies := 0
var bytes := 0
var pending := 0
var rd: RenderingDevice


func _ready() -> void:
	if OS.get_environment("LOB_FRAME_PROBE").is_empty():
		set_process(false)
		return
	rd = RenderingServer.get_rendering_device()
	print("FRAMEPROBE armed: mode=", OS.get_environment("LOB_FRAME_PROBE"),
			" rd=", "yes" if rd != null else "NO RENDERING DEVICE")


func _process(_delta: float) -> void:
	frames += 1
	if frames < 60:
		return
	if frames == 60:
		t_start = Time.get_ticks_usec()
	var mode := OS.get_environment("LOB_FRAME_PROBE")
	if mode == "sync":
		var t0 := Time.get_ticks_usec()
		var img := get_viewport().get_texture().get_image()
		cost_ms += float(Time.get_ticks_usec() - t0) / 1000.0
		copies += 1
		bytes = img.get_data().size()
		if frames == 120:
			_save_png(img)
	elif mode == "async" and rd != null and pending < 3:
		var rd_tex := RenderingServer.texture_get_rd_texture(
				get_viewport().get_texture().get_rid())
		if rd_tex.is_valid():
			pending += 1
			var t0 := Time.get_ticks_usec()
			rd.texture_get_data_async(rd_tex, 0, func(data: PackedByteArray) -> void:
				pending -= 1
				copies += 1
				bytes = data.size()
				cost_ms += float(Time.get_ticks_usec() - t0) / 1000.0)
	if frames == 660:
		_report()


func _save_png(img: Image) -> void:
	var path := OS.get_environment("LOB_FRAME_PROBE_PNG")
	if not path.is_empty():
		img.save_png(path)
		print("FRAMEPROBE saved ", path, " ", img.get_width(), "x", img.get_height())


func _report() -> void:
	var wall := float(Time.get_ticks_usec() - t_start) / 1e6
	print("FRAMEPROBE mode=%s sampled=600 wall=%.2fs fps=%.1f copies=%d avg_cost_ms=%.2f frame_bytes=%d driver=%s" % [
			OS.get_environment("LOB_FRAME_PROBE"), wall, 600.0 / wall, copies,
			cost_ms / maxf(copies, 1), bytes,
			RenderingServer.get_current_rendering_driver_name()])
	get_tree().quit()
