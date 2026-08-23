// Browser input capture → protocol frames.
//
// Keyboard and mouse go straight into frames; mouse motion is accumulated
// and flushed once per animation frame so a 1 kHz mouse does not become a
// thousand datachannel messages. Gamepads are polled every frame and only
// changes are sent.
import { KEY, JOY_BUTTON, JOY_AXIS, MOUSE_BUTTON, CODE_TO_KEY, KEYNAME_TO_KEY, UNSHIFTED_ASCII } from './godot_keys.js';
import * as P from './protocol.js';

// Standard Gamepad API mapping → Godot. Buttons 6/7 (triggers) become axes.
const PAD_BUTTONS = [
  JOY_BUTTON.JOY_BUTTON_A, JOY_BUTTON.JOY_BUTTON_B, JOY_BUTTON.JOY_BUTTON_X, JOY_BUTTON.JOY_BUTTON_Y,
  JOY_BUTTON.JOY_BUTTON_LEFT_SHOULDER, JOY_BUTTON.JOY_BUTTON_RIGHT_SHOULDER,
  null, null, // triggers → JOY_AXIS_TRIGGER_LEFT / RIGHT
  JOY_BUTTON.JOY_BUTTON_BACK, JOY_BUTTON.JOY_BUTTON_START,
  JOY_BUTTON.JOY_BUTTON_LEFT_STICK, JOY_BUTTON.JOY_BUTTON_RIGHT_STICK,
  JOY_BUTTON.JOY_BUTTON_DPAD_UP, JOY_BUTTON.JOY_BUTTON_DPAD_DOWN, JOY_BUTTON.JOY_BUTTON_DPAD_LEFT, JOY_BUTTON.JOY_BUTTON_DPAD_RIGHT,
  JOY_BUTTON.JOY_BUTTON_GUIDE, JOY_BUTTON.JOY_BUTTON_MISC1,
];
const PAD_TRIGGER_AXES = { 6: JOY_AXIS.JOY_AXIS_TRIGGER_LEFT, 7: JOY_AXIS.JOY_AXIS_TRIGGER_RIGHT };
const PAD_AXES = [JOY_AXIS.JOY_AXIS_LEFT_X, JOY_AXIS.JOY_AXIS_LEFT_Y, JOY_AXIS.JOY_AXIS_RIGHT_X, JOY_AXIS.JOY_AXIS_RIGHT_Y];

// Browser MouseEvent.button → Godot MouseButton.
const MOUSE_BUTTONS = [MOUSE_BUTTON.MOUSE_BUTTON_LEFT, MOUSE_BUTTON.MOUSE_BUTTON_MIDDLE, MOUSE_BUTTON.MOUSE_BUTTON_RIGHT,
  MOUSE_BUTTON.MOUSE_BUTTON_XBUTTON1, MOUSE_BUTTON.MOUSE_BUTTON_XBUTTON2];

function modsOf(e) {
  return (e.shiftKey ? P.MODS.SHIFT : 0) | (e.ctrlKey ? P.MODS.CTRL : 0) | (e.altKey ? P.MODS.ALT : 0) | (e.metaKey ? P.MODS.META : 0);
}

// Godot keycode: layout-aware for letters/digits/unshifted punctuation (the
// thing the InputMap is bound to), physical-key fallback for the rest.
function godotKeycode(e) {
  const k = e.key;
  if (k.length === 1) {
    const c = k.charCodeAt(0);
    if (c >= 0x61 && c <= 0x7a) return c - 32;            // a-z → A-Z
    if ((c >= 0x41 && c <= 0x5a) || (c >= 0x30 && c <= 0x39)) return c;
    if (k in UNSHIFTED_ASCII) return UNSHIFTED_ASCII[k];
    // Shifted symbol ("!" on a US board, "é" elsewhere): use the physical key
    // so the action bound to that key still fires.
    if (e.code in CODE_TO_KEY) return CODE_TO_KEY[e.code];
    return c < 0x10000 ? c : KEY.KEY_UNKNOWN;
  }
  if (k in KEYNAME_TO_KEY) return KEYNAME_TO_KEY[k];
  if (e.code in CODE_TO_KEY) return CODE_TO_KEY[e.code];
  return KEY.KEY_UNKNOWN;
}

function godotPhysical(e) {
  return CODE_TO_KEY[e.code] ?? KEY.KEY_UNKNOWN;
}

function godotLocation(e) {
  return e.location === 1 ? 1 : e.location === 2 ? 2 : 0; // KeyLocation LEFT/RIGHT/UNSPECIFIED
}

