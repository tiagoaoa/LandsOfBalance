extends Node

## Stamina pool with recover-delay + block regen modifier.
##
## Attacks call `try_spend(cost)` — returns false if there isn't enough
## stamina to fire. Every spend resets `_recover_timer` to `recover_delay`,
## so repeated spending stops regen entirely. While `blocking == true`,
## regen is multiplied by `block_regen_modifier` (like the souls-like
## "holding up shield cuts regen in half").
##
## Pattern adapted from bright-souls' StaminaBehaviour.cs.

signal stamina_changed(current: float, maximum: float)
signal exhausted()  # fired when try_spend fails

@export var max_stamina: float = 100.0
@export var recover_rate: float = 30.0  # stamina/sec while free-regen
@export var recover_delay: float = 0.6
@export var block_regen_modifier: float = 0.35

var current_stamina: float = 100.0
var blocking: bool = false
var _recover_timer: float = 0.0


func _ready() -> void:
	current_stamina = max_stamina


func _process(delta: float) -> void:
	if _recover_timer > 0.0:
		_recover_timer = maxf(0.0, _recover_timer - delta)
		return
	if current_stamina >= max_stamina:
		return
	var mod: float = block_regen_modifier if blocking else 1.0
	current_stamina = minf(max_stamina, current_stamina + recover_rate * mod * delta)
	stamina_changed.emit(current_stamina, max_stamina)


func try_spend(cost: float) -> bool:
	if cost <= 0.0:
		return true
	if current_stamina < cost:
		exhausted.emit()
		return false
	current_stamina -= cost
	_recover_timer = recover_delay
	stamina_changed.emit(current_stamina, max_stamina)
	return true


func ratio() -> float:
	return current_stamina / max_stamina if max_stamina > 0.0 else 0.0
