/**
 * Port of ui/gothic_hud.gd, ui/combat_hud.gd and ui/minimap.gd.
 *
 * Four regions, matching the Godot layout:
 *   - Top-left: circular emblem + HP/Stamina bar pair.
 *   - Top-right: COMBATANTS panel with a row per live enemy.
 *   - Bottom-left: ornate ability slots with rune glyphs.
 *   - Bottom-right: estus charges and the damage-buff readout.
 * Plus the minimap, the lock-on reticle and the centre feedback label.
 */
import type { Camera, Vector3 } from 'three'
import type { Combatant } from '../core/context'
import { LANDMARKS, MAP_MAX, MAP_MIN } from '../core/tuning'

interface AbilitySlot {
  el: HTMLElement
  rune: string
  key: string
}

export class Hud {
  readonly root: HTMLElement

  private readonly hpFill: HTMLElement
  private readonly hpText: HTMLElement
  private readonly staFill: HTMLElement
  private readonly staText: HTMLElement
  private readonly foeList: HTMLElement
  private readonly estusCount: HTMLElement
  private readonly buffText: HTMLElement
  private readonly centreLabel: HTMLElement
  private readonly damageFlash: HTMLElement
  private readonly reticle: HTMLElement
  private readonly minimapCanvas: HTMLCanvasElement
  private readonly placeLabel: HTMLElement
  private readonly controls: HTMLElement
  private readonly slots: Record<string, AbilitySlot> = {}

  private labelTimer = 0

  constructor(parent: HTMLElement) {
    this.root = document.createElement('div')
    this.root.id = 'hud'
    this.root.innerHTML = `
      <div class="panel" id="stats">
        <div id="emblem">✠</div>
        <div class="bars">
          <div class="bar"><div class="fill" id="hp-fill"></div><div class="label" id="hp-text"></div></div>
          <div class="bar"><div class="fill" id="stamina-fill"></div><div class="label" id="stamina-text"></div></div>
        </div>
      </div>

      <div class="panel" id="combatants">
        <h2>Combatants</h2>
        <div id="foe-list"></div>
      </div>

      <div class="panel" id="minimap">
        <canvas width="204" height="216"></canvas>
        <div class="place">The Lands of Balance</div>
      </div>

      <div class="panel" id="abilities"></div>

      <div class="panel" id="buff">
        <div class="caption">Buff</div>
        <div class="count" id="buff-text">+0%</div>
      </div>

      <div class="panel" id="estus">
        <div class="caption">Estus</div>
        <div class="count" id="estus-count">3</div>
      </div>

      <div id="crosshair"></div>
      <div id="reticle"></div>
      <div id="centre-label"></div>
      <div id="damage-flash"></div>
    `
    parent.appendChild(this.root)

    this.hpFill = this.q('#hp-fill')
    this.hpText = this.q('#hp-text')
    this.staFill = this.q('#stamina-fill')
    this.staText = this.q('#stamina-text')
    this.foeList = this.q('#foe-list')
    this.estusCount = this.q('#estus-count')
    this.buffText = this.q('#buff-text')
    this.centreLabel = this.q('#centre-label')
    this.damageFlash = this.q('#damage-flash')
    this.reticle = this.q('#reticle')
    this.minimapCanvas = this.q('#minimap canvas') as HTMLCanvasElement
    this.placeLabel = this.q('#minimap .place')

    this.buildAbilitySlots()
    this.controls = this.buildControlsCard(parent)
  }

  private q<E extends HTMLElement = HTMLElement>(sel: string): E {
    const el = this.root.querySelector<E>(sel)
    if (!el) throw new Error(`HUD element missing: ${sel}`)
    return el
  }

  /** Three ornate slots with rune glyphs, as in `_build_bottom_left_slots`. */
  private buildAbilitySlots(): void {
    const defs: [string, string, string][] = [
      ['parry', '⛨', 'G'],
      ['roll', '⤫', 'X'],
      ['estus', '⚱', 'H'],
      ['lock', '◈', 'T'],
    ]
    const host = this.q('#abilities')
    for (const [id, rune, key] of defs) {
      const el = document.createElement('div')
      el.className = 'slot'
      el.innerHTML = `<span class="rune">${rune}</span><span class="key">${key}</span>`
      host.appendChild(el)
      this.slots[id] = { el, rune, key }
    }
  }

