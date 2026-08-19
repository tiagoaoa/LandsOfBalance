/**
 * The sky, authored in TSL.
 *
 * The old sky was a flat fog-coloured clear plus a hard horizon line where
 * the ground slab ended — the single most "not a real game" thing in the
 * frame. This replaces it with a shaded dome:
 *
 *   - a Rayleigh-ish zenith→horizon gradient, so the sky has depth
 *   - a warm scattering halo around the key light, which sells the sun as
 *     the source of the lighting rather than an arbitrary directional
 *   - a night pass with stars, a Milky Way band and a moon glow
 *   - a horizon haze band that the scene fog is colour-matched to, which is
 *     what actually dissolves the hard terrain edge
 *
 * The dome doubles as the image-based lighting source: `captureEnvironment`
 * renders it through PMREM so metal and cloth pick up sky colour instead of
 * sitting flat under a bare hemisphere light.
 */
import {
  BackSide,
  Mesh,
  MeshBasicNodeMaterial,
  PMREMGenerator,
  Scene,
  SphereGeometry,
  Vector3,
  type WebGPURenderer,
} from 'three'
import {
  Fn,
  abs,
  clamp,
  dot,
  exp,
  float,
  floor,
  fract,
  max,
  mix,
  normalize,
  positionLocal,
  pow,
  time,
  sin,
  smoothstep,
  uniform,
  vec2,
  vec3,
} from 'three/tsl'

import type { Node } from 'three'
import type { ShaderNodeObject } from 'three/src/nodes/tsl/TSLCore.js'

/** A TSL value of any node kind — see the note in terrain.ts. */
type TSL = ShaderNodeObject<Node>

const SKY_RADIUS = 900

/** 2D value hash + fbm, for the cloud layer. */
const hash2 = /*@__PURE__*/ Fn(([p]: [TSL]) =>
  fract(sin(p.x.mul(127.1).add(p.y.mul(311.7))).mul(43758.5453)),
)

const noise2 = /*@__PURE__*/ Fn(([p]: [TSL]) => {
  const i = p.floor()
  const f = p.fract()
  const u = f.mul(f).mul(f.mul(-2).add(3))
  const a = hash2(i)
  const b = hash2(i.add(vec2(1, 0)))
  const c = hash2(i.add(vec2(0, 1)))
  const d = hash2(i.add(vec2(1, 1)))
  return mix(mix(a, b, u.x), mix(c, d, u.x), u.y)
})

/** Five octaves — enough for cumulus edges without banding. */
const fbm2 = /*@__PURE__*/ Fn(([p]: [TSL]) => {
  let sum = noise2(p).mul(0.5)
  sum = sum.add(noise2(p.mul(2.03)).mul(0.25))
  sum = sum.add(noise2(p.mul(4.01)).mul(0.125))
  sum = sum.add(noise2(p.mul(8.05)).mul(0.0625))
  sum = sum.add(noise2(p.mul(16.1)).mul(0.03125))
  return sum
})

/** Cheap 3D value hash — used for the star field. */
const hash3 = /*@__PURE__*/ Fn(([p]: [TSL]) => {
  const q = p.mul(127.1).add(p.yzx.mul(311.7)).add(p.zxy.mul(74.7))
  return fract(sin(q.x.add(q.y).add(q.z)).mul(43758.5453))
})

export class Sky {
  readonly mesh: Mesh

  /** Direction TOWARD the key light (sun by day, moon by night). */
  readonly lightDir = uniform(new Vector3(0.3, 0.5, 0.4))
  /** 0 = full day, 1 = full night. Driven by the lighting manager. */
  readonly night = uniform(0)
  /** Overall sky brightness, so exposure changes don't blow the dome out. */
  readonly intensity = uniform(1)

  private readonly pmrem: PMREMGenerator | null = null
  private readonly envScene = new Scene()

