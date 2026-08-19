/**
 * Port of combat/slash_trail.gd plus the small hit-feedback effects.
 *
 * The golden rule of this project's combat is that damage only ever happens
 * on visible contact — so the slash ribbon is drawn *exactly* while the blade
 * can hurt (`_hitbox_active_window`). The visible arc IS the hit volume's
 * path, which is what makes the rule legible to the player.
 */
import {
  AdditiveBlending,
  BufferGeometry,
  Color,
  DoubleSide,
  Float32BufferAttribute,
  Group,
  Mesh,
  MeshBasicMaterial,
  Points,
  PointsMaterial,
  type Scene,
  Vector3,
} from 'three'
import { randRange } from '../core/gdmath'
import { Label3D } from '../world/label3d'
import { sparkSprite } from './sprites'

const TRAIL_SEGMENTS = 14

/**
 * A ribbon that follows the blade tip. Points are pushed each frame while
 * `emitting`, and fade out behind the swing.
 */
export class SlashTrail {
  readonly mesh: Mesh
  emitting = false
  color = new Color(0xffe68c)

  private readonly top: Vector3[] = []
  private readonly bottom: Vector3[] = []
  private readonly geometry = new BufferGeometry()
  private readonly material: MeshBasicMaterial
  private live = 0

  constructor() {
    for (let i = 0; i < TRAIL_SEGMENTS; i++) {
      this.top.push(new Vector3())
      this.bottom.push(new Vector3())
    }
    const verts = new Float32Array(TRAIL_SEGMENTS * 2 * 3)
    const colors = new Float32Array(TRAIL_SEGMENTS * 2 * 3)
    const indices: number[] = []
    for (let i = 0; i < TRAIL_SEGMENTS - 1; i++) {
      const a = i * 2
      indices.push(a, a + 1, a + 2, a + 1, a + 3, a + 2)
    }
    this.geometry.setAttribute('position', new Float32BufferAttribute(verts, 3))
    this.geometry.setAttribute('color', new Float32BufferAttribute(colors, 3))
    this.geometry.setIndex(indices)
    this.material = new MeshBasicMaterial({
      vertexColors: true,
      transparent: true,
      opacity: 0.85,
      blending: AdditiveBlending,
      depthWrite: false,
      side: DoubleSide,
      fog: false,
    })
    this.mesh = new Mesh(this.geometry, this.material)
    this.mesh.frustumCulled = false
    this.mesh.visible = false
  }

  /** Feed the blade's current root/tip world positions. */
  push(root: Vector3, tip: Vector3): void {
    for (let i = TRAIL_SEGMENTS - 1; i > 0; i--) {
      this.top[i].copy(this.top[i - 1])
      this.bottom[i].copy(this.bottom[i - 1])
    }
    this.top[0].copy(tip)
    this.bottom[0].copy(root)
    this.live = TRAIL_SEGMENTS
  }

  /** Snap the whole ribbon to one pose — used when a swing starts. */
  reset(root: Vector3, tip: Vector3): void {
    for (let i = 0; i < TRAIL_SEGMENTS; i++) {
      this.top[i].copy(tip)
      this.bottom[i].copy(root)
    }
    this.live = 0
  }

  update(): void {
    if (!this.emitting && this.live > 0) this.live--
    this.mesh.visible = this.emitting || this.live > 0
    if (!this.mesh.visible) return

    const pos = this.geometry.getAttribute('position') as Float32BufferAttribute
    const col = this.geometry.getAttribute('color') as Float32BufferAttribute
    for (let i = 0; i < TRAIL_SEGMENTS; i++) {
      pos.setXYZ(i * 2, this.bottom[i].x, this.bottom[i].y, this.bottom[i].z)
      pos.setXYZ(i * 2 + 1, this.top[i].x, this.top[i].y, this.top[i].z)
      // Fade along the tail so the arc reads as motion, not a solid fan.
      const f = Math.pow(1 - i / TRAIL_SEGMENTS, 1.6)
      col.setXYZ(i * 2, this.color.r * f, this.color.g * f, this.color.b * f)
      col.setXYZ(i * 2 + 1, this.color.r * f, this.color.g * f, this.color.b * f)
    }
    pos.needsUpdate = true
    col.needsUpdate = true
  }
}

