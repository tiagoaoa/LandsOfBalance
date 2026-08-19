/**
 * Port of player/arrow.gd — the archer's fire arrow.
 *
 * Ballistic, not hitscan: it drops under the same gravity as everything else,
 * so range is a skill. The burning tip is registered in the `fire_arrows`
 * group, which is what lets an arrow in flight briefly reveal characters to
 * AI eyes (combat/perception.gd), and where it lands it leaves a ground fire.
 */
import {
  AdditiveBlending,
  ConeGeometry,
  CylinderGeometry,
  Group,
  Mesh,
  MeshBasicMaterial,
  MeshStandardMaterial,
  PointLight,
  SphereGeometry,
  Vector3,
} from 'three'
import type { Combatant, GameContext } from '../core/context'
import * as T from '../core/tuning'

const _toTarget = new Vector3()
const _step = new Vector3()

export class Arrow {
  readonly object = new Group()
  readonly velocity = new Vector3()
  /** A loose fired on the move leaves the string at half force. */
  shotPower = 1
  airborneShot = false

  private life = 0
  private hasHit = false
  dead = false
  private readonly light: PointLight
  private readonly flame: Mesh

  constructor(
    private readonly ctx: GameContext,
    private readonly shooter: unknown,
    position: Vector3,
    direction: Vector3,
  ) {
    this.object.position.copy(position)
    this.velocity.copy(direction).normalize().multiplyScalar(T.ARROW_SPEED)

    // A fletched war arrow: cedar shaft, forged bodkin head. Forward is -Z,
    // matching the Godot build so `lookAt(pos + velocity)` orients it right.
    const wood = new MeshStandardMaterial({ color: 0x614528, roughness: 0.7 })
    const metal = new MeshStandardMaterial({ color: 0x9ea1ad, metalness: 1, roughness: 0.35 })

    const shaft = new Mesh(new CylinderGeometry(0.01, 0.013, 0.92, 8), wood)
    shaft.rotation.x = -Math.PI / 2
    this.object.add(shaft)

    const head = new Mesh(new ConeGeometry(0.024, 0.14, 6), metal)
    head.rotation.x = -Math.PI / 2
    head.position.z = -0.53
    this.object.add(head)

    this.flame = new Mesh(
      new SphereGeometry(0.13, 8, 6),
      new MeshBasicMaterial({ color: 0xffa23a, transparent: true, opacity: 0.85, blending: AdditiveBlending, fog: false }),
    )
    this.flame.position.z = -0.5
    this.object.add(this.flame)

    // Half-brightness flame on an unplanted shot, mirroring the damage cut.
    this.light = new PointLight(0xff8a35, this.airborneShot ? 3 : 6, 12, 1.5)
    this.object.add(this.light)

    ctx.scene.add(this.object)
    ctx.groups.add('fire_arrows', this)
  }

  /** `fire_arrows` group members are read positionally by the AI. */
  get position(): Vector3 {
    return this.object.position
  }

  update(dt: number): void {
    if (this.dead) return
    this.life += dt
    if (this.life > T.ARROW_LIFETIME) {
      this.destroy()
      return
    }
    if (this.hasHit) return

    this.velocity.y -= T.GRAVITY * dt
    _step.copy(this.velocity).multiplyScalar(dt)
    const prev = this.object.position.clone()
    this.object.position.add(_step)
    this.object.lookAt(_toTarget.copy(this.object.position).add(this.velocity))

    // Flicker the burning tip.
    const f = 0.75 + Math.sin(this.ctx.now * 24) * 0.25
    this.light.intensity = (this.airborneShot ? 3 : 6) * f
    this.flame.scale.setScalar(0.8 + f * 0.4)

    if (this.checkCharacterHit(prev)) return
    this.checkGroundHit(prev)
  }

  /**
   * Swept test against every live character. Sweeping rather than point
   * testing matters at 50 m/s: a per-frame point check tunnels straight
   * through a body at 60 fps.
   */
  private checkCharacterHit(prev: Vector3): boolean {
    const segLen = prev.distanceTo(this.object.position)
    if (segLen <= 0) return false
    const dir = _step.copy(this.object.position).sub(prev).divideScalar(segLen)

    for (const group of ['bobba', 'skeletons', 'player', 'companion'] as const) {
      for (const c of this.ctx.groups.get<Combatant>(group)) {
        if (c.isDead || c === this.shooter) continue
        // Closest approach of the flight segment to the body's centre mass.
        _toTarget.copy(c.position).add(new Vector3(0, 1.0, 0)).sub(prev)
        const along = Math.max(0, Math.min(segLen, _toTarget.dot(dir)))
        const closest = prev.clone().addScaledVector(dir, along)
        if (closest.distanceTo(c.position.clone().add(new Vector3(0, 1.0, 0))) > 0.6) continue

        this.hasHit = true
        let pct = T.ARROW_DIRECT_HIT_DAMAGE_PCT
        if (this.airborneShot) pct *= T.ARROW_AIRBORNE_SHOT_DAMAGE_MULT
        c.takeDamagePct?.(pct, 'arrow')
        c.ignite?.(4.0)
        this.ctx.audio.play('arrow_impact', closest, -4)
        this.ctx.fx.spawnHitSpark(closest, 0xffb45a)
        this.ctx.fx.spawnGroundFire(new Vector3(closest.x, this.groundY(closest), closest.z))
        this.destroy()
        return true
      }
    }
    return false
  }

  private checkGroundHit(prev: Vector3): void {
    const ground = this.groundY(this.object.position)
    if (this.object.position.y > ground) return
    this.hasHit = true
    // Land on the surface rather than inside it.
    const t = (prev.y - ground) / Math.max(prev.y - this.object.position.y, 1e-6)
    const impact = prev.clone().lerp(this.object.position, Math.min(Math.max(t, 0), 1))
    impact.y = ground
    this.ctx.fx.spawnGroundFire(impact)
    this.ctx.audio.play('arrow_impact', impact, -6)
    this.destroy()
  }

  private groundY(at: Vector3): number {
    return this.ctx.world.groundHeight(at.x, at.z) ?? 0.5
  }

  destroy(): void {
    if (this.dead) return
    this.dead = true
    this.ctx.groups.remove('fire_arrows', this)
    this.ctx.scene.remove(this.object)
  }
}
