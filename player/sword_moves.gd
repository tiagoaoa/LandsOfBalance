extends RefCounted

const NAMES := ["SwordSlash", "Attack1", "Attack2", "HeavyAttack"]
const KEYS := ["sword_slash", "attack1", "attack2", "heavy_attack"]
const DURATIONS: Array[float] = [0.68, 0.74, 0.92, 1.08]
const WINDOWS: Array[Vector2] = [Vector2(0.30, 0.49),
	Vector2(0.34, 0.53), Vector2(0.36, 0.58), Vector2(0.36, 0.58)]
const RECOVERY: Array[float] = [0.62, 0.64, 0.70, 0.76]
const TRIMS := {"sword_slash": Vector2(0.35, 1.70),
	"attack1": Vector2(0.0, 1.40), "attack2": Vector2(1.70, 3.30),
	"heavy_attack": Vector2(1.70, 3.30)}
