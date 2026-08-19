/**
 * The ground.
 *
 * It used to be a 1070 m cube with one tiled texture on top: perfectly flat,
 * visibly repeating, and ending on a razor line at the horizon. Three things
 * fix that, and they have to agree with each other:
 *
 *  1. **Relief.** A subdivided plane displaced by fbm noise, flattened to a
 *     dead-level pad under the village so the buildings don't float. The
 *     height function is exported so grass, props and spawns sit on the same
 *     surface the collider uses.
 *  2. **Macro variation.** The albedo mixes two tilings of the grass texture
 *     at very different scales against a low-frequency noise mask, which is
 *     what actually kills the "wallpaper" read — far more than any amount of
 *     extra texture resolution.
 *  3. **Surface normals.** A derived normal from the same noise gives the
 *     ground something for the moonlight to catch, so it stops looking like
 *     painted cardboard.
 */
import {
  BufferAttribute,
  Group,
  Mesh,
  MeshStandardNodeMaterial,
  PlaneGeometry,
  RepeatWrapping,
  type Texture,
  Vector3,
} from 'three'
import { Fn, float, mix, positionWorld, smoothstep, texture, vec2, vec3 } from 'three/tsl'
import type { Node } from 'three'
import type { ShaderNodeObject } from 'three/src/nodes/tsl/TSLCore.js'

/**
 * A TSL value of any node kind. The generated types are precise per
 * operation, which is helpful inside an expression and pure friction at
 * helper-function boundaries.
 */
type TSL = ShaderNodeObject<Node>
import type { AssetLoader } from '../core/assets'

/** Extent of the playable, displaced terrain (metres, centred on origin). */
export const TERRAIN_SIZE = 620
/** Vertex spacing ≈ TERRAIN_SIZE / SEGMENTS. */
const SEGMENTS = 280  // ~2.2 m spacing; the relief is low-frequency
/** Peak relief amplitude away from the village. */
const RELIEF = 7.5
/** Everything inside this radius is dead flat, for the village and spawns. */
const FLAT_RADIUS = 46
/** Relief ramps in between FLAT_RADIUS and this. */
const BLEND_RADIUS = 108

/**
 * Integer bit-mix hash. The obvious `sin(x*127.1 + y*311.7)*43758` costs a
 * transcendental per lattice corner — 16 of them per height query — and this
 * function is called for every terrain vertex, every scattered prop and every
 * one of ~100k grass tufts each time the field recentres. The bit mix is the
 * same quality here and roughly an order of magnitude cheaper.
 */
function hash2(x: number, y: number): number {
  let h = (Math.imul(x | 0, 0x27d4eb2d) ^ Math.imul(y | 0, 0x165667b1)) >>> 0
  h = Math.imul(h ^ (h >>> 15), 0x2545f491) >>> 0
  h ^= h >>> 13
  return (h >>> 0) / 4294967296
}

function valueNoise(x: number, y: number): number {
  const xi = Math.floor(x)
  const yi = Math.floor(y)
  const xf = x - xi
  const yf = y - yi
  // Smoothstep interpolation — bilinear alone leaves visible grid creases.
  const u = xf * xf * (3 - 2 * xf)
  const v = yf * yf * (3 - 2 * yf)
  const a = hash2(xi, yi)
  const b = hash2(xi + 1, yi)
  const c = hash2(xi, yi + 1)
  const d = hash2(xi + 1, yi + 1)
  return a * (1 - u) * (1 - v) + b * u * (1 - v) + c * (1 - u) * v + d * u * v
}

/** Four octaves is enough for rolling ground; more just adds noise. */
function fbm(x: number, y: number): number {
  let sum = 0
  let amp = 0.5
  let freq = 1
  for (let i = 0; i < 4; i++) {
    sum += valueNoise(x * freq, y * freq) * amp
    freq *= 2.07
    amp *= 0.5
  }
  return sum
}

