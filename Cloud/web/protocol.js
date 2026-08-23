// Binary input protocol, browser side. Mirrors Cloud/internal/proto/proto.go
// and autoload/cloud_input.gd — change all three together.
export const FRAME = {
  KEY: 0x01, MOUSE_MOVE: 0x02, MOUSE_BUTTON: 0x03, JOY_BUTTON: 0x04,
  JOY_AXIS: 0x05, JOY_CONNECT: 0x06, RELEASE_ALL: 0x07, PING: 0x08,
  MOUSE_MODE: 0x80, PONG: 0x81, HELLO: 0x82,
};

// Godot Input.MouseMode
export const MOUSE_MODE = { VISIBLE: 0, HIDDEN: 1, CAPTURED: 2, CONFINED: 3, CONFINED_HIDDEN: 4 };

export const MODS = { SHIFT: 1, CTRL: 2, ALT: 4, META: 8 };

function frame(len) {
  const b = new ArrayBuffer(len);
  return [b, new DataView(b)];
}

export function encodeKey(pressed, keycode, physical, unicode, mods, echo, location) {
  const [b, v] = frame(17);
  v.setUint8(0, FRAME.KEY);
  v.setUint8(1, pressed ? 1 : 0);
  v.setUint32(2, keycode >>> 0, true);
  v.setUint32(6, physical >>> 0, true);
  v.setUint32(10, unicode >>> 0, true);
  v.setUint8(14, mods);
  v.setUint8(15, echo ? 1 : 0);
  v.setUint8(16, location);
  return b;
}

export function encodeMouseMove(x, y, dx, dy, buttons) {
  const [b, v] = frame(18);
  v.setUint8(0, FRAME.MOUSE_MOVE);
  v.setFloat32(1, x, true);
  v.setFloat32(5, y, true);
  v.setFloat32(9, dx, true);
  v.setFloat32(13, dy, true);
  v.setUint8(17, buttons);
  return b;
}

export function encodeMouseButton(pressed, button, x, y, factor, mods, dbl) {
  const [b, v] = frame(17);
  v.setUint8(0, FRAME.MOUSE_BUTTON);
  v.setUint8(1, pressed ? 1 : 0);
  v.setUint8(2, button);
  v.setFloat32(3, x, true);
  v.setFloat32(7, y, true);
  v.setFloat32(11, factor, true);
  v.setUint8(15, mods);
  v.setUint8(16, dbl ? 1 : 0);
  return b;
}

export function encodeJoyButton(device, button, pressed, pressure) {
  const [b, v] = frame(8);
  v.setUint8(0, FRAME.JOY_BUTTON);
  v.setUint8(1, device);
  v.setUint8(2, button);
  v.setUint8(3, pressed ? 1 : 0);
  v.setFloat32(4, pressure, true);
  return b;
}

export function encodeJoyAxis(device, axis, value) {
  const [b, v] = frame(7);
  v.setUint8(0, FRAME.JOY_AXIS);
  v.setUint8(1, device);
  v.setUint8(2, axis);
  v.setFloat32(3, value, true);
  return b;
}

export function encodeJoyConnect(device, connected, name) {
  const bytes = new TextEncoder().encode((name || 'gamepad').slice(0, 64));
  const [b, v] = frame(4 + bytes.length);
  v.setUint8(0, FRAME.JOY_CONNECT);
  v.setUint8(1, device);
  v.setUint8(2, connected ? 1 : 0);
  v.setUint8(3, bytes.length);
  new Uint8Array(b, 4).set(bytes);
  return b;
}

export function encodeReleaseAll() {
  return new Uint8Array([FRAME.RELEASE_ALL]).buffer;
}

export function encodePing(seq) {
  const [b, v] = frame(5);
  v.setUint8(0, FRAME.PING);
  v.setUint32(1, seq >>> 0, true);
  return b;
}

// Decode a game→browser message (may hold several frames).
export function decodeGameFrames(buf, onFrame) {
  const v = new DataView(buf);
  let o = 0;
  while (o < v.byteLength) {
    const t = v.getUint8(o);
    if (t === FRAME.MOUSE_MODE) { onFrame({ type: 'mouseMode', mode: v.getUint8(o + 1) }); o += 2; }
    else if (t === FRAME.PONG) { onFrame({ type: 'pong', seq: v.getUint32(o + 1, true) }); o += 5; }
    else if (t === FRAME.HELLO) { onFrame({ type: 'hello', version: v.getUint8(o + 1) }); o += 2; }
    else { console.warn('unknown game frame', t); return; }
  }
}

// Concatenate ArrayBuffers into one message.
export function batch(frames) {
  let n = 0;
  for (const f of frames) n += f.byteLength;
  const out = new Uint8Array(n);
  let o = 0;
  for (const f of frames) { out.set(new Uint8Array(f), o); o += f.byteLength; }
  return out.buffer;
}
