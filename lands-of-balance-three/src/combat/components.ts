/**
 * Ports of combat/health_component.gd, stamina_component.gd and
 * poise_component.gd — the three pools every fighter in the game runs on.
 *
 * Godot signals become plain callback arrays; everything else (including the
 * comments explaining *why* a rule exists) is carried over unchanged so the
 * two builds stay comparable.
 */
import * as T from '../core/tuning'

type Listener<A extends unknown[]> = (...args: A) => void

class Signal<A extends unknown[]> {
  private readonly listeners: Listener<A>[] = []
  connect(fn: Listener<A>): void {
    this.listeners.push(fn)
  }
  emit(...args: A): void {
    for (const fn of this.listeners) fn(...args)
  }
}

/** combat/health_component.gd */
export class HealthComponent {
  maxHp: number
  currentHp: number
  invulnerable = false

  readonly healthChanged = new Signal<[number, number]>()
  readonly damaged = new Signal<[number]>()
  readonly healed = new Signal<[number]>()
  readonly died = new Signal<[]>()

  constructor(maxHp: number) {
    this.maxHp = maxHp
    this.currentHp = maxHp
  }

  /** Deal a flat amount of damage (e.g. sword swings). */
  damageFlat(amount: number): void {
    if (this.invulnerable || amount <= 0 || this.currentHp <= 0) return
    const prev = this.currentHp
    this.currentHp = Math.max(0, this.currentHp - amount)
    this.damaged.emit(prev - this.currentHp)
    this.healthChanged.emit(this.currentHp, this.maxHp)
    if (this.currentHp <= 0) this.died.emit()
  }

  /** Damage as a fraction of max HP — `pct` is 0..1 (0.05 = 5%). */
  damagePct(pct: number): void {
    this.damageFlat(this.maxHp * pct)
  }

  healFlat(amount: number): void {
    if (amount <= 0 || this.currentHp <= 0) return
    const prev = this.currentHp
    this.currentHp = Math.min(this.maxHp, this.currentHp + amount)
    const actual = this.currentHp - prev
    if (actual > 0) {
      this.healed.emit(actual)
      this.healthChanged.emit(this.currentHp, this.maxHp)
    }
  }

  healPct(pct: number): void {
    this.healFlat(this.maxHp * pct)
  }

  resetToFull(): void {
    this.currentHp = this.maxHp
    this.healthChanged.emit(this.currentHp, this.maxHp)
  }

  isAlive(): boolean {
    return this.currentHp > 0
  }

  ratio(): number {
    return this.maxHp > 0 ? this.currentHp / this.maxHp : 0
  }
}

/**
 * combat/stamina_component.gd
 *
 * Every spend resets the recover timer, so repeated spending stops regen
 * entirely; holding the shield up cuts regen to `blockRegenModifier`.
 */
export class StaminaComponent {
  maxStamina = T.STAMINA_MAX
  recoverRate = T.STAMINA_RECOVER_RATE
  recoverDelay = T.STAMINA_RECOVER_DELAY
  blockRegenModifier = T.STAMINA_BLOCK_REGEN_MODIFIER

  currentStamina = T.STAMINA_MAX
  blocking = false
  private recoverTimer = 0

  readonly exhausted = new Signal<[]>()

  update(dt: number): void {
    if (this.recoverTimer > 0) {
      this.recoverTimer = Math.max(0, this.recoverTimer - dt)
      return
    }
    if (this.currentStamina >= this.maxStamina) return
    const mod = this.blocking ? this.blockRegenModifier : 1
    this.currentStamina = Math.min(this.maxStamina, this.currentStamina + this.recoverRate * mod * dt)
  }

  /** Returns false — and fires `exhausted` — when the action can't be paid for. */
  trySpend(cost: number): boolean {
    if (cost <= 0) return true
    if (this.currentStamina < cost) {
      this.exhausted.emit()
      return false
    }
    this.currentStamina -= cost
    this.recoverTimer = this.recoverDelay
    return true
  }

  ratio(): number {
    return this.maxStamina > 0 ? this.currentStamina / this.maxStamina : 0
  }
}

/**
 * combat/poise_component.gd
 *
 * A second health pool that triggers a stagger when depleted. After
 * `maxConsecutiveStaggers` inside `staggerWindow` the owner goes Unstoppable,
 * so a player can't chain-lock a tough enemy forever.
 */
export class PoiseComponent {
  maxPoise = T.POISE_MAX
  recoverDelay = T.POISE_RECOVER_DELAY
  recoverRate = T.POISE_RECOVER_RATE
  staggerWindow = T.POISE_STAGGER_WINDOW
  maxConsecutiveStaggers = T.POISE_MAX_CONSECUTIVE_STAGGERS
  unstoppableDuration = T.POISE_UNSTOPPABLE_DURATION

  currentPoise = T.POISE_MAX
  private sinceLastHit = 0
  private staggerCount = 0
  private lastStaggerAt = -1e9
  private unstoppableTimer = 0
  private clock = 0

  readonly staggered = new Signal<[]>()
  readonly unstoppableStarted = new Signal<[]>()
  readonly unstoppableEnded = new Signal<[]>()

  update(dt: number): void {
    this.clock += dt
    if (this.unstoppableTimer > 0) {
      this.unstoppableTimer -= dt
      if (this.unstoppableTimer <= 0) this.unstoppableEnded.emit()
    }
    this.sinceLastHit += dt
    if (this.sinceLastHit >= this.recoverDelay && this.currentPoise < this.maxPoise) {
      this.currentPoise = Math.min(this.maxPoise, this.currentPoise + this.recoverRate * dt)
    }
  }

  isUnstoppable(): boolean {
    return this.unstoppableTimer > 0
  }

  /** Returns true when this call is what staggered the owner. */
  takePoiseDamage(amount: number): boolean {
    if (amount <= 0 || this.isUnstoppable()) return false
    this.sinceLastHit = 0
    this.currentPoise -= amount
    if (this.currentPoise > 0) return false

    this.currentPoise = this.maxPoise
    if (this.clock - this.lastStaggerAt <= this.staggerWindow) this.staggerCount++
    else this.staggerCount = 1
    this.lastStaggerAt = this.clock
    this.staggered.emit()
    if (this.staggerCount >= this.maxConsecutiveStaggers) {
      this.staggerCount = 0
      this.unstoppableTimer = this.unstoppableDuration
      this.unstoppableStarted.emit()
    }
    return true
  }
}

/**
 * combat/attack_data.gd — a data-driven attack definition. `applyTo` mirrors
 * the GDScript: build the knockback from attacker→target, hand it to the
 * defender's `takeHit`, and let the defender decide whether it landed.
 */
export interface Damageable {
  takeHit(
    damage: number,
    knockback: import('three').Vector3,
    blocked: boolean,
    attacker: unknown,
    isFullyBlockable: boolean,
  ): boolean
}

export class AttackData {
  attackName = ''
  damage = 0
  poiseDamage = 0
  staminaCost = 0
  knockbackMagnitude = 0
  isFullyBlockable = false
  hitWindowStart = 0.15
  hitWindowEnd = 0.95
}
