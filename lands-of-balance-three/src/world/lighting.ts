/**
 * Port of stage/lighting_manager.gd + stage/moon.gd.
 *
 * Two presets, toggled with L:
 *
 * NIGHT (default) — rainy night under a full moon. Humid air (dense fog), a
 * silver moon as the only key light, and every surface WET: ground and grass
 * drop to low roughness so the moonlight lays a sheen across the field
 * instead of dying in matte darkness. The baseline is DELIBERATELY dark,
 * because firelight is a gameplay mechanic: the archer's arrows light paths
 * and reveal enemies for the paladin, and the darker the night the more
 * those fires matter.
 *
 * DAY — Skyrim-style cold Nordic overcast: bright diffuse skylight, strong
 * distance haze, a soft warm sun cutting the cool ambient.
 */
import {
  AmbientLight,
  BackSide,
  Color,
  DirectionalLight,
  FogExp2,
  HemisphereLight,
  Mesh,
  MeshBasicMaterial,
  type MeshStandardMaterial,
  type Object3D,
  PointLight,
  type Scene,
  SphereGeometry,
} from 'three'
import { TimeOfDay } from '../core/context'
import type { Sky } from './sky'
import { degToRad, lerpf } from '../core/gdmath'

interface Preset {
  fogColor: number
  fogDensity: number
  ambientColor: number
  ambientEnergy: number
  hemiSky: number
  hemiGround: number
  hemiEnergy: number
  sunColor: number
  sunEnergy: number
  sunElevation: number // degrees
  sunAzimuth: number // degrees
  exposure: number
  /** Wetness applied to ground/grass materials — the rainy-night sheen. */
  roughness: number
  metalness: number
}

/** DAY_SETTINGS in lighting_manager.gd. */
const DAY: Preset = {
  fogColor: 0xa8bcd4,
  fogDensity: 0.0022,
  ambientColor: 0xa3b5d1,
  ambientEnergy: 0.85,
  hemiSky: 0xa3b5d1,
  hemiGround: 0x5a5348,
  hemiEnergy: 0.8,
  sunColor: 0xfff5db,
  sunEnergy: 2.4,  // more key, less fill — the day had no contrast
  sunElevation: 48,
  sunAzimuth: -125,
  exposure: 1.05,
  roughness: 0.95,
  metalness: 0.0,
}

/** NIGHT_SETTINGS in lighting_manager.gd, plus moon.gd's key light. */
const NIGHT: Preset = {
  fogColor: 0x121a29,
  fogDensity: 0.0028,
  ambientColor: 0x1a2438,
  ambientEnergy: 0.3,
  hemiSky: 0x1b2740,
  hemiGround: 0x0a0c12,
  hemiEnergy: 0.34,
  // moon.gd: silvery-blue full moon, elevation 25°, azimuth 135°.
  sunColor: 0x9fb0d8,
  // A full moon reads as a key light, but at 2.1 it lit the meadow like
  // noon. The characters stay readable because the post chain desaturates
  // and cools the night rather than because the moon is bright.
  sunEnergy: 1.35,
  sunElevation: 25,
  sunAzimuth: 135,
  exposure: 1.0,
  roughness: 0.35,
  metalness: 0.15,
}

const MOON_SIZE = 80.0
const MOON_DISTANCE = 400.0

export class LightingManager {
  timeOfDay: TimeOfDay = TimeOfDay.NIGHT

  readonly sun = new DirectionalLight(0xffffff, 1)
  readonly ambient = new AmbientLight(0xffffff, 1)
  readonly hemi = new HemisphereLight(0xffffff, 0x444444, 1)
  readonly moonMesh: Mesh
  /** Warm bloom-ish halo so the moon reads as the source of the light. */
  private readonly moonGlow: Mesh
  private readonly moonHalo = new PointLight(0x9fb0dd, 0, 0)

  private readonly scene: Scene
  /** The dome, when attached. Drives fog colour and image-based lighting. */
  private sky: Sky | null = null
  /** Re-capture IBL only when the preset has visibly moved. */
  private lastEnvBlend = -1
  /** Materials that get the wet/dry treatment on a preset change. */
  private readonly wetMaterials: MeshStandardMaterial[] = []
  private readonly dryRoughness = new WeakMap<MeshStandardMaterial, number>()

  private blend = 1 // 0 = day, 1 = night; eased for a smooth transition
  private target = 1

