/**
 * Visual iteration loop: boot the game on the REAL GPU, pose the camera at a
 * set of fixed vantage points, and write a screenshot per vantage.
 *
 * Playing the game through `console_check.mjs` is far too slow to iterate on
 * looks. This drives straight to a pose and captures, so a lighting or shader
 * change can be judged in one run.
 *
 * Usage: node scripts/shot.mjs [outPrefix] [night|day] [class]
 */
import { existsSync, mkdirSync, writeFileSync } from 'node:fs'
import { chromium } from 'playwright'

const OUT = process.argv[2] ?? 'scratch/shot'
const TIME = process.argv[3] ?? 'night'
const CLASS = process.argv[4] ?? 'paladin'
// Headless Chromium reports a WebGPU adapter and submits draw calls, but only
// the clear colour ever reaches the page — so the visual harness pins the
// WebGL2 backend of the same node renderer. The TSL graph under test is
// identical on both; only the backend differs.
const URL = process.env.URL ?? 'http://127.0.0.1:5273/?webgl=1&hud=0'

const FULL_CHROMIUM = `${process.env.HOME}/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome`

/** Fixed vantages: [name, playerX, playerZ, cameraYaw, cameraPitch]. */
const VANTAGES = [
  ['village', 6, 22, Math.PI, -0.13],
  ['field', 22, -38, 2.0, -0.08],
  ['closeup', 3, 17, 2.6, -0.06],
  // On the BANK of the northern branch, not in it — standing in the channel
  // put the camera inside the water plane and hid the landscape.
  ['riverbank', -44, 44, 1.05, -0.10],
  ['vista', 64, -74, 2.35, -0.05],
]

mkdirSync(OUT.split('/').slice(0, -1).join('/') || '.', { recursive: true })

const browser = await chromium.launch({
  executablePath: existsSync(FULL_CHROMIUM) ? FULL_CHROMIUM : undefined,
  args: [
    '--use-angle=vulkan',
    '--enable-features=Vulkan',
    '--enable-unsafe-webgpu',
    '--no-sandbox',
    '--disable-dev-shm-usage',
  ],
})
const page = await browser.newPage({ viewport: { width: 1600, height: 900 } })
const errors = []
page.on('pageerror', (e) => errors.push('PAGEERROR ' + e.message))
page.on('console', (m) => {
  if (m.type() === 'error') errors.push(m.text())
})

await page.goto(URL, { waitUntil: 'domcontentloaded', timeout: 60000 })
await page.click(`.choice[data-class="${CLASS}"]`, { timeout: 60000 })
await page.waitForSelector('.overlay h1:text("Ready")', { timeout: 180000 })
await page.click('.overlay')
await page.waitForTimeout(1200)

console.log('renderer:', JSON.stringify(await page.evaluate(() => window.lob?.rendererInfo?.() ?? null)))

if (TIME === 'day') {
  await page.keyboard.press('KeyL')
  await page.waitForTimeout(2500) // let the 2 s preset transition settle
}

if (process.env.FIRE === '1') {
  await page.evaluate(() => {
    const g = window.lob
    const p = g.player.position
    for (const [dx, dz] of [[3, -4], [-5, -7], [7, -9]]) {
      g.ctx.fx.spawnGroundFire(new (g.player.position.constructor)(p.x + dx, g.ctx.world.groundHeight(p.x + dx, p.z + dz) ?? 0, p.z + dz))
    }
  })
  await page.waitForTimeout(600)
}

for (const [name, x, z, yaw, pitch] of VANTAGES) {
  await page.evaluate(
    ([px, pz, cy, cp]) => {
      const g = window.lob
      const y = g.ctx.world.groundHeight(px, pz) ?? 1
      g.player.object.position.set(px, y + 0.1, pz)
      g.player.velocity.set(0, 0, 0)
      g.engine.cameraRotation.x = cy
      g.engine.cameraRotation.y = cp
      g.engine.syncPivotRotation()
      g.player.syncCameraPivot()
    },
    [x, z, yaw, pitch],
  )
  // Let temporal effects converge, animations settle, and — importantly —
  // the grass field finish recentring after the teleport, so the FPS sample
  // reflects steady state rather than the rebuild.
  await page.waitForTimeout(2200)
  // Always the COMPOSITED page screenshot. Reading the canvas back in-page
  // (toDataURL / drawImage) returns black for a WebGL or WebGPU canvas
  // outside its render tick, which reads exactly like a broken renderer —
  // it cost an hour of chasing a bug that wasn't there.
  writeFileSync(`${OUT}-${name}.png`, await page.screenshot())
  const fps = await page.evaluate(() => window.lob?.fps?.() ?? 0)
  console.log(`wrote ${OUT}-${name}.png  (${fps} fps)`)
}

if (errors.length) {
  console.log(`\n${errors.length} console errors:`)
  for (const e of errors.slice(0, 12)) console.log('  ', e)
}
await browser.close()
