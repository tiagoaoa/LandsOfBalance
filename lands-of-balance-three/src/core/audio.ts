/**
 * Port of autoload/sfx.gd — the one-line SFX access the whole game uses.
 *
 * Same contract as the GDScript autoload: one-shots go through a small pool
 * with random pitch jitter so repeated hits never sound machine-gunned, and
 * positional sounds attenuate with distance from the listener. The streams
 * are the project's own WAV set (assets/audio/sfx, see its CREDITS.md).
 */
import { AudioListener, Audio as ThreeAudio, PositionalAudio, type Object3D, type Vector3 } from 'three'

const SFX = [
  'arrow_impact', 'block_chip', 'bobba_roar', 'bow_release', 'death_thud',
  'estus_drink', 'fire_crackle_loop', 'fire_ignite', 'hit_flesh', 'hit_metal',
  'night_rain_loop', 'parry_ring', 'punch_whoosh', 'river_loop', 'roll',
  'sword_whoosh_1', 'sword_whoosh_2', 'sword_whoosh_3',
] as const

const POOL_SIZE = 16
const MAX_DISTANCE = 60

export class AudioManager {
  readonly listener = new AudioListener()
  private readonly buffers = new Map<string, AudioBuffer>()
  private readonly pool: PositionalAudio[] = []
  private poolIdx = 0
  private ambience: ThreeAudio | null = null
  private ready = false
  muted = false

  constructor(camera: Object3D) {
    camera.add(this.listener)
    for (let i = 0; i < POOL_SIZE; i++) {
      const p = new PositionalAudio(this.listener)
      p.setRefDistance(6)
      p.setMaxDistance(MAX_DISTANCE)
      p.setDistanceModel('inverse')
      this.pool.push(p)
    }
  }

  /** Decode the whole set up front — it is only ~5 MB and avoids first-hit lag. */
  async load(base = '/assets/audio/'): Promise<void> {
    const ctx = this.listener.context
    await Promise.all(
      SFX.map(async (name) => {
        try {
          const res = await fetch(`${base}${name}.wav`)
          if (!res.ok) return
          this.buffers.set(name, await ctx.decodeAudioData(await res.arrayBuffer()))
        } catch {
          // A missing sample must never take the game down with it.
        }
      }),
    )
    this.ready = true
  }

  /**
   * Browsers refuse to start audio before a user gesture; call this from the
   * click that starts the game.
   */
  resume(): void {
    void this.listener.context.resume()
  }

  /**
   * Fire a one-shot. `volumeDb` matches the Godot call sites, which pass
   * negative decibels; positional sounds need a parent in the scene, so the
   * pool player is re-parented to a scratch object at `pos`.
   */
  play(name: string, pos?: Vector3, volumeDb = 0, host?: Object3D): void {
    if (this.muted || !this.ready) return
    const buffer = this.buffers.get(name)
    if (!buffer) return

    const player = this.pool[this.poolIdx]
    this.poolIdx = (this.poolIdx + 1) % this.pool.length
    if (player.isPlaying) player.stop()

    if (pos && host) {
      host.add(player)
      player.position.copy(pos)
    }
    player.setBuffer(buffer)
    player.setVolume(Math.pow(10, volumeDb / 20))
    // Pitch jitter, so a burst of sword hits doesn't sound like one sample.
    player.setPlaybackRate(0.92 + Math.random() * 0.16)
    player.play()
  }

  /** The rainy-night ambience bed — a loop, not a one-shot. */
  startAmbience(name = 'night_rain_loop', volumeDb = -18): void {
    if (this.muted || !this.ready) return
    const buffer = this.buffers.get(name)
    if (!buffer) return
    this.ambience?.stop()
    this.ambience = new ThreeAudio(this.listener)
    this.ambience.setBuffer(buffer)
    this.ambience.setLoop(true)
    this.ambience.setVolume(Math.pow(10, volumeDb / 20))
    this.ambience.play()
  }

  stopAmbience(): void {
    this.ambience?.stop()
    this.ambience = null
  }
}
