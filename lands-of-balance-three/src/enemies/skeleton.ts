/**
 * Port of enemies/skeleton.gd — the undead axe-wielding draugr.
 *
 * Behaviour, carried over rule for rule:
 * - DARK VISION: unlike every living AI, skeletons need no moonlight and no
 *   fire — they always know where the characters are.
 * - Within AGGRO_RANGE they RUN at the closest character and CROWD him: each
 *   skeleton approaches on its own drifting bearing with separation from its
 *   brothers, so a pack surrounds instead of forming a conga line.
 * - FIRE is anathema: standing near burning ground deals damage, so their
 *   pathing swerves around flames — the archer's fire walls work.
 * - Killed skeletons collapse and RISE AGAIN elsewhere (handled by the crew).
 */
import { Color, Group, type Mesh, MeshStandardMaterial, type Object3D, Vector3 } from 'three'
import type { AssetLoader } from '../core/assets'
import { enableShadows, fitToHeight } from '../core/assets'
import type { Combatant, GameContext } from '../core/context'
import { lerpAngle, moveToward, randRange, randIntRange } from '../core/gdmath'
import { moveAndSlide, type MoveResult } from '../core/physics'
import { allCharacters, nearestFire } from '../combat/perception'
import { FlameCloud } from '../fx/fire'
import * as T from '../core/tuning'
import { Label3D } from '../world/label3d'
import { SkeletonAnimator } from './skeleton_anim'

const CAPSULE_RADIUS = 0.35
const CAPSULE_HEIGHT = 1.8
/** Preferred striking distance in the crowd ring (never beyond ATTACK_RANGE:
 * a slot you cannot strike from stalls the AI). */
const RING_MIN = 1.2
const RING_MAX = 1.7

const _v1 = new Vector3()
const _v2 = new Vector3()
const _move = new Vector3()
const _kb = new Vector3()

export class Skeleton implements Combatant {
  readonly object = new Group()
  private readonly model = new Group()
  private anim: SkeletonAnimator | null = null

  hp = T.SKEL_MAX_HP
  isDead = false
  crowdSlot = 0
  homePost = new Vector3()

  private readonly velocity = new Vector3()
  private readonly move: MoveResult = { onFloor: false, onCeiling: false, onWall: false }

  // Ragged crowd: every skeleton keeps its OWN drifting approach bearing and
  // striking distance, re-rolled every few seconds — the pack surrounds prey
  // as a loose mob, never as an evenly-spaced honour guard.
  private ringAngle = Math.random() * Math.PI * 2
  private ringDist = randRange(RING_MIN, RING_MAX)
  private ringReroll = 0
  private gaitScale = randRange(0.85, 1.15)

  private target: Combatant | null = null
  private attackLeft = 0
  private attackCooldown = 0
  private attackDealt = false
  private staggerLeft = 0
  private burnLeft = 0
  private burnFx: FlameCloud | null = null
  private collapse = 0

  private hpLabel: Label3D | null = null
  private hpLabelTimer = 0

  private constructor(private readonly ctx: GameContext) {
    this.object.add(this.model)
    ctx.scene.add(this.object)
    ctx.groups.add('skeletons', this)
  }

  static async create(ctx: GameContext, assets: AssetLoader, at: Vector3, slot: number): Promise<Skeleton> {
    const sk = new Skeleton(ctx)
    sk.crowdSlot = slot
    sk.object.position.copy(at)
    sk.homePost.copy(at)
    await sk.build(assets)
    return sk
  }

  private async build(assets: AssetLoader): Promise<void> {
    const loaded = await assets.instance('/assets/characters/skeleton_axe.glb')
    const root = loaded.scene
    // Godot scales this rig by MODEL_SCALE (0.53) off a ~3.5-unit import;
    // measure instead, so the draugr stands the same height regardless of
    // what our Blender bake happened to export it at.
    fitToHeight(root, T.SKEL_MODEL_SCALE * 3.5)
    // Bind-pose soles sit slightly above the rig origin. Godot writes this
    // offset on the same node it scales, so it is already in METRES — it must
    // not be multiplied by our (differently-based) fit factor.
    root.position.y = -0.28 * T.SKEL_MODEL_SCALE
    enableShadows(root)
    this.applyGraveTone(root, assets)
    this.model.add(root)

    this.anim = new SkeletonAnimator(root)
    this.anim.desync(Math.random(), this.gaitScale)
    this.anim.play('Idle', true)

    this.hpLabel = new Label3D('', { fontSize: 40, color: '#b3e5b3', outlineSize: 4, worldScale: 0.005 })
    this.hpLabel.position.set(0, 2.1, 0)
    this.hpLabel.visible = false
    this.object.add(this.hpLabel)
  }

