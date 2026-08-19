/**
 * Port of enemies/bobba.gd — the boss of the Lands.
 *
 * The fight's shape, carried over from the GDScript:
 * - Bobba is BLIND in the rainy night like every living AI. It finds you by
 *   SMELL inside 10 m, by moonlight up close, or because a fire lit you up —
 *   and anyone who HITS it has revealed themselves.
 * - Arrows barely scratch it (1 damage flat, 50x less than the sword): the
 *   archer's job is to TRAP it with fire, not to whittle it down. Bobba
 *   panics near flames and routes around them.
 * - Its fists are BLUNT: a raised shield only chips the damage down, it
 *   never cancels it. Only a timed parry does — and a parry opens the long
 *   riposte window the paladin's sword crits into.
 * - Badly wounded it DISENGAGES and runs, regenerating out of combat, so
 *   letting it escape has a real cost.
 */
import { AnimationClip, Group, type Object3D, Vector3 } from 'three'
import { AnimRig } from '../core/anim'
import type { AssetLoader } from '../core/assets'
import { enableShadows, fitToHeight } from '../core/assets'
import type { Combatant, DamageSource, GameContext } from '../core/context'
import { lerpAngle, moveToward, randRange } from '../core/gdmath'
import { moveAndSlide, type MoveResult } from '../core/physics'
import { allCharacters, canSee, nearestFire } from '../combat/perception'
import { HealthComponent, PoiseComponent } from '../combat/components'
import * as T from '../core/tuning'
import { Label3D } from '../world/label3d'

export enum BobbaState {
  ROAMING = 0,
  CHASING = 1,
  ATTACKING = 2,
  RETREATING = 3,
  FLEEING = 4,
  STAGGERED = 5,
  DEAD = 6,
}

const CAPSULE_RADIUS = 0.6
const CAPSULE_HEIGHT = 2.4
/** Bobba towers over the player; the Godot import lands about here. */
const MODEL_HEIGHT = 2.4
/** Fist reach when the blow lands — the hitbox window is 0.3..0.7 of the clip. */
const FIST_HIT_RANGE = 2.6

const _v1 = new Vector3()
const _v2 = new Vector3()
const _kb = new Vector3()

export class Bobba implements Combatant {
  readonly object = new Group()
  private readonly model = new Group()
  private rig: AnimRig | null = null

  state = BobbaState.ROAMING
  isDead = false
  isBlocking = false

  private readonly velocity = new Vector3()
  private readonly move: MoveResult = { onFloor: false, onCeiling: false, onWall: false }

  readonly healthComp = new HealthComponent(T.BOBBA_MAX_HEALTH)
  private readonly poise = new PoiseComponent()

  private target: Combatant | null = null
  private readonly roamDirection = new Vector3()
  private roamTimer = 0
  private attackCooldown = 0
  private attackLeft = 0
  private hasHitThisAttack = false
  private staggerLeft = 0

  /** Set by a successful parry; the paladin's next sword hit crits into it. */
  private riposteWindow = 0

  private blockTimer = 0
  private blockCheckCooldown = 0

  private timeSinceDamage = 999
  private isFleeing = false
  private readonly fleeDir = new Vector3()
  private fleeRouteTimer = 0

  private retreatTimer = 0
  private readonly retreatDirection = new Vector3()

  private hpLabel: Label3D | null = null

  private constructor(private readonly ctx: GameContext) {
    this.object.add(this.model)
    ctx.scene.add(this.object)
    ctx.groups.add('bobba', this)

    this.healthComp.died.connect(() => this.die())
    this.poise.staggered.connect(() => {
      this.staggerLeft = 1.0
      this.state = BobbaState.STAGGERED
      this.ctx.hud.floatText(this.headPos(_v1), 'STAGGERED', 0xffcc44)
    })
  }

  static async create(ctx: GameContext, assets: AssetLoader, at: Vector3): Promise<Bobba> {
    const b = new Bobba(ctx)
    b.object.position.copy(at)
    await b.build(assets)
    return b
  }

