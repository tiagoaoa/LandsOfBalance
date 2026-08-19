/**
 * Renderer, scene, third-person camera rig and the post-processing graph.
 *
 * The renderer is three's node-based `WebGPURenderer`. It uses WebGPU where
 * the browser offers it and transparently falls back to a WebGL2 backend
 * where it doesn't, so there is one code path either way — and, crucially,
 * the TSL post-processing stack (AO, bloom, antialiasing, grading) runs on
 * both. That stack is where most of the image quality lives.
 *
 * The camera is Godot's SpringArm3D: a pivot carrying the yaw/pitch the
 * player aims with, and an arm that shortens when geometry would clip between
 * the camera and the character. `player.ts` eases `springLength` and `fov` for
 * the archer's aim zoom, so both stay writable.
 */
import {
  NeutralToneMapping,
  Object3D,
  PerspectiveCamera,
  PostProcessing,
  Scene,
  SRGBColorSpace,
  Vector2,
  Vector3,
  WebGPURenderer,
} from 'three'
import { mix, mrt, normalView, output, pass, uniform, vec3, vec4 } from 'three/tsl'
import { ao } from 'three/addons/tsl/display/GTAONode.js'
import { bloom } from 'three/addons/tsl/display/BloomNode.js'
import { smaa } from 'three/addons/tsl/display/SMAANode.js'
import type { WorldCollision } from './physics'
import { clampf, degToRad } from './gdmath'
import * as T from './tuning'

export interface QualityOptions {
  /** Master switch: off renders the scene straight to screen, no node graph. */
  post: boolean
  /** Ambient occlusion — the biggest "these things are actually touching" cue. */
  ao: boolean
  bloom: boolean
  antialias: boolean
  /** Render scale; <1 trades sharpness for framerate. */
  resolutionScale: number
  /**
   * Force the WebGL2 backend even where WebGPU exists. The node graph is
   * identical on both, but headless Chromium composites a WebGPU canvas as
   * black, so the automated screenshots have to go through WebGL2.
   */
  forceWebGL: boolean
}

const DEFAULT_QUALITY: QualityOptions = {
  post: true,
  ao: true,
  bloom: true,
  antialias: true,
  resolutionScale: 1,
  forceWebGL: false,
}

export class Engine {
  readonly renderer: WebGPURenderer
  readonly scene = new Scene()
  readonly camera: PerspectiveCamera
  /** Yaw/pitch carrier — the character's facing follows this. */
  readonly cameraPivot = new Object3D()
  /** Godot SpringArm3D.spring_length; eased by the archer aim zoom. */
  springLength = T.DEFAULT_SPRING_LENGTH

  /** camera_rotation in player.gd: x = yaw, y = pitch (radians). */
  cameraRotation = { x: 0, y: -0.15 }

  private postProcessing: PostProcessing | null = null
  private readonly quality: QualityOptions
  /** Live exposure, driven by the lighting preset. */
  private readonly exposureUniform = uniform(1)
  /** 0 = day, 1 = night. Drives the scotopic grade below. */
  private readonly nightUniform = uniform(0)
  private bloomStrength: { value: number } | null = null

  private readonly desired = new Vector3()
  private readonly pivotWorld = new Vector3()

