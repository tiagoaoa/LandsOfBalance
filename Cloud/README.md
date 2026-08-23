# Lands of Balance — Cloud

Cloud gaming for one game. The game runs on a server (a real Godot
instance with a GPU or a CPU rasteriser), the picture and sound are encoded
and streamed over WebRTC to a browser, and the browser sends keyboard,
mouse and gamepad back. Think Xbox Cloud Gaming, scoped down to Lands of
Balance and small enough to read in an afternoon.

```
 browser (Firefox / Chromium)                   gateway host
 ┌──────────────────────────┐     WebRTC      ┌─────────────────────────────────────────────┐
 │ <video> ← H.264 + Opus   │◀───────────────│ lobcloud (Go, Pion)                           │
 │ input.js → datachannels  │───────────────▶│   per session:                                │
 │  keyboard/mouse/gamepad  │   WS signaling  │   ┌ X display (:N, Xvfb | Xorg | your :0)     │
 └──────────────────────────┘ + REST sessions │   ├ PulseAudio null sink  lob_<id>             │
                                              │   ├ Godot ──LOB_CLOUD_INPUT_PORT──▶ CloudInput │
                                              │   │        (autoload/cloud_input.gd)           │
                                              │   └ ffmpeg x11grab ─▶ nvenc|vaapi|x264 ─▶ RTP  │
                                              │     ffmpeg pulse   ─▶ opus           ─▶ RTP  │
                                              └─────────────────────────────────────────────┘
```

Input never touches X: the browser encodes events into a tiny binary
protocol, the gateway forwards them over a loopback TCP socket, and the
`CloudInput` autoload turns them into `InputEvent`s with
`Input.parse_input_event()` — the same path a real X11 event takes, so the
InputMap, mouse capture, UI focus and joypad actions all behave. The game
reports its mouse mode back so the browser locks the pointer exactly when
the game captures it and releases it when a menu shows the cursor.

## Layout

```
Cloud/
  cmd/lobcloud/        gateway binary (HTTP + WebSocket signaling + sessions)
  cmd/lobprobe/        headless test client (creates a session, counts packets, pings the game)
  internal/config      flags + LOB_* env
  internal/session     display / audio sink / game process / ffmpeg capture / lifecycle
  internal/rtc         Pion peer: H.264+Opus tracks fed by loopback RTP, input datachannels
  internal/proto       the binary input protocol (validated here, decoded in Godot)
  internal/api         REST + WS handlers
  web/                 browser client: app.js (session/WebRTC), input.js (capture), protocol.js,
                       godot_keys.js (generated from the engine's enum dump)
  scripts/run_dev.sh   stream the game from this desktop
  scripts/build_game.sh export the game for the container
  docker/              Dockerfile, entrypoint, NVIDIA headless xorg.conf, coturn config
  docker-compose.yml   node + optional TURN relay
../autoload/cloud_input.gd   the game-side bridge (registered as the CloudInput autoload)
```

## Quick start (developer desktop)

Needs: Go ≥ 1.24, ffmpeg (with `x11grab`, `libopus` and one of
`h264_nvenc` / `h264_vaapi` / `libx264`), `xdotool`, PulseAudio or
pipewire-pulse, and the Godot binary.

```sh
cd Cloud
scripts/run_dev.sh                # builds bin/lobcloud, runs it on :8080 against ../
# open http://localhost:8080 → Play
```