/** The two river branches, as world-space centre-lines. */
const RIVER: [number, number, number, number][] = [
  [25, 137.9, -65, -17.9],
  [82.4, 2.4, -2.4, -82.4],
]
/** Channel half-width and depth. Water sits at WATER_LEVEL inside it. */
const RIVER_HALF_WIDTH = 6.5
const RIVER_DEPTH = 2.1
export const WATER_LEVEL = -1.15

/** Flat distance from (x, z) to a segment — the CPU twin of segmentDistance. */
function distanceToSegment(x: number, z: number, ax: number, az: number, bx: number, bz: number): number {
  const abx = bx - ax
  const abz = bz - az
  const denom = abx * abx + abz * abz
  const t = denom > 0 ? Math.min(Math.max(((x - ax) * abx + (z - az) * abz) / denom, 0), 1) : 0
  return Math.hypot(x - (ax + abx * t), z - (az + abz * t))
}

/**
 * World height at (x, z). The single source of truth: the terrain mesh is
 * built from it, and grass, scatter and spawn probes all query it, so nothing
 * floats and nothing sinks.
 */
export function terrainHeight(x: number, z: number): number {
  const r = Math.hypot(x, z)
  let h = 0
  if (r > FLAT_RADIUS) {
    const ramp = Math.min((r - FLAT_RADIUS) / (BLEND_RADIUS - FLAT_RADIUS), 1)
    // Smootherstep, so the pad meets the hills without a visible crease ring.
    const k = ramp * ramp * ramp * (ramp * (ramp * 6 - 15) + 10)
    const broad = fbm(x * 0.0042, z * 0.0042) - 0.5
    const detail = (fbm(x * 0.017, z * 0.017) - 0.5) * 0.28
    h = (broad + detail) * 2 * RELIEF * k
  }

  // Carve the river channel. The Godot build lays a flat water slab on flat
  // ground; on displaced terrain that slab just intersects the hillside and
  // reads as a rectangular hole, so the ground gets an actual valley instead
  // and the water sits down inside it.
  let carve = 0
  for (const [ax, az, bx, bz] of RIVER) {
    const d = distanceToSegment(x, z, ax, az, bx, bz)
    if (d >= RIVER_HALF_WIDTH * 2.6) continue
    // Smooth V with a flat bed: full depth in the channel, easing out to the
    // banks over roughly another channel width.
    const bank = 1 - Math.min(Math.max((d - RIVER_HALF_WIDTH) / (RIVER_HALF_WIDTH * 1.6), 0), 1)
    const smooth = bank * bank * (3 - 2 * bank)
    carve = Math.max(carve, smooth)
  }
  return h - carve * RIVER_DEPTH
}

export interface Terrain {
  root: Group
  mesh: Mesh
  height(x: number, z: number): number
}

export function buildTerrain(assets: AssetLoader): Terrain {
  const geometry = new PlaneGeometry(TERRAIN_SIZE, TERRAIN_SIZE, SEGMENTS, SEGMENTS)
  geometry.rotateX(-Math.PI / 2)

  const pos = geometry.attributes.position as BufferAttribute
  for (let i = 0; i < pos.count; i++) {
    pos.setY(i, terrainHeight(pos.getX(i), pos.getZ(i)))
  }
  pos.needsUpdate = true
  geometry.computeVertexNormals()

  const albedo = assets.texture('/assets/world/ground_grass.jpg')
  albedo.wrapS = albedo.wrapT = RepeatWrapping

  const material = new MeshStandardNodeMaterial()
  material.roughness = 0.94
  material.metalness = 0
  material.colorNode = groundColourNode(albedo)

  const mesh = new Mesh(geometry, material)
  mesh.name = 'Terrain'
  mesh.receiveShadow = true
  mesh.castShadow = false

  const root = new Group()
  root.name = 'Ground'
  root.add(mesh)

  return { root, mesh, height: terrainHeight }
}

