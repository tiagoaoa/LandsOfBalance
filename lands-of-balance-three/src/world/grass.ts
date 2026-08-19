/**
 * The grass field.
 *
 * The old version was ~16k static crossed quads at 0.32 m, scattered on a
 * flat plane. It read as green cardboard standing in a car park, and it was
 * the loudest "this is a hobby project" signal in the frame. What actually
 * fixes that is not more instances — it is:
 *
 *  - **A blade silhouette.** Tapered, bent geometry instead of a rectangle,
 *    so the alpha edge isn't a straight vertical line.
 *  - **Ground-colour inheritance.** Each tuft is tinted toward the terrain
 *    beneath it and darkened at the base, so it belongs to the ground
 *    instead of hovering over it.
 *  - **Wind.** A two-frequency gust field bending blades from the root, with
 *    per-instance phase. Static grass reads as plastic no matter how dense.
 *  - **Distance fade.** Tufts shrink into the terrain past a radius rather
 *    than popping, so the field can be dense near the camera and free far
 *    away.
 *
 * Placement follows `terrainHeight`, so the field sits on the relief rather
 * than intersecting it.
 */
import {
  BufferGeometry,
  DoubleSide,
  Float32BufferAttribute,
  InstancedBufferAttribute,
  InstancedMesh,
  Matrix4,
  MeshStandardNodeMaterial,
  Quaternion,
  type Texture,
  Vector3,
} from 'three'
import {
  Fn,
  attribute,
  cos,
  float,
  mix,
  positionLocal,
  sin,
  smoothstep,
  texture,
  time,
  uv,
  vec3,
  vec4,
} from 'three/tsl'
import type { AssetLoader } from '../core/assets'
import { randRange } from '../core/gdmath'
import { terrainHeight } from './terrain'

/** Instances. Dense near the player, thinning with radius. */
const COUNT = 105_000
const RADIUS = 88
/** Recentre the field once the player has walked this far from its middle. */
const RECENTER_DISTANCE = 18
/** Instances re-placed per frame while recentring, to avoid a visible hitch. */
const CHUNK = 8_000
/** Past this the tufts are scaled out entirely. */
const FADE_START = 66
const FADE_END = 86

/**
 * One tuft: three crossed, tapered, slightly bent blades. Built by hand
 * rather than from PlaneGeometry so the tip can be narrowed to a point and
 * the whole card can lean — a rectangle is what makes billboard grass read
 * as cardboard.
 */
function bladeCluster(): BufferGeometry {
  const positions: number[] = []
  const uvs: number[] = []
  const indices: number[] = []
  const normals: number[] = []

  const BLADES = 3
  for (let b = 0; b < BLADES; b++) {
    const yaw = (b / BLADES) * Math.PI + Math.random() * 0.2
    const cos_ = Math.cos(yaw)
    const sin_ = Math.sin(yaw)
    const halfWidth = 0.035
    const height = 0.30
    const lean = (Math.random() - 0.5) * 0.09
    const base = positions.length / 3

    // Four rungs from root to tip, narrowing as they rise.
    const RUNGS = 3  // 18 tris per tuft; the 4th rung was invisible at range
    for (let r = 0; r <= RUNGS; r++) {
      const t = r / RUNGS
      const w = halfWidth * (1 - t * 0.92)
      const y = height * t
      const x = lean * t * t
      positions.push((x - w) * cos_, y, (x - w) * sin_)
      positions.push((x + w) * cos_, y, (x + w) * sin_)
      uvs.push(0, t, 1, t)
      normals.push(-sin_, 0, cos_, -sin_, 0, cos_)
    }
    for (let r = 0; r < RUNGS; r++) {
      const a = base + r * 2
      indices.push(a, a + 1, a + 2, a + 1, a + 3, a + 2)
    }
  }

  const geo = new BufferGeometry()
  geo.setAttribute('position', new Float32BufferAttribute(positions, 3))
  geo.setAttribute('uv', new Float32BufferAttribute(uvs, 2))
  geo.setAttribute('normal', new Float32BufferAttribute(normals, 3))
  geo.setIndex(indices)
  return geo
}

export interface Grass {
  mesh: InstancedMesh
  /** Call each frame: keeps the field centred on the player. */
  setPlayerPosition(p: Vector3): void
}