  constructor(renderer: WebGPURenderer) {
    const material = new MeshBasicNodeMaterial()
    material.side = BackSide
    material.depthWrite = false
    material.fog = false
    material.colorNode = this.buildColourNode()

    this.mesh = new Mesh(new SphereGeometry(SKY_RADIUS, 64, 32), material)
    this.mesh.name = 'Sky'
    // Always draw first, and never let frustum culling drop it.
    this.mesh.renderOrder = -1000
    this.mesh.frustumCulled = false

    try {
      this.pmrem = new PMREMGenerator(renderer)
    } catch {
      this.pmrem = null
    }
  }

  // Return type left to inference: TSL node types are precise per operation
  // and naming one here just fights the graph.
  private buildColourNode() {
    const dir = normalize(positionLocal)
    // Height above the horizon, 0 at the horizon, 1 at the zenith.
    const h = clamp(dir.y, 0, 1)
    const cosLight = dot(dir, normalize(this.lightDir))

    // ── Day ──────────────────────────────────────────────────────────────
    // Nordic overcast: cool blue zenith falling to a pale, slightly warm
    // horizon. The exponent is what stops it reading as a linear ramp.
    const dayZenith = vec3(0.12, 0.26, 0.58)
    const dayHorizon = vec3(0.55, 0.66, 0.79)
    const dayGrad = mix(dayHorizon, dayZenith, pow(h, float(0.42)))
    // Forward-scattering halo: the sky brightens toward the sun.
    const sunHalo = pow(max(cosLight, 0), float(6)).mul(0.55)
    const sunDisc = smoothstep(float(0.9985), float(0.9995), cosLight).mul(6)
    const day = dayGrad.add(vec3(1.0, 0.93, 0.78).mul(sunHalo)).add(vec3(1.0, 0.96, 0.88).mul(sunDisc))

    // ── Night ────────────────────────────────────────────────────────────
    const nightZenith = vec3(0.0025, 0.0045, 0.012)
    const nightHorizon = vec3(0.014, 0.022, 0.042)
    const nightGrad = mix(nightHorizon, nightZenith, pow(h, float(0.55)))

    // Stars: split the sphere into cells, drop ONE point at a hashed position
    // inside each, and shade by distance to it. Lighting whole cells instead
    // (the obvious approach) paints diagonal streaks, because neighbouring
    // cells line up along the quantisation grid.
    const starCell = dir.mul(160)
    const cellId = floor(starCell)
    const cellUv = starCell.sub(cellId)
    const starRnd = hash3(cellId)
    const jitter = vec3(
      hash3(cellId.add(vec3(1.7, 9.2, 3.3))),
      hash3(cellId.add(vec3(5.1, 2.7, 7.4))),
      hash3(cellId.add(vec3(8.3, 4.6, 1.9))),
    )
    const starDist = cellUv.sub(jitter).length()
    // Only a small fraction of cells host a star at all.
    const starPresent = smoothstep(float(0.955), float(0.995), starRnd)
    const starPoint = smoothstep(float(0.13), float(0.0), starDist)
    const twinkle = sin(starRnd.mul(410)).mul(0.3).add(0.8)
    const starFade = smoothstep(float(0.015), float(0.3), dir.y)
    const stars = vec3(0.86, 0.9, 1.0).mul(starPresent.mul(starPoint).mul(twinkle).mul(starFade).mul(2.6))

    // A soft galactic band across the sky, low contrast so it never reads
    // as a texture seam.
    const band = exp(abs(dot(dir, normalize(vec3(0.55, 0.42, -0.72)))).mul(-3.2)).mul(0.013)
    const milkyWay = vec3(0.55, 0.62, 0.85).mul(band.mul(starFade))

    // Moon: a bright disc plus a wide halo through the humid air.
    const moonHalo = pow(max(cosLight, 0), float(220)).mul(0.5)
    const moonWide = pow(max(cosLight, 0), float(14)).mul(0.06)
    const moonDisc = smoothstep(float(0.9992), float(0.99975), cosLight).mul(4)
    const night = nightGrad
      .add(stars)
      .add(milkyWay)
      .add(vec3(0.72, 0.79, 0.98).mul(moonHalo.add(moonWide)))
      .add(vec3(0.95, 0.96, 1.0).mul(moonDisc))

    // ── Clouds ───────────────────────────────────────────────────────────
    // The direction is projected onto a plane well above the camera, which
    // gives clouds real perspective: they crowd together toward the horizon
    // instead of sitting on the dome like wallpaper. Two layers drift at
    // different speeds so the sky never looks like one scrolling texture.
    const drift = time.mul(0.004)
    const plane = dir.xz.div(max(dir.y, float(0.16)))
    const lowLayer = fbm2(plane.mul(0.16).add(vec2(drift, drift.mul(0.6))))
    const highLayer = fbm2(plane.mul(0.29).add(vec2(drift.mul(-1.7), drift.mul(0.9))))
    const density = lowLayer.mul(0.72).add(highLayer.mul(0.28))
    // Coverage: broken overcast by day, thin and sparse at night.
    const coverEdge = mix(float(0.36), float(0.60), this.night)
    const cover = smoothstep(coverEdge, coverEdge.add(0.22), density)
    // Fade out near the horizon, where the projection stretches to mush.
    const cloudFade = smoothstep(float(0.06), float(0.30), dir.y)
    const cloudAmount = cover.mul(cloudFade).mul(mix(float(0.9), float(0.55), this.night))

    // Lit from the key light, shaded away from it.
    const lit = pow(max(cosLight, 0), float(2.5)).mul(0.5).add(0.5)
    const dayCloud = mix(vec3(0.42, 0.45, 0.52), vec3(1.0, 0.97, 0.92), lit)
    const nightCloud = mix(vec3(0.017, 0.022, 0.036), vec3(0.10, 0.115, 0.15), lit)
    const cloudColour = mix(dayCloud, nightCloud, this.night)

    // ── Horizon haze ─────────────────────────────────────────────────────
    // The band the scene fog is matched to. Without it the terrain ends on a
    // razor line against the sky.
    const hazeAmount = pow(float(1).sub(h), float(14))
    const hazeColour = mix(vec3(0.62, 0.71, 0.82), vec3(0.016, 0.026, 0.05), this.night)
    const base = mix(mix(day, night, this.night), cloudColour, cloudAmount)
    return mix(base, hazeColour, hazeAmount.mul(0.6)).mul(this.intensity)
  }