/** GPU value noise, matching the CPU one closely enough for shading. */
const gpuNoise = /*@__PURE__*/ Fn(([p]: [TSL]) => {
  const i = p.floor()
  const f = p.fract()
  const u = f.mul(f).mul(f.mul(-2).add(3))
  const h = /*@__PURE__*/ Fn(([q]: [TSL]) =>
    q.x.mul(127.1).add(q.y.mul(311.7)).sin().mul(43758.5453).fract(),
  )
  const a = h(i)
  const b = h(i.add(vec2(1, 0)))
  const c = h(i.add(vec2(0, 1)))
  const d = h(i.add(vec2(1, 1)))
  return mix(mix(a, b, u.x), mix(c, d, u.x), u.y)
})

/**
 * Two tilings of the same texture, cross-faded by low-frequency noise, then
 * tinted by a second noise octave. Cheap, and it defeats the repeat pattern
 * that makes large ground planes look like wallpaper.
 */
function groundColourNode(albedo: Texture) {
  const world = positionWorld.xz

  // Two tilings close enough in scale that neither reads as a distinct
  // pattern. An earlier version mixed a 2.4 m tiling with a 12 m one, and the
  // coarse layer just looked like big blurry squares.
  const fine = texture(albedo, world.mul(0.55))
  const alt = texture(albedo, world.mul(0.31).add(vec2(0.37, 0.11)))
  const blendMask = gpuNoise(world.mul(0.035))
  const blended = mix(fine, alt, blendMask.mul(0.8).add(0.1))

  // Patchiness: drier, paler ground in broad sweeps, damp green in hollows.
  const patch = gpuNoise(world.mul(0.0055))
  const dry = vec3(0.40, 0.38, 0.24)
  const lush = vec3(0.18, 0.30, 0.12)
  const tint = mix(lush, dry, patch.mul(0.85).add(0.08))
  const grassColour = blended.rgb.mul(tint).mul(2.0)

  // Roads are painted into the terrain rather than laid on top of it. As
  // geometry they were hard-edged slabs that either floated over the relief
  // or cut into it; as a mask they follow the ground exactly and can have a
  // soft, worn edge.
  const path = pathMask(world)
  const dirt = vec3(0.20, 0.165, 0.125).mul(blended.rgb.mul(1.5).add(0.5))
  return mix(grassColour, dirt, path)
}

/**
 * Distance to a line segment in the XZ plane, as a TSL node.
 * Standard capsule SDF: project onto the segment, clamp, measure.
 */
const segmentDistance = /*@__PURE__*/ Fn(([p, a, b]: [TSL, TSL, TSL]) => {
  const pa = p.sub(a)
  const ba = b.sub(a)
  const h = pa.dot(ba).div(ba.dot(ba).max(0.0001)).clamp(0, 1)
  return pa.sub(ba.mul(h)).length()
})

/** The three roads from the Godot scene, as world-space segments. */
const ROADS: [number, number, number, number][] = [
  [-11.7, -58.3, -68.3, -1.7], // The Long Road
  [62.5, -64.0, 17.5, 14.0], // Trade Road
  [0, 0, 0, 70], // North Road
]

function pathMask(world: TSL): TSL {
  const halfWidth = float(2.6)
  let mask: TSL = float(0)
  for (const [ax, az, bx, bz] of ROADS) {
    const d = segmentDistance(world, vec2(ax, az), vec2(bx, bz))
    // Wander the edge with noise so the road isn't a stencil-clean stripe.
    const edge = halfWidth.add(gpuNoise(world.mul(0.35)).mul(1.1).sub(0.3))
    mask = mask.max(smoothstep(edge, edge.mul(0.35), d))
  }
  return mask.clamp(0, 1)
}

// NOTE: an earlier version perturbed the normal with a tangent-space
// normalNode. PlaneGeometry carries no tangents, so three derived a per-face
// tangent frame and the terrain shaded as visible 2.2 m facets. Surface
// interest comes from the albedo variation and the geometric relief instead.

/** Convenience for placing anything on the ground. */
export function groundPoint(x: number, z: number, out = new Vector3()): Vector3 {
  return out.set(x, terrainHeight(x, z), z)
}