  /**
   * The FBX ships broken texture paths, so the Godot build rebuilds the
   * materials from the asset's own texture set and keeps the aged-dark
   * grading: old bones, dark rusted iron under the night grade.
   */
  private applyGraveTone(root: Object3D, assets: AssetLoader): void {
    const boneTex = assets.texture('/assets/skeleton/skeleton.jpeg')
    const boneN = assets.texture('/assets/skeleton/skeleton_n.jpeg')
    const axeTex = assets.texture('/assets/skeleton/draugrbattleaxe_m.jpeg')
    const axeN = assets.texture('/assets/skeleton/draugrbattleaxe_n.jpeg')

    root.traverse((o) => {
      const mesh = o as Mesh
      if (!mesh.isMesh) return
      // Anything parented under an axe/weapon bone wears the axe texture.
      let isAxe = /axe/i.test(mesh.name)
      for (let p: Object3D | null = mesh.parent; p && !isAxe; p = p.parent) {
        if (/axe|weapon/i.test(p.name)) isAxe = true
      }
      const mat = new MeshStandardMaterial({
        map: isAxe ? axeTex : boneTex,
        normalMap: isAxe ? axeN : boneN,
        color: new Color(isAxe ? 0x6b6154 : 0x8c806b),
        roughness: isAxe ? 0.85 : 0.92,
        metalness: isAxe ? 0.35 : 0,
      })
      mesh.material = mat
    })
  }

  get position(): Vector3 {
    return this.object.position
  }

  get health(): number {
    return this.hp
  }

  get maxHealth(): number {
    return T.SKEL_MAX_HP
  }

  get displayName(): string {
    return `Skeleton ${this.crowdSlot + 1}`
  }

  getFacingRotation(): number {
    return this.model.rotation.y
  }

