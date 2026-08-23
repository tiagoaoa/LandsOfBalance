// Lands of Balance cloud client: session REST + WebSocket signaling +
// WebRTC (H.264/Opus in, input datachannels out) + a thin HUD.
import { InputCapture } from './input.js';
import * as P from './protocol.js';

const $ = (id) => document.getElementById(id);
const els = {
  lobby: $('lobby'), stage: $('stage'), video: $('video'), status: $('status'),
  play: $('play'), token: $('token'), tokenRow: $('tokenRow'), sessions: $('sessions'),
  hud: $('hud'), stats: $('stats'), hint: $('hint'), banner: $('banner'),
  leave: $('leave'), fullscreen: $('fullscreen'), unlock: $('unlock'), hudToggle: $('hudToggle'),
  sens: $('sens'), sensVal: $('sensVal'), capacity: $('capacity'),
};

const state = {
  cfg: null, token: localStorage.getItem('lob.token') || '', sessionId: null,
  ws: null, pc: null, input: null, motion: null, capture: null, statsTimer: 0,
  lastStats: null, reconnects: 0, leaving: false, pingSeq: 0, pingSent: new Map(), rttGame: null,
};

function setStatus(msg, cls) {
  els.status.textContent = msg;
  els.status.className = cls || '';
}

function banner(msg) {
  els.banner.textContent = msg || '';
  els.banner.hidden = !msg;
}

function authHeaders() {
  return state.token ? { Authorization: 'Bearer ' + state.token } : {};
}

async function api(method, path, body) {
  const r = await fetch(path, { method, headers: { 'Content-Type': 'application/json', ...authHeaders() }, body: body ? JSON.stringify(body) : undefined });
  if (r.status === 204) return null;
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(j.error || r.statusText);
  return j;
}

async function loadConfig() {
  try {
    state.cfg = await api('GET', '/api/config');
    els.tokenRow.hidden = !state.cfg.authRequired;
    els.capacity.textContent = `${state.cfg.sessions}/${state.cfg.capacity} slots in use · ${state.cfg.width}×${state.cfg.height}@${state.cfg.fps}`;
    await refreshSessions();
    els.play.disabled = false;
    setStatus('Ready.');
  } catch (e) {
    setStatus('Cannot reach the gateway: ' + e.message, 'err');
  }
}

async function refreshSessions() {
  if (state.cfg?.authRequired && !state.token) { els.sessions.innerHTML = ''; return; }
  try {
    const list = await api('GET', '/api/sessions');
    els.sessions.innerHTML = '';
    for (const s of list) {
      const li = document.createElement('li');
      li.innerHTML = `<code>${s.id}</code> <span class="tag ${s.state}">${s.state}</span> ${s.peerConnected ? '· player attached' : ''}`;
      if (!s.peerConnected && (s.state === 'ready' || s.state === 'waiting' || s.state === 'starting')) {
        const b = document.createElement('button');
        b.textContent = 'Rejoin';
        b.onclick = () => join(s.id);
        li.appendChild(b);
      }
      const d = document.createElement('button');
      d.textContent = 'Kill';
      d.className = 'danger';
      d.onclick = async () => { await api('DELETE', '/api/sessions/' + s.id).catch(() => {}); refreshSessions(); };
      li.appendChild(d);
      els.sessions.appendChild(li);
    }
  } catch (e) {
    setStatus(e.message, 'err');
  }
}

// ---------------------------------------------------------------- session

async function play() {
  state.token = els.token.value.trim();
  localStorage.setItem('lob.token', state.token);
  els.play.disabled = true;
  setStatus('Creating session…');
  try {
    const r = await api('POST', '/api/sessions');
    await join(r.session.id);
  } catch (e) {
    setStatus(e.message, 'err');
    els.play.disabled = false;
  }
}

async function join(id) {
  state.sessionId = id;
  state.leaving = false;
  state.reconnects = 0;
  location.hash = 's=' + id;
  els.lobby.hidden = true;
  els.stage.hidden = false;
  banner('Starting game…');
  connect();
}

function wsURL(id) {
  const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
  return `${proto}//${location.host}/ws/${id}${state.token ? '?token=' + encodeURIComponent(state.token) : ''}`;
}

function connect() {
  const ws = new WebSocket(wsURL(state.sessionId));
  state.ws = ws;
  ws.onopen = () => { state.reconnects = 0; startPeer(); };
  ws.onmessage = (ev) => onSignal(JSON.parse(ev.data));
  ws.onclose = () => {
    if (state.ws !== ws) return;
    teardownPeer();
    if (state.leaving) return;
    if (state.reconnects++ < 8) {
      banner(`Connection lost — reconnecting (${state.reconnects})…`);
      setTimeout(() => { if (!state.leaving) connect(); }, 1500);
    } else {
      leave('Could not reconnect.');
    }
  };
  ws.onerror = () => {};
}

