/**
 * Port of player/player.gd — Douglass, the Keeper of Balance.
 *
 * The souls-like verb set lives here, and every rule is carried across with
 * its reasoning intact:
 *
 * - The character ALWAYS faces camera-forward. The mouse is the steering
 *   wheel, in and out of combat, so a swing can never come out backwards.
 * - Damage only ever happens on visible contact (the project's golden rule).
 *   The sword hitbox is the blade capsule on the hand bone, and the slash
 *   ribbon is drawn exactly while that capsule can hurt.
 * - A block SOFTENS a hit, it never erases it — only a timed parry cancels
 *   damage outright. Shields are best against clean weapon strikes; blunt
 *   force hurts through the guard.
 * - Roll i-frames start slightly after the roll and end before recovery, so
 *   the startup and tail stay punishable.
 * - Jumping is FLIGHT, not offense: an airborne paladin cannot swing at all,
 *   but takes half damage.
 */
import {
  type AnimationClip,
  type Bone,
  Group,
  type Object3D,
  Quaternion,
  Vector3,
} from 'three'
import { AnimRig } from '../core/anim'
import type { AssetLoader } from '../core/assets'
import { enableShadows } from '../core/assets'
import type { Combatant, GameContext } from '../core/context'
import type { Engine } from '../core/engine'
import { clampf, degToRad, lerpAngle, lerpf, moveToward, vecMoveToward, yawForward, yawRight } from '../core/gdmath'
import { moveAndSlide, type MoveResult } from '../core/physics'
import * as T from '../core/tuning'
import { AttackData, HealthComponent, StaminaComponent } from '../combat/components'
import { SlashTrail } from '../fx/effects'
import { composeBlockStances } from './block_stance'
import { Arrow } from './arrow'

export enum CharacterClass {
  PALADIN = 0,
  ARCHER = 1,
}

export enum CombatMode {
  UNARMED = 0,
  ARMED = 1,
}

/** Mixamo rigs face +Z, so the model sits half a turn off the camera yaw. */
const MODEL_FACING_OFFSET = Math.PI

const CAPSULE_RADIUS = 0.4
const CAPSULE_HEIGHT = 1.8
/** Blade capsule on the hand bone: radius 0.1, spanning 0.05..1.55 local +Z. */
const BLADE_NEAR = 0.05
const BLADE_FAR = 1.55
const BLADE_RADIUS = 0.1
/** Paladin's channelled rite: length and payoff. */
const CAST_DURATION = 2.2
const CAST_HEAL_PCT = 0.15

const _v1 = new Vector3()
const _v2 = new Vector3()
const _v3 = new Vector3()
const _fwd = new Vector3()
const _rt = new Vector3()
const _knock = new Vector3()
const _bladeRoot = new Vector3()
const _bladeTip = new Vector3()
const _handQuat = new Quaternion()

export class Player implements Combatant {
  readonly object = new Group()
  /** `_character_model` — rotates independently of the body, like Godot. */
  readonly modelHolder = new Group()

  characterClass: CharacterClass
  combatMode = CombatMode.ARMED

  readonly velocity = new Vector3()
  private readonly move: MoveResult = { onFloor: false, onCeiling: false, onWall: false }
  private onFloor = false

  // ── state flags, one per GDScript member ────────────────────────────────
  isDead = false
  isAttacking = false
  isBlocking = false
  isCasting = false
  isCrouching = false
  isRolling = false
  isParrying = false
  isDrinking = false
  isJumping = false
  isRunning = false
  isDrawingBow = false
  isHoldingBow = false

  private attackCooldown = 0
  private timeSinceAttackClick = 999
  private comboStep = 0
  private comboClicksBuffered = 0
  private attackInputBuffer = 0
  private attackAnimProgress = 0
  private hitboxActiveWindow = false
  private hasHitThisAttack = false
  private readonly attackLungeDir = new Vector3()
  private currentAttack: AttackData | null = null
  private readonly comboAttacks: AttackData[] = []

  private rollTimer = 0
  private readonly rollDir = new Vector3()
  private parryTimer = 0
  private drinkTimer = 0
  estusCharges = T.ESTUS_MAX_CHARGES

  private bowDrawTime = 0
  private bowLooseLock = 0

  private readonly knockbackVelocity = new Vector3()
  private isStunned = false
  private stunTimer = 0
  private spawnImmunityTimer = T.SPAWN_IMMUNITY_DURATION
  damageBuffPct = 0

  lockTarget: Combatant | null = null

  readonly healthComp: HealthComponent
  readonly stamina = new StaminaComponent()
  readonly trail = new SlashTrail()

  private rig: AnimRig | null = null
  private handBone: Bone | null = null
  private readonly arrows: Arrow[] = []
  /** Diagnostics for the headless smoke test. */
  shotsFired = 0

  private constructor(
    private readonly ctx: GameContext,
    private readonly engine: Engine,
    characterClass: CharacterClass,
  ) {
    this.characterClass = characterClass
    this.healthComp = new HealthComponent(
      characterClass === CharacterClass.PALADIN ? T.PALADIN_MAX_HP : T.ARCHER_MAX_HP,
    )
    this.object.add(this.modelHolder)
    ctx.scene.add(this.object)
    ctx.scene.add(this.trail.mesh)
    ctx.groups.add('player', this)

    this.healthComp.died.connect(() => this.onDeath())
    this.healthComp.damaged.connect((amount) => {
      this.ctx.hud.floatText(this.headPos(_v1), `-${Math.round(amount)}`, 0xff5544)
      this.ctx.hud.flashDamage()
    })
  }

  static async create(
    ctx: GameContext,
    engine: Engine,
    assets: AssetLoader,
    characterClass: CharacterClass,
  ): Promise<Player> {
    const player = new Player(ctx, engine, characterClass)
    await player.loadModel(assets)
    return player
  }

  private async loadModel(assets: AssetLoader): Promise<void> {
    const url =
      this.characterClass === CharacterClass.PALADIN
        ? '/assets/characters/paladin.glb'
        : '/assets/characters/archer.glb'
    const model = await assets.instance(url)
    enableShadows(model.scene)
    this.modelHolder.add(model.scene)
    this.modelHolder.rotation.y = MODEL_FACING_OFFSET

    // The Block twins the packs don't ship (BlockWalk, BlockHold, ...).
    const clips: Map<string, AnimationClip> = new Map(model.clips)
    composeBlockStances(clips)

    this.rig = new AnimRig(model.scene, clips)
    this.rig.play('Idle')

    model.scene.traverse((o) => {
      if ((o as Bone).isBone && o.name.endsWith('RightHand')) this.handBone = o as Bone
    })
  }