  constructor(scene: Scene) {
    this.scene = scene
    scene.fog = new FogExp2(NIGHT.fogColor, NIGHT.fogDensity)
    scene.background = new Color(NIGHT.fogColor)

    this.sun.castShadow = true
    this.configureShadows()
    scene.add(this.sun)
    scene.add(this.sun.target)
    scene.add(this.ambient)
    scene.add(this.hemi)

    // moon.gd builds an unshaded emissive sphere so the light visibly COMES
    // from an object in the sky rather than from nowhere.
    this.moonMesh = new Mesh(
      new SphereGeometry(MOON_SIZE / 2, 32, 16),
      new MeshBasicMaterial({ color: 0xf2f2da, fog: false }),
    )
    this.moonGlow = new Mesh(
      new SphereGeometry(MOON_SIZE * 0.95, 24, 12),
      new MeshBasicMaterial({ color: 0x8fa4d6, transparent: true, opacity: 0.18, side: BackSide, fog: false, depthWrite: false }),
    )
    this.moonMesh.add(this.moonGlow)
    this.moonMesh.renderOrder = -1
    scene.add(this.moonMesh)
    scene.add(this.moonHalo)

    this.apply(1)
  }

  /**
   * Register ground/grass materials for the rainy-night wetness pass. The
   * Godot build calls this `_apply_surface_wetness`.
   */
  registerWetSurface(root: Object3D): void {
    root.traverse((o) => {
      const m = (o as Mesh).material as MeshStandardMaterial | MeshStandardMaterial[] | undefined
      if (!m) return
      for (const mat of Array.isArray(m) ? m : [m]) {
        if (mat && 'roughness' in mat && !this.dryRoughness.has(mat)) {
          this.dryRoughness.set(mat, mat.roughness)
          this.wetMaterials.push(mat)
        }
      }
    })
    this.applyWetness(this.blend)
  }

  /**
   * Hand the manager the sky dome. From here the dome's light direction, its
   * night blend and the scene fog colour all move together — decoupling them
   * is how you end up with blue-hour fog under a midday sky.
   */
  attachSky(sky: Sky): void {
    this.sky = sky
    this.scene.add(sky.mesh)
    this.apply(this.blend)
    this.refreshEnvironment(true)
  }

  /**
   * Tighten the shadow map around the player.
   *
   * Cascades were the obvious answer here and `CSMShadowNode` is the node
   * renderer's implementation of them — but it is documented as WebGPU-only
   * and throws during graph construction on the WebGL2 backend, which is the
   * path every browser without WebGPU takes. A shipped crash is worse than a
   * softer distant shadow.
   *
   * Instead the single map is kept tight: a 2048 map over a 60 m box is ~34
   * texels per metre, enough for crisp contact shadows on the characters. It
   * follows the player, so the budget is always spent where the camera is.
   */
  private configureShadows(): void {
    const cam = this.sun.shadow.camera
    cam.left = -30
    cam.right = 30
    cam.top = 30
    cam.bottom = -30
    cam.near = 1
    cam.far = 320
    cam.updateProjectionMatrix()
    // 2048 over a 60 m box is ~34 texels/m — crisp on the characters, and
    // half the fill cost of the 4096 map it replaced.
    this.sun.shadow.mapSize.set(2048, 2048)
    this.sun.shadow.bias = -0.0004
    this.sun.shadow.normalBias = 0.022
  }

  /** Rebuild image-based lighting from the dome. Expensive; call sparingly. */
  refreshEnvironment(force = false): void {
    if (!this.sky) return
    if (!force && Math.abs(this.blend - this.lastEnvBlend) < 0.12) return
    this.lastEnvBlend = this.blend
    this.sky.captureEnvironment(this.scene)
  }

  toggle(): void {
    this.setTime(this.timeOfDay === TimeOfDay.DAY ? TimeOfDay.NIGHT : TimeOfDay.DAY)
  }

  setTime(t: TimeOfDay, instant = false): void {
    this.timeOfDay = t
    this.target = t === TimeOfDay.NIGHT ? 1 : 0
    if (instant) {
      this.blend = this.target
      this.apply(this.blend)
    }
  }

  update(dt: number): void {
    if (Math.abs(this.blend - this.target) < 0.001) {
      this.refreshEnvironment()
      return
    }
    // transition_duration = 2.0 s in lighting_manager.gd.
    this.blend += Math.sign(this.target - this.blend) * Math.min(dt / 2.0, Math.abs(this.target - this.blend))
    this.apply(this.blend)
  }