function signal(msg) {
  if (state.ws && state.ws.readyState === WebSocket.OPEN) state.ws.send(JSON.stringify(msg));
}

async function onSignal(m) {
  switch (m.type) {
    case 'answer':
      await state.pc.setRemoteDescription({ type: 'answer', sdp: m.sdp });
      break;
    case 'ice':
      if (m.candidate && state.pc) state.pc.addIceCandidate(m.candidate).catch(() => {});
      break;
    case 'state':
      onSessionState(m.session);
      break;
    case 'stats':
      state.serverStats = m.stats;
      break;
    case 'error':
      leave('Gateway error: ' + m.error);
      break;
  }
}

function onSessionState(s) {
  switch (s.state) {
    case 'starting': banner('Starting the game on the server…'); break;
    case 'ready': banner('Game is up — connecting the stream…'); break;
    case 'streaming': banner(''); break;
    case 'waiting': banner('Waiting for the stream…'); break;
    case 'stopped': leave('Session ended: ' + (s.error || 'stopped')); break;
    case 'error': leave('Session failed: ' + (s.error || 'unknown error')); break;
  }
}

// ------------------------------------------------------------------ WebRTC

async function startPeer() {
  teardownPeer();
  const pc = new RTCPeerConnection({ iceServers: state.cfg?.iceServers || [], bundlePolicy: 'max-bundle' });
  state.pc = pc;
  window.__pc = pc;

  pc.addTransceiver('video', { direction: 'recvonly' });
  pc.addTransceiver('audio', { direction: 'recvonly' });
  // Ask for zero playout delay: this is a game, not a movie.
  for (const r of pc.getReceivers()) {
    try { r.playoutDelayHint = 0; } catch (_) {}
    try { r.jitterBufferTarget = 0; } catch (_) {}
  }

  const input = pc.createDataChannel('input', { ordered: true });
  const motion = pc.createDataChannel('motion', { ordered: false, maxRetransmits: 0 });
  input.binaryType = 'arraybuffer';
  motion.binaryType = 'arraybuffer';
  state.input = input; state.motion = motion;
  input.onopen = () => {
    state.capture.start();
    state.capture.announcePads();
    sendPing();
  };
  input.onmessage = (ev) => P.decodeGameFrames(ev.data, onGameFrame);

  const stream = new MediaStream();
  pc.ontrack = (ev) => {
    stream.addTrack(ev.track);
    if (els.video.srcObject !== stream) els.video.srcObject = stream;
    els.video.play().catch(() => {});
  };
  pc.onicecandidate = (ev) => { if (ev.candidate) signal({ type: 'ice', candidate: ev.candidate.toJSON() }); };
  pc.onconnectionstatechange = () => {
    if (pc.connectionState === 'connected') banner('');
    else if (pc.connectionState === 'failed') { banner('Media connection failed — retrying…'); if (state.ws) state.ws.close(); }
  };

  const offer = await pc.createOffer();
  await pc.setLocalDescription(offer);
  signal({ type: 'offer', sdp: pc.localDescription.sdp });

  clearInterval(state.statsTimer);
  state.statsTimer = setInterval(pollStats, 1000);
}

function teardownPeer() {
  clearInterval(state.statsTimer);
  if (state.capture) state.capture.stop();
  if (state.pc) { try { state.pc.close(); } catch (_) {} }
  state.pc = null; state.input = null; state.motion = null; state.lastStats = null;
}

function sendFrame(buf, reliable) {
  const ch = reliable ? state.input : (state.motion?.readyState === 'open' ? state.motion : state.input);
  if (ch && ch.readyState === 'open') {
    try { ch.send(buf); } catch (_) {}
  }
}

function sendPing() {
  if (!state.input || state.input.readyState !== 'open') return;
  const seq = ++state.pingSeq;
  state.pingSent.set(seq, performance.now());
  sendFrame(P.encodePing(seq), true);
  if (state.pingSent.size > 20) state.pingSent.delete(seq - 20);
}

function onGameFrame(f) {
  if (f.type === 'mouseMode') {
    state.capture.setGameMouseMode(f.mode);
    updateHint();
  } else if (f.type === 'pong') {
    const t = state.pingSent.get(f.seq);
    if (t) { state.rttGame = performance.now() - t; state.pingSent.delete(f.seq); }
  }
}