  // ── Combatant surface ───────────────────────────────────────────────────

  get position(): Vector3 {
    return this.object.position
  }

  get maxHealth(): number {
    return this.healthComp.maxHp
  }

  get currentHealth(): number {
    return this.healthComp.currentHp
  }

  /** Combatant surface: enemies and the HUD read a plain number here. */
  get health(): number {
    return this.healthComp.currentHp
  }

  get displayName(): string {
    return this.isPaladin() ? 'Paladin' : 'Archer'
  }

  getFacingRotation(): number {
    return this.modelHolder.rotation.y
  }

  isPaladin(): boolean {
    return this.characterClass === CharacterClass.PALADIN
  }

  isArcher(): boolean {
    return this.characterClass === CharacterClass.ARCHER
  }

  isSpawnImmune(): boolean {
    return this.spawnImmunityTimer > 0
  }

  private headPos(out: Vector3): Vector3 {
    return out.copy(this.object.position).add(_v3.set(0, 2.3, 0))
  }

  // ── Input (port of _input) ──────────────────────────────────────────────

  handleInput(): void {
    const input = this.ctx.input

    // Mouse look. The character's facing follows this every frame, so the
    // mouse steers the body as much as the camera.
    if (input.pointerLocked && (input.mouseDx !== 0 || input.mouseDy !== 0)) {
      this.engine.cameraRotation.x -= input.mouseDx * T.MOUSE_SENSITIVITY
      this.engine.cameraRotation.y -= input.mouseDy * T.MOUSE_SENSITIVITY
      this.engine.syncPivotRotation()
    }

    if (this.isDead) return

    if (input.isActionJustPressed('lock_on')) this.toggleLockOn()
    if (input.isActionJustPressed('dodge')) this.tryDodge()
    if (input.isActionJustPressed('parry')) this.tryParry()
    if (input.isActionJustPressed('estus')) this.tryEstus()
    if (input.isActionJustPressed('spell_cast')) this.doSpellCast()

    if (this.characterClass === CharacterClass.ARCHER) {
      // Bow: press to draw, release to loose.
      if (input.isActionJustPressed('attack')) this.startBowDraw()
      else if (input.isActionJustReleased('attack')) this.releaseBow()
    } else if (input.isActionJustPressed('attack')) {
      this.doAttack()
    }
  }

  // ── Main step (port of _physics_process) ────────────────────────────────

