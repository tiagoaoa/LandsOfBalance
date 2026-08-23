extends Node
## CloudInput — the game side of the cloud streaming bridge (see Cloud/).
##
## When LOB_CLOUD_INPUT_PORT is set the gateway runs this game on a server and
## a browser plays it over WebRTC. Keyboard, mouse and gamepad events arrive
## here as small binary frames over a loopback TCP socket and are fed to the
## engine with Input.parse_input_event(), i.e. they take exactly the path a
## real X11 event would (InputMap, Control focus, mouse capture, the lot).
## The only thing that goes back is the mouse mode, so the browser knows when
## to lock the pointer. Without the env var this node is inert.
##
## Frame layout (little-endian, first byte is the type) — keep in sync with
## Cloud/internal/proto/proto.go and Cloud/web/protocol.js:
##   0x01 KEY          pressed u8, keycode u32, physical u32, unicode u32, mods u8, echo u8, location u8
##   0x02 MOUSE_MOVE   x f32, y f32, dx f32, dy f32, buttons u8
##   0x03 MOUSE_BUTTON pressed u8, button u8, x f32, y f32, factor f32, mods u8, double u8
##   0x04 JOY_BUTTON   device u8, button u8, pressed u8, pressure f32
##   0x05 JOY_AXIS     device u8, axis u8, value f32
##   0x06 JOY_CONNECT  device u8, connected u8, name_len u8, name[name_len]
##   0x07 RELEASE_ALL
##   0x08 PING         seq u32
##   0x80 MOUSE_MODE   mode u8            (game → browser)
##   0x81 PONG         seq u32            (game → browser)
##   0x82 HELLO        version u8         (game → browser)

const FRAME_KEY := 0x01
const FRAME_MOUSE_MOVE := 0x02
const FRAME_MOUSE_BUTTON := 0x03
const FRAME_JOY_BUTTON := 0x04
const FRAME_JOY_AXIS := 0x05
const FRAME_JOY_CONNECT := 0x06
const FRAME_RELEASE_ALL := 0x07
const FRAME_PING := 0x08
const FRAME_MOUSE_MODE := 0x80
const FRAME_PONG := 0x81
const FRAME_HELLO := 0x82
const PROTO_VERSION := 1

const FIXED_LEN := {
	FRAME_KEY: 17, FRAME_MOUSE_MOVE: 18, FRAME_MOUSE_BUTTON: 17,
	FRAME_JOY_BUTTON: 8, FRAME_JOY_AXIS: 7, FRAME_RELEASE_ALL: 1, FRAME_PING: 5,
}

var _server: TCPServer
var _peer: StreamPeerTCP
var _buf := PackedByteArray()
var _mouse_pos := Vector2.ZERO
var _button_mask := 0
var _keys_down := {}        # keycode -> physical keycode
var _joy_down := {}         # "device:button" -> true
var _joy_axes := {}         # "device:axis" -> true (non-zero)
var _last_mouse_mode := -1
var _mode_hint := -1   #what the game ASKED for, honored or not (see set_mouse_mode)
var _frames := 0


## Game code routes mouse-mode changes through here instead of calling
## Input.set_mouse_mode directly. On a headless display server (weston: no
## input devices, no focus) the capture silently fails and
## Input.get_mouse_mode() keeps answering VISIBLE — but the cloud client
## needs the INTENT: it holds the real pointer, and it locks it when the
## game wants it captured. Off-cloud this is a plain passthrough.
func set_mouse_mode(mode: Input.MouseMode) -> void:
	_mode_hint = mode
	Input.set_mouse_mode(mode)


## The read-side twin: game code asking "is the mouse captured?" must get
## the INTENT too — on a headless display server the engine answers VISIBLE
## forever, which silently vetoes mouse-look, attack gating, everything
## conditioned on capture.
func get_mouse_mode() -> Input.MouseMode:
	if _mode_hint != -1:
		return _mode_hint as Input.MouseMode
	return Input.get_mouse_mode()


func _ready() -> void:
	var port_s := OS.get_environment("LOB_CLOUD_INPUT_PORT")
	if port_s.is_empty() or not port_s.is_valid_int():
		set_process(false)
		return
	var port := int(port_s)
	_server = TCPServer.new()
	var err := _server.listen(port, "127.0.0.1")
	if err != OK:
		push_error("CloudInput: cannot listen on 127.0.0.1:%d (%s)" % [port, error_string(err)])
		set_process(false)
		return
	# Keep feeding input while the tree is paused (menus) and make sure the
	# engine never sleeps the process loop — the stream must stay live.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_mouse_pos = get_viewport().get_visible_rect().size * 0.5
	print("CloudInput: listening on 127.0.0.1:%d" % port)


