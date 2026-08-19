/**
 * Port of enemies/skeleton_anim.gd — the draugr's procedural animation set.
 *
 * The axe skeleton ships no clips, so the Godot build generates them: every
 * key composes a SKELETON-SPACE delta on top of the bone's baseline pose
 * (parentBaseline⁻¹ · R · baseline), so zero delta = the imported stance and
 * the authoring signs stay stable regardless of the rig's local axes.
 *
 * Rig facts (measured from the FBX): the character faces -Z, up +Y, right
 * +X. Sign conventions for the deltas:
 *   - DOWN-pointing bones (thighs, calves, upper arms, forearms):
 *     +X swings the limb FORWARD (toward -Z), -X backward.
 *   - UP-pointing bones (spine chain, neck, head): -X leans FORWARD.
 *   - +Z tips a hanging limb out to the character's right (+X side).
 *   - Y twists around the vertical (torso wind-up).
 *
 * Blade contact for both attacks is at t = 0.5 of the 1.0 s clip — the AI
 * deals damage exactly then.
 */
import { type Bone, Euler, type Object3D, Quaternion } from 'three'
import { clampf, degToRad, TAU } from '../core/gdmath'

// Rig bone names (Skyrim NPC naming).
const B_SPINE0 = 'NPC_Spine__Spn0_'
const B_SPINE2 = 'NPC_Spine2__Spn2_'
const B_NECK = 'NPC_Neck__Neck_'
const B_HEAD = 'NPC_Head__Head_'
const B_JAW = 'NPC_Head__Jaw_'
const B_R_THIGH = 'NPC_R_Thigh__RThg_'
const B_L_THIGH = 'NPC_L_Thigh__LThg_'
const B_R_CALF = 'NPC_R_Calf__RClf_'
const B_L_CALF = 'NPC_L_Calf__LClf_'
const B_R_ARM = 'NPC_R_UpperArm__RUar_'
const B_L_ARM = 'NPC_L_UpperArm__LUar_'
const B_R_FORE = 'NPC_R_Forearm__RLar_'
const B_L_FORE = 'NPC_L_Forearm__LLar_'

/** Euler degrees for one bone at normalised clip time `t`. */
type Sampler = (t: number) => [number, number, number]
type Clip = { length: number; loop: boolean; tracks: Record<string, Sampler> }

export type SkeletonClipName = 'Idle' | 'Walk' | 'Run' | 'AttackOverhead' | 'AttackSlash'

/**
 * Attack phase envelope: x = windup weight (rises 0–0.35, dies by 0.65),
 * y = strike weight (whips in at 0.35–0.5, decays through recovery).
 */
function phase(t: number): [number, number] {
  const windup = clampf(t / 0.35, 0, 1) * clampf((0.65 - t) / 0.15, 0, 1)
  const strike = clampf((t - 0.35) / 0.15, 0, 1) * clampf((1 - t) / 0.35, 0, 1)
  return [clampf(windup, 0, 1), clampf(strike, 0, 1)]
}

/** The dead thing breathes anyway: slow sway, axe drifting, jaw working. */
const IDLE: Clip = {
  length: 2.8,
  loop: true,
  tracks: {
    [B_SPINE0]: (t) => [-3 + 1.5 * Math.sin(TAU * t), 2.5 * Math.sin(TAU * t + 1.2), 0],
    [B_SPINE2]: (t) => [-2 + 1.5 * Math.sin(TAU * t + 0.5), 0, 2 * Math.sin(TAU * t)],
    [B_HEAD]: (t) => [2 * Math.sin(TAU * t + 0.8), 6 * Math.sin(TAU * t), 0],
    [B_JAW]: (t) => [-8 * Math.max(0, Math.sin(TAU * t * 3)), 0, 0],
    [B_R_ARM]: (t) => [2.5 * Math.sin(TAU * t), 0, 2 * Math.sin(TAU * t + 2)],
    [B_L_ARM]: (t) => [2 * Math.sin(TAU * t + 1), 0, -1.5 * Math.sin(TAU * t)],
  },
}

/**
 * Legs AND arms swing in opposition, knees fold on the swing-through, the
 * torso counter-twists — a full-body gait, not a glide.
 */
