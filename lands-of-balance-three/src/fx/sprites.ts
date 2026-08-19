/**
 * Soft particle sprites.
 *
 * `PointsMaterial` with no map draws an opaque square, which at close range
 * turns a campfire into a wall of orange tiles. Every particle system in the
 * game therefore points at one of these radial-falloff textures — built once,
 * on a canvas, so nothing has to ship as an image.
 */
import { CanvasTexture, LinearFilter, SRGBColorSpace, type Texture } from 'three'

const cache = new Map<string, Texture>()

function build(size: number, stops: [number, string][]): Texture {
  const canvas = document.createElement('canvas')
  canvas.width = canvas.height = size
  const ctx = canvas.getContext('2d')
  if (ctx) {
    const g = ctx.createRadialGradient(size / 2, size / 2, 0, size / 2, size / 2, size / 2)
    for (const [at, color] of stops) g.addColorStop(at, color)
    ctx.fillStyle = g
    ctx.fillRect(0, 0, size, size)
  }
  const tex = new CanvasTexture(canvas)
  tex.minFilter = LinearFilter
  tex.colorSpace = SRGBColorSpace
  return tex
}

/** Hot core fading to nothing — the flame/ember body. */
export function flameSprite(): Texture {
  let t = cache.get('flame')
  if (!t) {
    t = build(64, [
      [0, 'rgba(255,255,255,1)'],
      [0.28, 'rgba(255,235,190,0.85)'],
      [0.62, 'rgba(255,150,60,0.32)'],
      [1, 'rgba(255,110,30,0)'],
    ])
    cache.set('flame', t)
  }
  return t
}

/** Tighter, harder dot — sparks read as flecks of metal, not puffs. */
export function sparkSprite(): Texture {
  let t = cache.get('spark')
  if (!t) {
    t = build(32, [
      [0, 'rgba(255,255,255,1)'],
      [0.4, 'rgba(255,240,200,0.9)'],
      [1, 'rgba(255,200,120,0)'],
    ])
    cache.set('spark', t)
  }
  return t
}
