extends Node

const BANK = preload("res://assets/audio/designed/bank.gd").FILES
const POOL_SIZE := 32

var _streams: Dictionary = {}
var _last: Dictionary = {}
var _pool: Array[AudioStreamPlayer3D] = []
var muted := false


func _ready() -> void:
	for i in range(POOL_SIZE):
		var p := AudioStreamPlayer3D.new()
		p.name = "OneShot%d" % i
		_configure(p, "hit_flesh", 60.0)
		add_child(p)
		_pool.append(p)


func _bus(event: String) -> StringName:
	if event.begins_with("spell_") or event == "fire_ignite":
		return &"Magic"
	if event.ends_with("_loop"):
		return &"Ambience"
	if event.begins_with("step_") or event in ["armor_step", "roll", "jump", "land", "estus_drink", "coin", "bow_draw"]:
		return &"Foley"
	return &"Combat"


func _priority(event: String) -> int:
	if event in ["parry_ring", "death_thud", "dragon_roar", "bobba_roar"]:
		return 3
	if event.begins_with("hit_") or event.begins_with("spell_") or event == "block_chip":
		return 2
	return 1


func _configure(p: AudioStreamPlayer3D, event: String, distance: float) -> void:
	p.bus = _bus(event)
	p.max_distance = distance
	p.unit_size = 5.0 if p.bus == &"Combat" else 4.0
	p.max_db = 0.0
	p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	p.attenuation_filter_cutoff_hz = 14000.0
	p.attenuation_filter_db = -12.0


func _get_stream(event: String, looped: bool = false) -> AudioStream:
	if not BANK.has(event):
		push_warning("Sfx: unknown event '%s'" % event)
		return null
	var files: Array = BANK[event]
	var index := randi_range(0, files.size() - 1)
	if files.size() > 1 and index == _last.get(event, -1):
		index = (index + randi_range(1, files.size() - 1)) % files.size()
	_last[event] = index
	if not looped:
		return files[index]
	var key := "%s:%d:loop" % [event, index]
	if not _streams.has(key):
		var wav: AudioStreamWAV = files[index].duplicate()
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_begin = 0
		wav.loop_end = roundi(wav.get_length() * wav.mix_rate)
		_streams[key] = wav
	return _streams[key]


func _voice(event: String, pos: Vector3) -> AudioStreamPlayer3D:
	var idle: AudioStreamPlayer3D
	var victim: AudioStreamPlayer3D
	var count := 0
	var now := Time.get_ticks_msec()
	for p in _pool:
		if not p.playing:
			idle = p
			continue
		if p.get_meta("event", "") == event:
			count += 1
			#Attacker and defender may report the same contact in one tick.
			if now - int(p.get_meta("started")) < 35 and p.global_position.distance_to(pos) < 1.0:
				return null
		if victim == null or int(p.get_meta("priority")) < int(victim.get_meta("priority")) \
				or (p.get_meta("priority") == victim.get_meta("priority") \
					and int(p.get_meta("started")) < int(victim.get_meta("started"))):
			victim = p
	if count >= 6:
		return null
	if idle:
		return idle
	#Footsteps must not cut off a parry or death cue during a crowded fight.
	return victim if int(victim.get_meta("priority")) <= _priority(event) else null


func play3d(event: String, pos: Vector3, volume_db: float = 0.0,
		pitch_jitter: float = .04) -> void:
	if muted:
		return
	var p := _voice(event, pos)
	if p == null:
		return
	var stream := _get_stream(event)
	if stream == null:
		return
	p.stop()
	p.stream = stream
	_configure(p, event, 60.0)
	p.global_position = pos
	p.volume_db = volume_db + randf_range(-.7, .3)
	p.pitch_scale = 1.0 + randf_range(-minf(pitch_jitter, .06), minf(pitch_jitter, .06))
	p.set_meta("event", event)
	p.set_meta("priority", _priority(event))
	p.set_meta("started", Time.get_ticks_msec())
	p.play()


func loop3d(event: String, parent: Node, offset: Vector3 = Vector3.ZERO,
		volume_db: float = 0.0, max_dist: float = 30.0) -> AudioStreamPlayer3D:
	if muted:
		return null
	var p := AudioStreamPlayer3D.new()
	p.name = "Loop_" + event
	p.stream = _get_stream(event, true)
	_configure(p, event, max_dist)
	p.position = offset
	parent.add_child(p)
	p.volume_db = -60.0
	p.play(randf() * p.stream.get_length())
	var fade := p.create_tween()
	fade.tween_property(p, "volume_db", volume_db, .18)
	p.set_meta("fade", fade)
	return p


func loop2d(event: String, volume_db: float = -18.0) -> AudioStreamPlayer:
	if muted:
		return null
	var p := AudioStreamPlayer.new()
	p.name = "Bed_" + event
	p.bus = &"Ambience"
	p.stream = _get_stream(event, true)
	p.volume_db = -60.0
	add_child(p)
	p.play(randf() * p.stream.get_length())
	var fade := p.create_tween()
	fade.tween_property(p, "volume_db", volume_db, .7)
	p.set_meta("fade", fade)
	return p


func fade_stop(p: Node, seconds: float = .3) -> void:
	if not is_instance_valid(p):
		return
	if p.has_meta("fade"):
		var fade: Tween = p.get_meta("fade")
		fade.kill()
	var tw := p.create_tween()
	tw.tween_property(p, "volume_db", -60.0, seconds)
	tw.tween_callback(p.queue_free)
	p.set_meta("fade", tw)


func surface(body: Object) -> String:
	if body.has_meta("audio_surface"):
		return str(body.get_meta("audio_surface"))
	var label := String(body.name).to_lower()
	if "wood" in label or "plank" in label or "bridge" in label:
		return "wood"
	if "terrain" in label or "grass" in label or "ground" in label or "landscape" in label:
		return "grass"
	return "concrete"
