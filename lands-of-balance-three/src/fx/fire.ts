/**
 * Port of combat/fire_fx.gd and the ground-fire half of player/arrow.gd.
 *
 * Fire is not decoration in this game — it is the night's only reliable
 * light, it reveals characters to AI eyes (combat/perception.gd), skeletons
 * path around it and burn in it, and Bobba panics near it. So a ground fire
 * is a real entity with a lifetime, a radius and a damage tick, registered in
 * the `ground_fire` group that every AI queries.
 */
import {
  AdditiveBlending,
  BufferGeometry,
  Color,
  Float32BufferAttribute,
  Points,
  PointsMaterial,
  PointLight,
  type Scene,
  Vector3,
} from 'three'
import type { Combatant, GameContext } from '../core/context'
import { randRange } from '../core/gdmath'
import { flameSprite } from './sprites'
import * as T from '../core/tuning'

const FLAME_COLORS = [0xffd27a, 0xff9a3c, 0xff5a1e, 0xc22d0c]

/** A pool of rising, flickering embers — FireFX.add_flames + add_embers. */
export class FlameCloud {
  readonly points: Points
  private readonly velocities: Vector3[] = []
  private readonly ages: number[] = []
  private readonly lifetimes: number[] = []
  private readonly origins: Vector3[] = []
  private readonly count: number
  private readonly radius: number
  private readonly rise: number
  private readonly baseSize: number

  constructor(count: number, radius: number, rise = 2.4, size = 0.45) {
    this.count = count
    this.radius = radius
    this.rise = rise
    this.baseSize = size

    const positions = new Float32Array(count * 3)
    const colors = new Float32Array(count * 3)
    for (let i = 0; i < count; i++) {
      this.velocities.push(new Vector3())
      this.origins.push(new Vector3())
      this.ages.push(Math.random() * 1.5)
      this.lifetimes.push(randRange(0.7, 1.6))
      const c = new Color(FLAME_COLORS[i % FLAME_COLORS.length])
      colors[i * 3] = c.r
      colors[i * 3 + 1] = c.g
      colors[i * 3 + 2] = c.b
    }
    const geo = new BufferGeometry()
    geo.setAttribute('position', new Float32BufferAttribute(positions, 3))
    geo.setAttribute('color', new Float32BufferAttribute(colors, 3))
    this.points = new Points(
      geo,
      new PointsMaterial({
        // A mapless PointsMaterial draws an opaque SQUARE, which at close
        // range turns the fire into a wall of orange tiles.
        map: flameSprite(),
        size,
        vertexColors: true,
        transparent: true,
        opacity: 0.9,
        blending: AdditiveBlending,
        depthWrite: false,
        sizeAttenuation: true,
        fog: false,
      }),
    )
    this.points.frustumCulled = false
    for (let i = 0; i < count; i++) this.respawn(i)
  }

  private respawn(i: number): void {
    const a = Math.random() * Math.PI * 2
    const r = Math.sqrt(Math.random()) * this.radius
    this.origins[i].set(Math.cos(a) * r, 0, Math.sin(a) * r)
    this.velocities[i].set(randRange(-0.25, 0.25), randRange(0.6, 1.0) * this.rise, randRange(-0.25, 0.25))
    this.ages[i] = 0
    this.lifetimes[i] = randRange(0.7, 1.6)
  }

  update(dt: number): void {
    const pos = this.points.geometry.getAttribute('position') as Float32BufferAttribute
    for (let i = 0; i < this.count; i++) {
      this.ages[i] += dt
      if (this.ages[i] >= this.lifetimes[i]) this.respawn(i)
      const t = this.ages[i]
      const o = this.origins[i]
      const v = this.velocities[i]
      // Converge toward the axis as it rises — a flame tapers, smoke doesn't.
      const taper = 1 - Math.min(t / this.lifetimes[i], 1) * 0.7
      pos.setXYZ(i, o.x * taper + v.x * t, o.y + v.y * t, o.z * taper + v.z * t)
    }
    pos.needsUpdate = true
  }

  setIntensity(f: number): void {
    const mat = this.points.material as PointsMaterial
    mat.opacity = 0.9 * f
    mat.size = this.baseSize * (0.5 + 0.5 * f)
  }

  dispose(): void {
    this.points.geometry.dispose()
    ;(this.points.material as PointsMaterial).dispose()
  }
}

/**
 * A burning patch of ground left by a fire arrow.
 *
 * Ticks `GROUND_FIRE_DAMAGE_PCT_PER_SEC` of max HP to every character inside
 * `GROUND_FIRE_RADIUS`, burns for `GROUND_FIRE_LIFETIME`, and is the reveal
 * source AI perception looks for.
 */
export class GroundFire {
  readonly position: Vector3
  private readonly flames: FlameCloud
  private readonly light: PointLight
  private life = T.GROUND_FIRE_LIFETIME
  private tickAcc = 0
  dead = false

  constructor(
    private readonly ctx: GameContext,
    scene: Scene,
    position: Vector3,
  ) {
    this.position = position.clone()
    this.flames = new FlameCloud(150, T.GROUND_FIRE_RADIUS * 0.5, 2.2, 0.55)
    this.flames.points.position.copy(this.position)
    scene.add(this.flames.points)

    this.light = new PointLight(0xff8a3a, 9, T.GROUND_FIRE_RADIUS * 3.2, 1.6)
    this.light.position.copy(this.position).add(new Vector3(0, 1.2, 0))
    scene.add(this.light)

    ctx.groups.add('ground_fire', this)
  }

  update(dt: number): void {
    if (this.dead) return
    this.life -= dt
    if (this.life <= 0) {
      this.destroy()
      return
    }
    this.flames.update(dt)

    // Guttering flicker + a fade over the last few seconds.
    const fade = Math.min(this.life / 4, 1)
    const flicker = 0.82 + Math.sin(this.ctx.now * 11.3) * 0.1 + Math.sin(this.ctx.now * 27.7) * 0.06
    this.light.intensity = 9 * fade * flicker
    this.flames.setIntensity(fade)

    // DoT: 5% of max HP per second to anything standing in the flames.
    this.tickAcc += dt
    if (this.tickAcc >= 0.25) {
      const pct = T.GROUND_FIRE_DAMAGE_PCT_PER_SEC * this.tickAcc
      this.tickAcc = 0
      for (const group of ['player', 'companion', 'skeletons', 'bobba'] as const) {
        for (const c of this.ctx.groups.get<Combatant>(group)) {
          if (c.isDead) continue
          if (c.position.distanceTo(this.position) > T.GROUND_FIRE_RADIUS) continue
          c.takeDamagePct?.(pct, 'fire')
          c.ignite?.(4.0)
        }
      }
    }
  }

  destroy(): void {
    if (this.dead) return
    this.dead = true
    this.ctx.groups.remove('ground_fire', this)
    this.flames.points.parent?.remove(this.flames.points)
    this.flames.dispose()
    this.light.parent?.remove(this.light)
  }
}