  update(dt: number): void {
    if (this.isDead) {
      this.updateCollapse(dt)
      this.anim?.update(dt)
      return
    }

    this.velocity.y -= T.GRAVITY * dt
    this.attackCooldown -= dt
    if (this.hpLabelTimer > 0) {
      this.hpLabelTimer -= dt
      if (this.hpLabelTimer <= 0 && this.hpLabel) this.hpLabel.visible = false
    }

    if (this.staggerLeft > 0) {
      this.staggerLeft -= dt
      this.velocity.x = moveToward(this.velocity.x, 0, 20 * dt)
      this.velocity.z = moveToward(this.velocity.z, 0, 20 * dt)
      this.finishStep(dt)
      return
    }

    // Fire burns the unliving.
    if (nearestFire(this.ctx, this.object.position, T.SKEL_FIRE_HURT_DIST)) {
      this.hp -= T.SKEL_FIRE_DPS * dt
      this.showHp()
      if (this.hp <= 0) return this.die()
    }
    // Caught fire from an arrow: burn down until the flames gutter out.
    if (this.burnLeft > 0) {
      this.burnLeft -= dt
      this.hp -= T.SKEL_BURN_DPS * dt
      this.burnFx?.update(dt)
      if (this.burnLeft <= 0) this.extinguish()
      if (this.hp <= 0) {
        this.showHp()
        return this.die()
      }
    }

    if (this.attackLeft > 0) {
      this.attackLeft -= dt
      // The blade falls mid-clip: deal damage exactly once, on contact.
      if (!this.attackDealt && this.attackLeft <= T.SKEL_ATTACK_LEN - T.SKEL_ATTACK_HIT_TIME) {
        this.attackDealt = true
        this.strike()
      }
      this.velocity.x = moveToward(this.velocity.x, 0, 14 * dt)
      this.velocity.z = moveToward(this.velocity.z, 0, 14 * dt)
      this.finishStep(dt)
      return
    }

    this.target = this.closestCharacter()
    _move.set(0, 0, 0)
    let running = false

    if (this.target) {
      _v1.copy(this.target.position).sub(this.object.position)
      _v1.y = 0
      const dist = _v1.length()
      if (dist <= T.SKEL_ATTACK_RANGE && this.attackCooldown <= 0) {
        this.startAttack()
        return
      }
      // Crowd the prey from MY current bearing; bearing and distance drift
      // every few seconds so the mob stays ragged.
      this.ringReroll -= dt
      if (this.ringReroll <= 0) {
        this.ringReroll = randRange(3, 7)
        this.ringAngle += randRange(-1.2, 1.2)
        this.ringDist = randRange(RING_MIN, RING_MAX)
      }
      _v2.set(Math.cos(this.ringAngle), 0, Math.sin(this.ringAngle)).multiplyScalar(this.ringDist)
      _move.copy(this.target.position).add(_v2).sub(this.object.position)
      _move.y = 0
      if (_move.length() > 0.2) _move.normalize()
      running = dist > 4
    } else {
      // Nothing within 50 m: haunt the post.
      _move.copy(this.homePost).sub(this.object.position)
      _move.y = 0
      if (_move.length() > 3) _move.normalize()
      else _move.set(0, 0, 0)
    }

    // Personal space from the brothers.
    for (const other of this.ctx.groups.get<Skeleton>('skeletons')) {
      if (other === this || other.isDead) continue
      _v1.copy(this.object.position).sub(other.position)
      _v1.y = 0
      const d = _v1.length()
      if (d < T.SKEL_SEPARATION_DIST && d > 0.01) _move.addScaledVector(_v1.normalize(), 0.8)
    }
    // Flames are walls: swerve hard around any fire on the path.
    const fire = nearestFire(this.ctx, this.object.position, T.SKEL_FIRE_AVOID_DIST)
    if (fire) {
      _v1.copy(this.object.position).sub(fire)
      _v1.y = 0
      if (_v1.length() > 0.01) _move.addScaledVector(_v1.normalize(), 1.6)
    }

    if (_move.length() > 0.1) {
      _move.normalize()
      const speed = (running ? T.SKEL_RUN_SPEED : T.SKEL_WALK_SPEED) * this.gaitScale
      this.velocity.x = _move.x * speed
      this.velocity.z = _move.z * speed
      // Close to prey the eyes stay ON the prey — ring manoeuvring and
      // separation shoves must not turn a skeleton's back on its target.
      _v1.copy(_move)
      if (this.target) {
        _v2.copy(this.target.position).sub(this.object.position)
        _v2.y = 0
        const d = _v2.length()
        if (d < 7 && d > 0.1) _v1.copy(_v2).normalize()
      }
      this.face(_v1, dt)
      this.anim?.play(running ? 'Run' : 'Walk')
    } else {
      this.velocity.x = moveToward(this.velocity.x, 0, 12 * dt)
      this.velocity.z = moveToward(this.velocity.z, 0, 12 * dt)
      if (this.target) {
        _v1.copy(this.target.position).sub(this.object.position)
        _v1.y = 0
        if (_v1.length() > 0.1) this.face(_v1.normalize(), dt)
      }
      this.anim?.play('Idle')
    }
    this.finishStep(dt)
  }

  private finishStep(dt: number): void {
    moveAndSlide(this.ctx.world, this.object.position, this.velocity, CAPSULE_RADIUS, CAPSULE_HEIGHT, dt, this.move)
    this.anim?.update(dt)
    if (this.burnFx) this.burnFx.points.position.copy(this.object.position).add(_v1.set(0, 0.9, 0))
  }

  /** Dark vision: every character is always known — no light rules apply. */
  private closestCharacter(): Combatant | null {
    let best: Combatant | null = null
    let bestDist = T.SKEL_AGGRO_RANGE
    for (const c of allCharacters(this.ctx)) {
      if (c.isDead) continue
      const d = this.object.position.distanceTo(c.position)
      if (d < bestDist) {
        best = c
        bestDist = d
      }
    }
    return best
  }