  update(dt: number): void {
    if (this.attackCooldown > 0) this.attackCooldown -= dt
    this.timeSinceAttackClick += dt

    // Advance the parry attempt — active frames, then recovery, then done.
    if (this.isParrying) {
      this.parryTimer += dt
      if (this.parryTimer >= T.PARRY_TOTAL) this.isParrying = false
    }

    this.updateCast(dt)

    // The estus channel: the heal lands only when the timer empties.
    if (this.isDrinking) {
      this.drinkTimer -= dt
      if (this.drinkTimer <= 0) this.finishEstus()
    }

    this.updateBlockState()
    this.stamina.blocking = this.isBlocking
    this.stamina.update(dt)

    if (this.spawnImmunityTimer > 0) this.spawnImmunityTimer -= dt
    this.updateAttackHitboxTiming()
    this.updateBowDraw(dt)

    // Fire a buffered attack tap the moment a swing becomes legal — a tap
    // eaten during recovery is the single biggest "controls feel dead" cause.
    if (this.attackInputBuffer > 0) {
      this.attackInputBuffer -= dt
      if (
        this.attackInputBuffer > 0 &&
        !this.isAttacking &&
        this.attackCooldown <= 0 &&
        !(this.isRolling || this.isParrying || this.isDrinking || this.isDead)
      ) {
        this.attackInputBuffer = 0
        this.doAttack()
      }
    }

    // Crouch: held stance — slower, braced (25% less damage), body lowered.
    this.isCrouching = !this.isDead && this.ctx.input.isActionPressed('crouch')
    this.modelHolder.scale.y = lerpf(this.modelHolder.scale.y, this.isCrouching ? 0.74 : 1.0, 12 * dt)

    // The loose burst borrows the body only briefly; then locomotion gets it
    // back even though the (long) source clip keeps running underneath.
    if (this.bowLooseLock > 0) {
      this.bowLooseLock -= dt
      if (this.bowLooseLock <= 0 && this.isArcher() && this.isAttacking) this.isAttacking = false
    }

    for (let i = this.arrows.length - 1; i >= 0; i--) {
      this.arrows[i].update(dt)
      if (this.arrows[i].dead) this.arrows.splice(i, 1)
    }

    if (this.isDead) {
      this.velocity.x = 0
      this.velocity.z = 0
      this.velocity.y -= T.GRAVITY * dt
      moveAndSlide(this.ctx.world, this.object.position, this.velocity, CAPSULE_RADIUS, CAPSULE_HEIGHT, dt, this.move)
      this.rig?.update(dt)
      return
    }

    // Stun / knockback: a shove has to carry the player clear of reach.
    if (this.isStunned) {
      this.stunTimer -= dt
      this.velocity.x = this.knockbackVelocity.x
      this.velocity.z = this.knockbackVelocity.z
      this.velocity.y -= T.GRAVITY * dt
      vecMoveToward(this.knockbackVelocity, _v1.set(0, 0, 0), 12 * dt)
      if (this.stunTimer <= 0) {
        this.isStunned = false
        this.knockbackVelocity.set(0, 0, 0)
      }
      this.applyMove(dt)
      this.rig?.update(dt)
      return
    }

    // Gamepad camera stick.
    const look = this.ctx.input.padLook
    if (Math.abs(look.x) > 0.01 || Math.abs(look.y) > 0.01) {
      this.engine.cameraRotation.x -= look.x * T.GAMEPAD_SENSITIVITY * dt
      this.engine.cameraRotation.y -= look.y * T.GAMEPAD_SENSITIVITY * dt
      this.engine.syncPivotRotation()
    }

    // Lock-on steers the camera onto the target, overriding mouse/stick look.
    this.updateLockOn(dt)
    this.updateAimZoom(dt)

    if (this.ctx.input.isActionPressed('reset_position') || this.object.position.y < -12) {
      this.spawnAtTower()
    }

    this.velocity.y -= T.GRAVITY * dt

    // ── Jump ──
    if (this.onFloor) {
      if (this.isJumping) this.isJumping = false
      if (
        this.ctx.input.isActionJustPressed('jump') &&
        !this.isAttacking &&
        !this.isRolling
      ) {
        this.velocity.y = T.JUMP_VELOCITY
        this.isJumping = true
        this.ctx.audio.play('jump', this.object.position, -3)
        // Directional leap: holding a movement direction turns "press Space"
        // into a horizontal dodge, not just a platformer hop.
        const raw = this.ctx.input.getVector()
        if (Math.hypot(raw.x, raw.y) > 0.15) {
          const len = Math.hypot(raw.x, raw.y)
          const nx = raw.x / len
          const ny = raw.y / len
          const camYaw = this.engine.cameraPivot.rotation.y
          yawForward(camYaw, _fwd)
          yawRight(camYaw, _rt)
          _v1.copy(_fwd).multiplyScalar(-ny).addScaledVector(_rt, nx).normalize()
          this.velocity.x = _v1.x * T.JUMP_FORWARD_BOOST
          this.velocity.z = _v1.z * T.JUMP_FORWARD_BOOST
        }
      }
    }

    // ── Movement input ──
    const raw = this.ctx.input.getVector()
    let inX = raw.x
    let inY = raw.y
    if (this.isCrouching) {
      inX *= T.CROUCH_SPEED_MULT
      inY *= T.CROUCH_SPEED_MULT
    }
    const rawLen = Math.hypot(inX, inY)

    // Run state: Shift on keyboard, >60% stick intensity on a pad.
    this.isRunning = this.ctx.input.isActionPressed('run') || (this.ctx.input.padActive && rawLen > T.RUN_THRESHOLD)

    const maxSpeed = this.isRunning ? T.RUN_SPEED : T.WALK_SPEED
    let dirX = inX
    let dirY = inY
    if (rawLen > 0.1) {
      dirX /= rawLen
      dirY /= rawLen
    }
    // Attacking, parrying and drinking all bleed movement speed.
    if (this.isAttacking) {
      dirX *= 0.3
      dirY *= 0.3
    } else if (this.isParrying || this.isDrinking) {
      dirX *= 0.25
      dirY *= 0.25
    }

    const camYaw = this.engine.cameraPivot.rotation.y
    yawForward(camYaw, _fwd)
    yawRight(camYaw, _rt)
    const moveDir = _v1.copy(_fwd).multiplyScalar(-dirY).addScaledVector(_rt, dirX)
    if (moveDir.lengthSq() > 0) moveDir.normalize()
    const hasMoveInput = Math.hypot(dirX, dirY) > 0.1

    const horizontal = _v2.set(this.velocity.x, 0, this.velocity.z)

    if (this.isRolling) {
      // A committed dash along the locked direction with an ease-out;
      // movement input is ignored for the duration.
      this.rollTimer -= dt
      const rollT = clampf(this.rollTimer / T.ROLL_DURATION, 0, 1)
      horizontal.copy(this.rollDir).multiplyScalar(T.ROLL_SPEED * (0.25 + 0.75 * rollT))
      if (this.rollTimer <= 0) this.isRolling = false
    } else if (this.isAttacking && this.onFloor && this.combatMode === CombatMode.ARMED && this.isPaladin()) {
      // Combo lunge: the swing carries the character forward. This is where
      // the sword's extra reach lives — the blade still has to connect.
      const lungeT = clampf(1 - this.attackAnimProgress / 0.55, 0, 1)
      horizontal.copy(this.attackLungeDir).multiplyScalar(T.COMBO_LUNGE_SPEED[this.comboStep] * lungeT)
    } else if (this.onFloor) {
      if (hasMoveInput) vecMoveToward(horizontal, _v3.copy(moveDir).multiplyScalar(maxSpeed), T.ACCEL * dt)
      else vecMoveToward(horizontal, _v3.set(0, 0, 0), T.DEACCEL * dt)
    } else if (hasMoveInput) {
      horizontal.addScaledVector(moveDir, T.ACCEL * 0.3 * dt)
      if (horizontal.length() > maxSpeed) horizontal.setLength(maxSpeed)
    }

    // ── Facing ──
    // The character ALWAYS faces camera-forward; locked-on swings square up
    // to the target instead, so the paladin can never swing away from what
    // the player is looking at.
    let targetRot = camYaw + MODEL_FACING_OFFSET
    if (this.isAttacking && this.lockTarget && this.attackLungeDir.lengthSq() > 0.01) {
      targetRot = Math.atan2(this.attackLungeDir.x, this.attackLungeDir.z)
    }
    this.modelHolder.rotation.y = lerpAngle(this.modelHolder.rotation.y, targetRot, 12 * dt)

    this.velocity.x = horizontal.x
    this.velocity.z = horizontal.z
    this.applyMove(dt)

    this.updateAnimation(dirX, dirY)
    this.updateTrail()
    this.rig?.update(dt)
  }

  private applyMove(dt: number): void {
    moveAndSlide(this.ctx.world, this.object.position, this.velocity, CAPSULE_RADIUS, CAPSULE_HEIGHT, dt, this.move)
    this.onFloor = this.move.onFloor
  }

  isOnFloor(): boolean {
    return this.onFloor
  }

  /**
   * Guard state is reconciled against the real button every frame rather
   * than edge-driven: any missed release (focus change, touch cancel, an
   * analog trigger snapping back) used to pin the shield up for good.
   */
  private updateBlockState(): void {
    if (this.isParrying || this.isDead) {
      this.isBlocking = false
      return
    }
    this.isBlocking = this.ctx.input.isActionPressed('block')
  }

  /**
   * Archer aim zoom: drawing eases the camera in over the shoulder and
   * narrows the FOV. Only for a PLANTED archer — moving cancels it, because
   * this asset has no aim-walk stance behind a moving draw.
   */
  private updateAimZoom(dt: number): void {
    const aiming =
      this.isArcher() &&
      (this.isDrawingBow || this.isHoldingBow) &&
      this.onFloor &&
      Math.hypot(this.velocity.x, this.velocity.z) < 0.8
    this.engine.springLength = lerpf(
      this.engine.springLength,
      aiming ? T.AIM_ZOOM_SPRING : T.DEFAULT_SPRING_LENGTH,
      10 * dt,
    )
    this.engine.camera.fov = lerpf(this.engine.camera.fov, aiming ? T.AIM_ZOOM_FOV : T.DEFAULT_CAMERA_FOV, 10 * dt)
    this.engine.camera.updateProjectionMatrix()
  }

  // ── Lock-on ─────────────────────────────────────────────────────────────

  private toggleLockOn(): void {
    if (this.lockTarget) this.dropLockOn()
    else this.acquireLockTarget()
  }

