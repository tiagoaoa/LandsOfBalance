/**
 * Port of combat/perception.gd — the night-vision rules shared by every AI.
 *
 * The world is a rainy NIGHT: AI characters cannot see other characters in
 * the dark. A character becomes visible when FIRE reveals them — standing in
 * the glow of a burning ground fire (the archer's fire arrows are the reveal
 * tool) or right next to a fire arrow in flight. Smell/touch exceptions live
 * with the specific AI (Bobba smells anyone who comes too close; anyone who
 * HITS an AI reveals himself).
 */
import type { Vector3 } from 'three'
import { type Combatant, type GameContext, TimeOfDay } from '../core/context'
import * as T from '../core/tuning'

export interface FireSource {
  position: Vector3
}

/**
 * Moonlight visibility range: the rainy night has a full moon, so nearby
 * silhouettes ARE visible without fire; the day preset sees much further.
 */
export function moonlightRange(ctx: GameContext): number {
  return ctx.timeOfDay === TimeOfDay.DAY ? T.DAY_REVEAL_RADIUS : T.MOON_REVEAL_RADIUS
}

/** True when `pos` stands in the light of any burning fire. */
export function isLitByFire(ctx: GameContext, pos: Vector3): boolean {
  for (const fire of ctx.groups.get<FireSource>('ground_fire')) {
    if (pos.distanceTo(fire.position) <= T.FIRE_REVEAL_RADIUS) return true
  }
  for (const arrow of ctx.groups.get<FireSource>('fire_arrows')) {
    if (pos.distanceTo(arrow.position) <= T.ARROW_REVEAL_RADIUS) return true
  }
  return false
}

/**
 * The one question every AI asks: can `observer` see `target` right now?
 * Yes if the target is close enough to read under the moonlight, or if it
 * stands in a fire's glow — then it is visible from far across the dark.
 */
export function canSee(ctx: GameContext, observer: Vector3, target: Vector3): boolean {
  const dist = observer.distanceTo(target)
  if (dist <= moonlightRange(ctx)) return true
  return dist <= T.FIRE_SIGHT_RADIUS && isLitByFire(ctx, target)
}

/**
 * Every character an AI could care about: the human player, the AI
 * companion, and any remote players.
 */
export function allCharacters(ctx: GameContext): Combatant[] {
  const out: Combatant[] = []
  for (const g of ['player', 'companion', 'remote_players'] as const) {
    for (const n of ctx.groups.get<Combatant>(g)) {
      if (!out.includes(n)) out.push(n)
    }
  }
  return out
}

/** Nearest live fire within `radius`, or null. Skeletons path around these. */
export function nearestFire(ctx: GameContext, pos: Vector3, radius: number): Vector3 | null {
  let best: Vector3 | null = null
  let bestD = radius
  for (const g of ['ground_fire', 'fire_arrows'] as const) {
    for (const fire of ctx.groups.get<FireSource>(g)) {
      const d = pos.distanceTo(fire.position)
      if (d < bestD) {
        bestD = d
        best = fire.position
      }
    }
  }
  return best
}