export class InputCapture {
  /**
   * @param {HTMLVideoElement} video  the stream surface
   * @param {(buf: ArrayBuffer, reliable: boolean) => void} send  frame sender
   */
  constructor(video, send) {
    this.video = video;
    this.send = send;
    this.active = false;
    this.locked = false;
    this.gameMouseMode = P.MOUSE_MODE.VISIBLE;
    this.streamW = 1280;
    this.streamH = 720;
    this.sensitivity = 1.0;
    // virtual cursor in stream pixels, used while pointer-locked
    this.cur = { x: 640, y: 360 };
    this.pending = { dx: 0, dy: 0, moved: false, x: 640, y: 360 };
    this.buttons = 0;
    this.pads = new Map(); // index → {buttons:[], axes:[]}
    this.raf = 0;
    this.onLockChange = () => {};
    this._bind();
  }

  setStreamSize(w, h) {
    this.streamW = w; this.streamH = h;
    this.cur = { x: w / 2, y: h / 2 };
  }

  start() {
    if (this.active) return;
    this.active = true;
    this._loop();
  }

  stop() {
    if (!this.active) return;
    this.active = false;
    cancelAnimationFrame(this.raf);
    if (document.pointerLockElement) document.exitPointerLock();
    this.send(P.encodeReleaseAll(), true);
  }

  // Called with the game's mouse mode so pointer lock follows it.
  setGameMouseMode(mode) {
    this.gameMouseMode = mode;
    if (mode !== P.MOUSE_MODE.CAPTURED && mode !== P.MOUSE_MODE.CONFINED_HIDDEN && this.locked) {
      document.exitPointerLock();
    }
  }

  wantsLock() {
    return this.gameMouseMode === P.MOUSE_MODE.CAPTURED || this.gameMouseMode === P.MOUSE_MODE.CONFINED_HIDDEN;
  }

  requestLock() {
    if (this.locked || !this.active) return;
    const el = this.video;
    try {
      const p = el.requestPointerLock({ unadjustedMovement: true });
      if (p && p.catch) p.catch(() => el.requestPointerLock());
    } catch (_) {
      el.requestPointerLock();
    }
  }

  // Map a client position onto stream pixels, honouring object-fit: contain.
  _toStream(clientX, clientY) {
    const r = this.video.getBoundingClientRect();
    const vw = this.video.videoWidth || this.streamW, vh = this.video.videoHeight || this.streamH;
    const scale = Math.min(r.width / vw, r.height / vh) || 1;
    const ox = r.left + (r.width - vw * scale) / 2;
    const oy = r.top + (r.height - vh * scale) / 2;
    return { x: (clientX - ox) / scale, y: (clientY - oy) / scale, scale };
  }

  _displayScale() {
    const r = this.video.getBoundingClientRect();
    const vw = this.video.videoWidth || this.streamW, vh = this.video.videoHeight || this.streamH;
    return Math.min(r.width / vw, r.height / vh) || 1;
  }

