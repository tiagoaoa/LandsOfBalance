/**
 * Godot's Label3D — a billboarded, outlined text sprite. Used for the world
 * landmarks ("Village of Eights", "The Burning Peaks", ...), floating damage
 * numbers, and enemy HP readouts.
 */
import { CanvasTexture, LinearFilter, Sprite, SpriteMaterial } from 'three'

export interface Label3DOptions {
  fontSize?: number
  color?: string
  outline?: string
  outlineSize?: number
  /** World height of one text line. Godot's pixel_size scaled up. */
  worldScale?: number
  /** Draw over everything, like Label3D's no_depth_test. */
  noDepthTest?: boolean
}

export class Label3D extends Sprite {
  // No field initialisers here: they run immediately after `super()` and
  // would replace the canvas the texture was built from.
  private readonly canvas: HTMLCanvasElement
  private readonly opts: Required<Label3DOptions>
  private text: string

  constructor(text: string, opts: Label3DOptions = {}) {
    const o: Required<Label3DOptions> = {
      fontSize: opts.fontSize ?? 48,
      color: opts.color ?? '#e0cc99',
      outline: opts.outline ?? '#000000',
      outlineSize: opts.outlineSize ?? 6,
      worldScale: opts.worldScale ?? 0.02,
      noDepthTest: opts.noDepthTest ?? false,
    }
    const canvas = document.createElement('canvas')
    const tex = new CanvasTexture(canvas)
    tex.minFilter = LinearFilter
    super(
      new SpriteMaterial({
        map: tex,
        transparent: true,
        depthTest: !o.noDepthTest,
        depthWrite: false,
        fog: false,
      }),
    )
    this.canvas = canvas
    this.opts = o
    this.text = ''
    this.setText(text)
  }

  setText(text: string): void {
    if (text === this.text) return
    this.text = text
    const { fontSize, color, outline, outlineSize, worldScale } = this.opts
    const lines = text.split('\n')
    const ctx = this.canvas.getContext('2d')
    if (!ctx) return

    const font = `bold ${fontSize}px "Times New Roman", Georgia, serif`
    ctx.font = font
    const pad = outlineSize * 2 + 8
    const width = Math.max(...lines.map((l) => ctx.measureText(l).width)) + pad * 2
    const lineHeight = fontSize * 1.2
    const height = lineHeight * lines.length + pad * 2

    this.canvas.width = Math.ceil(width)
    this.canvas.height = Math.ceil(height)
    ctx.clearRect(0, 0, this.canvas.width, this.canvas.height)
    ctx.font = font
    ctx.textAlign = 'center'
    ctx.textBaseline = 'middle'
    ctx.lineJoin = 'round'
    ctx.lineWidth = outlineSize
    ctx.strokeStyle = outline
    ctx.fillStyle = color
    lines.forEach((line, i) => {
      const y = pad + lineHeight * (i + 0.5)
      if (outlineSize > 0) ctx.strokeText(line, this.canvas.width / 2, y)
      ctx.fillText(line, this.canvas.width / 2, y)
    })

    const mat = this.material as SpriteMaterial
    ;(mat.map as CanvasTexture).image = this.canvas
    ;(mat.map as CanvasTexture).needsUpdate = true
    this.scale.set(this.canvas.width * worldScale, this.canvas.height * worldScale, 1)
  }

  setOpacity(a: number): void {
    ;(this.material as SpriteMaterial).opacity = a
  }
}