  /**
   * Pick the enemy best aligned with where the camera already points, within
   * range and inside the acquire cone: what you're looking at first, then
   * proximity.
   */
  private acquireLockTarget(): void {
    const candidates = [
      ...this.ctx.groups.get<Combatant>('bobba'),
      ...this.ctx.groups.get<Combatant>('skeletons'),
    ]
    this.engine.camera.getWorldDirection(_fwd)
    const halfCos = Math.cos(degToRad(T.LOCK_ON_ACQUIRE_HALF_ANGLE))
    let best: Combatant | null = null
    let bestScore = -Infinity
    for (const c of candidates) {
      if (c === (this as unknown as Combatant) || c.isDead) continue
      _v1.copy(c.position).sub(this.object.position)
      const dist = _v1.length()
      if (dist < 0.1 || dist > T.LOCK_ON_RANGE) continue
      const aim = _v1.divideScalar(dist).dot(_fwd)
      if (aim < halfCos) continue
      const score = aim - dist * 0.02
      if (score > bestScore) {
        bestScore = score
        best = c
      }
    }
    if (best) this.lockTarget = best
  }

  private dropLockOn(): void {
    this.lockTarget = null
  }

  private updateLockOn(dt: number): void {
    const target = this.lockTarget
    if (!target) return
    if (target.isDead || this.object.position.distanceTo(target.position) > T.LOCK_ON_BREAK_RANGE) {
      this.dropLockOn()
      return
    }
    // Steer the camera to face the target. atan2(-x, -z) matches the yaw
    // convention the movement code uses.
    _v1.copy(target.position).sub(this.engine.cameraPivot.position)
    _v1.y = 0
    if (_v1.length() < 0.05) return
    const desiredYaw = Math.atan2(-_v1.x, -_v1.z)
    this.engine.cameraRotation.x = lerpAngle(this.engine.cameraRotation.x, desiredYaw, T.LOCK_ON_TURN_SPEED * dt)
    this.engine.cameraRotation.y = lerpAngle(
      this.engine.cameraRotation.y,
      degToRad(T.LOCK_ON_PITCH_DEG),
      T.LOCK_ON_TURN_SPEED * dt,
    )
    this.engine.syncPivotRotation()
  }

  // ── Dodge roll ──────────────────────────────────────────────────────────

  private tryDodge(): void {
    if (
      this.isRolling || this.isAttacking || this.isStunned || this.isCasting ||
      this.isParrying || this.isDrinking || this.isDead
    ) return
    if (this.isDrawingBow || this.isHoldingBow) return
    if (!this.onFloor) return
    // A roll you can't afford simply doesn't happen.
    if (!this.stamina.trySpend(T.ROLL_STAMINA_COST)) return

    const raw = this.ctx.input.getVector()
    const camYaw = this.engine.cameraPivot.rotation.y
    yawForward(camYaw, _fwd)
    yawRight(camYaw, _rt)
    let animKey = 'DodgeB'
    const len = Math.hypot(raw.x, raw.y)
    if (len > 0.15) {
      const nx = raw.x / len
      const ny = raw.y / len
      this.rollDir.copy(_fwd).multiplyScalar(-ny).addScaledVector(_rt, nx).normalize()
      if (Math.abs(ny) >= Math.abs(nx)) animKey = ny < 0 ? 'DodgeF' : 'DodgeB'
      else animKey = nx < 0 ? 'DodgeL' : 'DodgeR'
    } else {
      this.rollDir.copy(_fwd).negate() // backstep away from the camera facing
    }

    this.isRolling = true
    this.rollTimer = T.ROLL_DURATION
    this.ctx.audio.play('roll', this.object.position, -8)
    this.rig?.play(animKey, 0.08, 1, true)
  }

  // ── Parry ───────────────────────────────────────────────────────────────

  /**
   * Paladin (shield) only — the archer's evasion verbs are the roll and the
   * jump. The shield flick is the Block clip played fast; deflect frames and
   * recovery are tracked by `parryTimer`.
   */
  private tryParry(): void {
    if (!this.isPaladin() || this.combatMode !== CombatMode.ARMED) return
    if (
      this.isParrying || this.isAttacking || this.isRolling || this.isStunned ||
      this.isCasting || this.isDrinking || this.isDead
    ) return
    if (!this.onFloor) return
    if (!this.stamina.trySpend(T.PARRY_STAMINA_COST)) return

    this.isParrying = true
    this.parryTimer = 0
    this.isBlocking = false // parry replaces any held block for its duration
    this.rig?.play('Block', 0.05, 2.2, true)
  }

  // ── Estus ───────────────────────────────────────────────────────────────

  /**
   * The charge is consumed up front; the heal lands only if the channel
   * completes uninterrupted. Healing in melee range is a gamble, as the
   * genre demands.
   */
  private tryEstus(): void {
    if (
      this.isDrinking || this.isAttacking || this.isRolling || this.isParrying ||
      this.isStunned || this.isCasting || this.isDead
    ) return
    if (this.isDrawingBow || this.isHoldingBow) return
    if (this.estusCharges <= 0) {
      this.ctx.hud.showLabel('No estus!')
      return
    }
    if (this.healthComp.currentHp >= this.healthComp.maxHp) return

    this.estusCharges--
    this.isDrinking = true
    this.drinkTimer = T.ESTUS_DRINK_DURATION
    this.ctx.audio.play('estus_drink', this.object.position, -6)
    this.rig?.play('Estus', 0.12, 1, true)
  }

  private finishEstus(): void {
    this.isDrinking = false
    this.healthComp.healPct(T.ESTUS_HEAL_PCT)
    this.ctx.hud.floatText(
      this.headPos(_v1),
      `+${Math.round(this.healthComp.maxHp * T.ESTUS_HEAL_PCT)} HP`,
      0x33ff59,
    )
  }

  // ── Melee ───────────────────────────────────────────────────────────────

  private doAttack(): void {
    if (this.isRolling || this.isParrying || this.isDrinking || this.isDead) return
    // Jumping is FLIGHT, not offense: an airborne paladin cannot swing at
    // all. Leaping away halves incoming damage but buys zero attack.
    if (this.isPaladin() && !this.onFloor) return

    // Only FAST consecutive clicks bank combo steps. A slow click mid-swing
    // does nothing — the chain is a deliberate triple-click.
    const clickGap = this.timeSinceAttackClick
    this.timeSinceAttackClick = 0

    if (this.isAttacking) {
      if (
        this.isPaladin() &&
        this.combatMode === CombatMode.ARMED &&
        clickGap <= T.COMBO_CLICK_WINDOW &&
        this.comboStep + this.comboClicksBuffered < T.COMBO_ANIMS.length - 1
      ) {
        this.comboClicksBuffered++
      } else {
        this.attackInputBuffer = T.ATTACK_BUFFER_TIME
      }
      return
    }

    if (this.attackCooldown > 0) {
      this.attackInputBuffer = T.ATTACK_BUFFER_TIME
      return
    }

    if (this.isPaladin() && this.combatMode === CombatMode.ARMED) {
      this.comboClicksBuffered = 0
      this.startComboSwing(0)
    }
  }