  /** Keep the dome centred on the viewer so it never clips. */
  follow(pos: { x: number; y: number; z: number }): void {
    this.mesh.position.set(pos.x, pos.y, pos.z)
  }

  /**
   * Render the dome to an environment map so materials get real sky lighting.
   * Called on preset changes rather than per frame — PMREM is not cheap.
   */
  captureEnvironment(scene: Scene): void {
    if (!this.pmrem) return
    const previousParent = this.mesh.parent
    this.envScene.add(this.mesh)
    try {
      const target = this.pmrem.fromScene(this.envScene, 0.04)
      scene.environment?.dispose?.()
      scene.environment = target.texture
    } catch {
      // IBL is an enhancement; a failure here must not take the frame down.
    } finally {
      if (previousParent) previousParent.add(this.mesh)
    }
  }

  /** Horizon colour for the current preset — the scene fog matches this. */
  horizonColour(nightAmount: number): [number, number, number] {
    const day: [number, number, number] = [0.62, 0.71, 0.82]
    const night: [number, number, number] = [0.016, 0.026, 0.05]
    return [
      day[0] + (night[0] - day[0]) * nightAmount,
      day[1] + (night[1] - day[1]) * nightAmount,
      day[2] + (night[2] - day[2]) * nightAmount,
    ]
  }
}
