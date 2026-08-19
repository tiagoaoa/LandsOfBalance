/**
 * A thin stand-in for Godot's AnimationPlayer.
 *
 * The ported gameplay code asks the same three questions the GDScript did:
 * "play this clip", "how far through the current clip am I"
 * (`current_animation_position / current_animation_length` — which drives
 * every hit window and combo chain point), and "has it finished".
 */
import { AnimationMixer, type AnimationAction, type AnimationClip, LoopOnce, LoopRepeat, type Object3D } from 'three'

export class AnimRig {
  readonly mixer: AnimationMixer
  private readonly actions = new Map<string, AnimationAction>()
  private readonly clips: Map<string, AnimationClip>
  private currentName = ''
  private current: AnimationAction | null = null

  /** Clips that must not loop — Godot marks these LOOP_NONE. */
  private static readonly ONE_SHOT = new Set([
    'Attack', 'Attack1', 'Attack2', 'SwordSlash', 'SpellCast', 'Estus', 'Sheath',
    'DodgeF', 'DodgeB', 'DodgeL', 'DodgeR', 'ReactHit', 'Death', 'Jump',
    'TurnLeft', 'TurnRight',
  ])

  constructor(root: Object3D, clips: Map<string, AnimationClip>) {
    this.mixer = new AnimationMixer(root)
    this.clips = clips
  }

  has(name: string): boolean {
    return this.clips.has(name)
  }

  get currentAnim(): string {
    return this.currentName
  }

  /**
   * Godot `AnimationPlayer.play(name, blend, speed)`. Restarting the clip
   * that is already playing is a no-op unless `restart` is set, matching the
   * GDScript guard that keeps looping locomotion from stuttering.
   */
  play(name: string, blend = 0.15, speed = 1, restart = false): boolean {
    const clip = this.clips.get(name)
    if (!clip) return false
    if (name === this.currentName && !restart) {
      if (this.current) this.current.timeScale = speed
      return true
    }

    let action = this.actions.get(name)
    if (!action) {
      action = this.mixer.clipAction(clip)
      this.actions.set(name, action)
    }
    const oneShot = AnimRig.ONE_SHOT.has(name)
    action.setLoop(oneShot ? LoopOnce : LoopRepeat, oneShot ? 1 : Infinity)
    action.clampWhenFinished = oneShot
    action.reset()
    action.timeScale = speed
    action.enabled = true
    action.setEffectiveWeight(1)

    if (this.current && this.current !== action && blend > 0) {
      this.current.crossFadeTo(action, blend, false)
      action.play()
    } else {
      this.current?.stop()
      action.play()
    }
    this.current = action
    this.currentName = name
    return true
  }

  /** Jump to a normalised point in the current clip (Godot's `seek`). */
  seekRatio(ratio: number): void {
    if (!this.current) return
    this.current.time = this.current.getClip().duration * ratio
  }

  /** Absolute seek, in clip seconds. */
  seek(seconds: number): void {
    if (this.current) this.current.time = seconds
  }

  get length(): number {
    return this.current?.getClip().duration ?? 0
  }

  get position(): number {
    return this.current?.time ?? 0
  }

  /** `current_animation_position / current_animation_length`, clamped 0..1. */
  get progress(): number {
    const len = this.length
    if (len <= 0) return 0
    return Math.min(this.position / len, 1)
  }

  get finished(): boolean {
    const a = this.current
    if (!a) return true
    if (a.loop === LoopRepeat) return false
    return a.time >= a.getClip().duration - 1e-4
  }

  setSpeed(speed: number): void {
    if (this.current) this.current.timeScale = speed
  }

  update(dt: number): void {
    this.mixer.update(dt)
  }
}