  private startAttack(): void {
    this.attackLeft = T.SKEL_ATTACK_LEN
    this.attackDealt = false
    this.attackCooldown = T.SKEL_ATTACK_LEN + randRange(0.9, 1.7)
    if (this.target) {
      _v1.copy(this.target.position).sub(this.object.position)
      _v1.y = 0
      if (_v1.length() > 0.1) this.face(_v1.normalize(), 0, true)
    }
    // Two distinct swings — an overhead chop and a cross-body slash.
    this.anim?.play(Math.random() < 0.5 ? 'AttackOverhead' : 'AttackSlash', true)
    this.ctx.audio.play(`sword_whoosh_${randIntRange(1, 2)}`, this.object.position, -8)
  }

  private strike(): void {
    const target = this.target
    if (!target || target.isDead) return
    _v1.copy(target.position).sub(this.object.position)
    if (_v1.length() > T.SKEL_ATTACK_HIT_RANGE) return

    _kb.copy(_v1).normalize().multiplyScalar(4)
    _kb.y = 0.2
    // Rusty blade: fully blockable — a raised shield chips, a parry cancels.
    // The defender is the authority on whether the contact counted, so no
    // impact SFX when the hit was negated outright.
    const landed = target.takeHit(T.SKEL_ATTACK_DAMAGE, _kb, false, this, true)
    if (landed !== false) this.ctx.audio.play('hit_flesh', target.position, -6)
  }

  /**
   * An arrow's flame catches on the dry bones: burn for `duration` seconds
   * (stacking hits refresh, not stack), with flames riding the ribcage.
   */
  ignite(duration = 4): void {
    if (this.isDead) return
    this.burnLeft = Math.max(this.burnLeft, duration)
    if (!this.burnFx) {
      this.burnFx = new FlameCloud(40, 0.3, 1.4, 0.26)
      this.ctx.scene.add(this.burnFx.points)
    }
  }

  private extinguish(): void {
    this.burnLeft = 0
    if (this.burnFx) {
      this.ctx.scene.remove(this.burnFx.points)
      this.burnFx.dispose()
      this.burnFx = null
    }
  }

  /** Player sword / companion hits. */
  takeHit(damage: number, knockback: Vector3, _blocked = false, _attacker?: unknown, _fullyBlockable = false): boolean {
    if (this.isDead) return false
    this.hp -= damage
    this.showHp()
    this.ctx.audio.play('hit_metal', this.object.position, -8)
    this.velocity.addScaledVector(_v1.set(knockback.x, 0, knockback.z), 0.8)
    this.staggerLeft = 0.3
    if (this.hp <= 0) this.die()
    return true
  }

  /** Arrows and DoT auras. */
  takeDamagePct(pct: number): void {
    if (this.isDead) return
    this.hp -= T.SKEL_MAX_HP * pct
    this.showHp()
    if (this.hp <= 0) this.die()
  }

  private die(): void {
    if (this.isDead) return
    this.isDead = true
    this.hp = 0
    if (this.hpLabel) this.hpLabel.visible = false
    this.ctx.audio.play('death_thud', this.object.position, -8)
    this.extinguish()
    this.collapse = 0
    this.onDied?.(this)
  }

  /** Bones hold no pose in death: topple forward and settle. */
  private updateCollapse(dt: number): void {
    if (this.collapse >= 1) return
    this.collapse = Math.min(1, this.collapse + dt / 0.5)
    const e = this.collapse * this.collapse // EASE_IN, TRANS_QUAD
    this.model.rotation.x = -(Math.PI / 2) * e
    this.model.position.y = 0.35 * e
    this.anim?.relax(Math.min(1, dt * 4))
  }

  onDied: ((s: Skeleton) => void) | null = null