function locomotion(length: number, legAmp: number, armAmp: number, hunch: number): Clip {
  return {
    length,
    loop: true,
    tracks: {
      // Legs: +X swings forward. Right leg leads at t=0.
      [B_R_THIGH]: (t) => [legAmp * Math.sin(TAU * t), 0, 0],
      [B_L_THIGH]: (t) => [-legAmp * Math.sin(TAU * t), 0, 0],
      // Knees fold BACKWARD while that leg swings through — peak flexion mid
      // swing-through, never on the planted leg.
      [B_R_CALF]: (t) => [-legAmp * 0.9 * Math.max(0, Math.sin(TAU * t + 2.2)), 0, 0],
      [B_L_CALF]: (t) => [-legAmp * 0.9 * Math.max(0, Math.sin(TAU * t + 2.2 + Math.PI)), 0, 0],
      // Arms counter-swing the legs; the axe arm keeps a bent elbow.
      [B_R_ARM]: (t) => [-armAmp * Math.sin(TAU * t), 0, 3],
      [B_L_ARM]: (t) => [armAmp * Math.sin(TAU * t), 0, -3],
      [B_R_FORE]: (t) => [14 + armAmp * 0.4 * Math.max(0, -Math.sin(TAU * t)), 0, 0],
      [B_L_FORE]: (t) => [10 + armAmp * 0.4 * Math.max(0, Math.sin(TAU * t)), 0, 0],
      // Hungry hunch; torso counter-twists the hips; head locked on the prey.
      [B_SPINE0]: (t) => [-hunch, 6 * Math.sin(TAU * t), 0],
      [B_SPINE2]: (t) => [-hunch * 0.6 - 2 * Math.sin(TAU * t * 2), -4 * Math.sin(TAU * t), 0],
      [B_HEAD]: (t) => [hunch * 0.9, -2 * Math.sin(TAU * t), 0],
      [B_JAW]: (t) => [-6 * Math.max(0, Math.sin(TAU * t * 2)), 0, 0],
    },
  }
}

/**
 * TWO-HANDED overhead chop: both arms haul the axe high behind the skull
 * (windup 0–0.35), then slam it down-forward through the target line
 * (contact ~0.5) with the whole spine committing to the blow.
 */
const ATTACK_OVERHEAD: Clip = {
  length: 1.0,
  loop: false,
  tracks: {
    [B_R_ARM]: (t) => { const [w, s] = phase(t); return [-150 * w + 55 * s, 0, 8 * w] },
    [B_L_ARM]: (t) => { const [w, s] = phase(t); return [-145 * w + 50 * s, 0, -8 * w] },
    [B_R_FORE]: (t) => { const [w, s] = phase(t); return [45 * w - 8 * s, 0, 0] },
    [B_L_FORE]: (t) => { const [w, s] = phase(t); return [42 * w - 6 * s, 0, 0] },
    [B_SPINE0]: (t) => { const [w, s] = phase(t); return [14 * w - 22 * s, 0, 0] },
    [B_SPINE2]: (t) => { const [w, s] = phase(t); return [12 * w - 20 * s, 0, 0] },
    [B_NECK]: (t) => { const [w, s] = phase(t); return [-10 * w + 6 * s, 0, 0] },
    [B_JAW]: (t) => [-18 * clampf(Math.sin(TAU * t), 0, 1), 0, 0],
  },
}

/**
 * Torso-loaded horizontal sweep: wind the shoulders hard to the right with
 * the axe drawn out wide, then rip the whole upper body around, the axe arm
 * sweeping flat across the frontal arc.
 */
const ATTACK_SLASH: Clip = {
  length: 1.0,
  loop: false,
  tracks: {
    [B_SPINE0]: (t) => { const [w, s] = phase(t); return [-4 * s, -30 * w + 34 * s, 0] },
    [B_SPINE2]: (t) => { const [w, s] = phase(t); return [-6 * s, -26 * w + 30 * s, 0] },
    [B_R_ARM]: (t) => { const [w, s] = phase(t); return [-25 * w + 70 * s, 0, 55 * w - 20 * s] },
    [B_R_FORE]: (t) => { const [w, s] = phase(t); return [30 * w - 5 * s, 0, 0] },
    [B_L_ARM]: (t) => { const [w, s] = phase(t); return [15 * w - 20 * s, 0, -12 * w] },
    [B_NECK]: (t) => { const [w, s] = phase(t); return [0, 22 * w - 18 * s, 0] },
    [B_JAW]: (t) => [-14 * clampf(Math.sin(TAU * t + 0.5), 0, 1), 0, 0],
  },
}

const CLIPS: Record<SkeletonClipName, Clip> = {
  Idle: IDLE,
  Walk: locomotion(1.15, 24, 16, 5),
  Run: locomotion(0.64, 38, 26, 10),
  AttackOverhead: ATTACK_OVERHEAD,
  AttackSlash: ATTACK_SLASH,
}