  /**
   * Kick off combo step `step`. Pays stamina, re-arms the hitbox (each chain
   * step may land its own hit) and starts the clip at combo speed.
   */
  private startComboSwing(step: number): boolean {
    const animName = T.COMBO_ANIMS[step]
    if (!this.rig?.has(animName)) return false
    const cost = step === 0 ? T.SWORD_STAMINA_COST : T.COMBO_CHAIN_STAMINA_COST
    if (!this.stamina.trySpend(cost)) return false

    this.comboStep = step
    this.currentAttack = this.getComboAttack(step)
    this.isAttacking = true
    this.enableAttackHitbox()
    this.rig.play(animName, 0.1, T.COMBO_ANIM_SPEEDS[step], true)
    this.ctx.audio.play(`sword_whoosh_${step + 1}`, this.object.position, -6)

    // Lunge along the locked target when locked, else straight ahead of the
    // camera — the character faces camera-forward, so the swing always goes
    // where the player is looking.
    if (this.lockTarget) {
      _v1.copy(this.lockTarget.position).sub(this.object.position)
      _v1.y = 0
      if (_v1.length() > 0.05) this.attackLungeDir.copy(_v1).normalize()
      else this.attackLungeDir.set(0, 0, 0)
    } else {
      yawForward(this.engine.cameraPivot.rotation.y, this.attackLungeDir)
    }

    this.trail.color.setHex(
      step === T.COMBO_ANIMS.length - 1 ? T.COMBO_TRAIL_COLOR_FINISHER : T.COMBO_TRAIL_COLOR,
    )
    return true
  }

  /** Damage escalates through the chain; the finisher hits hardest. */
  private getComboAttack(step: number): AttackData {
    if (this.comboAttacks.length === 0) {
      for (let i = 0; i < T.COMBO_ANIMS.length; i++) {
        const a = new AttackData()
        a.attackName = `KnightSwordCombo${i + 1}`
        a.damage = T.KNIGHT_SWORD_DAMAGE * T.COMBO_DAMAGE_MULT[i]
        a.poiseDamage = T.COMBO_POISE_DAMAGE[i]
        a.staminaCost = i === 0 ? T.SWORD_STAMINA_COST : T.COMBO_CHAIN_STAMINA_COST
        a.knockbackMagnitude = T.COMBO_KNOCKBACK[i]
        a.isFullyBlockable = true
        a.hitWindowStart = 0.15
        a.hitWindowEnd = 0.9
        this.comboAttacks.push(a)
      }
    }
    return this.comboAttacks[step]
  }

  private enableAttackHitbox(): void {
    this.hasHitThisAttack = false
    this.attackAnimProgress = 0
    this.hitboxActiveWindow = false
    this.bladeSegment(_bladeRoot, _bladeTip)
    this.trail.reset(_bladeRoot, _bladeTip)
  }

  private disableAttackHitbox(): void {
    this.hitboxActiveWindow = false
    this.attackAnimProgress = 0
  }

  /** World endpoints of the blade capsule hanging off the right hand bone. */
  private bladeSegment(root: Vector3, tip: Vector3): boolean {
    if (!this.handBone) {
      // Fallback: a blade length in front of the chest.
      yawForward(this.modelHolder.rotation.y + MODEL_FACING_OFFSET, _v3)
      root.copy(this.object.position).add(_v1.set(0, 1.2, 0)).addScaledVector(_v3, 0.3)
      tip.copy(root).addScaledVector(_v3, BLADE_FAR - BLADE_NEAR)
      return false
    }
    this.handBone.updateWorldMatrix(true, false)
    this.handBone.getWorldPosition(root)
    this.handBone.getWorldQuaternion(_handQuat)
    // The hitbox lies along the hand's local +Z, as in the Godot capsule.
    _v3.set(0, 0, 1).applyQuaternion(_handQuat)
    tip.copy(root).addScaledVector(_v3, BLADE_FAR)
    root.addScaledVector(_v3, BLADE_NEAR)
    return true
  }

  /**
   * Port of `_update_attack_hitbox_timing`: chain point, active window,
   * recovery cancel and the per-frame overlap scan, in that order.
   */
  private updateAttackHitboxTiming(): void {
    if (this.isArcher()) return // archers use projectiles, not melee hitboxes
    if (!this.isAttacking || !this.rig) {
      this.hitboxActiveWindow = false
      this.trail.emitting = false
      return
    }

    this.attackAnimProgress = this.rig.progress

    // A banked combo step cancels the recovery tail of the current swing.
    if (
      this.comboClicksBuffered > 0 &&
      this.combatMode === CombatMode.ARMED &&
      this.attackAnimProgress >= T.COMBO_CHAIN_POINT &&
      this.comboStep < T.COMBO_ANIMS.length - 1
    ) {
      this.comboClicksBuffered--
      if (this.startComboSwing(this.comboStep + 1)) return
      this.comboClicksBuffered = 0 // couldn't chain (winded) — drop the bank
    }

    const winStart = this.currentAttack?.hitWindowStart ?? T.SWORD_HITBOX_START
    const winEnd = this.currentAttack?.hitWindowEnd ?? T.SWORD_HITBOX_END
    this.hitboxActiveWindow = this.attackAnimProgress >= winStart && this.attackAnimProgress <= winEnd

    // RECOVERY CANCEL (souls rule): once the blade's active frames are done
    // and no chain is banked, MOVING ends the swing early. The heavy
    // finisher keeps its damage timing but stops imprisoning the player for
    // its whole tail.
    if (this.attackAnimProgress > T.COMBO_CHAIN_POINT && this.comboClicksBuffered === 0 && this.isPaladin()) {
      const mv = this.ctx.input.getVector()
      if (Math.hypot(mv.x, mv.y) > 0.4) {
        this.isAttacking = false
        this.disableAttackHitbox()
        this.attackCooldown =
          this.comboStep >= T.COMBO_ANIMS.length - 1 ? T.COMBO_FINISHER_COOLDOWN : 0.2
        this.comboStep = 0
        this.comboClicksBuffered = 0
        return
      }
    }

    // The swing ended on its own.
    if (this.rig.finished) {
      this.isAttacking = false
      this.disableAttackHitbox()
      this.attackCooldown =
        this.comboStep >= T.COMBO_ANIMS.length - 1 ? T.COMBO_FINISHER_COOLDOWN : 0.15
      this.comboStep = 0
      return
    }

    // The slash ribbon draws exactly while the blade can hurt — the visible
    // arc IS the hit volume's path (the golden rule made legible).
    this.trail.emitting = this.hitboxActiveWindow && this.combatMode === CombatMode.ARMED

    if (this.hitboxActiveWindow && !this.hasHitThisAttack) this.scanForHits()
  }

