/**
 * Godot's InputMap, in the browser.
 *
 * The ported gameplay code asks the same questions it asked in GDScript —
 * `isActionPressed('run')`, `isActionJustPressed('dodge')`, `getVector()` —
 * so the control logic didn't have to be rewritten around DOM events. The
 * bindings mirror project.godot's `[input]` section (see the key comments).
 *
 * `justPressed` is edge state consumed once per frame: call `endFrame()`
 * after the game step, exactly like Godot clears its just-pressed flags at
 * the end of a physics tick.
 */

export type Action =
  | 'move_left' | 'move_right' | 'move_forward' | 'move_back'
  | 'jump' | 'run' | 'crouch'
  | 'attack' | 'block' | 'parry' | 'dodge' | 'estus'
  | 'lock_on' | 'spell_cast' | 'toggle_combat' | 'reset_position' | 'revive'
  | 'class_paladin' | 'class_archer'
  | 'toggle_time' | 'toggle_map' | 'toggle_help'

/** code -> actions. `code` is KeyboardEvent.code (layout independent). */
const KEY_BINDINGS: Record<string, Action[]> = {
  KeyW: ['move_forward'], ArrowUp: ['move_forward'],
  KeyS: ['move_back'], ArrowDown: ['move_back'],
  KeyA: ['move_left'], ArrowLeft: ['move_left'],
  KeyD: ['move_right'], ArrowRight: ['move_right'],
  Space: ['jump'],
  ShiftLeft: ['run'], ShiftRight: ['run'],
  ControlLeft: ['crouch'], ControlRight: ['crouch'],
  KeyF: ['attack'],
  KeyG: ['parry'],
  KeyX: ['dodge'],
  KeyH: ['estus'],
  KeyT: ['lock_on'],
  KeyC: ['spell_cast'],
  KeyE: ['revive'],
  KeyR: ['reset_position'],
  Tab: ['toggle_combat'],
  Digit2: ['class_paladin'],
  Digit3: ['class_archer'],
  // Not in the Godot InputMap — the Godot build toggles these from _input
  // keycodes (L for day/night) or scene flags. Same keys here.
  KeyL: ['toggle_time'],
  KeyM: ['toggle_map'],
  F1: ['toggle_help'],
}

/** MouseEvent.button -> actions. */
const MOUSE_BINDINGS: Record<number, Action[]> = {
  0: ['attack'],
  2: ['block'],
}

/** Gamepad button index -> actions (Standard Gamepad mapping). */
const PAD_BUTTONS: Record<number, Action[]> = {
  0: ['jump'],        // A
  1: ['spell_cast'],  // B
  2: ['attack'],      // X
  4: ['dodge'],       // LB
  5: ['parry'],       // RB
  7: ['block'],       // RT
  10: ['run'],        // L3
  11: ['lock_on'],    // R3
  13: ['estus'],      // d-pad down
}

export class InputManager {
  private readonly down = new Set<Action>()
  private readonly pressedThisFrame = new Set<Action>()
  private readonly releasedThisFrame = new Set<Action>()
  private readonly padHeld = new Set<Action>()

  /** Accumulated pointer motion since the last frame, in pixels. */
  mouseDx = 0
  mouseDy = 0
  pointerLocked = false
  /** Left stick, Godot's `Input.get_vector` convention (y+ = back). */
  padMove = { x: 0, y: 0 }
  /** Right stick, for camera look. */
  padLook = { x: 0, y: 0 }
  padActive = false

  private readonly canvas: HTMLElement

  constructor(canvas: HTMLElement) {
    this.canvas = canvas
    window.addEventListener('keydown', this.onKeyDown)
    window.addEventListener('keyup', this.onKeyUp)
    window.addEventListener('mousedown', this.onMouseDown)
    window.addEventListener('mouseup', this.onMouseUp)
    window.addEventListener('mousemove', this.onMouseMove)
    window.addEventListener('contextmenu', (e) => e.preventDefault())
    document.addEventListener('pointerlockchange', this.onPointerLockChange)
    // Losing focus must release everything — a key that "sticks down" while
    // the tab is backgrounded is the classic cause of a character that walks
    // into a wall forever on return.
    window.addEventListener('blur', () => this.releaseAll())
  }

  requestPointerLock(): void {
    if (!this.pointerLocked) void this.canvas.requestPointerLock()
  }