  _bind() {
    const v = this.video;
    const doc = document;

    doc.addEventListener('pointerlockchange', () => {
      this.locked = doc.pointerLockElement === v;
      this.onLockChange(this.locked);
    });

    v.addEventListener('contextmenu', (e) => e.preventDefault());
    v.addEventListener('dragstart', (e) => e.preventDefault());

    v.addEventListener('mousemove', (e) => {
      if (!this.active) return;
      const s = this._displayScale();
      const dx = (e.movementX / s) * this.sensitivity, dy = (e.movementY / s) * this.sensitivity;
      if (this.locked) {
        this.cur.x = Math.max(0, Math.min(this.streamW, this.cur.x + dx));
        this.cur.y = Math.max(0, Math.min(this.streamH, this.cur.y + dy));
      } else {
        const p = this._toStream(e.clientX, e.clientY);
        this.cur.x = p.x; this.cur.y = p.y;
      }
      this.pending.dx += dx; this.pending.dy += dy;
      this.pending.x = this.cur.x; this.pending.y = this.cur.y;
      this.pending.moved = true;
    });

    const button = (e, pressed) => {
      if (!this.active) return;
      e.preventDefault();
      const gb = MOUSE_BUTTONS[e.button];
      if (gb === undefined) return;
      if (!this.locked) {
        const p = this._toStream(e.clientX, e.clientY);
        this.cur.x = p.x; this.cur.y = p.y;
      }
      this._flushMotion();
      const bit = 1 << (gb - 1);
      this.buttons = pressed ? (this.buttons | bit) : (this.buttons & ~bit);
      const dbl = pressed && e.detail === 2;
      this.send(P.encodeMouseButton(pressed, gb, this.cur.x, this.cur.y, 1.0, modsOf(e), dbl), true);
      if (pressed && !this.locked && this.wantsLock()) this.requestLock();
    };
    v.addEventListener('mousedown', (e) => button(e, true));
    v.addEventListener('mouseup', (e) => button(e, false));
    // Releases that happen off the element must still arrive.
    window.addEventListener('mouseup', (e) => { if (this.active && e.target !== v) button(e, false); });

    v.addEventListener('wheel', (e) => {
      if (!this.active) return;
      e.preventDefault();
      this._flushMotion();
      const mods = modsOf(e);
      // Godot wants one press per notch; deltaMode 0 is pixels (~100 per notch on Chrome, ~3 lines elsewhere).
      const unit = e.deltaMode === 0 ? 100 : e.deltaMode === 1 ? 3 : 1;
      const fy = Math.min(Math.abs(e.deltaY) / unit, 10) || 0, fx = Math.min(Math.abs(e.deltaX) / unit, 10) || 0;
      if (e.deltaY) this.send(P.encodeMouseButton(true, e.deltaY < 0 ? MOUSE_BUTTON.MOUSE_BUTTON_WHEEL_UP : MOUSE_BUTTON.MOUSE_BUTTON_WHEEL_DOWN, this.cur.x, this.cur.y, Math.max(fy, 0.1), mods, false), true);
      if (e.deltaX) this.send(P.encodeMouseButton(true, e.deltaX < 0 ? MOUSE_BUTTON.MOUSE_BUTTON_WHEEL_LEFT : MOUSE_BUTTON.MOUSE_BUTTON_WHEEL_RIGHT, this.cur.x, this.cur.y, Math.max(fx, 0.1), mods, false), true);
    }, { passive: false });

    const key = (e, pressed) => {
      if (!this.active) return;
      // Leave devtools alone; everything else belongs to the game.
      if (e.code === 'F12') return;
      e.preventDefault();
      const unicode = pressed && e.key.length === 1 ? e.key.codePointAt(0) : 0;
      this.send(P.encodeKey(pressed, godotKeycode(e), godotPhysical(e), unicode, modsOf(e), e.repeat, godotLocation(e)), true);
    };
    window.addEventListener('keydown', (e) => key(e, true));
    window.addEventListener('keyup', (e) => key(e, false));

    const releaseAll = () => { if (this.active) { this.buttons = 0; this.send(P.encodeReleaseAll(), true); } };
    window.addEventListener('blur', releaseAll);
    doc.addEventListener('visibilitychange', () => { if (doc.hidden) releaseAll(); });

    window.addEventListener('gamepadconnected', (e) => this._padConnected(e.gamepad));
    window.addEventListener('gamepaddisconnected', (e) => {
      if (!this.pads.has(e.gamepad.index)) return;
      this.pads.delete(e.gamepad.index);
      this.send(P.encodeJoyConnect(e.gamepad.index, false, e.gamepad.id), true);
    });
  }

  _padConnected(gp) {
    if (!gp || this.pads.has(gp.index)) return;
    this.pads.set(gp.index, { buttons: gp.buttons.map(() => 0), axes: gp.axes.map(() => 0), id: gp.id });
    if (this.active) this.send(P.encodeJoyConnect(gp.index, true, gp.id), true);
  }

  // Announce already-plugged pads when a session starts.
  announcePads() {
    for (const [idx, st] of this.pads) this.send(P.encodeJoyConnect(idx, true, st.id), true);
  }

  _flushMotion() {
    if (!this.pending.moved) return;
    this.send(P.encodeMouseMove(this.pending.x, this.pending.y, this.pending.dx, this.pending.dy, this.buttons), false);
    this.pending.dx = 0; this.pending.dy = 0; this.pending.moved = false;
  }

  _pollPads() {
    const pads = navigator.getGamepads ? navigator.getGamepads() : [];
    const frames = [];
    for (const gp of pads) {
      if (!gp) continue;
      if (!this.pads.has(gp.index)) this._padConnected(gp);
      const st = this.pads.get(gp.index);
      gp.buttons.forEach((b, i) => {
        const val = typeof b === 'number' ? b : b.value;
        const pressed = typeof b === 'number' ? b > 0.5 : b.pressed;
        if (i in PAD_TRIGGER_AXES) {
          if (Math.abs(val - st.buttons[i]) > 0.004 || (val === 0) !== (st.buttons[i] === 0)) {
            st.buttons[i] = val;
            frames.push(P.encodeJoyAxis(gp.index, PAD_TRIGGER_AXES[i], val));
          }
          return;
        }
        const p = pressed ? 1 : 0;
        if (p !== st.buttons[i]) {
          st.buttons[i] = p;
          const gb = PAD_BUTTONS[i];
          if (gb !== null && gb !== undefined) frames.push(P.encodeJoyButton(gp.index, gb, pressed, val));
        }
      });
      gp.axes.forEach((a, i) => {
        if (i >= PAD_AXES.length) return;
        if (Math.abs(a - st.axes[i]) > 0.004 || (a === 0) !== (st.axes[i] === 0)) {
          st.axes[i] = a;
          frames.push(P.encodeJoyAxis(gp.index, PAD_AXES[i], a));
        }
      });
    }
    if (frames.length) this.send(P.batch(frames), true);
  }

  _loop() {
    if (!this.active) return;
    this._flushMotion();
    this._pollPads();
    this.raf = requestAnimationFrame(() => this._loop());
  }
}