  private updateTrail(): void {
    if (this.trail.emitting) {
      this.bladeSegment(_bladeRoot, _bladeTip)
      this.trail.push(_bladeRoot, _bladeTip)
    }
    this.trail.update()
  }

  /** Blade-capsule overlap test against every live enemy. */
  private scanForHits(): void {
    this.bladeSegment(_bladeRoot, _bladeTip)
    const segDir = _v1.copy(_bladeTip).sub(_bladeRoot)
    const segLen = segDir.length()
    if (segLen < 1e-4) return
    segDir.divideScalar(segLen)

    for (const group of ['bobba', 'skeletons'] as const) {
      for (const enemy of this.ctx.groups.get<Combatant>(group)) {
        if (enemy.isDead) continue
        // Enemy body as a vertical capsule at its origin.
        _v2.copy(enemy.position).add(_v3.set(0, 0.95, 0))
        const along = clampf(_v3.copy(_v2).sub(_bladeRoot).dot(segDir), 0, segLen)
        _v3.copy(_bladeRoot).addScaledVector(segDir, along)
        if (_v3.distanceTo(_v2) > BLADE_RADIUS + 0.55) continue
        this.onBladeHit(enemy, _v3)
        if (this.hasHitThisAttack) return
      }
    }
  }

  /** Port of `_on_attack_hitbox_body_entered`. */
  private onBladeHit(enemy: Combatant, contact: Vector3): void {
    if (this.isPaladin() && !this.onFloor) return // belt-and-braces no-swing rule
    this.hasHitThisAttack = true

    _knock.copy(enemy.position).sub(this.object.position).normalize()
    _knock.y = 0.2

    let damage = T.PLAYER_ATTACK_DAMAGE
    let fullyBlockable = false

    if (this.isPaladin() && this.combatMode === CombatMode.ARMED) {
      // Positional/stateful crits. Both require the blade to have visually
      // connected (we are inside the contact path), so the golden rule
      // holds — the crit only changes how much the contact hurts.
      let critMult = 1
      let critLabel = ''
      if (enemy.isRiposteReady?.()) {
        critMult = T.RIPOSTE_DAMAGE_MULT
        critLabel = 'RIPOSTE!'
        enemy.consumeRiposte?.()
      } else if (this.isBehindTarget(enemy)) {
        critMult = T.BACKSTAB_DAMAGE_MULT
        critLabel = 'BACKSTAB!'
      }

      const atk = this.currentAttack ?? this.getComboAttack(0)
      const stepMult = this.currentAttack ? T.COMBO_DAMAGE_MULT[this.comboStep] : 1
      atk.damage =
        T.KNIGHT_SWORD_DAMAGE * stepMult * (1 + clampf(this.damageBuffPct, 0, T.DAMAGE_BUFF_MAX_PCT)) * critMult
      damage = atk.damage
      fullyBlockable = atk.isFullyBlockable

      if (critLabel) this.ctx.hud.showLabel(critLabel, 0xffd24d)
      _knock.multiplyScalar(atk.knockbackMagnitude)
      enemy.takeHit(damage, _knock, false, this, fullyBlockable)
    } else {
      _knock.multiplyScalar(T.PLAYER_KNOCKBACK_FORCE)
      enemy.takeHit(damage, _knock, false, this, fullyBlockable)
    }

    this.ctx.fx.spawnHitSpark(contact, 0xffd973)
    this.ctx.audio.play(this.combatMode === CombatMode.ARMED ? 'hit_metal' : 'hit_flesh', contact, -4)
  }

  /**
   * True when this player stands inside `enemy`'s rear cone. Uses the same
   * facing convention the enemies use: model yaw θ means forward (sinθ, cosθ).
   */
  private isBehindTarget(enemy: Combatant): boolean {
    if (!enemy.getFacingRotation) return false
    const facing = enemy.getFacingRotation()
    _v1.set(Math.sin(facing), 0, Math.cos(facing))
    _v2.copy(this.object.position).sub(enemy.position)
    _v2.y = 0
    if (_v2.length() < 0.01) return false
    return _v1.dot(_v2.normalize()) < T.BACKSTAB_CONE_DOT
  }

  // ── Bow ─────────────────────────────────────────────────────────────────

  private startBowDraw(): void {
    if (!this.isArcher()) return
    if (this.isRolling || this.isDrinking || this.isDead || this.isStunned) return
    if (this.isDrawingBow || this.isHoldingBow) return
    this.isDrawingBow = true
    this.bowDrawTime = 0
    this.isAttacking = true
    this.rig?.play('Attack', 0.1, 3.0, true) // BOW_DRAW_ANIM_SPEED
  }

  private updateBowDraw(dt: number): void {
    if (!this.isDrawingBow) return
    this.bowDrawTime += dt
    if (this.bowDrawTime >= T.BOW_DRAW_TIME_REQUIRED && !this.isHoldingBow) {
      this.isHoldingBow = true
      // Hold on the drawn pose rather than running on into the loose.
      this.rig?.seek(0.9) // BOW_DRAW_POSE_TIME
      this.rig?.setSpeed(0)
    }
  }

  private releaseBow(): void {
    if (!this.isDrawingBow && !this.isHoldingBow) return
    const drawn = this.isHoldingBow
    this.isDrawingBow = false
    this.isHoldingBow = false

    if (!drawn) {
      // Released before the string was back: no shot, just drop the draw.
      this.isAttacking = false
      this.rig?.setSpeed(1)
      return
    }

    // The loose lives in the last part of the (long) source clip.
    this.rig?.seekRatio(0.85) // BOW_LOOSE_TAIL
    this.rig?.setSpeed(1.4) // BOW_LOOSE_SPEED
    this.bowLooseLock = T.BOW_LOOSE_LOCK

    this.shootArrow()
  }

