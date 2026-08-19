/**
 * World scatter: trees, rocks and bushes.
 *
 * The field beyond the grass radius was an empty green plain running to the
 * horizon — no silhouettes, no depth cues, nothing to judge distance or
 * scale against. That emptiness read as "unfinished" more loudly than any
 * shader problem.
 *
 * Everything here is generated: low-poly trunks, canopy blobs and displaced
 * icosahedron rocks, drawn as a handful of InstancedMeshes. Density falls off
 * with distance, the village pad and the roads are kept clear, and the canopy
 * shares the grass's wind so the treeline isn't eerily still while the field
 * moves.
 */
import {
  CylinderGeometry,
  Group,
  IcosahedronGeometry,
  InstancedBufferAttribute,
  InstancedMesh,
  Matrix4,
  MeshStandardNodeMaterial,
  Quaternion,
  Vector3,
  type BufferGeometry,
} from 'three'
import { mergeGeometries } from 'three/examples/jsm/utils/BufferGeometryUtils.js'
import { Fn, attribute, cos, float, mix, positionLocal, sin, time, uv, vec3 } from 'three/tsl'
import type { Node } from 'three'
import type { ShaderNodeObject } from 'three/src/nodes/tsl/TSLCore.js'

/** A TSL value of any node kind — see the note in terrain.ts. */
type TSL = ShaderNodeObject<Node>
import { randRange } from '../core/gdmath'
import { terrainHeight } from './terrain'

const TREE_COUNT = 900
const ROCK_COUNT = 700
const BUSH_COUNT = 1400

/** Nothing is placed inside this radius — the village pad and the arena. */
const CLEAR_RADIUS = 52
const SCATTER_RADIUS = 290

/** Road centre-lines, so trees don't grow in the middle of the track. */
const ROADS: [number, number, number, number][] = [
  [-11.7, -58.3, -68.3, -1.7],
  [62.5, -64.0, 17.5, 14.0],
  [0, 0, 0, 70],
]

function distanceToRoads(x: number, z: number): number {
  let best = Infinity
  for (const [ax, az, bx, bz] of ROADS) {
    const abx = bx - ax
    const abz = bz - az
    const t = Math.min(Math.max(((x - ax) * abx + (z - az) * abz) / (abx * abx + abz * abz), 0), 1)
    best = Math.min(best, Math.hypot(x - (ax + abx * t), z - (az + abz * t)))
  }
  return best
}

/**
 * Two species, because a forest of one silhouette repeated 900 times reads as
 * a pattern no matter how you scatter it.
 *
 * `conifer` is a tapered trunk under stacked cones; `broadleaf` is a taller
 * bare trunk under overlapping crown blobs.
 */
function conifer(): { trunk: BufferGeometry; canopy: BufferGeometry } {
  const trunk = new CylinderGeometry(0.12, 0.3, 3.2, 6, 1)
  trunk.translate(0, 1.6, 0)

  const tiers: BufferGeometry[] = []
  for (let i = 0; i < 3; i++) {
    const t = i / 2
    const cone = new CylinderGeometry(0, 1.9 - t * 0.85, 2.3 - t * 0.5, 7, 1)
    cone.translate(0, 2.5 + i * 1.25, 0)
    tiers.push(cone)
  }
  return { trunk, canopy: mergeGeometries(tiers) ?? tiers[0] }
}

function broadleaf(): { trunk: BufferGeometry; canopy: BufferGeometry } {
  const trunk = new CylinderGeometry(0.16, 0.34, 4.1, 6, 1)
  trunk.translate(0, 2.05, 0)

  const blobs: BufferGeometry[] = []
  const offsets: [number, number, number, number][] = [
    [0, 4.9, 0, 1.65],
    [0.85, 4.35, 0.35, 1.15],
    [-0.75, 4.5, -0.5, 1.05],
    [0.2, 5.6, -0.6, 0.95],
  ]
  for (const [x, y, z, r] of offsets) {
    const blob = new IcosahedronGeometry(r, 1)
    blob.scale(1, 0.82, 1)
    blob.translate(x, y, z)
    blobs.push(blob)
  }
  return { trunk, canopy: mergeGeometries(blobs) ?? blobs[0] }
}

