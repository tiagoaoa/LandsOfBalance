/**
 * Godot's scalar/vector helpers, reimplemented so ported gameplay code reads
 * the same as the GDScript it came from. Three.js has `lerp`/`clamp` but no
 * `lerp_angle`, `move_toward` or `Vector3.move_toward`, and getting those
 * subtly wrong is exactly how ported movement code starts to feel different.
 */
import { Vector3 } from 'three'

export const TAU = Math.PI * 2

export function clampf(v: number, lo: number, hi: number): number {
  return v < lo ? lo : v > hi ? hi : v
}

export function lerpf(a: number, b: number, t: number): number {
  return a + (b - a) * t
}

export function degToRad(d: number): number {
  return (d * Math.PI) / 180
}

/** Godot `lerp_angle` — interpolates the short way around the circle. */
export function lerpAngle(from: number, to: number, weight: number): number {
  const diff = (to - from) % TAU
  const dist = ((2 * diff) % TAU) - diff
  return from + dist * weight
}

/** Godot `move_toward` — step `delta` toward `to`, never overshooting. */
export function moveToward(from: number, to: number, delta: number): number {
  return Math.abs(to - from) <= delta ? to : from + Math.sign(to - from) * delta
}

/** Godot `Vector3.move_toward`. Mutates and returns `from`. */
export function vecMoveToward(from: Vector3, to: Vector3, delta: number): Vector3 {
  const dx = to.x - from.x
  const dy = to.y - from.y
  const dz = to.z - from.z
  const len = Math.sqrt(dx * dx + dy * dy + dz * dz)
  if (len <= delta || len < 1e-6) return from.copy(to)
  return from.set(from.x + (dx / len) * delta, from.y + (dy / len) * delta, from.z + (dz / len) * delta)
}

export function randRange(lo: number, hi: number): number {
  return lo + Math.random() * (hi - lo)
}

export function randIntRange(lo: number, hi: number): number {
  return Math.floor(randRange(lo, hi + 1))
}

/**
 * `Vector3.FORWARD.rotated(Vector3.UP, yaw)` — the camera-relative basis the
 * whole movement system is built on. Godot's FORWARD is -Z.
 */
export function yawForward(yaw: number, out = new Vector3()): Vector3 {
  return out.set(-Math.sin(yaw), 0, -Math.cos(yaw))
}

/** `Vector3.RIGHT.rotated(Vector3.UP, yaw)`. */
export function yawRight(yaw: number, out = new Vector3()): Vector3 {
  return out.set(Math.cos(yaw), 0, -Math.sin(yaw))
}

/** Flat (XZ) distance — the measure every AI range check in the game uses. */
export function flatDist(a: Vector3, b: Vector3): number {
  const dx = a.x - b.x
  const dz = a.z - b.z
  return Math.sqrt(dx * dx + dz * dz)
}