export function buildGrass(assets: AssetLoader): Grass {
  const geometry = bladeCluster()

  const mesh = new InstancedMesh(geometry, grassMaterial(assets), COUNT)
  mesh.name = 'Grass'
  mesh.castShadow = false
  mesh.receiveShadow = false
  // Instances span the whole field; the default bounding sphere would cull
  // the lot the moment the origin left the frustum.
  mesh.frustumCulled = false

  // Per-instance constants. Offsets are relative to the field CENTRE, which
  // follows the player — grass anchored to the world origin means bare ground
  // everywhere the player actually walks.
  const offsetX = new Float32Array(COUNT)
  const offsetZ = new Float32Array(COUNT)
  const yaw = new Float32Array(COUNT)
  const scaleXZ = new Float32Array(COUNT)
  const scaleY = new Float32Array(COUNT)
  const phase = new Float32Array(COUNT)
  const variation = new Float32Array(COUNT)

  for (let i = 0; i < COUNT; i++) {
    // sqrt() would spread instances evenly by area; a lower exponent biases
    // them toward the middle, so the near field stays thick while the field
    // still reaches the treeline for the price of the same instance count.
    const r = Math.pow(Math.random(), 0.62) * RADIUS
    const a = Math.random() * Math.PI * 2
    offsetX[i] = Math.cos(a) * r
    offsetZ[i] = Math.sin(a) * r
    yaw[i] = Math.random() * Math.PI * 2
    // Fade out with distance instead of popping at a hard cut. Based on the
    // OFFSET, so it stays stable as the field moves.
    const fade = 1 - Math.min(Math.max((r - FADE_START) / (FADE_END - FADE_START), 0), 1)
    scaleXZ[i] = randRange(0.55, 1.0) * fade
    scaleY[i] = randRange(0.55, 1.15) * fade
    phase[i] = Math.random() * Math.PI * 2
    variation[i] = Math.random()
  }

  geometry.setAttribute('aPhase', new InstancedBufferAttribute(phase, 1))
  geometry.setAttribute('aVariation', new InstancedBufferAttribute(variation, 1))

  const m = new Matrix4()
  const pos = new Vector3()
  const quat = new Quaternion()
  const scale = new Vector3()
  const up = new Vector3(0, 1, 0)

  const centre = new Vector3(Infinity, 0, Infinity)
  let rebuildFrom = 0

  /** Rewrite one slice of the field around `centre`. */
  const writeSlice = (start: number, end: number): void => {
    for (let i = start; i < end; i++) {
      const x = centre.x + offsetX[i]
      const z = centre.z + offsetZ[i]
      pos.set(x, terrainHeight(x, z) - 0.03, z)
      quat.setFromAxisAngle(up, yaw[i])
      scale.set(scaleXZ[i], scaleY[i], scaleXZ[i])
      mesh.setMatrixAt(i, m.compose(pos, quat, scale))
    }
    mesh.instanceMatrix.needsUpdate = true
  }

  return {
    mesh,
    setPlayerPosition(p: Vector3) {
      // Recentre in whole steps: re-placing 145k tufts every frame would cost
      // more than drawing them, and moving the field continuously would make
      // the near blades crawl underfoot.
      if (rebuildFrom === 0 && Math.hypot(p.x - centre.x, p.z - centre.z) > RECENTER_DISTANCE) {
        centre.set(p.x, 0, p.z)
        rebuildFrom = 1
        writeSlice(0, CHUNK)
        return
      }
      // Spread the rest of the rebuild across the following frames.
      if (rebuildFrom > 0) {
        const start = rebuildFrom === 1 ? CHUNK : rebuildFrom
        const end = Math.min(start + CHUNK, COUNT)
        writeSlice(start, end)
        rebuildFrom = end >= COUNT ? 0 : end
      }
    },
  }
}

function grassMaterial(assets: AssetLoader): MeshStandardNodeMaterial {
  const blade = assets.texture('/assets/world/realistic_grass_1.png')

  const material = new MeshStandardNodeMaterial()
  material.side = DoubleSide
  material.transparent = false
  material.alphaTest = 0.42
  material.roughness = 0.82
  material.metalness = 0

  const phase = attribute('aPhase', 'float')
  const variation = attribute('aVariation', 'float')

  // ── Wind ───────────────────────────────────────────────────────────────
  // Two frequencies: a slow travelling gust plus a faster flutter, both
  // scaled by height along the blade so the root stays planted.
  material.positionNode = grassWind(phase)

  // ── Colour ─────────────────────────────────────────────────────────────
  material.colorNode = grassColour(blade, variation)

  return material
}

const grassWind = /*@__PURE__*/ Fn(([phase]: [ReturnType<typeof float>]) => {
  const local = positionLocal
  // uv.y is 0 at the root, 1 at the tip; cubing it keeps the base rigid.
  const h = uv().y
  const bendAmount = h.mul(h).mul(h.mul(0.6).add(0.4))

  const t = time.mul(1.35).add(phase)
  const gust = sin(t).mul(0.75).add(sin(t.mul(0.41).add(1.7)).mul(0.35))
  const flutter = sin(t.mul(3.1)).mul(0.12)
  const sway = gust.add(flutter).mul(0.22)

  // Bend along a fixed prevailing direction, with a little cross-sway.
  const dirX = cos(phase.mul(0.3).add(0.6))
  const dirZ = sin(phase.mul(0.3).add(0.6))
  return vec3(
    local.x.add(sway.mul(bendAmount).mul(dirX)),
    // Bending shortens the blade slightly; without this it visibly stretches.
    local.y.sub(sway.abs().mul(bendAmount).mul(0.12)),
    local.z.add(sway.mul(bendAmount).mul(dirZ)),
  )
})

const grassColour = /*@__PURE__*/ Fn(
  ([map, variation]: [Texture, ReturnType<typeof float>]) => {
    const tex = texture(map, uv())
    const h = uv().y

    // Per-tuft colour roll: dry straw through to deep green.
    const dry = vec3(0.34, 0.33, 0.15)
    const lush = vec3(0.10, 0.24, 0.07)
    const body = mix(lush, dry, variation.mul(0.7))

    // Ambient occlusion down the blade: dark at the root, bright at the tip.
    // This one trick does more for "grounded" grass than any lighting change.
    const rootShade = smoothstep(float(0), float(0.55), h).mul(0.75).add(0.25)
    // Tips catch light — a cheap stand-in for subsurface scattering.
    const tipGlow = smoothstep(float(0.6), float(1), h).mul(0.35)

    return vec4(body.mul(rootShade).add(tipGlow).mul(tex.rgb.mul(1.6).add(0.35)), tex.a)
  },
)