interface Spark {
  points: Points
  velocities: Vector3[]
  life: number
  maxLife: number
}

/** Short-lived burst where the blade met the body — the hack-and-slash clang. */
export class SparkPool {
  private readonly active: Spark[] = []

  constructor(private readonly scene: Scene) {}

  spawn(pos: Vector3, color: number, count = 22): void {
    const positions = new Float32Array(count * 3)
    const velocities: Vector3[] = []
    for (let i = 0; i < count; i++) {
      positions[i * 3] = pos.x
      positions[i * 3 + 1] = pos.y
      positions[i * 3 + 2] = pos.z
      const dir = new Vector3(randRange(-1, 1), randRange(-0.2, 1), randRange(-1, 1)).normalize()
      velocities.push(dir.multiplyScalar(randRange(2.5, 7)))
    }
    const geo = new BufferGeometry()
    geo.setAttribute('position', new Float32BufferAttribute(positions, 3))
    const points = new Points(
      geo,
      new PointsMaterial({
        map: sparkSprite(),
        color,
        size: 0.14,
        transparent: true,
        blending: AdditiveBlending,
        depthWrite: false,
        fog: false,
      }),
    )
    points.frustumCulled = false
    this.scene.add(points)
    this.active.push({ points, velocities, life: 0, maxLife: 0.42 })
  }

  update(dt: number): void {
    for (let i = this.active.length - 1; i >= 0; i--) {
      const s = this.active[i]
      s.life += dt
      if (s.life >= s.maxLife) {
        this.scene.remove(s.points)
        s.points.geometry.dispose()
        ;(s.points.material as PointsMaterial).dispose()
        this.active.splice(i, 1)
        continue
      }
      const pos = s.points.geometry.getAttribute('position') as Float32BufferAttribute
      for (let k = 0; k < s.velocities.length; k++) {
        const v = s.velocities[k]
        v.y -= 22 * dt // sparks fall under the same gravity as everything else
        pos.setXYZ(k, pos.getX(k) + v.x * dt, pos.getY(k) + v.y * dt, pos.getZ(k) + v.z * dt)
      }
      pos.needsUpdate = true
      ;(s.points.material as PointsMaterial).opacity = 1 - s.life / s.maxLife
    }
  }
}

interface FloatingLabel {
  label: Label3D
  life: number
  maxLife: number
  origin: Vector3
  /** Label3D sizes itself from its canvas; the pop scales relative to that. */
  baseScale: { x: number; y: number }
}

/**
 * Port of `_show_hit_label` — text that pops, floats up and fades. The Godot
 * version tweens scale, position and alpha; same curve here.
 */
export class FloatingTextPool {
  private readonly active: FloatingLabel[] = []
  readonly root = new Group()

  constructor(scene: Scene) {
    scene.add(this.root)
  }

  spawn(worldPos: Vector3, text: string, color = 0xff6650): void {
    const label = new Label3D(text, {
      fontSize: 40,
      color: `#${color.toString(16).padStart(6, '0')}`,
      outlineSize: 5,
      worldScale: 0.006,
      noDepthTest: true,
    })
    label.position.copy(worldPos)
    label.renderOrder = 40
    this.root.add(label)
    this.active.push({
      label,
      life: 0,
      maxLife: 1.1,
      origin: worldPos.clone(),
      baseScale: { x: label.scale.x, y: label.scale.y },
    })
  }

  update(dt: number): void {
    for (let i = this.active.length - 1; i >= 0; i--) {
      const f = this.active[i]
      f.life += dt
      const t = f.life / f.maxLife
      if (t >= 1) {
        this.root.remove(f.label)
        this.active.splice(i, 1)
        continue
      }
      // Rise 1.3 m over the life, hold opacity then fade out over the tail.
      f.label.position.set(f.origin.x, f.origin.y + 1.3 * Math.min(t * 1.6, 1), f.origin.z)
      f.label.setOpacity(t < 0.55 ? 1 : 1 - (t - 0.55) / 0.45)
      // Overshoot pop on the way in (Godot tweens this with TRANS_BACK).
      const pop = t < 0.14 ? 0.6 + (t / 0.14) * 0.6 : 1.2 - Math.min((t - 0.14) / 0.2, 1) * 0.2
      f.label.scale.set(f.baseScale.x * pop, f.baseScale.y * pop, 1)
    }
  }
}
