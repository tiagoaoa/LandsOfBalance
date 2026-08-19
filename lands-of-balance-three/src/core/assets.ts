/**
 * GLB loading with a progress-reporting cache.
 *
 * The Godot build loads a rigged GLB plus ~25 animation FBXs per character
 * and retargets at runtime. That's far too much work for a browser, so
 * `scripts/bake_characters.py` does the retarget offline and ships one GLB
 * per character with every clip already named after its Godot key
 * ("SwordSlash", "DodgeF", "AimWalkBack", ...). This module just loads them.
 */
import {
  type AnimationClip,
  Box3,
  type Group,
  LoadingManager,
  type Object3D,
  RepeatWrapping,
  type Texture,
  TextureLoader,
  Vector3,
} from 'three'
import { GLTFLoader } from 'three/examples/jsm/loaders/GLTFLoader.js'

export interface LoadedModel {
  scene: Group
  clips: Map<string, AnimationClip>
}

export class AssetLoader {
  private readonly manager = new LoadingManager()
  private readonly gltf = new GLTFLoader(this.manager)
  private readonly textures = new TextureLoader(this.manager)
  private readonly cache = new Map<string, Promise<LoadedModel>>()

  onProgress: ((loaded: number, total: number, url: string) => void) | null = null

  constructor() {
    this.manager.onProgress = (url, loaded, total) => this.onProgress?.(loaded, total, url)
  }

  load(url: string): Promise<LoadedModel> {
    let entry = this.cache.get(url)
    if (!entry) {
      entry = this.gltf.loadAsync(url).then((g) => ({
        scene: g.scene as Group,
        clips: new Map(g.animations.map((c) => [c.name, c])),
      }))
      this.cache.set(url, entry)
    }
    return entry
  }

  /** A fresh instance of a cached model — clones share geometry/materials. */
  async instance(url: string): Promise<LoadedModel> {
    const base = await this.load(url)
    const { clone } = await import('three/examples/jsm/utils/SkeletonUtils.js')
    return { scene: clone(base.scene) as Group, clips: base.clips }
  }

  texture(url: string, repeat = 1): Texture {
    const tex = this.textures.load(url)
    if (repeat !== 1) {
      tex.wrapS = tex.wrapT = RepeatWrapping
      tex.repeat.set(repeat, repeat)
    }
    return tex
  }
}

/**
 * Uniformly scale `root` so it stands `targetMeters` tall.
 *
 * The Godot build hardcodes a per-rig scale factor (e.g. `MODEL_SCALE = 0.53`
 * for the draugr, "rig is ~3.5 units tall"), but those factors are relative to
 * how Godot's FBX importer sized the rig. Our GLBs come through Blender at a
 * different base scale, so a copied constant would be meaningless. Measuring
 * the rendered bounds and fitting to the height the Godot factor produces
 * gives the same on-screen size without depending on either importer.
 */
export function fitToHeight(root: Object3D, targetMeters: number): number {
  root.updateWorldMatrix(true, true)
  const height = measureRigHeight(root)
  if (!Number.isFinite(height) || height <= 1e-4) return 1
  const factor = targetMeters / height
  root.scale.multiplyScalar(factor)
  root.updateWorldMatrix(true, true)
  return factor
}

const _bonePos = new Vector3()

/**
 * Standing height of a rig, measured from its BONES.
 *
 * `Box3.setFromObject` measures undeformed geometry, which is worthless for
 * some of these assets: the draugr's mesh is authored lying along Z and only
 * stands up once the bind matrices are applied, so a geometry bbox reports a
 * 0.12 m creature. The bone hierarchy is already posed, so its vertical
 * extent is the number we actually want. Falls back to the geometry bounds
 * for unskinned props.
 */
export function measureRigHeight(root: Object3D): number {
  let lo = Infinity
  let hi = -Infinity
  root.traverse((o) => {
    if (!(o as { isBone?: boolean }).isBone) return
    o.getWorldPosition(_bonePos)
    lo = Math.min(lo, _bonePos.y)
    hi = Math.max(hi, _bonePos.y)
  })
  if (hi > lo) return hi - lo
  const box = new Box3().setFromObject(root, true)
  return box.max.y - box.min.y
}

/** Enable shadows on every mesh under `root` — Godot does this per-node. */
export function enableShadows(root: Object3D, cast = true, receive = true): void {
  root.traverse((o) => {
    const m = o as { isMesh?: boolean; castShadow?: boolean; receiveShadow?: boolean; frustumCulled?: boolean }
    if (m.isMesh) {
      m.castShadow = cast
      m.receiveShadow = receive
    }
    // Skinned meshes whose bounds the animation pushes around are culled
    // wrongly by the default sphere; the Godot importer has the same problem
    // and solves it the same way.
    const s = o as { isSkinnedMesh?: boolean; frustumCulled?: boolean }
    if (s.isSkinnedMesh) s.frustumCulled = false
  })
}
