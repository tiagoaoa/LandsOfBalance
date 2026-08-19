/**
 * Godot's `CharacterBody3D.move_and_slide()`, rebuilt on three-mesh-bvh.
 *
 * Everything that walks in this game is a kinematic capsule pushed through
 * static world geometry: it slides along walls, climbs shallow slopes, is
 * stopped by steep ones, and reports `is_on_floor()`. That behaviour is what
 * the ported movement code assumes at every turn, so it lives here once
 * instead of being approximated per entity.
 *
 * Resolution is the standard BVH shapecast sweep: gather the triangles
 * overlapping the capsule, push the capsule out along the shallowest
 * separating direction, repeat a few times. The vertical component of the
 * accumulated push is what tells us we landed on something.
 */
import { Box3, Line3, Matrix4, type Mesh, type Object3D, Quaternion, Ray, Vector3 } from 'three'
import { MeshBVH } from 'three-mesh-bvh'

/** Slopes steeper than this are walls, not floors (Godot's default is 45°). */
const FLOOR_NORMAL_Y = Math.cos((46 * Math.PI) / 180)
/** Push-out iterations per move. More = less chance of tunnelling a wall. */
const SOLVE_STEPS = 4

interface Collider {
  bvh: MeshBVH
  toLocal: Matrix4
  toWorld: Matrix4
  bounds: Box3
  /** Uniform scale factor of `toWorld`, to convert radii into local space. */
  localScale: number
}

export interface MoveResult {
  onFloor: boolean
  onCeiling: boolean
  onWall: boolean
}

const _box = new Box3()
const _queryBox = new Box3()
const _seg = new Line3()
const _localSeg = new Line3()
const _triPoint = new Vector3()
const _capPoint = new Vector3()
const _delta = new Vector3()
const _tmp = new Vector3()
const _worldStart = new Vector3()
const _ray = new Ray()

export class WorldCollision {
  private readonly colliders: Collider[] = []

  /**
   * Register a mesh as solid world. Call once the mesh's world matrix is
   * final: the BVH is built in mesh-local space and the transform baked in
   * here, so later movement of the mesh is not tracked.
   */
  addMesh(mesh: Mesh): void {
    const geom = mesh.geometry
    if (!geom?.attributes.position) return
    mesh.updateWorldMatrix(true, false)

    const bvh = new MeshBVH(geom, { targetLeafSize: 8 })
    const toWorld = mesh.matrixWorld.clone()
    const bounds = new Box3()
    bvh.getBoundingBox(bounds)
    bounds.applyMatrix4(toWorld)

    // Capsule radii are world-space; the shapecast runs in local space.
    const scale = new Vector3()
    toWorld.decompose(new Vector3(), new Quaternion(), scale)
    this.colliders.push({
      bvh,
      toWorld,
      toLocal: toWorld.clone().invert(),
      bounds,
      localScale: 1 / Math.max(scale.x, scale.y, scale.z, 1e-6),
    })
  }

  /** Register every visible mesh under `root`. */
  addAll(root: Object3D): void {
    root.updateWorldMatrix(true, true)
    root.traverse((o) => {
      const m = o as Mesh
      if (m.isMesh && m.visible) this.addMesh(m)
    })
  }

  get colliderCount(): number {
    return this.colliders.length
  }

  /**
   * Downward probe at (x, z) — Godot's `intersect_ray` ground query, used to
   * plant spawn points and settle props onto the terrain. Returns the highest
   * surface Y under the point, or `null` if nothing is there.
   */
  groundHeight(x: number, z: number, fromY = 200, maxDist = 400): number | null {
    let best: number | null = null
    for (const c of this.colliders) {
      if (x < c.bounds.min.x || x > c.bounds.max.x) continue
      if (z < c.bounds.min.z || z > c.bounds.max.z) continue
      _ray.origin.set(x, fromY, z).applyMatrix4(c.toLocal)
      _ray.direction.set(0, -1, 0).transformDirection(c.toLocal).normalize()
      const hit = c.bvh.raycastFirst(_ray, undefined, 0, maxDist)
      if (!hit) continue
      const y = _tmp.copy(hit.point).applyMatrix4(c.toWorld).y
      if (best === null || y > best) best = y
    }
    return best
  }

