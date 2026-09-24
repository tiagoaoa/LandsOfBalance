extends Node3D

var active := false
var element := "lightning"
var channel: AudioStreamPlayer3D


func start(fire: bool) -> void:
	if active:
		return
	active = true
	element = "fire" if fire else "lightning"
	Sfx.play3d("spell_%s_start" % element, global_position + Vector3.UP, -2.0)
	channel = Sfx.loop3d("spell_%s_loop" % element, self, Vector3.UP, -10.0, 38.0)


func stop() -> void:
	if not active:
		return
	active = false
	Sfx.fade_stop(channel, .35)
	channel = null
	Sfx.play3d("spell_%s_end" % element, global_position + Vector3.UP, -5.0)
