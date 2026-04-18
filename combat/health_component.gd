extends Node

## Shared health component for players and NPCs.
##
## Stores health as flat HP internally but exposes both flat and percent-based
## damage/heal APIs. Percent operations are always relative to max_hp — useful
## for the souls-like combat spells in this project (e.g. "arrows deal 5% of
## max HP", "heal spell regenerates 5%/sec").
##
## Actors wire their own `health_changed` and `died` signals to this component,
## and typically expose `current_health` / `max_health` as property forwarders
## so external code can keep using the old API.

signal health_changed(current_hp: float, max_hp: float)
signal damaged(amount: float)
signal healed(amount: float)
signal died()

@export var max_hp: float = 100.0
var current_hp: float = 100.0
var invulnerable: bool = false


func _ready() -> void:
	current_hp = max_hp


## Set a new max HP. By default the current HP keeps its ratio (e.g. a
## creature at 50% stays at 50%). Pass `keep_ratio = false` to restore to full.
func set_max_hp(new_max: float, keep_ratio: bool = true) -> void:
	if new_max <= 0.0:
		return
	if keep_ratio and max_hp > 0.0:
		var ratio: float = current_hp / max_hp
		max_hp = new_max
		current_hp = new_max * ratio
	else:
		max_hp = new_max
		current_hp = new_max
	health_changed.emit(current_hp, max_hp)


## Directly set the current HP (clamped to [0, max_hp]). No damaged/healed
## signals are emitted — use damage_* / heal_* if you want those.
func set_current_hp(value: float) -> void:
	current_hp = clampf(value, 0.0, max_hp)
	health_changed.emit(current_hp, max_hp)
	if current_hp <= 0.0:
		died.emit()


## Reset to full health.
func reset_to_full() -> void:
	current_hp = max_hp
	health_changed.emit(current_hp, max_hp)


## Deal a flat amount of damage (e.g. sword swings).
func damage_flat(amount: float) -> void:
	if invulnerable or amount <= 0.0 or current_hp <= 0.0:
		return
	var prev: float = current_hp
	current_hp = maxf(0.0, current_hp - amount)
	var actual: float = prev - current_hp
	damaged.emit(actual)
	health_changed.emit(current_hp, max_hp)
	if current_hp <= 0.0:
		died.emit()


## Deal damage as a percentage of max HP. `pct` is 0.0–1.0 (e.g. 0.05 = 5%).
func damage_pct(pct: float) -> void:
	damage_flat(max_hp * pct)


## Heal a flat amount.
func heal_flat(amount: float) -> void:
	if amount <= 0.0 or current_hp <= 0.0:
		return
	var prev: float = current_hp
	current_hp = minf(max_hp, current_hp + amount)
	var actual: float = current_hp - prev
	if actual > 0.0:
		healed.emit(actual)
		health_changed.emit(current_hp, max_hp)


## Heal a percentage of max HP. `pct` is 0.0–1.0 (e.g. 0.05 = 5%).
func heal_pct(pct: float) -> void:
	heal_flat(max_hp * pct)


func is_alive() -> bool:
	return current_hp > 0.0


func get_health_ratio() -> float:
	return current_hp / max_hp if max_hp > 0.0 else 0.0
