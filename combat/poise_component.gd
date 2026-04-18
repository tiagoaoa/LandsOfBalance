extends Node

## Poise / stagger — a second "health pool" that accumulates from hits
## independently of HP, triggering a stagger animation/state when it
## depletes. After `max_consecutive_staggers` staggers inside
## `stagger_window`, the owner goes Unstoppable for `unstoppable_duration`
## seconds (incoming poise damage is ignored) so the player can't chain-lock
## a tough enemy forever.
##
## Pattern adapted from bright-souls' StaggerBehaviour.cs (MIT-unlicensed
## reference; reimplemented from scratch in GDScript).

signal staggered()
signal unstoppable_started()
signal unstoppable_ended()

@export var max_poise: float = 100.0
@export var recover_delay: float = 3.0
@export var recover_rate: float = 15.0  # poise/sec once recovery begins
@export var stagger_window: float = 3.0  # grouping window for consecutive staggers
@export var max_consecutive_staggers: int = 3
@export var unstoppable_duration: float = 2.0

var current_poise: float = 100.0
var _since_last_hit: float = 0.0
var _stagger_count: int = 0
var _last_stagger_at_ms: int = -99999
var _unstoppable_timer: float = 0.0


func _ready() -> void:
	current_poise = max_poise


func _process(delta: float) -> void:
	if _unstoppable_timer > 0.0:
		_unstoppable_timer -= delta
		if _unstoppable_timer <= 0.0:
			unstoppable_ended.emit()
	_since_last_hit += delta
	if _since_last_hit >= recover_delay and current_poise < max_poise:
		current_poise = minf(max_poise, current_poise + recover_rate * delta)


func is_unstoppable() -> bool:
	return _unstoppable_timer > 0.0


## Apply poise damage. Returns true if the owner just got staggered on this
## call, so callers can trigger an animation/state change.
func take_poise_damage(amount: float) -> bool:
	if amount <= 0.0:
		return false
	if is_unstoppable():
		return false
	_since_last_hit = 0.0
	current_poise -= amount
	if current_poise > 0.0:
		return false
	# Drained — stagger.
	current_poise = max_poise
	var now_ms: int = Time.get_ticks_msec()
	if now_ms - _last_stagger_at_ms <= int(stagger_window * 1000.0):
		_stagger_count += 1
	else:
		_stagger_count = 1
	_last_stagger_at_ms = now_ms
	staggered.emit()
	if _stagger_count >= max_consecutive_staggers:
		_stagger_count = 0
		_unstoppable_timer = unstoppable_duration
		unstoppable_started.emit()
	return true