func _process(_delta: float) -> void:
	if _server.is_connection_available():
		var p := _server.take_connection()
		if _peer != null:
			_peer.disconnect_from_host()
		_peer = p
		_peer.set_no_delay(true)
		_buf.clear()
		_last_mouse_mode = -1
		_send(PackedByteArray([FRAME_HELLO, PROTO_VERSION]))
		print("CloudInput: gateway connected")
	if _peer == null:
		return
	_peer.poll()
	var st := _peer.get_status()
	if st != StreamPeerTCP.STATUS_CONNECTED:
		if st == StreamPeerTCP.STATUS_ERROR or st == StreamPeerTCP.STATUS_NONE:
			print("CloudInput: gateway gone")
			_peer = null
			_release_all()
		return
	var avail := _peer.get_available_bytes()
	if avail > 0:
		var res := _peer.get_partial_data(avail)
		if res[0] == OK:
			_buf.append_array(res[1])
			_drain()
	var mm := _mode_hint if _mode_hint != -1 else Input.get_mouse_mode()
	if mm != _last_mouse_mode:
		_last_mouse_mode = mm
		printerr("CloudInput: mouse mode -> %d" % mm)
		_send(PackedByteArray([FRAME_MOUSE_MODE, mm]))


func _send(bytes: PackedByteArray) -> void:
	if _peer != null and _peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		_peer.put_data(bytes)


# Pull whole frames off the buffer; keep the tail for the next read.
func _drain() -> void:
	var off := 0
	var n := _buf.size()
	while off < n:
		var t := _buf[off]
		var flen: int = FIXED_LEN.get(t, 0)
		if t == FRAME_JOY_CONNECT:
			if off + 4 > n:
				break
			flen = 4 + _buf[off + 3]
		if flen == 0:
			push_warning("CloudInput: unknown frame 0x%02x, resyncing" % t)
			_buf.clear()
			return
		if off + flen > n:
			break
		_handle(t, off)
		off += flen
		_frames += 1
	if off > 0:
		_buf = _buf.slice(off)


func _mods(ev: InputEventWithModifiers, mods: int) -> void:
	ev.shift_pressed = (mods & 1) != 0
	ev.ctrl_pressed = (mods & 2) != 0
	ev.alt_pressed = (mods & 4) != 0
	ev.meta_pressed = (mods & 8) != 0