  private async build(assets: AssetLoader): Promise<void> {
    const loaded = await assets.instance('/assets/characters/bobba.glb')
    const root = loaded.scene
    fitToHeight(root, MODEL_HEIGHT)
    enableShadows(root)
    this.model.add(root)

    const clips: Map<string, AnimationClip> = new Map(loaded.clips)
    this.rig = new AnimRig(root, clips)
    // This pack names its clips lowercase; map to the names we play.
    for (const [from, to] of [['idle', 'Idle'], ['walk', 'Walk'], ['run', 'Run'], ['attack', 'Attack'], ['dying', 'Death']]) {
      const c = clips.get(from)
      if (c && !clips.has(to)) clips.set(to, c)
    }
    this.rig.play('Idle')

    this.hpLabel = new Label3D('BOBBA', { fontSize: 44, color: '#e8b0b0', outlineSize: 5, worldScale: 0.0055 })
    this.hpLabel.position.set(0, 3.2, 0)
    this.object.add(this.hpLabel)
  }

  // ── Combatant surface ───────────────────────────────────────────────────

  get position(): Vector3 {
    return this.object.position
  }

  get health(): number {
    return this.healthComp.currentHp
  }

  get maxHealth(): number {
    return this.healthComp.maxHp
  }

  get displayName(): string {
    return 'Bobba'
  }

  getFacingRotation(): number {
    return this.model.rotation.y
  }

  isRiposteReady(): boolean {
    return this.riposteWindow > 0
  }

  consumeRiposte(): void {
    this.riposteWindow = 0
  }

  /**
   * The paladin caught the blow on the shield edge. Bobba is knocked open
   * for a long moment — this is the window a riposte crits into.
   */
  onParried(_by: unknown): void {
    this.riposteWindow = T.BOBBA_RIPOSTE_WINDOW
    this.staggerLeft = T.BOBBA_RIPOSTE_WINDOW
    this.state = BobbaState.STAGGERED
    this.attackLeft = 0
    this.hasHitThisAttack = true
    this.ctx.hud.floatText(this.headPos(_v1), 'OPENED', 0xffd24d)
  }

  private headPos(out: Vector3): Vector3 {
    return out.copy(this.object.position).add(_v2.set(0, 3.0, 0))
  }

  // ── Step ────────────────────────────────────────────────────────────────

