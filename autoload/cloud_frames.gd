extends Node
## CloudFrames — the X-less half of the cloud streaming bridge (see Cloud/).
##
## When LOB_CLOUD_FRAMES_PORT is set, every rendered frame is read back from
## the GPU (async, ~1 frame behind) and pushed to the gateway over loopback
## TCP as raw RGBA, where ffmpeg turns it into the WebRTC video stream. This
## replaces x11grab: the game needs a Wayland socket to render (weston
## headless), but no X server and no screen capture. Inert without the env.
##
## Wire format: one 16-byte header on connect —
##   "LOBF"  width u32  height u32  fourcc u32 ("RGBA" or "RGB8", LE)
## — then raw frames, width*height*bpp bytes each, no framing. Frame
## boundaries are implicit, so a frame is only started once the previous one
## has been written completely; when the socket cannot keep up, whole frames
## are dropped, never split.

var _port := 0
var _peer: StreamPeerTCP
var _frame := PackedByteArray()  #frame currently being written
var _off := 0                    #bytes of _frame already written
var _next := PackedByteArray()   #latest completed readback, waiting its turn
var _pending := 0                #readbacks in flight on the GPU
var _size := Vector2i.ZERO
var _bpp := 0                    #bytes per pixel, discovered from the first readback
var _sent_header := false
var _retry := 0.0
var _dropped := 0
var _shipped := 0
var _async_tries := 0   #frames spent waiting for the first async callback
var _use_sync := false  #fallback: async readback proved barren, use get_image()
var rd: RenderingDevice


func _ready() -> void:
	var port_s := OS.get_environment("LOB_CLOUD_FRAMES_PORT")
	if port_s.is_empty() or not port_s.is_valid_int():
		set_process(false)
		return
	_port = int(port_s)
	rd = RenderingServer.get_rendering_device()
	if rd == null:
		push_error("CloudFrames: no RenderingDevice (dummy renderer?)")
		set_process(false)
		return
	process_mode = Node.PROCESS_MODE_ALWAYS
	# stderr: stdout is block-buffered without a tty and vanishes on SIGTERM.
	printerr("CloudFrames: streaming frames to 127.0.0.1:%d" % _port)


func _process(delta: float) -> void:
	if not _connected(delta):
		return
	if _use_sync:
		_sync_readback()
	else:
		_request_readback()
		# Async readback silently yields nothing on some driver/WSI combos;
		# after a second of that, take the blocking copy instead. ~8 ms per
		# frame, but 8 ms that demonstrably produces pixels.
		if _bpp == 0:
			_async_tries += 1
			if _async_tries > 60:
				_use_sync = true
				printerr("CloudFrames: async readback yields nothing, falling back to sync get_image()")
	_pump()


func _sync_readback() -> void:
	if not _next.is_empty():
		return   #writer still busy; skip this frame
	var img := get_viewport().get_texture().get_image()
	if img == null:
		return
	if img.get_format() != Image.FORMAT_RGB8:
		img.convert(Image.FORMAT_RGB8)
	_size = Vector2i(img.get_width(), img.get_height())
	if _bpp == 0:
		_bpp = 3
		printerr("CloudFrames: sync frames %dx%d, 3 bytes/px" % [_size.x, _size.y])
	_next = img.get_data()


func _connected(delta: float) -> bool:
	if _peer != null:
		_peer.poll()
		var st := _peer.get_status()
		if st == StreamPeerTCP.STATUS_CONNECTED:
			return true
		if st == StreamPeerTCP.STATUS_CONNECTING:
			return false
		_peer = null   #error / closed: retry below
		_sent_header = false
	_retry -= delta
	if _retry > 0.0:
		return false
	_retry = 2.0
	_peer = StreamPeerTCP.new()
	if _peer.connect_to_host("127.0.0.1", _port) != OK:
		_peer = null
	else:
		_peer.set_no_delay(true)
	return false


func _request_readback() -> void:
	if _pending >= 2:
		return
	var vp := get_viewport()
	var rd_tex := RenderingServer.texture_get_rd_texture(vp.get_texture().get_rid())
	if not rd_tex.is_valid():
		if _async_tries == 30:
			printerr("CloudFrames: viewport has no RD texture handle")
		return
	var size := vp.get_texture().get_size()
	_pending += 1
	rd.texture_get_data_async(rd_tex, 0, func(data: PackedByteArray) -> void:
		_pending -= 1
		if data.size() != size.x * size.y * 4:
			return   #format surprise; skip rather than corrupt the stream
		_size = size
		if _next.is_empty():
			_next = data
		else:
			_dropped += 1   #writer is behind; newest frame wins
			_next = data)


## Push bytes out without ever blocking the frame loop: finish the frame in
## flight first, then promote the freshest readback.
func _pump() -> void:
	if not _sent_header:
		if _size == Vector2i.ZERO:
			return
		var h := PackedByteArray()
		h.resize(16)
		h[0] = 0x4C; h[1] = 0x4F; h[2] = 0x42; h[3] = 0x46  # "LOBF"
		h.encode_u32(4, _size.x)
		h.encode_u32(8, _size.y)
		var fourcc := "RGBA" if _bpp == 4 else "RGB8"
		for i in range(4):
			h[12 + i] = fourcc.unicode_at(i)
		if _peer.put_data(h) != OK:
			return
		_sent_header = true
		printerr("CloudFrames: header sent (%s)" % fourcc)
	for _i in range(4):   #a few chunks per tick; put_partial_data caps each one
		if _frame.is_empty():
			if _next.is_empty():
				return
			if _next.size() != _size.x * _size.y * _bpp:
				_next = PackedByteArray()
				return
			_frame = _next
			_next = PackedByteArray()
			_off = 0
		var res := _peer.put_partial_data(_frame.slice(_off))
		if res[0] != OK:
			_peer.disconnect_from_host()
			_peer = null
			_sent_header = false
			_frame = PackedByteArray()
			return
		_off += res[1]
		if _off >= _frame.size():
			_frame = PackedByteArray()
			_shipped += 1
		elif res[1] == 0:
			return   #socket full; try again next tick