  private buildControlsCard(parent: HTMLElement): HTMLElement {
    const el = document.createElement('div')
    el.id = 'controls'
    el.innerHTML = [
      ['WASD', 'move'],
      ['Shift', 'run'],
      ['Ctrl', 'crouch (brace, −25% dmg)'],
      ['Space', 'jump / leap dodge'],
      ['LMB / F', 'attack — hold to draw the bow'],
      ['RMB', 'block (chips, never cancels)'],
      ['G', 'parry — the only clean cancel'],
      ['X', 'dodge roll (i-frames)'],
      ['H', 'estus flask'],
      ['T', 'lock on'],
      ['C', 'cast rite'],
      ['Tab', 'sheathe / draw'],
      ['L', 'day / night'],
      ['M', 'minimap'],
      ['R', 'return to spawn'],
      ['F1', 'toggle this card'],
    ]
      .map(([k, v]) => `<div><b>${k}</b> — ${v}</div>`)
      .join('')
    parent.appendChild(el)
    return el
  }

  toggleControls(): void {
    this.controls.classList.toggle('show')
  }

  toggleMinimap(): void {
    const m = this.q('#minimap')
    m.style.display = m.style.display === 'none' ? '' : 'none'
  }

  // ── Feedback ────────────────────────────────────────────────────────────

  showLabel(text: string, color = 0xe0cc99): void {
    this.centreLabel.textContent = text
    this.centreLabel.style.color = `#${color.toString(16).padStart(6, '0')}`
    this.centreLabel.style.opacity = '1'
    this.labelTimer = 1.4
  }

  flashDamage(): void {
    this.damageFlash.style.transition = 'none'
    this.damageFlash.style.opacity = '1'
    requestAnimationFrame(() => {
      this.damageFlash.style.transition = 'opacity 260ms ease-out'
      this.damageFlash.style.opacity = '0'
    })
  }

  // ── Per-frame ───────────────────────────────────────────────────────────

  update(
    dt: number,
    stats: {
      hp: number
      maxHp: number
      stamina: number
      maxStamina: number
      estus: number
      buffPct: number
      position: Vector3
      isBlocking: boolean
      isRolling: boolean
      isParrying: boolean
      lockTarget: Combatant | null
    },
    foes: Combatant[],
    camera: Camera,
  ): void {
    if (this.labelTimer > 0) {
      this.labelTimer -= dt
      if (this.labelTimer <= 0) this.centreLabel.style.opacity = '0'
    }

    const hpRatio = stats.maxHp > 0 ? stats.hp / stats.maxHp : 0
    this.hpFill.style.width = `${Math.max(0, hpRatio) * 100}%`
    this.hpText.textContent = `${Math.max(0, Math.round(stats.hp))} / ${Math.round(stats.maxHp)}`

    const staRatio = stats.maxStamina > 0 ? stats.stamina / stats.maxStamina : 0
    this.staFill.style.width = `${Math.max(0, staRatio) * 100}%`
    this.staText.textContent = `${Math.max(0, Math.round(stats.stamina))} / ${Math.round(stats.maxStamina)}`

    this.estusCount.textContent = `${stats.estus}`
    this.slots.estus.el.classList.toggle('spent', stats.estus <= 0)
    this.slots.parry.el.classList.toggle('active', stats.isParrying || stats.isBlocking)
    this.slots.roll.el.classList.toggle('active', stats.isRolling)
    this.slots.lock.el.classList.toggle('active', stats.lockTarget !== null)
    this.buffText.textContent = `+${Math.round(stats.buffPct * 100)}%`

    this.updateCombatants(foes, stats.lockTarget)
    this.updateReticle(stats.lockTarget, camera)
    this.updateMinimap(stats.position)
  }