const BLEND_TIME = 0.25

interface BaselineBone {
  bone: Bone
  /** Rotation of the bone in model space, in the imported stance. */
  base: Quaternion
  /** Rotation of the parent in model space, inverted. */
  parentInv: Quaternion
}

const _euler = new Euler()
const _delta = new Quaternion()
const _target = new Quaternion()
const _blendTmp = new Quaternion()

export class SkeletonAnimator {
  private readonly bones = new Map<string, BaselineBone>()
  private clip: SkeletonClipName = 'Idle'
  private prevClip: SkeletonClipName | null = null
  private time = 0
  private prevTime = 0
  private blend = 1
  /** Per-bone-bag stride/speed desync so a pack never marches in lockstep. */
  speedScale = 1
  private phaseOffset = 0

  constructor(root: Object3D) {
    // Every bone any clip touches, with its baseline model-space rotation.
    const wanted = new Set<string>()
    for (const c of Object.values(CLIPS)) for (const n of Object.keys(c.tracks)) wanted.add(n)

    root.updateWorldMatrix(true, true)
    const rootQuat = new Quaternion()
    root.getWorldQuaternion(rootQuat)
    const rootInv = rootQuat.clone().invert()

    root.traverse((o) => {
      if (!wanted.has(o.name)) return
      const bone = o as Bone
      const base = new Quaternion()
      bone.getWorldQuaternion(base)
      base.premultiply(rootInv)

      const parentQuat = new Quaternion()
      if (bone.parent) {
        bone.parent.getWorldQuaternion(parentQuat)
        parentQuat.premultiply(rootInv)
      }
      this.bones.set(o.name, { bone, base, parentInv: parentQuat.invert() })
    })
  }

  /** Randomise the loop phase — five brothers must not fall into lockstep. */
  desync(offset: number, speedScale: number): void {
    this.phaseOffset = offset
    this.speedScale = speedScale
    this.time = offset * CLIPS[this.clip].length
  }

  play(name: SkeletonClipName, restart = false): void {
    if (name === this.clip && !restart) return
    this.prevClip = this.clip
    this.prevTime = this.time
    this.blend = 0
    this.clip = name
    // Every clip switch lands on this skeleton's PERSONAL phase.
    this.time = CLIPS[name].loop ? this.phaseOffset * CLIPS[name].length : 0
  }

  get current(): SkeletonClipName {
    return this.clip
  }

  /** Normalised progress through the current clip (attack timing reads this). */
  get progress(): number {
    return Math.min(this.time / CLIPS[this.clip].length, 1)
  }

  update(dt: number): void {
    const scaled = dt * this.speedScale
    this.time += scaled
    const clip = CLIPS[this.clip]
    if (clip.loop) this.time %= clip.length
    else this.time = Math.min(this.time, clip.length)

    if (this.blend < 1) {
      this.prevTime += scaled
      const prev = this.prevClip ? CLIPS[this.prevClip] : null
      if (prev?.loop) this.prevTime %= prev.length
      this.blend = Math.min(1, this.blend + dt / BLEND_TIME)
    }

    for (const [name, entry] of this.bones) {
      const cur = this.sample(this.clip, name, this.time)
      let ex = cur[0]
      let ey = cur[1]
      let ez = cur[2]
      if (this.blend < 1 && this.prevClip) {
        const old = this.sample(this.prevClip, name, this.prevTime)
        ex = old[0] + (ex - old[0]) * this.blend
        ey = old[1] + (ey - old[1]) * this.blend
        ez = old[2] + (ez - old[2]) * this.blend
      }

      // local = parentBaseline⁻¹ · R · baseline — zero delta is the stance.
      _euler.set(degToRad(ex), degToRad(ey), degToRad(ez))
      _delta.setFromEuler(_euler)
      _target.copy(_delta).multiply(entry.base).premultiply(entry.parentInv)
      entry.bone.quaternion.copy(_target)
    }
  }

  private sample(clipName: SkeletonClipName, bone: string, time: number): [number, number, number] {
    const clip = CLIPS[clipName]
    const track = clip.tracks[bone]
    if (!track) return [0, 0, 0]
    return track(Math.min(time / clip.length, 1))
  }

  /** Blend the whole rig back toward its stance — used while collapsing. */
  relax(amount: number): void {
    for (const entry of this.bones.values()) {
      _blendTmp.copy(entry.base).premultiply(entry.parentInv)
      entry.bone.quaternion.slerp(_blendTmp, amount)
    }
  }
}
