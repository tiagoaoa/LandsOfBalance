class_name HitFeedback
extends RefCounted
## Shared impact effects — the discrete channels that say "that landed".
##
## Modelled on how Feel/MMFeedbacks structures juice: one effect per channel,
## each independently tunable, played together off a single event. Ours were
## scattered across the player and Bobba with their own ad-hoc constants; the
## ones that are pure geometry or hardware live here now so both actors get
## the same behaviour and there is one place to tune it.
##
## Per-actor STRENGTHS stay with the actor — Bobba is a three-metre orc and
## should not recoil like the Paladin — but the mechanics are shared.

## Squash-and-stretch. Volume-preserving: whatever an axis loses the other two
## gain, which is what makes a body read as having mass rather than simply
## being scaled down. This is the channel our hit feedback was missing
## entirely — the lurch translated the model, nothing deformed it.
const SQUASH_AMOUNT: float = 0.13
const SQUASH_IN: float = 0.05      # collapse fast on contact
const SQUASH_OUT: float = 0.26     # spring back slower


## Squash `target.<property>` and spring it back to `rest_scale`.
##
## Tweens a named property rather than a node's scale directly, because the
## player's crouch already writes `_character_model.scale.y` every physics
## frame — a tween on the same value would be overwritten mid-flight. There
## the squash rides its own factor which the crouch composes with.
##
## Returns the tween so a caller can cancel it if another hit lands first.
static func squash(target: Object, rest_scale: Vector3,
		amount: float = SQUASH_AMOUNT, vertical: bool = true,
		property: String = "scale") -> Tween:
	var model := target as Node
	if model == null or not model.is_inside_tree():
		return null
	var a: float = clampf(amount, 0.0, 0.6)
	# Compress vertically and bulge horizontally (a body absorbing a blow), or
	# the reverse for a stretch on a launch.
	var hit_scale: Vector3
	if vertical:
		hit_scale = Vector3(1.0 + a * 0.6, 1.0 - a, 1.0 + a * 0.6)
	else:
		hit_scale = Vector3(1.0 - a * 0.6, 1.0 + a, 1.0 - a * 0.6)
	var tw: Tween = model.create_tween()
	tw.tween_property(target, property, rest_scale * hit_scale, SQUASH_IN) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	# ELASTIC on the way back gives the overshoot-and-settle that sells weight.
	tw.tween_property(target, property, rest_scale, SQUASH_OUT) \
		.set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	return tw


## Controller rumble and phone vibration.
##
## We ship on Android and had no haptics at all, which on a small screen is
## the channel that most directly answers "did that connect" — the flash and
## the smear are easy to miss under a thumb.
##
## `weight` 0..1 scales both the amplitude and the duration, so a light jab
## and a finisher feel different rather than identical.
static func haptic(weight: float = 0.5) -> void:
	var w: float = clampf(weight, 0.0, 1.0)
	var ms: int = int(lerpf(40.0, 130.0, w))
	# Handheld: Godot exposes only a duration, so weight rides on length.
	if OS.get_name() in ["Android", "iOS"]:
		Input.vibrate_handheld(ms)
	# Gamepad: the low-frequency motor carries impact better than the high.
	for device in Input.get_connected_joypads():
		Input.start_joy_vibration(device, lerpf(0.25, 0.9, w),
				lerpf(0.15, 0.55, w), ms / 1000.0)


## True when this actor is the local human — the only one whose hits should
## reach the player's hands. An AI companion or a remote peer taking a hit
## must never buzz the controller.
static func is_local_human(actor: Node) -> bool:
	if actor == null:
		return false
	if "is_ai_companion" in actor and actor.is_ai_companion:
		return false
	if "_is_network_controlled" in actor and actor._is_network_controlled:
		return false
	return true