  /** COMBATANTS rows, nearest first — the restyled ui/combat_hud.gd panel. */
  private updateCombatants(foes: Combatant[], locked: Combatant | null): void {
    const rows = foes
      .filter((f) => !f.isDead && f.health !== undefined && f.maxHealth)
      .slice(0, 6)
      .map((f) => {
        const ratio = Math.max(0, (f.health ?? 0) / (f.maxHealth ?? 1))
        return `<div class="foe${f === locked ? ' locked' : ''}">
            <div class="foe-name"><span>${f.displayName ?? 'Foe'}</span><span>${Math.max(0, Math.round(f.health ?? 0))}</span></div>
            <div class="foe-bar"><div style="width:${ratio * 100}%"></div></div>
          </div>`
      })
      .join('')
    const html = rows || '<div class="foe"><div class="foe-name"><span>— none —</span></div></div>'
    if (this.foeList.innerHTML !== html) this.foeList.innerHTML = html
  }

  /** Billboard the bronze diamond over the locked target, in screen space. */
  private updateReticle(target: Combatant | null, camera: Camera): void {
    if (!target || target.isDead) {
      this.reticle.style.display = 'none'
      return
    }
    const p = target.position.clone()
    p.y += 1.5
    p.project(camera)
    if (p.z > 1) {
      this.reticle.style.display = 'none'
      return
    }
    this.reticle.style.display = 'block'
    this.reticle.style.left = `${((p.x + 1) / 2) * window.innerWidth}px`
    this.reticle.style.top = `${((-p.y + 1) / 2) * window.innerHeight}px`
  }

  /**
   * Minimap: the same bounds and landmark table as ui/minimap.gd, including
   * the "closest landmark within 50 m or else The Lands of Balance" caption.
   */
  private updateMinimap(pos: Vector3): void {
    const ctx = this.minimapCanvas.getContext('2d')
    if (!ctx) return
    const w = this.minimapCanvas.width
    const h = this.minimapCanvas.height
    ctx.clearRect(0, 0, w, h)
    ctx.fillStyle = '#07090d'
    ctx.fillRect(0, 0, w, h)

    const toScreen = (x: number, z: number): [number, number] => [
      ((x - MAP_MIN.x) / (MAP_MAX.x - MAP_MIN.x)) * w,
      (1 - (z - MAP_MIN.z) / (MAP_MAX.z - MAP_MIN.z)) * h,
    ]

    // Faint graticule so distances read.
    ctx.strokeStyle = 'rgba(133, 102, 37, 0.15)'
    ctx.lineWidth = 1
    for (let g = -150; g <= 150; g += 50) {
      const [gx] = toScreen(g, 0)
      const [, gy] = toScreen(0, g)
      ctx.beginPath()
      ctx.moveTo(gx, 0)
      ctx.lineTo(gx, h)
      ctx.moveTo(0, gy)
      ctx.lineTo(w, gy)
      ctx.stroke()
    }

    let closest = ''
    let closestDist = Infinity
    ctx.font = '9px "Times New Roman", serif'
    for (const [name, [lx, lz]] of Object.entries(LANDMARKS)) {
      const d = Math.hypot(pos.x - lx, pos.z - lz)
      if (d < closestDist) {
        closestDist = d
        closest = name
      }
      const [sx, sy] = toScreen(lx, lz)
      ctx.fillStyle = '#8a6f3c'
      ctx.beginPath()
      ctx.arc(sx, sy, 2.5, 0, Math.PI * 2)
      ctx.fill()
      ctx.fillStyle = 'rgba(224, 204, 153, 0.55)'
      ctx.fillText(name.replace(/^The /, ''), sx + 4, sy + 3)
    }

    const [px, py] = toScreen(pos.x, pos.z)
    ctx.fillStyle = '#f2e0ad'
    ctx.beginPath()
    ctx.arc(px, py, 3.5, 0, Math.PI * 2)
    ctx.fill()
    ctx.strokeStyle = '#bf9438'
    ctx.lineWidth = 1.5
    ctx.stroke()

    const caption = closestDist < 50 ? closest : 'The Lands of Balance'
    if (this.placeLabel.textContent !== caption) this.placeLabel.textContent = caption
  }
}
