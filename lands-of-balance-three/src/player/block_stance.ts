/**
 * Port of player/block_stance_anim.gd.
 *
 * None of the character packs ship "walk while holding a shield", so the
 * Godot build composes them: keep the locomotion clip's FOOTWORK, graft the
 * Block clip's guard pose over the arms/shoulders/weapon joints, and blend
 * the spine between the two. The result is BlockWalk / BlockRun /
 * BlockStrafeLeft / ... plus a standing BlockHold, because the raw Block clip
 * is a raise-block-lower reaction that pumps when looped.
 *
 * Done here at load time for exactly the same reason: without it the shield
 * drops every time the player takes a step, which is precisely when a souls
 * character should have their guard up.
 */
import { AnimationClip, type KeyframeTrack, Quaternion, QuaternionKeyframeTrack, VectorKeyframeTrack } from 'three'

const SAMPLE_FPS = 30
const SPINE_WEIGHT = 0.7
const HOLD_LENGTH = 1.6
const APEX_WINDOW_TOL = 6 // degrees
const APEX_WINDOW_MAX = 0.25

const GUARD_TOKENS = ['Shoulder', 'Arm', 'Hand', 'Shield', 'Sword', 'arch', 'arrow']
const SPINE_BONES = ['Spine', 'Spine1', 'Spine2', 'Neck', 'Head']
const APEX_BONES = ['LeftArm', 'LeftForeArm', 'RightArm', 'RightForeArm']

/** Locomotion clips that get a Block twin, and the name each twin takes. */
const LOCOMOTION: [string, string][] = [
  ['Walk', 'BlockWalk'],
  ['Run', 'BlockRun'],
  ['Sprint', 'BlockSprint'],
  ['StrafeLeft', 'BlockStrafeLeft'],
  ['StrafeRight', 'BlockStrafeRight'],
  ['RunStrafeLeft', 'BlockRunStrafeLeft'],
  ['RunStrafeRight', 'BlockRunStrafeRight'],
  ['WalkBack', 'BlockWalkBack'],
  ['RunBack', 'BlockRunBack'],
]

function boneOf(trackName: string): string {
  const dot = trackName.lastIndexOf('.')
  const node = dot < 0 ? trackName : trackName.slice(0, dot)
  return node.replace('mixamorig:', '').replace('mixamorig_', '')
}

function propOf(trackName: string): string {
  const dot = trackName.lastIndexOf('.')
  return dot < 0 ? '' : trackName.slice(dot + 1)
}

/** 1.0 = fully the guard pose, 0.7 = spine blend, 0 = keep the stride. */
function guardWeight(bone: string): number {
  if (!bone) return 0
  if (SPINE_BONES.includes(bone)) return SPINE_WEIGHT
  return GUARD_TOKENS.some((t) => bone.includes(t)) ? 1 : 0
}

type Sampler = (t: number) => Float32Array

function samplerFor(track: KeyframeTrack): Sampler {
  // `createInterpolant` is assigned at runtime and untyped; the linear
  // factory is the same interpolant with a declared signature.
  const interp = track.InterpolantFactoryMethodLinear()
  return (t: number) => interp.evaluate(t) as Float32Array
}

const _qa = new Quaternion()
const _qb = new Quaternion()

/**
 * The moment the Block clip's arms are furthest from their rest — i.e. the
 * frame where the guard is actually up. Everything else is composed from it.
 */
function guardApexTime(block: AnimationClip): number {
  const tracks = block.tracks.filter((t) => propOf(t.name) === 'quaternion' && APEX_BONES.includes(boneOf(t.name)))
  if (tracks.length === 0) return block.duration * 0.5

  const samplers = tracks.map(samplerFor)
  const neutral = samplers.map((s) => new Quaternion().fromArray([...s(0)]))
  const steps = Math.max(Math.ceil(block.duration * SAMPLE_FPS), 8)

  let bestT = block.duration * 0.5
  let bestDev = -1
  for (let i = 0; i <= steps; i++) {
    const t = (block.duration * i) / steps
    let dev = 0
    for (let k = 0; k < samplers.length; k++) {
      _qa.fromArray([...samplers[k](t)])
      dev += neutral[k].angleTo(_qa)
    }
    if (dev > bestDev) {
      bestDev = dev
      bestT = t
    }
  }
  return bestT
}

/** How long the clip stays essentially AT the apex pose, for the sway. */
function apexWindow(block: AnimationClip, guardT: number): number {
  const tracks = block.tracks.filter((t) => propOf(t.name) === 'quaternion' && APEX_BONES.includes(boneOf(t.name)))
  if (tracks.length === 0) return APEX_WINDOW_MAX
  const samplers = tracks.map(samplerFor)
  const apex = samplers.map((s) => new Quaternion().fromArray([...s(guardT)]))
  const tol = (APEX_WINDOW_TOL * Math.PI) / 180

  let window = 0
  const step = 1 / SAMPLE_FPS
  for (let d = step; d <= APEX_WINDOW_MAX; d += step) {
    let ok = true
    for (const sign of [-1, 1]) {
      const t = guardT + sign * d
      if (t < 0 || t > block.duration) continue
      for (let k = 0; k < samplers.length; k++) {
        _qb.fromArray([...samplers[k](t)])
        if (apex[k].angleTo(_qb) > tol) {
          ok = false
          break
        }
      }
      if (!ok) break
    }
    if (!ok) break
    window = d
  }
  return Math.max(window, step)
}

