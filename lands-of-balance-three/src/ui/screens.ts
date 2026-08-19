/**
 * Port of ui/character_select.tscn — the screen the Godot build boots into
 * (`run/main_scene` is character_select), plus the loading and death states.
 */
import { CharacterClass } from '../player/player'

function overlay(html: string): HTMLElement {
  const el = document.createElement('div')
  el.className = 'overlay'
  el.innerHTML = `<div>${html}</div>`
  document.body.appendChild(el)
  return el
}

/** Blocking character pick. Resolves with the chosen class. */
export function characterSelect(): Promise<CharacterClass> {
  const el = overlay(`
    <h1>Lands of Balance</h1>
    <div class="sub">Walk the Village of Eights as Douglass, Keeper of Balance</div>
    <div class="choices">
      <div class="choice" data-class="paladin">
        <div class="name">Paladin</div>
        <div class="desc">
          Sword &amp; shield. 150 HP.<br />
          Three-hit combo chain, timed parry into riposte,
          backstabs. Blocks chip; only a parry cancels.
        </div>
      </div>
      <div class="choice" data-class="archer">
        <div class="name">Archer</div>
        <div class="desc">
          Fire bow. 100 HP.<br />
          Arrows barely dent Bobba — light the ground instead.
          Fire reveals the blind, and burns the undead.
        </div>
      </div>
    </div>
    <div class="hint">The Lands are a rainy night. Press L for the Nordic day.</div>
  `)

  return new Promise((resolve) => {
    el.querySelectorAll<HTMLElement>('.choice').forEach((choice) => {
      choice.addEventListener('click', () => {
        el.remove()
        resolve(choice.dataset.class === 'paladin' ? CharacterClass.PALADIN : CharacterClass.ARCHER)
      })
    })
  })
}

export class LoadingScreen {
  private readonly el: HTMLElement
  private readonly bar: HTMLElement

  constructor() {
    this.el = overlay(`
      <h1>Lands of Balance</h1>
      <div class="sub">Raising the Lands…</div>
      <div id="loading-bar"><div></div></div>
    `)
    this.bar = this.el.querySelector('#loading-bar > div') as HTMLElement
  }

  setProgress(f: number): void {
    this.bar.style.width = `${Math.round(Math.min(Math.max(f, 0), 1) * 100)}%`
  }

  done(): void {
    this.el.remove()
  }
}

/** "Click to begin" — browsers need a gesture before pointer lock and audio. */
export function pressToStart(): Promise<void> {
  const el = overlay(`
    <h1>Ready</h1>
    <div class="sub">Click to take the field</div>
    <div class="hint">Esc releases the mouse · F1 lists the controls</div>
  `)
  return new Promise((resolve) => {
    const go = (): void => {
      el.remove()
      resolve()
    }
    el.addEventListener('click', go, { once: true })
  })
}

/** Death overlay — the Godot build reloads the scene; here we respawn. */
export function deathScreen(): Promise<void> {
  const el = overlay(`
    <h1 style="color:#a01410">YOU DIED</h1>
    <div class="sub">The Balance endures without you</div>
    <div class="choices"><div class="choice" style="width:200px"><div class="name">Rise again</div></div></div>
  `)
  return new Promise((resolve) => {
    el.querySelector('.choice')?.addEventListener('click', () => {
      el.remove()
      resolve()
    })
  })
}