  private onPointerLockChange = (): void => {
    this.pointerLocked = document.pointerLockElement === this.canvas
    if (!this.pointerLocked) this.releaseAll()
  }

  private onKeyDown = (e: KeyboardEvent): void => {
    const acts = KEY_BINDINGS[e.code]
    if (!acts) return
    if (e.code === 'Tab' || e.code === 'Space' || e.code.startsWith('Arrow')) e.preventDefault()
    if (e.repeat) return
    for (const a of acts) this.press(a)
  }

  private onKeyUp = (e: KeyboardEvent): void => {
    const acts = KEY_BINDINGS[e.code]
    if (!acts) return
    for (const a of acts) this.release(a)
  }

  private onMouseDown = (e: MouseEvent): void => {
    if (!this.pointerLocked) return
    for (const a of MOUSE_BINDINGS[e.button] ?? []) this.press(a)
  }

  private onMouseUp = (e: MouseEvent): void => {
    for (const a of MOUSE_BINDINGS[e.button] ?? []) this.release(a)
  }

  private onMouseMove = (e: MouseEvent): void => {
    if (!this.pointerLocked) return
    this.mouseDx += e.movementX
    this.mouseDy += e.movementY
  }

  private press(a: Action): void {
    if (!this.down.has(a)) this.pressedThisFrame.add(a)
    this.down.add(a)
  }

  private release(a: Action): void {
    if (this.down.has(a)) this.releasedThisFrame.add(a)
    this.down.delete(a)
  }

  private releaseAll(): void {
    for (const a of [...this.down]) this.release(a)
  }

  /** Poll the gamepad; call once per frame before reading actions. */
  pollGamepad(): void {
    const pads = navigator.getGamepads?.() ?? []
    const pad = [...pads].find((p) => p && p.connected)
    if (!pad) {
      for (const a of [...this.padHeld]) this.release(a)
      this.padHeld.clear()
      this.padActive = false
      this.padMove = { x: 0, y: 0 }
      this.padLook = { x: 0, y: 0 }
      return
    }
    const dz = (v: number) => (Math.abs(v) < 0.15 ? 0 : v)
    this.padMove = { x: dz(pad.axes[0] ?? 0), y: dz(pad.axes[1] ?? 0) }
    this.padLook = { x: dz(pad.axes[2] ?? 0), y: dz(pad.axes[3] ?? 0) }
    this.padActive = Math.hypot(this.padMove.x, this.padMove.y) > 0.1

    for (const [idxStr, acts] of Object.entries(PAD_BUTTONS)) {
      const btn = pad.buttons[Number(idxStr)]
      const on = !!btn && (btn.pressed || btn.value > 0.5)
      for (const a of acts) {
        if (on && !this.padHeld.has(a)) {
          this.padHeld.add(a)
          this.press(a)
        } else if (!on && this.padHeld.has(a)) {
          this.padHeld.delete(a)
          this.release(a)
        }
      }
    }
  }

  isActionPressed(a: Action): boolean {
    return this.down.has(a)
  }

  isActionJustPressed(a: Action): boolean {
    return this.pressedThisFrame.has(a)
  }

  isActionJustReleased(a: Action): boolean {
    return this.releasedThisFrame.has(a)
  }

  /**
   * Godot `Input.get_vector(left, right, forward, back)` — x = strafe,
   * y = forward/back with y NEGATIVE forward, which is what every movement
   * expression in player.gd assumes (`forward * -input.y`).
   */
  getVector(): { x: number; y: number } {
    if (this.padActive) return { ...this.padMove }
    const x = (this.isActionPressed('move_right') ? 1 : 0) - (this.isActionPressed('move_left') ? 1 : 0)
    const y = (this.isActionPressed('move_back') ? 1 : 0) - (this.isActionPressed('move_forward') ? 1 : 0)
    const len = Math.hypot(x, y)
    // Godot normalises the analog vector past the deadzone; a digital
    // diagonal must not be faster than a cardinal.
    return len > 1 ? { x: x / len, y: y / len } : { x, y }
  }

  /** Clear per-frame edges and mouse deltas. Call at the end of the tick. */
  endFrame(): void {
    this.pressedThisFrame.clear()
    this.releasedThisFrame.clear()
    this.mouseDx = 0
    this.mouseDy = 0
  }
}
