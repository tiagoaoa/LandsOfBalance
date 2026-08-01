extends Node

## Mobile playtest black box. Active on Android/iOS (or with
## --debug-record on desktop): records the MICROPHONE continuously in
## 60-second WAV chunks and writes a per-second telemetry heartbeat, so a
## hands-on tester can simply SAY "note: X happened now" — the spoken
## note, the heartbeat and the engine log all share one timeline.
##
## Output, under user://debug/session_<unixtime>/:
##   session_log.txt   — header + 1 Hz heartbeat:
##                       T+<elapsed> | fps, player pos/hp/stamina/flags,
##                       companion, bobba, fires, skeletons, memory
##   mic_T+<offset>s.wav — consecutive mic chunks; the filename offset is
##                       the session-elapsed second the chunk STARTED, so
##                       transcript times map directly onto the log.
## Engine prints go to user://logs/godot.log (file logging enabled) and
## logcat as usual.
##
## Retrieval from a debug APK:
##   adb shell run-as com.tpgame.douglassthekeeper sh -c \
##       'cd files; tar cf - debug' > session.tar

const CHUNK_SECONDS := 60.0
const HEARTBEAT_SECONDS := 1.0

var _active := false
var _session_dir := ""
var _log: FileAccess = null
var _record_bus_idx := -1
var _record_effect: AudioEffectRecord = null
var _mic_player: AudioStreamPlayer = null
var _elapsed := 0.0
var _chunk_started := 0.0
var _heartbeat_timer := 0.0
var _mic_ok := false


var _diag_prev: String = ""


func _ready() -> void:
	var mobile := OS.get_name() in ["Android", "iOS"]
	var forced := "--debug-record" in OS.get_cmdline_user_args() \
			or "--debug-record" in OS.get_cmdline_args()
	if not mobile and not forced:
		return
	_active = true
	Input.joy_connection_changed.connect(func(dev: int, connected: bool) -> void:
		print("INPUTDIAG pad %d %s: %s" % [dev,
				"connected" if connected else "disconnected",
				Input.get_joy_name(dev) if connected else ""])
		_log_line("INPUTDIAG pad %d %s %s" % [dev,
				"connected" if connected else "disconnected",
				Input.get_joy_name(dev) if connected else ""]))
	if OS.get_name() == "Android":
		OS.request_permissions()  # RECORD_AUDIO prompt on first run
	var stamp := Time.get_datetime_string_from_system().replace(":", "-")
	_session_dir = "user://debug/session_%d" % Time.get_unix_time_from_system()
	DirAccess.make_dir_recursive_absolute(_session_dir)
	_log = FileAccess.open(_session_dir + "/session_log.txt", FileAccess.WRITE)
	_log_line("=== Lands of Balance playtest session ===")
	_log_line("wallclock_start=%s unix=%d os=%s model=%s" % [
			stamp, Time.get_unix_time_from_system(), OS.get_name(), OS.get_model_name()])
	_log_line("Note protocol: say 'note: ...' aloud; mic chunks are named by session-elapsed offset.")
	_setup_mic()
	print("DebugRecorder: session at %s (mic=%s)" % [_session_dir, str(_mic_ok)])


func _setup_mic() -> void:
	# A dedicated muted bus carries the microphone into an AudioEffectRecord.
	_record_bus_idx = AudioServer.bus_count
	AudioServer.add_bus(_record_bus_idx)
	AudioServer.set_bus_name(_record_bus_idx, "DebugMicRecord")
	AudioServer.set_bus_mute(_record_bus_idx, true)  # never play back the mic
	_record_effect = AudioEffectRecord.new()
	AudioServer.add_bus_effect(_record_bus_idx, _record_effect)
	_mic_player = AudioStreamPlayer.new()
	_mic_player.stream = AudioStreamMicrophone.new()
	_mic_player.bus = &"DebugMicRecord"
	add_child(_mic_player)
	_mic_player.play()
	_record_effect.set_recording_active(true)
	_chunk_started = 0.0
	_mic_ok = true


func _process(delta: float) -> void:
	if not _active:
		return
	_elapsed += delta

	# Rotate mic chunks so a crash never loses more than a minute.
	if _mic_ok and _elapsed - _chunk_started >= CHUNK_SECONDS:
		_flush_mic_chunk()

	_heartbeat_timer += delta
	if _heartbeat_timer >= HEARTBEAT_SECONDS:
		_heartbeat_timer = 0.0
		_write_heartbeat()

	_input_diag()