  update(dt: number): void {
    if (this.isDead) {
      this.velocity.y -= T.GRAVITY * dt
      moveAndSlide(this.ctx.world, this.object.position, this.velocity, CAPSULE_RADIUS, CAPSULE_HEIGHT, dt, this.move)
      this.rig?.update(dt)
      return
    }

    this.poise.update(dt)
    this.timeSinceDamage += dt
    this.attackCooldown -= dt
    if (this.riposteWindow > 0) this.riposteWindow -= dt
    this.velocity.y -= T.GRAVITY * dt

    // Out-of-combat regeneration — fleeing has a payoff.
    if (this.timeSinceDamage >= T.BOBBA_REGEN_DELAY && this.healthComp.currentHp < this.healthComp.maxHp) {
      this.healthComp.healFlat(this.healthComp.maxHp * T.BOBBA_REGEN_PCT_PER_SEC * dt)
    }
    this.updateHpLabel()

    if (this.staggerLeft > 0) {
      this.staggerLeft -= dt
      this.velocity.x = moveToward(this.velocity.x, 0, 18 * dt)
      this.velocity.z = moveToward(this.velocity.z, 0, 18 * dt)
      this.rig?.play('Idle')
      if (this.staggerLeft <= 0) this.state = BobbaState.ROAMING
      return this.finishStep(dt)
    }

    // Mid-swing: the fist lands inside the 0.3..0.7 window of the clip.
    if (this.attackLeft > 0) {
      this.attackLeft -= dt
      const progress = 1 - this.attackLeft / T.BOBBA_ATTACK_LEN
      if (!this.hasHitThisAttack && progress >= T.BOBBA_HAND_HITBOX_START && progress <= T.BOBBA_HAND_HITBOX_END) {
        this.tryLandPunch()
      }
      this.velocity.x = moveToward(this.velocity.x, 0, 14 * dt)
      this.velocity.z = moveToward(this.velocity.z, 0, 14 * dt)
      if (this.target) this.faceToward(this.target.position, dt)
      return this.finishStep(dt)
    }

    // FIRE: panic first, avoid second. This is the archer's control tool.
    const panic = nearestFire(this.ctx, this.object.position, T.BOBBA_FIRE_PANIC_RADIUS)
    if (panic) {
      _v1.copy(this.object.position).sub(panic)
      _v1.y = 0
      if (_v1.length() > 0.01) {
        _v1.normalize()
        this.velocity.x = _v1.x * T.BOBBA_CHASE_SPEED
        this.velocity.z = _v1.z * T.BOBBA_CHASE_SPEED
        this.faceToward(_v2.copy(this.object.position).add(_v1), dt)
        this.rig?.play('Run')
      }
      return this.finishStep(dt)
    }

    // Badly wounded → disengage and run.
    if (!this.isFleeing && this.healthComp.ratio() <= T.BOBBA_FLEE_HP_FRACTION) {
      this.isFleeing = true
      this.state = BobbaState.FLEEING
      this.ctx.hud.showLabel('Bobba is fleeing!', 0xffaa33)
    } else if (this.isFleeing && this.healthComp.ratio() > T.BOBBA_FLEE_HP_FRACTION * 2.2) {
      this.isFleeing = false
      this.state = BobbaState.ROAMING
    }

    this.target = this.acquireTarget()

    if (this.isFleeing) {
      this.stepFlee(dt)
    } else if (this.retreatTimer > 0) {
      this.retreatTimer -= dt
      this.velocity.x = this.retreatDirection.x * T.BOBBA_RETREAT_SPEED
      this.velocity.z = this.retreatDirection.z * T.BOBBA_RETREAT_SPEED
      this.rig?.play('Walk')
      this.state = BobbaState.RETREATING
    } else if (this.target) {
      this.stepChase(dt)
    } else {
      this.stepRoam(dt)
    }

    this.updateBlockDecision(dt)
    this.finishStep(dt)
  }

  private finishStep(dt: number): void {
    moveAndSlide(this.ctx.world, this.object.position, this.velocity, CAPSULE_RADIUS, CAPSULE_HEIGHT, dt, this.move)
    this.rig?.update(dt)
  }

  /**
   * Perception: smell inside DETECTION_RADIUS, sight by the shared night
   * rules otherwise, and a target already engaged is tracked until it
   * escapes LOSE_RADIUS.
   */
  private acquireTarget(): Combatant | null {
    let best: Combatant | null = null
    let bestDist = Infinity
    for (const c of allCharacters(this.ctx)) {
      if (c.isDead) continue
      const d = this.object.position.distanceTo(c.position)
      if (d > T.BOBBA_LOSE_RADIUS) continue
      const smelled = d <= T.BOBBA_DETECTION_RADIUS
      if (!smelled && !canSee(this.ctx, this.object.position, c.position)) continue
      if (d < bestDist) {
        bestDist = d
        best = c
      }
    }
    return best
  }