/** Displaced icosahedron — reads as a weathered boulder at any distance. */
function rockGeometry(): BufferGeometry {
  const geo = new IcosahedronGeometry(1, 1)
  const pos = geo.attributes.position
  const v = new Vector3()
  for (let i = 0; i < pos.count; i++) {
    v.fromBufferAttribute(pos, i)
    // Hash off the vertex position so the deformation is stable and the
    // shared vertices of the icosahedron move together (no split seams).
    const n = Math.sin(v.x * 12.9898 + v.y * 78.233 + v.z * 37.719) * 43758.5453
    const d = 0.78 + (n - Math.floor(n)) * 0.44
    v.multiplyScalar(d)
    v.y *= 0.72 // squat, so they sit rather than float
    pos.setXYZ(i, v.x, v.y, v.z)
  }
  geo.computeVertexNormals()
  return geo
}

interface Placement {
  x: number
  z: number
  scale: number
  /** Vertical stretch, decided once so all parts of an object share it. */
  stretch: number
  yaw: number
}

function placements(count: number, minRadius: number, maxRadius: number, roadClearance: number): Placement[] {
  const out: Placement[] = []
  let guard = 0
  while (out.length < count && guard < count * 12) {
    guard++
    // Bias outward: sqrt() alone clusters everything at the inner edge.
    const r = minRadius + (maxRadius - minRadius) * Math.sqrt(Math.random())
    const a = Math.random() * Math.PI * 2
    const x = Math.cos(a) * r
    const z = Math.sin(a) * r
    if (Math.hypot(x, z) < CLEAR_RADIUS) continue
    if (distanceToRoads(x, z) < roadClearance) continue
    out.push({
      x,
      z,
      scale: randRange(0.75, 1.5),
      stretch: randRange(0.85, 1.2),
      yaw: Math.random() * Math.PI * 2,
    })
  }
  return out
}

/**
 * Transforms are baked ONCE per spot set and reused across every part of the
 * object. Re-randomising inside the builder would give a tree's trunk and its
 * canopy different heights — they'd come apart.
 */
interface Baked {
  matrices: Matrix4[]
  phase: Float32Array
  /** Per-instance 0..1 roll, used to vary foliage tint. */
  tint: Float32Array
}

function bake(spots: Placement[], scaleBias: number, sink: number): Baked {
  const matrices: Matrix4[] = []
  const phase = new Float32Array(spots.length)
  const tint = new Float32Array(spots.length)
  const pos = new Vector3()
  const quat = new Quaternion()
  const scl = new Vector3()
  const up = new Vector3(0, 1, 0)

  spots.forEach((s, i) => {
    pos.set(s.x, terrainHeight(s.x, s.z) - sink, s.z)
    quat.setFromAxisAngle(up, s.yaw)
    const k = s.scale * scaleBias
    scl.set(k, k * s.stretch, k)
    matrices.push(new Matrix4().compose(pos, quat, scl))
    phase[i] = Math.random() * Math.PI * 2
    tint[i] = Math.random()
  })
  return { matrices, phase, tint }
}

function buildInstanced(
  geometry: BufferGeometry,
  material: MeshStandardNodeMaterial,
  baked: Baked,
  castShadow = true,
): InstancedMesh {
  const mesh = new InstancedMesh(geometry, material, baked.matrices.length)
  // Only the trees are worth a shadow pass: 1400 ankle-high bushes cost real
  // fill time and cast shadows nobody can distinguish from the grass.
  mesh.castShadow = castShadow
  mesh.receiveShadow = true
  mesh.frustumCulled = false
  baked.matrices.forEach((m, i) => mesh.setMatrixAt(i, m))
  mesh.instanceMatrix.needsUpdate = true
  geometry.setAttribute('aPhase', new InstancedBufferAttribute(baked.phase, 1))
  geometry.setAttribute('aTint', new InstancedBufferAttribute(baked.tint, 1))
  return mesh
}