  private shootArrow(): void {
    // Fire from the bow hand, along the camera's aim.
    this.engine.camera.getWorldDirection(_fwd)
    _v1.copy(this.object.position).add(_v2.set(0, 1.5, 0)).addScaledVector(_fwd, 0.5)

    const arrow = new Arrow(this.ctx, this, _v1, _fwd)
    // A loose on the move has no planted stance behind it: half force, and
    // the damage scales with it.
    const moving = Math.hypot(this.velocity.x, this.velocity.z) > 0.8
    arrow.airborneShot = !this.onFloor || moving
    if (arrow.airborneShot) {
      arrow.shotPower = 0.5
      arrow.velocity.multiplyScalar(0.5)
    }
    this.arrows.push(arrow)
    this.shotsFired++
    this.ctx.audio.play('bow_release', this.object.position, -4)
  }

  // ── Spell ───────────────────────────────────────────────────────────────

  /**
   * The paladin's lightning rite demands calm: it cannot be STARTED in
   * direct combat — a live enemy within melee reach, or a hit taken moments
   * ago — and a landed hit shatters it.
   */
  private doSpellCast(): void {
    if (this.isPaladin() && this.combatMode !== CombatMode.ARMED) return
    if (this.isPaladin()) {
      if (this.ctx.now - this.lastDamageAt < 2.5) {
        this.ctx.hud.showLabel('TOO HURT TO FOCUS')
        return
      }
      if (this.nearestCombatThreatDist() < 8) {
        this.ctx.hud.showLabel('IN COMBAT!')
        return
      }
    }
    if (
      this.isCasting || this.isAttacking || this.attackCooldown > 0 ||
      this.isParrying || this.isDrinking || this.isDead
    ) return
    if (this.isDrawingBow || this.isHoldingBow) return
    if (!this.rig?.has('SpellCast')) return

    this.isCasting = true
    this.castTimer = CAST_DURATION
    this.rig.play('SpellCast', 0.15, 1, true)
    this.ctx.audio.play('parry_ring', this.object.position, -8)
  }

  /**
   * The rite is a channel, ticked on the fixed step like everything else —
   * a wall-clock timer would keep running through a hit that broke it.
   */
  private updateCast(dt: number): void {
    if (!this.isCasting) return
    this.castTimer -= dt
    if (this.castTimer > 0) return
    this.isCasting = false
    this.healthComp.healPct(CAST_HEAL_PCT)
    this.ctx.hud.floatText(this.headPos(_v1), 'RITE COMPLETE', 0x9fd0ff)
  }

  private lastDamageAt = -1000
  private castTimer = 0

  private nearestCombatThreatDist(): number {
    let best = Infinity
    for (const group of ['bobba', 'skeletons'] as const) {
      for (const e of this.ctx.groups.get<Combatant>(group)) {
        if (e.isDead) continue
        best = Math.min(best, this.object.position.distanceTo(e.position))
      }
    }
    return best
  }

  private interruptSpell(): void {
    this.lastDamageAt = this.ctx.now
    if (this.isCasting) {
      this.isCasting = false
      this.ctx.hud.showLabel('SPELL BROKEN')
    }
  }

  // ── Taking hits (port of take_hit) ──────────────────────────────────────

  /**
   * Returns true when the hit actually connected (damage/knockback applied,
   * even if chip-reduced by a block) and false when the defender negated it
   * outright — roll i-frames, spawn immunity, timed parry — so the attacker
   * can confirm its hit honestly instead of assuming contact always counts.
   */
  takeHit(
    damage: number,
    knockback: Vector3,
    blocked: boolean,
    attacker: unknown,
    isFullyBlockable = false,
  ): boolean {
    if (this.isDead) return false

    // Roll i-frames: a hit inside the invulnerable window passes clean
    // through. Startup and recovery of the roll are still vulnerable.
    if (this.isRolling) {
      const elapsed = T.ROLL_DURATION - this.rollTimer
      if (elapsed >= T.ROLL_IFRAME_START && elapsed <= T.ROLL_IFRAME_END) return false
    }

    if (this.isSpawnImmune()) return false

    // Parry deflect: the enemy's hit visually connected while the shield
    // flick was in its active frames. Outside those frames (the parry's
    // recovery) this falls through to full, unblocked damage.
    const parryable = attacker as { onParried?: (by: unknown) => void } | null
    if (
      this.isParrying && parryable?.onParried &&
      this.parryTimer >= T.PARRY_WINDOW_START && this.parryTimer <= T.PARRY_WINDOW_END
    ) {
      this.ctx.hud.showLabel('PARRY!', 0xffd933)
      this.ctx.audio.play('parry_ring', this.object.position, -2)
      parryable.onParried(this)
      return false
    }

    // Airborne mitigation: jumping over a swing halves the damage. Stacks
    // with block, so a jumping block is nearly full mitigation.
    const airborneMult = this.onFloor ? 1 : T.AERIAL_DAMAGE_MULT
    let actual = damage * airborneMult

    if (blocked) {
      // The shield eats damage, not momentum — a blocked punch still shoves
      // the paladin back visibly. A block never erases a hit; chip always
      // gets through, and only a timed parry cancels one outright.
      this.knockbackVelocity.copy(knockback).multiplyScalar(T.PLAYER_KNOCKBACK_RESISTANCE)
      const chip = isFullyBlockable ? T.BLOCK_CHIP_MULT_WEAPON : T.BLOCK_CHIP_MULT_BLUNT
      actual = damage * chip * airborneMult
      this.ctx.audio.play('block_chip', this.object.position, -4)
      this.interruptSpell()
    } else {
      this.knockbackVelocity.copy(knockback).multiplyScalar(T.PLAYER_KNOCKBACK_RESISTANCE)
      this.ctx.audio.play('hit_flesh', this.object.position, -3)
      this.interruptSpell()
      this.isStunned = true
      this.stunTimer = T.STUN_DURATION
      this.isAttacking = false // a clean hit cancels the attack
      this.comboStep = 0 // ...and breaks the combo chain
      this.comboClicksBuffered = 0
      this.isParrying = false // recovery punish
      if (this.isDrinking) {
        // The charge was spent when the drink started; the heal is lost.
        this.isDrinking = false
        this.ctx.hud.showLabel('Estus lost!')
      }
      this.rig?.play('ReactHit', 0.08, 1, true)
    }

    // Crouching braces for impact — 25% off everything that lands.
    if (this.isCrouching) actual *= T.CROUCH_DAMAGE_MULT

    if (actual > 0) this.healthComp.damageFlat(actual)
    return true
  }

  takeDamagePct(pct: number): void {
    if (this.isSpawnImmune() || this.isDead) return
    this.healthComp.damagePct(pct)
  }

