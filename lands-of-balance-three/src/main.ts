/**
 * Bootstrap — the port's equivalent of game.tscn.
 *
 * The Godot scene tree is: LandsOfBalance (stage) + Player + Bobba +
 * SkeletonCrew + the HUD layers. Same here, assembled in load order, then
 * driven by one fixed-step loop so the ported `_physics_process` code keeps
 * the deterministic tick it was written against.
 */
import { Vector3 } from 'three'
import './ui/hud.css'

import { AnimRig } from './core/anim'
import { AssetLoader, measureRigHeight } from './core/assets'
import { AudioManager } from './core/audio'
import { type Combatant, type GameContext, Groups, TimeOfDay } from './core/context'
import { Engine } from './core/engine'
import { InputManager } from './core/input'
import { WorldCollision } from './core/physics'
import { Bobba } from './enemies/bobba'
import { SkeletonCrew } from './enemies/skeleton'
import { FloatingTextPool, SparkPool } from './fx/effects'
import { GroundFire } from './fx/fire'
import { Player } from './player/player'
import { Hud } from './ui/hud'
import { characterSelect, deathScreen, LoadingScreen, pressToStart } from './ui/screens'
import { LightingManager } from './world/lighting'
import { Sky } from './world/sky'
import { buildStage } from './world/stage'

/** game.tscn places Bobba at (3, 1, 13). */
const BOBBA_SPAWN = new Vector3(3, 1, 13)
/** Fixed step. The GDScript is written against a 60 Hz `_physics_process`. */
const FIXED_DT = 1 / 60
const MAX_STEPS_PER_FRAME = 5