/** Canopy and bushes sway; a still treeline beside moving grass looks wrong. */
const foliageSway = /*@__PURE__*/ Fn(([phase, amount]: [TSL, TSL]) => {
  const local = positionLocal
  // Height-weighted, so the sway pivots at the trunk.
  const h = local.y.mul(0.22).clamp(0, 1)
  const t = time.mul(0.7).add(phase)
  const sway = sin(t).add(sin(t.mul(2.3).add(1.1)).mul(0.35)).mul(amount)
  return vec3(local.x.add(sway.mul(h).mul(cos(phase))), local.y, local.z.add(sway.mul(h).mul(sin(phase))))
})

export function buildScatter(): Group {
  const root = new Group()
  root.name = 'Scatter'

  const pine = conifer()
  const leafy = broadleaf()
  // Split the tree budget between the two species.
  const pineSpots = placements(Math.round(TREE_COUNT * 0.62), CLEAR_RADIUS, SCATTER_RADIUS, 7)
  const leafySpots = placements(TREE_COUNT - pineSpots.length, CLEAR_RADIUS, SCATTER_RADIUS, 7)
  const rockSpots = placements(ROCK_COUNT, CLEAR_RADIUS, SCATTER_RADIUS, 4)
  const bushSpots = placements(BUSH_COUNT, CLEAR_RADIUS * 0.75, SCATTER_RADIUS * 0.8, 3.5)

  const barkMat = new MeshStandardNodeMaterial()
  barkMat.roughness = 0.95
  barkMat.metalness = 0
  barkMat.colorNode = vec3(0.14, 0.10, 0.075)

  const leafMat = new MeshStandardNodeMaterial()
  leafMat.roughness = 1.0
  leafMat.metalness = 0
  const leafPhase = attribute('aPhase', 'float')
  // Darker at the base of each tier, lighter at the tips — reads as depth in
  // the canopy without a texture.
  // Depth within the canopy (uv.y) crossed with a per-tree tint roll, so no
  // two trees are quite the same green.
  const leafTint = attribute('aTint', 'float')
  const canopyDepth = mix(vec3(0.022, 0.038, 0.02), vec3(0.062, 0.095, 0.045), uv().y)
  leafMat.colorNode = canopyDepth.mul(mix(float(0.7), float(1.35), leafTint))
  leafMat.positionNode = foliageSway(leafPhase, float(0.06))

  const rockMat = new MeshStandardNodeMaterial()
  rockMat.roughness = 0.85
  rockMat.metalness = 0.05
  rockMat.colorNode = vec3(0.17, 0.165, 0.15)

  const bushMat = new MeshStandardNodeMaterial()
  bushMat.roughness = 1.0
  bushMat.metalness = 0
  const bushPhase = attribute('aPhase', 'float')
  bushMat.colorNode = vec3(0.07, 0.105, 0.05)
  bushMat.positionNode = foliageSway(bushPhase, float(0.09))

  // One bake per object type; trunk and canopy share the tree bake so they
  // stay welded together.
  const pineBake = bake(pineSpots, 1, 0.15)
  root.add(buildInstanced(pine.trunk, barkMat, pineBake))
  root.add(buildInstanced(pine.canopy, leafMat, pineBake))
  const leafyBake = bake(leafySpots, 1, 0.15)
  root.add(buildInstanced(leafy.trunk, barkMat, leafyBake))
  root.add(buildInstanced(leafy.canopy, leafMat.clone(), leafyBake))
  root.add(buildInstanced(rockGeometry(), rockMat, bake(rockSpots, 0.85, 0.35)))
  root.add(buildInstanced(new IcosahedronGeometry(0.55, 0), bushMat, bake(bushSpots, 1, 0.18), false))

  return root
}
