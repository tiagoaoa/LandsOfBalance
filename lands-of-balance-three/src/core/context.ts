/**
 * The bits of Godot's SceneTree the gameplay code actually depends on:
 * node groups, the current lighting preset, and a handful of shared services.
 *
 * The GDScript is full of `get_tree().get_nodes_in_group("ground_fire")` and
 * `get_first_node_in_group("bobba")`. Rather than pretend those don't exist,
 * the port keeps a real group registry — the AI code then ports line for line.
 */
import type { Object3D, Scene, Vector3 } from 'three'
import type { WorldCollision } from './physics'
import type { InputManager } from './input'

export type Group =
  | 'player' | 'companion' | 'remote_players'
  | 'bobba' | 'skeletons' | 'enemies'
  | 'ground_fire' | 'fire_arrows'

export type DamageSource = 'arrow' | 'fire'

/** Anything that can be hit — the `take_hit` duck-type used everywhere. */
export interface Combatant {
  readonly object: Object3D
  readonly position: Vector3
  takeHit(damage: number, knockback: Vector3, blocked: boolean, attacker: unknown, isFullyBlockable: boolean): boolean
  isDead: boolean
  /** Model yaw, for the backstab cone (`get_facing_rotation` in GDScript). */
  getFacingRotation?(): number
  isRiposteReady?(): boolean
  consumeRiposte?(): void
  onParried?(by: unknown): void
  /**
   * Percentage damage from arrows and DoT auras. The source matters: Bobba
   * shrugs arrows off (1 flat) but burns properly in a ground fire, which is
   * what makes fire the archer's real weapon against it.
   */
  takeDamagePct?(pct: number, source?: DamageSource): void
  ignite?(duration: number): void
  health?: number
  maxHealth?: number
  displayName?: string
}

export enum TimeOfDay {
  DAY = 0,
  NIGHT = 1,
}

export class Groups {
  private readonly map = new Map<Group, Set<unknown>>()

  add(group: Group, node: unknown): void {
    let set = this.map.get(group)
    if (!set) this.map.set(group, (set = new Set()))
    set.add(node)
  }

  remove(group: Group, node: unknown): void {
    this.map.get(group)?.delete(node)
  }

  get<Tt = unknown>(group: Group): Tt[] {
    return [...(this.map.get(group) ?? [])] as Tt[]
  }

  first<Tt = unknown>(group: Group): Tt | null {
    const set = this.map.get(group)
    if (!set) return null
    for (const v of set) return v as Tt
    return null
  }
}

/** Passed to every system instead of Godot's implicit tree access. */
export interface GameContext {
  scene: Scene
  world: WorldCollision
  groups: Groups
  input: InputManager
  timeOfDay: TimeOfDay
  /** Seconds since the game started, unaffected by pauses. */
  now: number
  /** Screen-space feedback hooks the HUD implements. */
  hud: {
    showLabel(text: string, color?: number): void
    floatText(worldPos: Vector3, text: string, color?: number): void
    flashDamage(): void
  }
  fx: {
    spawnHitSpark(pos: Vector3, color: number): void
    spawnGroundFire(pos: Vector3): void
  }
  audio: {
    play(name: string, pos?: Vector3, volumeDb?: number): void
  }
}