  constructor(canvas: HTMLCanvasElement, quality: Partial<QualityOptions> = {}) {
    this.quality = { ...DEFAULT_QUALITY, ...quality }
    this.renderer = new WebGPURenderer({
      canvas,
      antialias: false, // handled in the post stack (SMAA), not by MSAA
      powerPreference: 'high-performance',
      forceWebGL: this.quality.forceWebGL,
    })
    this.renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2) * this.quality.resolutionScale)
    this.renderer.setSize(window.innerWidth, window.innerHeight)
    this.renderer.outputColorSpace = SRGBColorSpace
    // Khronos PBR Neutral. AgX was tried first and rolls highlights off
    // beautifully, but it desaturates hard — under it the overcast day sky
    // went from blue to a flat milky grey. Neutral keeps hue while still
    // taming the bright moon and firelight.
    this.renderer.toneMapping = NeutralToneMapping
    this.renderer.toneMappingExposure = 1
    this.renderer.shadowMap.enabled = true

    this.camera = new PerspectiveCamera(T.DEFAULT_CAMERA_FOV, window.innerWidth / window.innerHeight, 0.15, 1200)
    this.scene.add(this.cameraPivot)
    this.scene.add(this.camera)

    window.addEventListener('resize', this.onResize)
  }

  /** WebGPURenderer needs an async device handshake before the first frame. */
  async init(): Promise<void> {
    await this.renderer.init()
    if (this.quality.post) this.buildPostProcessing()
  }

  get backendName(): string {
    const anyRenderer = this.renderer as unknown as { backend?: { isWebGPUBackend?: boolean } }
    return anyRenderer.backend?.isWebGPUBackend ? 'WebGPU' : 'WebGL2'
  }

  /**
   * The post graph:
   *   scene ─┬─ colour ──────────────┐
   *          ├─ depth  ─┐            ├─ × AO ─ + bloom ─ SMAA ─ screen
   *          └─ normal ─┴─ GTAO ─────┘
   *
   * Tone mapping and the sRGB transform happen at the END via
   * `renderOutput()`, so AO and bloom operate on linear HDR values. Doing
   * either after tone mapping is what makes cheap post stacks look muddy.
   */
  private buildPostProcessing(): void {
    const pp = new PostProcessing(this.renderer)
    // We drive the output transform ourselves at the end of the chain.
    pp.outputColorTransform = false

    const scenePass = pass(this.scene, this.camera)
    // GTAO needs a view-space normal buffer. Without `normal` in the MRT the
    // AO node samples an empty target, returns zero, and multiplies the whole
    // image to black — which is exactly as silent as it sounds.
    scenePass.setMRT(mrt({ output, normal: normalView }))

    const colour = scenePass.getTextureNode('output')
    const depth = scenePass.getTextureNode('depth')
    const normal = scenePass.getTextureNode('normal')

    // Each stage is its own binding rather than one reassigned variable: the
    // TSL node types are precise per operation and don't narrow across
    // reassignment.
    let occluded
    if (this.quality.ao) {
      const aoPass = ao(depth, normal, this.camera)
      // Tuned for an outdoor scene: a wide radius reads as sky occlusion in
      // the grass and under the characters without haloing the horizon.
      aoPass.distanceExponent.value = 1.4
      aoPass.distanceFallOff.value = 0.7
      aoPass.radius.value = 0.9
      aoPass.scale.value = 1.4
      aoPass.thickness.value = 1.0
      // AO is low-frequency; half res is free quality.
      aoPass.resolutionScale = 0.5
      occluded = colour.mul(aoPass.getTextureNode())
    } else {
      occluded = colour.mul(1)
    }

    // Exposure lives in-graph so the lighting manager can drive it per preset
    // without fighting the renderer's own tone-mapping exposure.
    const exposed = occluded.mul(this.exposureUniform)

    // Night grade. Human night vision is nearly colourblind and blue-shifted;
    // without this the moonlit meadow renders as a bright green lawn under a
    // dark sky, which is exactly what "just turn the lights down" looks like.
    const luma = exposed.rgb.dot(vec3(0.2126, 0.7152, 0.0722))
    const desaturated = mix(exposed.rgb, luma.mul(vec3(0.82, 0.94, 1.28)), this.nightUniform.mul(0.62))
    const graded = vec4(desaturated, exposed.a)

    let composited: typeof graded | ReturnType<typeof graded.add> = graded
    if (this.quality.bloom) {
      // Threshold well above mid-grey so only genuine emitters bloom: the
      // moon disc, ground fire, sparks and the slash trail.
      const bloomPass = bloom(graded, 0.55, 0.5, 0.85)
      this.bloomStrength = bloomPass.strength as unknown as { value: number }
      composited = graded.add(bloomPass)
    }

    const finalNode = composited.renderOutput()
    pp.outputNode = this.quality.antialias ? smaa(finalNode) : finalNode
    this.postProcessing = pp
  }

  private onResize = (): void => {
    this.camera.aspect = window.innerWidth / window.innerHeight
    this.camera.updateProjectionMatrix()
    this.renderer.setSize(window.innerWidth, window.innerHeight)
  }

  /** Apply `cameraRotation` to the pivot (player.gd does this on every look). */
  syncPivotRotation(): void {
    this.cameraRotation.y = clampf(
      this.cameraRotation.y,
      degToRad(-T.CAMERA_VERTICAL_LIMIT),
      degToRad(T.CAMERA_VERTICAL_LIMIT),
    )
    this.cameraPivot.rotation.order = 'YXZ'
    this.cameraPivot.rotation.y = this.cameraRotation.x
    this.cameraPivot.rotation.x = this.cameraRotation.y
  }

  /**
   * Place the camera at the end of the spring arm, pulling it in when
   * something solid sits between the pivot and the ideal position.
   *
   * The probe goes through the BVH rather than `Raycaster.intersectObjects`:
   * this runs every frame against the whole village, and an unaccelerated
   * traversal of that mesh is a per-frame cost the game cannot afford.
   */
  updateSpringArm(world: WorldCollision): void {
    this.cameraPivot.updateWorldMatrix(true, false)
    this.cameraPivot.getWorldPosition(this.pivotWorld)

    // Arm points backward (+Z in pivot space) and is rotated by the pivot.
    this.desired.set(0, 0, 1).applyQuaternion(this.cameraPivot.quaternion)

    let length = this.springLength
    const hit = world.raycastDistance(this.pivotWorld, this.desired, this.springLength)
    if (hit !== null) length = Math.max(0.6, hit - 0.25)

    this.camera.position.copy(this.pivotWorld).addScaledVector(this.desired, length)
    this.camera.quaternion.copy(this.cameraPivot.quaternion)
  }

  setExposure(value: number): void {
    this.exposureUniform.value = value
  }

  /** 0 = day, 1 = night. Drives the scotopic desaturation. */
  setNightAmount(value: number): void {
    this.nightUniform.value = value
  }

  setBloomStrength(value: number): void {
    if (this.bloomStrength) this.bloomStrength.value = value
  }

  /** Screen size, for effects that need it. */
  get size(): Vector2 {
    return this.renderer.getSize(new Vector2())
  }

  render(): void {
    if (this.postProcessing) this.postProcessing.render()
    else this.renderer.render(this.scene, this.camera)
  }
}