function updateHint() {
  const c = state.capture;
  const show = c.active && c.wantsLock() && !c.locked;
  els.hint.hidden = !show;
  els.video.style.cursor = c.wantsLock() ? 'none' : 'default';
  els.unlock.hidden = !c.locked;
}

async function pollStats() {
  if (!state.pc) return;
  const rep = await state.pc.getStats().catch(() => null);
  if (!rep) return;
  let v = null, a = null, pair = null;
  rep.forEach((r) => {
    if (r.type === 'inbound-rtp' && r.kind === 'video') v = r;
    if (r.type === 'inbound-rtp' && r.kind === 'audio') a = r;
    if (r.type === 'candidate-pair' && (r.selected || r.nominated) && r.state === 'succeeded') pair = r;
  });
  if (!v) return;
  const prev = state.lastStats;
  let line = '';
  if (prev && v.timestamp > prev.timestamp) {
    const dt = (v.timestamp - prev.timestamp) / 1000;
    const kbps = Math.round(((v.bytesReceived - prev.bytesReceived) * 8) / dt / 1000);
    const fps = v.framesPerSecond ?? Math.round((v.framesDecoded - prev.framesDecoded) / dt);
    const dec = v.framesDecoded > prev.framesDecoded ? ((v.totalDecodeTime - prev.totalDecodeTime) / (v.framesDecoded - prev.framesDecoded)) * 1000 : 0;
    const jb = v.jitterBufferEmittedCount > (prev.jitterBufferEmittedCount || 0)
      ? ((v.jitterBufferDelay - prev.jitterBufferDelay) / (v.jitterBufferEmittedCount - prev.jitterBufferEmittedCount)) * 1000 : 0;
    const lost = v.packetsLost - prev.packetsLost;
    line = `${v.frameWidth || '?'}×${v.frameHeight || '?'} ${fps} fps · ${kbps} kbit/s · decode ${dec.toFixed(1)} ms · jitter buf ${jb.toFixed(0)} ms`
      + ` · loss ${lost}${v.nackCount ? ' nack ' + v.nackCount : ''}${v.pliCount ? ' pli ' + v.pliCount : ''}`
      + (pair && pair.currentRoundTripTime != null ? ` · rtt ${(pair.currentRoundTripTime * 1000).toFixed(0)} ms` : '')
      + (state.rttGame != null ? ` · input rtt ${state.rttGame.toFixed(0)} ms` : '')
      + (a ? ` · audio ${a.packetsReceived} pkts` : ' · no audio');
  }
  state.lastStats = v;
  if (line) els.stats.textContent = line;
  if (state.pingSeq % 2 === 0) sendPing(); else state.pingSeq++;
}

// --------------------------------------------------------------------- UI

async function leave(reason) {
  if (state.leaving) return;
  state.leaving = true;
  const id = state.sessionId;
  teardownPeer();
  if (state.ws) { try { state.ws.close(); } catch (_) {} state.ws = null; }
  if (reason === undefined && id) await api('DELETE', '/api/sessions/' + id).catch(() => {});
  state.sessionId = null;
  history.replaceState(null, '', location.pathname);
  els.stage.hidden = true;
  els.lobby.hidden = false;
  els.play.disabled = false;
  if (document.fullscreenElement) document.exitFullscreen().catch(() => {});
  setStatus(reason || 'Left the session.', reason && !reason.startsWith('Left') ? 'err' : '');
  refreshSessions();
}

function init() {
  state.capture = new InputCapture(els.video, sendFrame);
  state.capture.onLockChange = updateHint;
  els.token.value = state.token;
  els.play.onclick = play;
  els.leave.onclick = () => leave();
  els.fullscreen.onclick = () => {
    if (document.fullscreenElement) document.exitFullscreen();
    else els.stage.requestFullscreen().catch(() => {});
  };
  els.unlock.onclick = () => document.exitPointerLock();
  els.hudToggle.onclick = () => els.hud.classList.toggle('collapsed');
  els.hint.onclick = () => state.capture.requestLock();
  els.video.addEventListener('loadedmetadata', () => state.capture.setStreamSize(els.video.videoWidth, els.video.videoHeight));
  els.sens.oninput = () => { state.capture.sensitivity = Number(els.sens.value); els.sensVal.textContent = els.sens.value + '×'; };
  window.addEventListener('beforeunload', () => { if (state.ws) signal({ type: 'leave' }); });

  loadConfig().then(() => {
    const m = location.hash.match(/s=([0-9a-f]+)/);
    if (m) join(m[1]);
  });
}

init();