func _handle(t: int, o: int) -> void:
	match t:
		FRAME_KEY:
			var ev := InputEventKey.new()
			ev.pressed = _buf[o + 1] != 0
			ev.keycode = _buf.decode_u32(o + 2) as Key
			ev.physical_keycode = _buf.decode_u32(o + 6) as Key
			ev.unicode = _buf.decode_u32(o + 10)
			_mods(ev, _buf[o + 14])
			ev.echo = _buf[o + 15] != 0
			ev.location = _buf[o + 16] as KeyLocation
			ev.key_label = ev.keycode
			if ev.pressed:
				_keys_down[ev.keycode] = ev.physical_keycode
			else:
				_keys_down.erase(ev.keycode)
			Input.parse_input_event(ev)
		FRAME_MOUSE_MOVE:
			var x := _buf.decode_float(o + 1)
			var y := _buf.decode_float(o + 5)
			var dx := _buf.decode_float(o + 9)
			var dy := _buf.decode_float(o + 13)
			_button_mask = _buf[o + 17]
			var ev := InputEventMouseMotion.new()
			if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
				# Captured: the real pointer sits at the centre and only
				# the delta means anything, mirror what X11 would report.
				_mouse_pos = get_viewport().get_visible_rect().size * 0.5
			else:
				_mouse_pos = Vector2(x, y)
			ev.position = _mouse_pos
			ev.global_position = _mouse_pos
			ev.relative = Vector2(dx, dy)
			ev.screen_relative = ev.relative
			ev.button_mask = _button_mask as MouseButtonMask
			Input.parse_input_event(ev)
		FRAME_MOUSE_BUTTON:
			printerr("CloudInput: btn %d %s at (%.0f, %.0f)" % [_buf[o + 2],
					"down" if _buf[o + 1] != 0 else "up",
					_buf.decode_float(o + 3), _buf.decode_float(o + 7)])
			var pressed := _buf[o + 1] != 0
			var button := _buf[o + 2] as MouseButton
			_mouse_pos = Vector2(_buf.decode_float(o + 3), _buf.decode_float(o + 7))
			var factor := _buf.decode_float(o + 11)
			var mods := _buf[o + 15]
			var dbl := _buf[o + 16] != 0
			var wheel := button >= MOUSE_BUTTON_WHEEL_UP and button <= MOUSE_BUTTON_WHEEL_RIGHT
			if not wheel:
				var bit := 1 << (button - 1)
				_button_mask = (_button_mask | bit) if pressed else (_button_mask & ~bit)
			_mouse_button(button, pressed, factor, mods, dbl)
			if wheel and pressed:
				# X11 delivers wheel as press+release; the browser only sends the press.
				_mouse_button(button, false, factor, mods, false)
		FRAME_JOY_BUTTON:
			var ev := InputEventJoypadButton.new()
			ev.device = _buf[o + 1]
			ev.button_index = _buf[o + 2] as JoyButton
			ev.pressed = _buf[o + 3] != 0
			ev.pressure = _buf.decode_float(o + 4)
			var k := "%d:%d" % [ev.device, ev.button_index]
			if ev.pressed:
				_joy_down[k] = true
			else:
				_joy_down.erase(k)
			Input.parse_input_event(ev)
		FRAME_JOY_AXIS:
			var ev := InputEventJoypadMotion.new()
			ev.device = _buf[o + 1]
			ev.axis = _buf[o + 2] as JoyAxis
			ev.axis_value = clampf(_buf.decode_float(o + 3), -1.0, 1.0)
			var k := "%d:%d" % [ev.device, ev.axis]
			if absf(ev.axis_value) > 0.0001:
				_joy_axes[k] = true
			else:
				_joy_axes.erase(k)
			Input.parse_input_event(ev)
		FRAME_JOY_CONNECT:
			var device := _buf[o + 1]
			var connected := _buf[o + 2] != 0
			var name_len := _buf[o + 3]
			var pad_name := _buf.slice(o + 4, o + 4 + name_len).get_string_from_utf8()
			# Only the signal is scriptable; the events themselves never needed
			# a registered device. Listeners (HUD, rumble) still get told.
			Input.joy_connection_changed.emit(device, connected)
			print("CloudInput: joypad %d %s (%s)" % [device, "connected" if connected else "disconnected", pad_name])
		FRAME_RELEASE_ALL:
			_release_all()
		FRAME_PING:
			var out := PackedByteArray([FRAME_PONG, 0, 0, 0, 0])
			out.encode_u32(1, _buf.decode_u32(o + 1))
			_send(out)
			_last_mouse_mode = -1  # re-announce on next frame


func _mouse_button(button: MouseButton, pressed: bool, factor: float, mods: int, dbl: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = button
	ev.pressed = pressed
	ev.position = _mouse_pos
	ev.global_position = _mouse_pos
	ev.factor = factor if factor > 0.0 else 1.0
	ev.double_click = dbl
	ev.button_mask = _button_mask as MouseButtonMask
	_mods(ev, mods)
	Input.parse_input_event(ev)


# Let go of everything: the browser lost focus, the player disconnected, or
# the socket died. A stuck W key on a headless server is not a fun bug.
func _release_all() -> void:
	for keycode in _keys_down.keys():
		var ev := InputEventKey.new()
		ev.keycode = keycode
		ev.physical_keycode = _keys_down[keycode]
		ev.key_label = keycode
		ev.pressed = false
		Input.parse_input_event(ev)
	_keys_down.clear()
	for b in range(1, 4):
		if _button_mask & (1 << (b - 1)):
			_mouse_button(b as MouseButton, false, 1.0, 0, false)
	_button_mask = 0
	for k in _joy_down.keys():
		var parts: PackedStringArray = k.split(":")
		var ev := InputEventJoypadButton.new()
		ev.device = int(parts[0])
		ev.button_index = int(parts[1]) as JoyButton
		ev.pressed = false
		Input.parse_input_event(ev)
	_joy_down.clear()
	for k in _joy_axes.keys():
		var parts: PackedStringArray = k.split(":")
		var ev := InputEventJoypadMotion.new()
		ev.device = int(parts[0])
		ev.axis = int(parts[1]) as JoyAxis
		ev.axis_value = 0.0
		Input.parse_input_event(ev)
	_joy_axes.clear()