  private stepChase(dt: number): void {
    const target = this.target
    if (!target) return
    _v1.copy(target.position).sub(this.object.position)
    _v1.y = 0
    const dist = _v1.length()

    if (dist <= T.BOBBA_ATTACK_DISTANCE && this.attackCooldown <= 0) {
      this.startAttack()
      return
    }

    _v1.normalize()
    // Route around any fire between here and the prey.
    const fire = nearestFire(this.ctx, this.object.position, T.BOBBA_FIRE_AVOID_RADIUS)
    if (fire) {
      _v2.copy(this.object.position).sub(fire)
      _v2.y = 0
      if (_v2.length() > 0.01) _v1.addScaledVector(_v2.normalize(), 1.4).normalize()
    }

    this.velocity.x = _v1.x * T.BOBBA_CHASE_SPEED
    this.velocity.z = _v1.z * T.BOBBA_CHASE_SPEED
    this.faceToward(target.position, dt)
    this.rig?.play('Run')
    this.state = BobbaState.CHASING
  }

  private stepRoam(dt: number): void {
    this.roamTimer -= dt
    if (this.roamTimer <= 0) {
      this.roamTimer = T.BOBBA_ROAM_CHANGE_TIME + randRange(-1, 1)
      const a = Math.random() * Math.PI * 2
      this.roamDirection.set(Math.cos(a), 0, Math.sin(a))
    }
    this.velocity.x = this.roamDirection.x * T.BOBBA_ROAM_SPEED
    this.velocity.z = this.roamDirection.z * T.BOBBA_ROAM_SPEED
    this.faceToward(_v2.copy(this.object.position).add(this.roamDirection), dt)
    this.rig?.play('Walk')
    this.state = BobbaState.ROAMING
  }

  private stepFlee(dt: number): void {
    this.fleeRouteTimer -= dt
    if (this.fleeRouteTimer <= 0 || this.fleeDir.lengthSq() < 0.01) {
      this.fleeRouteTimer = randRange(1.2, 2.5)
      // Run directly away from the nearest character, jittered so it does
      // not sprint into the same corner every time.
      const near = this.acquireTarget()
      if (near) {
        this.fleeDir.copy(this.object.position).sub(near.position)
        this.fleeDir.y = 0
        this.fleeDir.normalize()
        const jitter = randRange(-0.6, 0.6)
        this.fleeDir.applyAxisAngle(_v2.set(0, 1, 0), jitter)
      } else {
        const a = Math.random() * Math.PI * 2
        this.fleeDir.set(Math.cos(a), 0, Math.sin(a))
      }
    }
    this.velocity.x = this.fleeDir.x * T.BOBBA_CHASE_SPEED
    this.velocity.z = this.fleeDir.z * T.BOBBA_CHASE_SPEED
    this.faceToward(_v2.copy(this.object.position).add(this.fleeDir), dt)
    this.rig?.play('Run')
    this.state = BobbaState.FLEEING
  }

  private startAttack(): void {
    this.attackLeft = T.BOBBA_ATTACK_LEN
    this.attackCooldown = T.BOBBA_ATTACK_LEN + randRange(0.7, 1.4)
    this.hasHitThisAttack = false
    this.isBlocking = false
    this.rig?.play('Attack', 0.1, 1, true)
    this.ctx.audio.play('bobba_roar', this.object.position, -6)
    this.state = BobbaState.ATTACKING
  }

  /** The fist connects only if the target is still inside reach. */
  private tryLandPunch(): void {
    const target = this.target
    if (!target || target.isDead) return
    _v1.copy(target.position).sub(this.object.position)
    _v1.y = 0
    if (_v1.length() > FIST_HIT_RANGE) return

    this.hasHitThisAttack = true
    _kb.copy(_v1).normalize().multiplyScalar(T.BOBBA_KNOCKBACK_FORCE)
    _kb.y = 0.3
    // Blunt force: `isFullyBlockable = false`, so a held shield only chips
    // it down (BLOCK_CHIP_MULT_BLUNT) and a parry is the only clean answer.
    const blocked = (target as { isBlocking?: boolean }).isBlocking === true
    target.takeHit(T.BOBBA_ATTACK_DAMAGE, _kb, blocked, this, false)
  }