  /** Keep the sun/moon rig centred on the player so shadows stay in range. */
  followTarget(pos: { x: number; y: number; z: number }): void {
    // With cascades the shadow frusta track the view camera themselves; only
    // the light DIRECTION still needs maintaining.
    this.sun.target.position.set(pos.x, pos.y, pos.z)
    this.sun.target.updateMatrixWorld()
    const dir = this.sunDirection(this.blend)
    this.sun.position.set(pos.x + dir.x * 120, pos.y + dir.y * 120, pos.z + dir.z * 120)
    this.moonMesh.position.set(pos.x + dir.x * MOON_DISTANCE, dir.y * MOON_DISTANCE, pos.z + dir.z * MOON_DISTANCE)
    this.moonHalo.position.copy(this.moonMesh.position)
  }

  /** Unit vector from the world toward the key light. */
  private sunDirection(blend: number): { x: number; y: number; z: number } {
    const elev = degToRad(lerpf(DAY.sunElevation, NIGHT.sunElevation, blend))
    const azi = degToRad(lerpf(DAY.sunAzimuth, NIGHT.sunAzimuth, blend))
    const c = Math.cos(elev)
    return { x: Math.sin(azi) * c, y: Math.sin(elev), z: Math.cos(azi) * c }
  }

  private apply(blend: number): void {
    const mix = (a: number, b: number) => new Color(a).lerp(new Color(b), blend)

    const fog = this.scene.fog as FogExp2
    fog.density = lerpf(DAY.fogDensity, NIGHT.fogDensity, blend)
    if (this.sky) {
      // Match fog to the dome's horizon band so distant terrain dissolves
      // into the sky instead of ending on a razor line.
      const [r, g, b] = this.sky.horizonColour(blend)
      fog.color.setRGB(r, g, b)
      this.sky.night.value = blend
      const dir = this.sunDirection(blend)
      this.sky.lightDir.value.set(dir.x, dir.y, dir.z)
      // The dome paints the background; a clear colour would fight the fog.
      this.scene.background = null
    } else {
      fog.color.copy(mix(DAY.fogColor, NIGHT.fogColor))
      ;(this.scene.background as Color)?.copy(fog.color)
    }

    this.ambient.color.copy(mix(DAY.ambientColor, NIGHT.ambientColor))
    // Once the sky dome supplies image-based lighting, the flat ambient and
    // hemisphere fills are counting the same light a second time — which is
    // exactly what turned the moonlit night into dusk.
    const fillScale = this.sky ? 0.25 : 1
    this.ambient.intensity = lerpf(DAY.ambientEnergy, NIGHT.ambientEnergy, blend) * fillScale
    this.hemi.color.copy(mix(DAY.hemiSky, NIGHT.hemiSky))
    this.hemi.groundColor.copy(mix(DAY.hemiGround, NIGHT.hemiGround))
    this.hemi.intensity = lerpf(DAY.hemiEnergy, NIGHT.hemiEnergy, blend) * fillScale

    this.sun.color.copy(mix(DAY.sunColor, NIGHT.sunColor))
    this.sun.intensity = lerpf(DAY.sunEnergy, NIGHT.sunEnergy, blend)

    // The moon disc only exists at night; it fades with the blend.
    const moonMat = this.moonMesh.material as MeshBasicMaterial
    const glowMat = this.moonGlow.material as MeshBasicMaterial
    moonMat.transparent = true
    moonMat.opacity = blend
    glowMat.opacity = 0.18 * blend
    // The sky dome draws its own moon disc and halo; showing this sphere too
    // would put two moons in the frame.
    this.moonMesh.visible = !this.sky && blend > 0.01
    this.moonHalo.intensity = 0

    this.applyWetness(blend)
  }

  private applyWetness(blend: number): void {
    for (const mat of this.wetMaterials) {
      const dry = this.dryRoughness.get(mat) ?? 0.95
      mat.roughness = lerpf(dry, NIGHT.roughness, blend)
      mat.metalness = lerpf(DAY.metalness, NIGHT.metalness, blend)
      mat.needsUpdate = false
    }
  }

  /** 0 = full day, 1 = full night; the post chain grades against this. */
  get nightAmount(): number {
    return this.blend
  }

  /** Renderer exposure for the current preset. */
  get exposure(): number {
    return lerpf(DAY.exposure, NIGHT.exposure, this.blend)
  }
}