/**
 * Standing guard: the apex pose, swayed gently back and forth across the
 * window where the clip is still at that pose. The sway follows a sine so
 * the loop closes with matching velocity.
 */
function composeHold(block: AnimationClip, guardT: number): AnimationClip {
  const window = apexWindow(block, guardT)
  const steps = Math.max(Math.ceil(HOLD_LENGTH * SAMPLE_FPS), 8)
  const times = new Float32Array(steps + 1)
  for (let i = 0; i <= steps; i++) times[i] = (HOLD_LENGTH * i) / steps

  const tracks: KeyframeTrack[] = []
  for (const src of block.tracks) {
    const prop = propOf(src.name)
    if (prop !== 'quaternion' && prop !== 'position') continue
    const sample = samplerFor(src)
    const stride = prop === 'quaternion' ? 4 : 3
    const values = new Float32Array((steps + 1) * stride)
    for (let i = 0; i <= steps; i++) {
      const phase = Math.sin((times[i] / HOLD_LENGTH) * Math.PI * 2)
      const t = Math.min(Math.max(guardT + phase * window, 0), block.duration)
      const v = sample(t)
      for (let c = 0; c < stride; c++) values[i * stride + c] = v[c]
    }
    tracks.push(
      prop === 'quaternion'
        ? new QuaternionKeyframeTrack(src.name, times as unknown as number[], values as unknown as number[])
        : new VectorKeyframeTrack(src.name, times as unknown as number[], values as unknown as number[]),
    )
  }
  return new AnimationClip('BlockHold', HOLD_LENGTH, tracks)
}

/** Footwork from `loco`, guard from `block` at its apex. */
function composeOne(name: string, loco: AnimationClip, block: AnimationClip, guardT: number): AnimationClip {
  const steps = Math.max(Math.ceil(loco.duration * SAMPLE_FPS), 4)
  const times = new Float32Array(steps + 1)
  for (let i = 0; i <= steps; i++) times[i] = (loco.duration * i) / steps

  // Index the block clip's tracks by name for the pose lookup.
  const blockByName = new Map(block.tracks.map((t) => [t.name, t]))

  const tracks: KeyframeTrack[] = []
  for (const src of loco.tracks) {
    const prop = propOf(src.name)
    if (prop !== 'quaternion' && prop !== 'position') continue
    const weight = guardWeight(boneOf(src.name))
    const stride = prop === 'quaternion' ? 4 : 3
    const sampleLoco = samplerFor(src)
    const blockTrack = weight > 0 ? blockByName.get(src.name) : undefined
    const samplePose = blockTrack ? samplerFor(blockTrack) : null

    const values = new Float32Array((steps + 1) * stride)
    for (let i = 0; i <= steps; i++) {
      const a = sampleLoco(times[i])
      if (!samplePose || weight <= 0) {
        for (let c = 0; c < stride; c++) values[i * stride + c] = a[c]
        continue
      }
      const b = samplePose(guardT)
      if (prop === 'quaternion') {
        _qa.fromArray([...a])
        _qb.fromArray([...b])
        _qa.slerp(_qb, weight)
        values[i * 4] = _qa.x
        values[i * 4 + 1] = _qa.y
        values[i * 4 + 2] = _qa.z
        values[i * 4 + 3] = _qa.w
      } else {
        for (let c = 0; c < 3; c++) values[i * 3 + c] = a[c] + (b[c] - a[c]) * weight
      }
    }
    tracks.push(
      prop === 'quaternion'
        ? new QuaternionKeyframeTrack(src.name, times as unknown as number[], values as unknown as number[])
        : new VectorKeyframeTrack(src.name, times as unknown as number[], values as unknown as number[]),
    )
  }
  return new AnimationClip(name, loco.duration, tracks)
}

/**
 * Build every Block* twin the rig can support and add them to `clips`.
 * Silently does nothing when the pack has no Block clip.
 */
export function composeBlockStances(clips: Map<string, AnimationClip>): string[] {
  const block = clips.get('Block')
  if (!block) return []
  const guardT = guardApexTime(block)
  const built: string[] = []

  const hold = composeHold(block, guardT)
  clips.set('BlockHold', hold)
  built.push('BlockHold')

  for (const [locoName, outName] of LOCOMOTION) {
    const loco = clips.get(locoName)
    if (!loco) continue
    clips.set(outName, composeOne(outName, loco, block, guardT))
    built.push(outName)
  }
  return built
}