  /**
   * Bobba raises its guard on a timer, not on a read — a 40% roll every
   * 1.5 s while a target is in reach.
   */
  private updateBlockDecision(dt: number): void {
    if (this.blockTimer > 0) {
      this.blockTimer -= dt
      if (this.blockTimer <= 0) this.isBlocking = false
      return
    }
    this.blockCheckCooldown -= dt
    if (this.blockCheckCooldown > 0) return
    this.blockCheckCooldown = T.BOBBA_BLOCK_CHECK_INTERVAL
    if (!this.target) return
    if (this.object.position.distanceTo(this.target.position) > T.BOBBA_ATTACK_DISTANCE * 2.5) return
    if (Math.random() < T.BOBBA_BLOCK_CHANCE) {
      this.isBlocking = true
      this.blockTimer = T.BOBBA_BLOCK_DURATION
    }
  }

  // ── Damage ──────────────────────────────────────────────────────────────

  /**
   * Sword hits. Anyone who HITS Bobba has revealed themselves, so the
   * attacker immediately becomes the tracked target regardless of light.
   */
  takeHit(damage: number, knockback: Vector3, _blocked = false, attacker?: unknown, _fullyBlockable = false): boolean {
    if (this.isDead) return false
    this.timeSinceDamage = 0

    // The shield eats part of the blow but never all of it.
    const dealt = this.isBlocking ? damage * 0.35 : damage
    this.healthComp.damageFlat(dealt)
    this.poise.takePoiseDamage(T.BOBBA_SWORD_POISE_DAMAGE)

    this.velocity.addScaledVector(_v1.set(knockback.x, 0, knockback.z), 0.35)
    this.ctx.hud.floatText(this.headPos(_v2), `-${Math.round(dealt)}`, this.isBlocking ? 0x88aaff : 0xffdd55)
    this.ctx.audio.play('hit_flesh', this.object.position, -4)

    const revealed = attacker as Combatant | undefined
    if (revealed && !revealed.isDead) this.target = revealed
    return true
  }

  /**
   * Arrows and DoT. Arrows barely scratch Bobba — the archer's job is to
   * TRAP it with fire, not to whittle it down.
   */
  takeDamagePct(pct: number, source: DamageSource = 'arrow'): void {
    if (this.isDead) return
    this.timeSinceDamage = 0
    // A direct arrow hit is worth a flat 1 HP — 50x less than a sword swing.
    // Ground fire keeps its full percentage bite, which is the whole point:
    // trap Bobba in the flames rather than shooting it down.
    const dealt = source === 'arrow' ? T.BOBBA_ARROW_DAMAGE : this.healthComp.maxHp * pct
    this.healthComp.damageFlat(dealt)
  }

  ignite(_duration: number): void {
    // Bobba does not catch fire — it flees from it. Panic is handled in the
    // step above; a burning Bobba would remove the reason to trap it.
  }

  private die(): void {
    if (this.isDead) return
    this.isDead = true
    this.state = BobbaState.DEAD
    this.velocity.set(0, 0, 0)
    this.rig?.play('Death', 0.15, 1, true)
    this.ctx.audio.play('death_thud', this.object.position, -2)
    this.ctx.hud.showLabel('BOBBA HAS FALLEN', 0xffd24d)
    if (this.hpLabel) this.hpLabel.visible = false
  }

  private updateHpLabel(): void {
    if (!this.hpLabel) return
    this.hpLabel.setText(`BOBBA  ${Math.max(0, Math.round(this.healthComp.currentHp))}/${this.healthComp.maxHp}`)
  }

  private faceToward(worldTarget: Vector3, dt: number): void {
    _v2.copy(worldTarget).sub(this.object.position)
    _v2.y = 0
    if (_v2.lengthSq() < 0.0001) return
    const targetYaw = Math.atan2(_v2.x, _v2.z)
    this.model.rotation.y = lerpAngle(this.model.rotation.y, targetYaw, T.BOBBA_ROTATION_SPEED * dt)
  }

  get modelObject(): Object3D {
    return this.model
  }
}