  private onDeath(): void {
    if (this.isDead) return
    this.isDead = true
    this.isAttacking = false
    this.isBlocking = false
    this.velocity.set(0, 0, 0)
    this.ctx.audio.play('death_thud', this.object.position, -4)
    this.rig?.play('Death', 0.15, 1, true)
    this.ctx.hud.showLabel('YOU DIED', 0xaa1111)
  }

  /** Respawn at the tower with full kit — matches `_respawn` in player.gd. */
  respawn(): void {
    const [x, y, z] = T.SPAWN_POINTS[0]
    this.object.position.set(x, y, z)
    const ground = this.ctx.world.groundHeight(x, z)
    if (ground !== null) this.object.position.y = ground + 0.1
    this.velocity.set(0, 0, 0)
    this.isDead = false
    this.isStunned = false
    this.isRolling = false
    this.isParrying = false
    this.isDrinking = false
    this.isAttacking = false
    this.comboStep = 0
    this.comboClicksBuffered = 0
    this.estusCharges = T.ESTUS_MAX_CHARGES
    this.healthComp.resetToFull()
    this.stamina.currentStamina = this.stamina.maxStamina
    this.spawnImmunityTimer = T.SPAWN_IMMUNITY_DURATION
    this.modelHolder.rotation.set(0, MODEL_FACING_OFFSET, 0)
    this.modelHolder.scale.set(1, 1, 1)
    this.rig?.play('Idle', 0.1, 1, true)
  }

  private spawnAtTower(): void {
    const [x, , z] = T.SPAWN_POINTS[0]
    const ground = this.ctx.world.groundHeight(x, z) ?? 1
    this.object.position.set(x, ground + 0.2, z)
    this.velocity.set(0, 0, 0)
  }

  // ── Mode / class ────────────────────────────────────────────────────────

  // NOTE: the Godot build also has an UNARMED mode (paladin_unarmed_v2.glb
  // plus its own boxing clips). This port bakes only the ARMED set, so the
  // mode stays ARMED rather than shipping a state in which the player cannot
  // attack at all. See the README's differences section.

  // ── Animation (port of _update_animation) ───────────────────────────────

  private updateAnimation(dirX: number, dirY: number): void {
    const rig = this.rig
    if (!rig) return

    // Action clips own the body while they run.
    if (this.isAttacking || this.isCasting || this.isRolling || this.isParrying || this.isDrinking) return

    const len = Math.hypot(dirX, dirY)

    // An aiming archer standing still holds the drawn pose; on the move the
    // pack's aim-locomotion keeps the bow up AND strides.
    if (this.isDrawingBow || this.isHoldingBow) {
      if (len < 0.15) return
      const aim = this.aimLocomotionAnim(dirX, dirY)
      if (aim) {
        rig.play(aim)
        return
      }
    }

    // Jump takes priority.
    if (!this.onFloor) {
      if (this.isJumping && rig.has('Jump')) rig.play('Jump')
      return
    }

    // Guard up does NOT stop the feet: the composed Block* clips keep the
    // stride while the upper body holds the guard.
    if (this.isBlocking) {
      const anim = this.blockStanceAnim(dirX, dirY)
      if (anim) rig.play(anim)
      return
    }

    let desired = ''
    if (Math.abs(dirX) > 0.5 && Math.abs(dirY) < 0.3) {
      // Run-strafes first when the rig has them, so circling an enemy at
      // speed doesn't play a walk cycle at a run.
      const side = dirX < 0 ? 'Left' : 'Right'
      desired = this.firstAnim([this.isRunning ? `RunStrafe${side}` : '', `Strafe${side}`, 'StrafeLeft', 'Walk'])
    } else if (dirY > 0.5 && Math.abs(dirX) < 0.5) {
      // Retreating. The character always faces camera-forward, so walking
      // backward on a forward stride moonwalks.
      desired = this.firstAnim([this.isRunning ? 'RunBack' : '', 'WalkBack', this.isRunning ? 'Run' : '', 'Walk'])
    } else if (this.isRunning && len > 0.1) {
      desired = this.firstAnim(['Run', 'Sprint', 'Walk'])
    } else if (len > 0.1) {
      desired = this.firstAnim(['Walk'])
    } else {
      desired = this.firstAnim(['Idle'])
    }
    if (desired) rig.play(desired)
  }

  private firstAnim(names: string[]): string {
    for (const n of names) {
      if (n && this.rig?.has(n)) return n
    }
    return ''
  }

  private blockStanceAnim(dirX: number, dirY: number): string {
    const candidates: string[] = []
    if (Math.hypot(dirX, dirY) > 0.1) {
      if (Math.abs(dirX) > 0.5 && Math.abs(dirY) < 0.3) {
        const side = dirX < 0 ? 'Left' : 'Right'
        if (this.isRunning) candidates.push(`BlockRunStrafe${side}`)
        candidates.push(`BlockStrafe${side}`)
      } else if (dirY > 0.5 && Math.abs(dirX) < 0.5) {
        // Shield up while backing off — the bread and butter of a souls
        // fight, and the one direction that used to moonwalk.
        if (this.isRunning) candidates.push('BlockRunBack')
        candidates.push('BlockWalkBack')
      }
      if (this.isRunning) candidates.push('BlockRun', 'BlockSprint')
      candidates.push('BlockWalk')
    }
    // Standing guard prefers the composed HOLD — the raw Block clip is a
    // raise-block-lower reaction that pumps when looped.
    candidates.push('BlockHold', 'Block')
    return this.firstAnim(candidates)
  }

  private aimLocomotionAnim(dirX: number, dirY: number): string {
    const candidates: string[] = []
    if (Math.abs(dirX) > 0.5 && Math.abs(dirY) < 0.3) {
      candidates.push(dirX < 0 ? 'AimStrafeLeft' : 'AimStrafeRight')
    } else if (dirY > 0.5) {
      candidates.push('AimWalkBack')
    }
    candidates.push('AimWalk')
    return this.firstAnim(candidates)
  }

  /** The camera pivot rides the player's head. */
  syncCameraPivot(): void {
    this.engine.cameraPivot.position.set(
      this.object.position.x,
      this.object.position.y + 1.5,
      this.object.position.z,
    )
  }

  /** Buff decay, matching `_update_damage_buff`. */
  updateDamageBuff(dt: number): void {
    this.damageBuffPct = moveToward(this.damageBuffPct, 0, 0.05 * dt)
  }

  get arrowsInFlight(): number {
    return this.arrows.length
  }

  get modelObject(): Object3D {
    return this.modelHolder
  }
}
