/**
 * River water.
 *
 * The Godot scene uses a translucent box, which on a displaced landscape
 * reads as a rectangular hole rather than a river. This is a subdivided
 * surface with two travelling ripple fields perturbing the normal, a fresnel
 * rim so it brightens at grazing angles, and depth-faded edges so the bank
 * blends instead of ending on a cut line.
 */
import { Mesh, MeshStandardNodeMaterial, PlaneGeometry } from 'three'
import { Fn, cos, float, mix, positionWorld, sin, time, uv, vec3 } from 'three/tsl'
import { degToRad } from '../core/gdmath'

/** Ripples: two crossing wave trains, which never reads as a repeating tile. */
const rippleNormal = /*@__PURE__*/ Fn(() => {
  const p = positionWorld.xz
  const t = time.mul(0.55)

  const w1 = sin(p.x.mul(1.7).add(p.y.mul(0.9)).add(t.mul(1.6)))
  const w2 = sin(p.x.mul(-0.8).add(p.y.mul(2.3)).sub(t.mul(1.15)))
  const w3 = cos(p.x.mul(3.1).sub(p.y.mul(2.2)).add(t.mul(2.4))).mul(0.4)

  const nx = w1.mul(0.06).add(w3.mul(0.03))
  const nz = w2.mul(0.06).add(w3.mul(0.03))
  return vec3(nx, nz, 1).normalize()
})

export function waterSurface(
  size: [number, number],
  pos: [number, number, number],
  yawDeg: number,
): Mesh {
  // Subdivided so the ripple normal has vertices to interpolate across.
  const geometry = new PlaneGeometry(size[0], size[1], 24, Math.round(size[1] / 4))
  geometry.rotateX(-Math.PI / 2)

  const material = new MeshStandardNodeMaterial()
  material.transparent = true
  material.roughness = 0.06
  material.metalness = 0.35
  material.normalNode = rippleNormal()

  // Deep channel colour in the middle, silting toward the banks.
  const bank = uv().x.sub(0.5).abs().mul(2)
  material.colorNode = mix(vec3(0.035, 0.075, 0.095), vec3(0.09, 0.12, 0.11), bank.mul(bank))
  // Fade the last of the width out so the edge meets the bed softly.
  material.opacityNode = float(0.9).sub(bank.mul(bank).mul(0.55))

  const mesh = new Mesh(geometry, material)
  mesh.position.set(pos[0], pos[1], pos[2])
  mesh.rotation.y = degToRad(yawDeg)
  mesh.receiveShadow = true
  return mesh
}