  /**
   * Nearest world hit along a ray, as a distance — the spring-arm camera's
   * "is something between me and the player" query. BVH-accelerated, because
   * this runs every frame against the whole village.
   */
  raycastDistance(origin: Vector3, direction: Vector3, maxDist: number): number | null {
    let best: number | null = null
    for (const c of this.colliders) {
      _ray.origin.copy(origin).applyMatrix4(c.toLocal)
      _ray.direction.copy(direction).transformDirection(c.toLocal).normalize()
      // A world length is `localScale` times as long in the mesh's own space.
      const hit = c.bvh.raycastFirst(_ray, undefined, 0, maxDist * c.localScale)
      if (!hit) continue
      const d = _tmp.copy(hit.point).applyMatrix4(c.toWorld).distanceTo(origin)
      if (d <= maxDist && (best === null || d < best)) best = d
    }
    return best
  }

  /**
   * Push a capsule out of the world.
   *
   * `position` is the capsule's FOOT — the entity origin, matching Godot's
   * CharacterBody3D convention — and is mutated in place.
   */
  resolve(position: Vector3, radius: number, height: number, out: MoveResult): MoveResult {
    out.onFloor = false
    out.onCeiling = false
    out.onWall = false
    const topOffset = Math.max(height - radius, radius)

    for (let step = 0; step < SOLVE_STEPS; step++) {
      _seg.start.set(position.x, position.y + radius, position.z)
      _seg.end.set(position.x, position.y + topOffset, position.z)

      let moved = false
      for (const c of this.colliders) {
        _box.makeEmpty().expandByPoint(_seg.start).expandByPoint(_seg.end)
        _box.min.addScalar(-radius)
        _box.max.addScalar(radius)
        if (!c.bounds.intersectsBox(_box)) continue

        _localSeg.copy(_seg)
        _localSeg.start.applyMatrix4(c.toLocal)
        _localSeg.end.applyMatrix4(c.toLocal)
        _worldStart.copy(_localSeg.start)
        const localRadius = radius * c.localScale

        _queryBox.makeEmpty().expandByPoint(_localSeg.start).expandByPoint(_localSeg.end)
        _queryBox.min.addScalar(-localRadius)
        _queryBox.max.addScalar(localRadius)

        c.bvh.shapecast({
          intersectsBounds: (box) => box.intersectsBox(_queryBox),
          intersectsTriangle: (tri) => {
            const dist = tri.closestPointToSegment(_localSeg, _triPoint, _capPoint)
            if (dist >= localRadius) return false
            _delta.copy(_capPoint).sub(_triPoint)
            if (_delta.lengthSq() < 1e-12) return false
            _delta.normalize().multiplyScalar(localRadius - dist)
            _localSeg.start.add(_delta)
            _localSeg.end.add(_delta)
            moved = true
            return false
          },
        })

        if (!moved) continue
        // Convert the local-space correction back by transforming both
        // endpoints — `transformDirection` normalises, which would throw the
        // penetration depth away.
        _delta
          .copy(_localSeg.start)
          .applyMatrix4(c.toWorld)
          .sub(_tmp.copy(_worldStart).applyMatrix4(c.toWorld))
        if (_delta.lengthSq() < 1e-12) continue
        position.add(_delta)

        const ny = _delta.clone().normalize().y
        if (ny > FLOOR_NORMAL_Y) out.onFloor = true
        else if (ny < -FLOOR_NORMAL_Y) out.onCeiling = true
        else out.onWall = true

        _seg.start.set(position.x, position.y + radius, position.z)
        _seg.end.set(position.x, position.y + topOffset, position.z)
      }
      if (!moved) break
    }
    return out
  }
}

const _before = new Vector3()
const _applied = new Vector3()

/**
 * The moving half of `move_and_slide`: integrate velocity, resolve the
 * overlap, and let the resolution cancel the velocity that ran into
 * geometry, so actors slide along walls rather than sticking to them.
 */
export function moveAndSlide(
  world: WorldCollision,
  position: Vector3,
  velocity: Vector3,
  radius: number,
  height: number,
  dt: number,
  out: MoveResult,
): MoveResult {
  _before.copy(position)
  position.addScaledVector(velocity, dt)
  world.resolve(position, radius, height, out)

  _applied.copy(position).sub(_before).divideScalar(Math.max(dt, 1e-6))
  if (out.onFloor && velocity.y < 0) velocity.y = 0
  if (out.onCeiling && velocity.y > 0) velocity.y = 0
  if (out.onWall) {
    velocity.x = _applied.x
    velocity.z = _applied.z
  }
  return out
}