## Raw controller truth, logged ONLY when something changes: every axis
## above noise, every button down, and the resulting state of the guard
## action. This is what tells us whether a released trigger actually
## reports its release — a stuck action state and a stuck axis value are
## different bugs with different fixes.
func _input_diag() -> void:
	var parts := PackedStringArray()
	for dev in Input.get_connected_joypads():
		var axes := PackedStringArray()
		for a in range(10):
			var v: float = Input.get_joy_axis(dev, a)
			if absf(v) > 0.08:
				axes.append("ax%d=%.2f" % [a, v])
		var buttons := PackedStringArray()
		for b in range(20):
			if Input.is_joy_button_pressed(dev, b):
				buttons.append("b%d" % b)
		parts.append("pad%d[%s][%s]" % [dev, ",".join(axes), ",".join(buttons)])
	parts.append("block=%s(%.2f)" % [str(Input.is_action_pressed(&"block")),
			Input.get_action_strength(&"block")])
	var line: String = " ".join(parts)
	if line == _diag_prev:
		return
	_diag_prev = line
	print("INPUTDIAG ", line)
	_log_line("INPUTDIAG " + line)


func _flush_mic_chunk() -> void:
	if _record_effect == null or not _record_effect.is_recording_active():
		return
	_record_effect.set_recording_active(false)
	var rec: AudioStreamWAV = _record_effect.get_recording()
	if rec != null:
		var path := "%s/mic_T+%04ds.wav" % [_session_dir, int(_chunk_started)]
		rec.save_to_wav(path)
		_log_line("mic chunk saved: %s (%.1fs)" % [path.get_file(), _elapsed - _chunk_started])
	_chunk_started = _elapsed
	_record_effect.set_recording_active(true)


func _write_heartbeat() -> void:
	var tree := get_tree()
	if tree == null:
		return
	var parts := PackedStringArray()
	parts.append("fps=%d" % Engine.get_frames_per_second())
	var player := tree.get_first_node_in_group("player")
	if player and is_instance_valid(player):
		var flags := PackedStringArray()
		for f in ["is_attacking", "is_rolling", "is_blocking", "is_drawing_bow",
				"is_holding_bow", "is_crouching", "is_reviving", "is_dead", "is_casting"]:
			if f in player and player.get(f):
				flags.append(f.trim_prefix("is_"))
		parts.append("player=%s hp=%.0f flags[%s]" % [
				str((player as Node3D).global_position.snapped(Vector3.ONE)),
				float(player.current_health), ",".join(flags)])
	var comp := tree.get_first_node_in_group("companion")
	if comp and is_instance_valid(comp):
		parts.append("ally_hp=%.0f%s" % [float(comp.current_health),
				" DEAD" if ("is_dead" in comp and comp.is_dead) else ""])
	var bobba := tree.get_first_node_in_group("bobba")
	if bobba and is_instance_valid(bobba):
		var tname := "none"
		if "target" in bobba and bobba.target != null and is_instance_valid(bobba.target):
			tname = str(bobba.target.name)
		parts.append("bobba_hp=%.0f state=%d target=%s dist=%.0f" % [
				float(bobba.health), int(bobba.state), tname,
				(bobba as Node3D).global_position.distance_to(
						(player as Node3D).global_position) if player else -1.0])
	parts.append("fires=%d skel=%d" % [
			tree.get_nodes_in_group("ground_fire").size(),
			tree.get_nodes_in_group("skeletons").size()])
	parts.append("mem=%.0fMB" % (float(OS.get_static_memory_usage()) / 1048576.0))
	_log_line(" | ".join(parts))


func _log_line(text: String) -> void:
	if _log == null:
		return
	_log.store_line("T+%07.2f  %s" % [_elapsed, text])
	_log.flush()


## Final flush on quit/background (mobile lifecycle).
func _notification(what: int) -> void:
	if not _active:
		return
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_APPLICATION_PAUSED \
			or what == NOTIFICATION_EXIT_TREE:
		_log_line("session ending (notification %d)" % what)
		if _mic_ok:
			_flush_mic_chunk()