The game opens as a normal window on your desktop; only that window is
captured (`-window_id`) so you can keep working next to it. Audio goes to a
private null sink, not your speakers. `Q` inside the game quits it and ends
the session (that is the game's own binding).

Without a browser:

```sh
bin/lobprobe -url http://localhost:8080 -duration 20s
# RESULT video_packets=21265 audio_packets=2340 hello=true pong=true mouse_mode=true
```

`pong=true` means a frame went browser → gateway → Godot → back, through
the same channels a player would use.

## Running it as a service

Every flag has an `LOB_*` environment twin (`lobcloud -h`). The ones that matter:

| flag | meaning | default |
|---|---|---|
| `--display-mode` | `existing` (your `$DISPLAY`), `xvfb` (one Xvfb per session, Mesa), `xorg` (one headless Xorg per session, NVIDIA) | `existing` |
| `--godot` / `--game-dir` | editor binary + project dir, **or** an exported game binary with an empty `--game-dir` | `godot`, `..` |
| `--width --height --fps` | stream format; the game window is opened at exactly this size | 1280 720 60 |
| `--encoder` | `auto` picks nvenc → vaapi → x264 by actually test-encoding a frame | `auto` |
| `--bitrate` | kbit/s, CBR with a ½ s buffer; 6000–12000 is the useful range at 720p60/1080p60 | 8000 |
| `--max-sessions` | concurrent game instances on this host | 2 |
| `--token` | shared secret; the client asks for it | open |
| `--public-ip` | advertise this IP in ICE candidates (cloud VM / 1:1 NAT) | — |
| `--udp-min --udp-max` | port range for WebRTC media; open it in the firewall | ephemeral |
| `--ice` | `stun:…`, `turn:user:pass@host:port` for players behind hard NAT | Google STUN |
| `--game-server` | also run `server/game_server` so sessions share one multiplayer world | off (`--singleplayer` is passed) |
| `--reconnect-grace` | how long the game survives after its player drops | 90 s |
| `--idle-timeout` | kill a streaming session that has had no input this long | 10 min |

### GPU modes

| | renders on | encodes with | how |
|---|---|---|---|
| **host, NVIDIA** | GPU | NVENC | `--display-mode xorg --xorg-config docker/xorg-nvidia.conf` (set the BusID). Needs the nvidia X driver and an Xorg that may start headless (root, or `needs_root_rights=yes` in Xwrapper). One Xorg per session on the same card is fine. |
| **host, AMD/Intel** | GPU | VAAPI | `--display-mode xvfb`. Mesa Vulkan has no DRI3 on Xvfb, so the gateway sets `MESA_VK_WSI_DEBUG=sw` and the frame is copied through the CPU once; the render itself is on the GPU. |
| **host, no GPU** | lavapipe (CPU) | x264 | `--display-mode xvfb`. Works everywhere, slow; drop to 960×540 and 30 fps. |
| **container** | Mesa (mount `/dev/dri`) or lavapipe | nvenc (`--gpus all`) / vaapi / x264 | `docker compose up`. NVIDIA inside Xvfb does not render (their X11 WSI needs their X driver), so an NVIDIA container is "render on CPU, encode on GPU" — fine for tests, not for 1080p60. |

### Container

```sh
Cloud/scripts/build_game.sh          # exports build/lob_server.x86_64 (needs the Linux export template)
docker build -f Cloud/docker/Dockerfile -t lobcloud .      # from the repo root
LOB_PUBLIC_IP=203.0.113.7 LOB_TOKEN=changeme docker compose -f Cloud/docker-compose.yml up
```

Port 8080/tcp for the page and signaling, 50000–50099/udp for media. Add
`--profile turn` and edit `docker/turnserver.conf` when players sit behind
symmetric NAT.

### Systemd (host, NVIDIA)

```ini
[Service]
Environment=LOB_DISPLAY_MODE=xorg LOB_XORG_CONFIG=/opt/lob/xorg-nvidia.conf
Environment=LOB_GODOT=/opt/lob/lob_server.x86_64 LOB_GAME_DIR= LOB_TOKEN=… LOB_PUBLIC_IP=…
Environment=LOB_UDP_MIN=50000 LOB_UDP_MAX=50099 LOB_MAX_SESSIONS=4 LOB_WIDTH=1920 LOB_HEIGHT=1080
ExecStartPre=/usr/bin/pulseaudio --daemonize=yes --exit-idle-time=-1
ExecStart=/opt/lob/lobcloud
```

## How a session goes

1. `POST /api/sessions` → the manager allocates a display number, starts the
   X server (if virtual), adds a Pulse null sink, launches Godot with
   `DISPLAY`, `PULSE_SINK`, `LOB_CLOUD_INPUT_PORT` and waits until the
   autoload is listening. State `starting` → `ready`.
2. The browser opens `/ws/<id>`, sends an SDP offer with two `recvonly`
   transceivers and two datachannels (`input` reliable+ordered,
   `motion` unordered+lossy). The gateway answers; ICE trickles both ways.
3. On `connected` the two ffmpeg processes start and send RTP to loopback
   ports the peer owns; Pion rewrites SSRC/PT and forwards. State `streaming`.
   The encoder emits an IDR keyframe every second, so a lost packet at a
   scene transition re-syncs within a second instead of freezing the picture.
4. Input frames are validated for shape and written to the game's TCP
   socket; the game answers `MOUSE_MODE` / `PONG` / `HELLO` on the same path.
5. Player drops → ffmpeg stops, the game gets `RELEASE_ALL` (no stuck keys)
   and waits `--reconnect-grace` for the same session id (`#s=<id>` in the
   URL). Game exits (its own `Q`) → session `stopped`. No input for
   `--idle-timeout` → killed. `DELETE /api/sessions/<id>` → killed now.

Per-session process logs live in `--log-dir` (`godot.log`, `ffmpeg-video.log`,
`ffmpeg-audio.log`, `xvfb.log`) — the first place to look when a session
ends in `error`.

## Latency notes

Measured on a laptop (GTX 1650, `existing` display, loopback), headless
Chromium: 60 fps at 8 Mbit/s, ~1 ms decode, video jitter buffer ~2–3 ms,
input round-trip browser→game→browser 4 ms. Things that were found to matter:

* **Separate stream ids for audio and video.** Tracks with the same msid are
  lip-synced by the browser and video then waits for the audio jitter
  buffer (hundreds of ms in bad cases). The gateway deliberately uses
  `lob-video` / `lob-audio`.
* `playoutDelayHint = 0` / `jitterBufferTarget = 0` on the receivers.
* Encoder: `p1`/`ull`/`zerolatency`, no B-frames, CBR, one IDR keyframe per
  second. x264 `ultrafast`+`zerolatency`+`sliced-threads`.
* Mouse motion is accumulated per animation frame and sent on the lossy
  channel; buttons and keys go reliable and flush pending motion first so
  ordering holds.
* ffmpeg has no back-channel, so it cannot answer a browser PLI with an
  on-demand keyframe. **This was a real bug:** with a single IDR followed by
  intra-refresh, a packet lost during the class→world scene load corrupted the
  reference chain permanently and the browser froze on the last menu frame
  while still receiving 8 Mbit/s. The fix is periodic IDRs (1 s) that let the
  decoder re-sync on its own; a GStreamer `webrtcbin` pipeline (keyframe on
  PLI) would be the next step to drop the steady-state keyframe cost.

## The input protocol

Defined in `internal/proto/proto.go`, encoded in `web/protocol.js`, decoded
in `autoload/cloud_input.gd`. Little-endian, first byte is the type:

| type | payload |
|---|---|
| `0x01 KEY` | pressed u8, keycode u32, physical u32, unicode u32, mods u8, echo u8, location u8 |
| `0x02 MOUSE_MOVE` | x f32, y f32, dx f32, dy f32, buttons u8 (stream pixels) |
| `0x03 MOUSE_BUTTON` | pressed u8, button u8, x f32, y f32, factor f32, mods u8, double u8 |
| `0x04 JOY_BUTTON` | device u8, button u8, pressed u8, pressure f32 |
| `0x05 JOY_AXIS` | device u8, axis u8, value f32 |
| `0x06 JOY_CONNECT` | device u8, connected u8, name_len u8, name |
| `0x07 RELEASE_ALL` | — (blur, disconnect) |
| `0x08 PING` | seq u32 |
| `0x80 MOUSE_MODE` ← | Godot `Input.MouseMode` |
| `0x81 PONG` ← | seq u32 |
| `0x82 HELLO` ← | protocol version |

Key codes are Godot's own (`web/godot_keys.js` is generated from
`godot --dump-extension-api`, so it follows the engine — note 4.5's
`KEY_SPECIAL` is `1<<22`). Keycode is layout-aware for letters, digits and
unshifted punctuation (what the InputMap binds), physical-key fallback for
the rest; gamepads use the standard mapping, triggers become axes 4/5.

## Next steps

* A native client (SDL + libwebrtc or a Pion/Go client with VA-API decode)
  — the signaling and protocol are already client-agnostic; `lobprobe` is
  the skeleton.
* Keyframe-on-PLI and congestion-adaptive bitrate (needs an encoder with a
  control channel: GStreamer or a direct NVENC/VAAPI binding).
* Rumble back to the browser (`Input.start_joy_vibration` is not
  observable from GDScript today; a tiny engine-side hook would do).
* More than one node: a front door that picks the nearest host; the REST
  surface here is what it would call.