  /** The crew raises it again somewhere else. */
  reviveAt(pos: Vector3): void {
    this.hp = T.SKEL_MAX_HP
    this.isDead = false
    this.object.position.copy(pos)
    this.homePost.copy(pos)
    this.velocity.set(0, 0, 0)
    this.model.rotation.set(0, this.model.rotation.y, 0)
    this.model.position.set(0, 0, 0)
    this.attackLeft = 0
    this.staggerLeft = 0
    this.collapse = 0
    this.extinguish()
    this.anim?.play('Idle', true)
  }

  /** Model faces -Z: yaw so -Z points along `dir`. */
  private face(dir: Vector3, dt: number, instant = false): void {
    const targetYaw = Math.atan2(-dir.x, -dir.z)
    if (instant) this.model.rotation.y = targetYaw
    else this.model.rotation.y = lerpAngle(this.model.rotation.y, targetYaw, 8 * dt)
  }

  private showHp(): void {
    if (!this.hpLabel) return
    this.hpLabel.setText(`${Math.max(0, Math.round(this.hp))}`)
    this.hpLabel.visible = true
    this.hpLabelTimer = 1.2
  }

  get modelObject(): Object3D {
    return this.model
  }

  dispose(): void {
    this.extinguish()
    this.ctx.groups.remove('skeletons', this)
    this.ctx.scene.remove(this.object)
  }
}

/**
 * Port of enemies/skeleton_crew.gd — spawns and shepherds the pack of five.
 *
 * The pack rises GROUPED at a random dark spot not far from Bobba's spawn
 * (the whole field is night, so any spot away from fires is "dark"). Each
 * killed skeleton lies where it fell and RISES AGAIN elsewhere in the haunt.
 */
export class SkeletonCrew {
  readonly members: Skeleton[] = []
  private readonly hauntCenter = new Vector3()
  private readonly pendingRevives: { skeleton: Skeleton; at: number }[] = []

  constructor(private readonly ctx: GameContext) {}

  async spawn(assets: AssetLoader, bobbaSpawn: Vector3): Promise<void> {
    const ang = Math.random() * Math.PI * 2
    const dist = randRange(T.CREW_HAUNT_MIN_DIST, T.CREW_HAUNT_MAX_DIST)
    this.hauntCenter.copy(this.onGround(_v1.set(
      bobbaSpawn.x + Math.cos(ang) * dist,
      bobbaSpawn.y,
      bobbaSpawn.z + Math.sin(ang) * dist,
    )))

    for (let i = 0; i < T.CREW_PACK_SIZE; i++) {
      // Ragged scatter — a risen pack, not a formation.
      const a = Math.random() * Math.PI * 2
      const r = randRange(1, T.CREW_CLUSTER_RADIUS + 2)
      const pos = this.onGround(
        _v1.set(this.hauntCenter.x + Math.cos(a) * r, this.hauntCenter.y, this.hauntCenter.z + Math.sin(a) * r),
      ).clone()
      pos.y += 0.3
      const sk = await Skeleton.create(this.ctx, assets, pos, i)
      sk.onDied = (s) => this.onSkeletonDied(s)
      this.members.push(sk)
    }
  }

  private onSkeletonDied(skeleton: Skeleton): void {
    this.pendingRevives.push({ skeleton, at: this.ctx.now + T.CREW_REVIVE_SECONDS })
  }

  update(dt: number): void {
    for (const m of this.members) m.update(dt)
    for (let i = this.pendingRevives.length - 1; i >= 0; i--) {
      const p = this.pendingRevives[i]
      if (this.ctx.now < p.at) continue
      this.pendingRevives.splice(i, 1)
      const a = Math.random() * Math.PI * 2
      const r = randRange(T.CREW_REVIVE_SCATTER_MIN, T.CREW_REVIVE_SCATTER_MAX)
      const pos = this.onGround(
        _v1.set(this.hauntCenter.x + Math.cos(a) * r, this.hauntCenter.y, this.hauntCenter.z + Math.sin(a) * r),
      ).clone()
      pos.y += 0.3
      p.skeleton.reviveAt(pos)
    }
  }

  private onGround(pos: Vector3): Vector3 {
    const y = this.ctx.world.groundHeight(pos.x, pos.z)
    pos.y = y ?? 1
    return pos
  }
}