async function main(): Promise<void> {
  const canvas = document.getElementById('view') as HTMLCanvasElement
  const loading = new LoadingScreen()

  const chosenClass = await characterSelect()

  // Quality switches are URL-driven so a rendering problem can be bisected
  // without a rebuild: ?post=0 / ?ao=0 / ?bloom=0 / ?aa=0 / ?scale=0.5
  const q = new URLSearchParams(location.search)
  const flag = (name: string, fallback: boolean): boolean =>
    q.has(name) ? q.get(name) !== '0' && q.get(name) !== 'off' : fallback
  const engine = new Engine(canvas, {
    post: flag('post', true),
    ao: flag('ao', true),
    bloom: flag('bloom', true),
    antialias: flag('aa', true),
    resolutionScale: Number(q.get('scale') ?? 1) || 1,
    forceWebGL: flag('webgl', false),
  })
  await engine.init()
  const input = new InputManager(canvas)
  const world = new WorldCollision()
  const groups = new Groups()
  const assets = new AssetLoader()
  const audio = new AudioManager(engine.camera)
  const hud = new Hud(document.body)
  // ?hud=0 strips the interface for clean look-development screenshots.
  if (!flag('hud', true)) hud.root.style.display = 'none'
  const showLabels = flag('labels', true)

  const sparks = new SparkPool(engine.scene)
  const floaters = new FloatingTextPool(engine.scene)
  const fires: GroundFire[] = []

  const ctx: GameContext = {
    scene: engine.scene,
    world,
    groups,
    input,
    timeOfDay: TimeOfDay.NIGHT,
    now: 0,
    hud: {
      showLabel: (text, color) => hud.showLabel(text, color),
      floatText: (pos, text, color) => floaters.spawn(pos, text, color),
      flashDamage: () => hud.flashDamage(),
    },
    fx: {
      spawnHitSpark: (pos, color) => sparks.spawn(pos, color),
      spawnGroundFire: (pos) => {
        fires.push(new GroundFire(ctx, engine.scene, pos))
      },
    },
    audio: {
      play: (name, pos, volumeDb) => audio.play(name, pos, volumeDb, engine.scene),
    },
  }

  loading.setProgress(0.1)
  const lighting = new LightingManager(engine.scene)
  lighting.setTime(TimeOfDay.NIGHT, true)
  const sky = new Sky(engine.renderer)
  lighting.attachSky(sky)

  // ── World ──
  const stage = await buildStage(assets, world)
  engine.scene.add(stage.root)
  lighting.registerWetSurface(stage.root)
  loading.setProgress(0.45)

  // ── Actors ──
  const player = await Player.create(ctx, engine, assets, chosenClass)
  const spawnY = world.groundHeight(0, 10)
  player.object.position.set(0, (spawnY ?? 0.5) + 0.1, 10)
  loading.setProgress(0.7)

  const bobbaGround = world.groundHeight(BOBBA_SPAWN.x, BOBBA_SPAWN.z)
  const bobba = await Bobba.create(
    ctx,
    assets,
    new Vector3(BOBBA_SPAWN.x, (bobbaGround ?? 1) + 0.1, BOBBA_SPAWN.z),
  )
  loading.setProgress(0.85)

  const crew = new SkeletonCrew(ctx)
  await crew.spawn(assets, bobba.position)
  loading.setProgress(0.95)

  await audio.load()
  loading.setProgress(1)
  loading.done()

  await pressToStart()
  audio.resume()
  audio.startAmbience()
  input.requestPointerLock()
  canvas.addEventListener('click', () => input.requestPointerLock())

  // ── Loop ──
  let last = performance.now() / 1000
  // Rolling frame-time average — quality work is only worth it if the frame
  // budget survives, so the screenshot harness reports this next to the image.
  let frameAvg = 16.7
  let accumulator = 0
  let awaitingRespawn = false

  const step = (dt: number): void => {
    ctx.now += dt
    input.pollGamepad()

    player.handleInput()

    // Global toggles the Godot build reads in `_input`.
    if (input.isActionJustPressed('toggle_time')) {
      lighting.toggle()
      ctx.timeOfDay = lighting.timeOfDay
      hud.showLabel(ctx.timeOfDay === TimeOfDay.NIGHT ? 'Night falls' : 'Nordic day')
    }
    if (input.isActionJustPressed('toggle_map')) hud.toggleMinimap()
    if (input.isActionJustPressed('toggle_help')) hud.toggleControls()

    player.update(dt)
    player.updateDamageBuff(dt)
    player.syncCameraPivot()

    bobba.update(dt)
    crew.update(dt)

    for (let i = fires.length - 1; i >= 0; i--) {
      fires[i].update(dt)
      if (fires[i].dead) fires.splice(i, 1)
    }
    sparks.update(dt)
    floaters.update(dt)

    lighting.update(dt)
    lighting.followTarget(player.object.position)
    sky.follow(player.object.position)
    stage.grass.setPlayerPosition(player.object.position)

    input.endFrame()
  }

  const frame = (): void => {
    requestAnimationFrame(frame)
    const now = performance.now() / 1000
    let frameTime = now - last
    last = now
    // A long stall (tab in the background, a GC pause) must not be replayed
    // as fifty physics steps — clamp instead of spiralling.
    if (frameTime > MAX_STEPS_PER_FRAME * FIXED_DT) frameTime = MAX_STEPS_PER_FRAME * FIXED_DT
    accumulator += frameTime
    frameAvg += (frameTime * 1000 - frameAvg) * 0.05

    let steps = 0
    while (accumulator >= FIXED_DT && steps < MAX_STEPS_PER_FRAME) {
      step(FIXED_DT)
      accumulator -= FIXED_DT
      steps++
    }

    engine.syncPivotRotation()
    engine.updateSpringArm(world)
    stage.updateLabels(engine.camera.position, showLabels)
    engine.setExposure(lighting.exposure)
    engine.setNightAmount(lighting.nightAmount)

    const foes: Combatant[] = [
      ...groups.get<Combatant>('bobba'),
      ...groups.get<Combatant>('skeletons'),
    ].sort((a, b) => a.position.distanceTo(player.position) - b.position.distanceTo(player.position))

    hud.update(
      frameTime,
      {
        hp: player.healthComp.currentHp,
        maxHp: player.healthComp.maxHp,
        stamina: player.stamina.currentStamina,
        maxStamina: player.stamina.maxStamina,
        estus: player.estusCharges,
        buffPct: player.damageBuffPct,
        position: player.position,
        isBlocking: player.isBlocking,
        isRolling: player.isRolling,
        isParrying: player.isParrying,
        lockTarget: player.lockTarget,
      },
      foes,
      engine.camera,
    )

    if (player.isDead && !awaitingRespawn) {
      awaitingRespawn = true
      void deathScreen().then(() => {
        player.respawn()
        awaitingRespawn = false
        input.requestPointerLock()
      })
    }

    engine.render()
  }

  frame()

  // Handy for poking at the running game from the console.
  Object.assign(window as unknown as Record<string, unknown>, {
    lob: {
      engine,
      player,
      bobba,
      crew,
      lighting,
      ctx,
      AnimRig,
      /**
       * Render and read back in the same task. The drawing buffer isn't
       * preserved, so a screenshot taken by an external tool comes out blank
       * — this is how the headless check captures a real frame.
       */
      /**
       * Which GPU actually rendered this. Verification runs must be able to
       * tell a real device from a silent SwiftShader fallback — the two look
       * like completely different games.
       */
      fps: () => Math.round(1000 / Math.max(frameAvg, 0.01)),
      rendererInfo: () => {
        // WebGPURenderer exposes no getContext(); sniff the WebGL2 fallback's
        // device string off a scratch canvas instead.
        let device = 'unknown'
        try {
          const gl = document.createElement('canvas').getContext('webgl2')
          const dbg = gl?.getExtension('WEBGL_debug_renderer_info')
          if (gl && dbg) device = String(gl.getParameter(dbg.UNMASKED_RENDERER_WEBGL))
        } catch {
          /* reporting only */
        }
        return { backend: engine.backendName, device }
      },
      /** Measured standing heights, for scale tuning. */
      heights: () => ({
        player: measureRigHeight(player.modelObject),
        bobba: measureRigHeight(bobba.modelObject),
        skeleton: crew.members[0] ? measureRigHeight(crew.members[0].modelObject) : null,
      }),
      snapshot(): string {
        engine.render()
        return canvas.toDataURL('image/png')
      },
    },
  })
}

void main().catch((err) => {
  console.error('[lands-of-balance] fatal:', err)
  const el = document.createElement('div')
  el.className = 'overlay'
  el.innerHTML = `<div><h1>The Lands did not rise</h1><div class="sub">${String(err)}</div></div>`
  document.body.appendChild(el)
})
