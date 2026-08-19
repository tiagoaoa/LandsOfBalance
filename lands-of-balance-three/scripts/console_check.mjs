/**
 * Headless smoke test: boot the game, pick a class, let it run, and report
 * every console error / page exception. Uses the system Chromium with
 * SwiftShader, since CI machines rarely have a GPU.
 *
 * Usage: node scripts/console_check.mjs [url] [seconds] [paladin|archer]
 */
import { existsSync } from 'node:fs'
import { chromium } from 'playwright'

const URL = process.argv[2] ?? 'http://127.0.0.1:5273/'
const SECONDS = Number(process.argv[3] ?? 20)
const CLASS = process.argv[4] ?? 'paladin'

// Playwright's FULL Chromium (not the headless shell) driven through ANGLE's
// Vulkan backend renders on the real GPU. That is worth insisting on: the
// headless shell falls back to SwiftShader, which runs at a few frames per
// second and makes every screenshot look far worse than the game does.
// Set CHROMIUM_PATH to override, or GPU=0 to force software.
const FULL_CHROMIUM = `${process.env.HOME}/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome`
const useGpu = process.env.GPU !== '0'
const browser = await chromium.launch({
  executablePath: process.env.CHROMIUM_PATH ?? (existsSync(FULL_CHROMIUM) ? FULL_CHROMIUM : undefined),
  args: [
    ...(useGpu
      ? ['--use-angle=vulkan', '--enable-features=Vulkan', '--enable-unsafe-webgpu']
      : ['--enable-unsafe-swiftshader']),
    '--no-sandbox',
    '--disable-dev-shm-usage',
    '--autoplay-policy=no-user-gesture-required',
  ],
})

const page = await browser.newPage({ viewport: { width: 1280, height: 720 } })
const errors = []
const warnings = []
const logs = []

page.on('console', (msg) => {
  const text = `${msg.text()}`
  if (msg.type() === 'error') errors.push(text)
  else if (msg.type() === 'warning') warnings.push(text)
  else logs.push(text)
})
page.on('pageerror', (err) => errors.push(`PAGEERROR ${err.message}`))
page.on('requestfailed', (req) => {
  // Favicon noise is not worth failing a run over.
  if (!req.url().includes('favicon')) errors.push(`REQFAIL ${req.url()} ${req.failure()?.errorText}`)
})

console.log(`→ ${URL}`)
await page.goto(URL, { waitUntil: 'domcontentloaded', timeout: 60000 })

// Character select, then the "click to take the field" gate.
await page.waitForSelector(`.choice[data-class="${CLASS}"]`, { timeout: 30000 })
await page.click(`.choice[data-class="${CLASS}"]`)
console.log(`  picked ${CLASS}, waiting for the Lands to rise…`)

await page.waitForSelector('.overlay h1:text("Ready")', { timeout: 120000 }).catch(() => {})
await page.click('.overlay', { timeout: 30000 }).catch(() => {})

// Drive it a little: walk, swing, roll, parry, lock on, toggle day.
const DAY = process.env.DAY === '1'
const script = [
  // Shoot FIRST: the field is lethal within a couple of seconds, and a dead
  // archer never gets to prove that arrows leave ground fire.
  // Class-specific opener. Holding attack is the ARCHER's draw; for the
  // Paladin it is just one swing followed by five idle seconds, which is
  // long enough for Bobba and five skeletons to kill him before the test
  // ever gets to the combo.
  ...(CLASS === 'archer'
    ? [['keydown', 'KeyF'], ['wait', 2500], ['keyup', 'KeyF'], ['wait', 2500]]
    : [['key', 'KeyF'], ['wait', 260], ['key', 'KeyF'], ['wait', 260], ['key', 'KeyF'], ['wait', 900]]),
  ['keydown', 'KeyW'], ['wait', 700], ['keyup', 'KeyW'],
  ['key', 'KeyT'], ['wait', 300],
  ['key', 'KeyF'], ['wait', 300], ['key', 'KeyF'], ['wait', 300], ['key', 'KeyF'], ['wait', 700],
  ['key', 'KeyX'], ['wait', 700],
  ['key', 'KeyG'], ['wait', 700],
  ['key', 'KeyH'], ['wait', 1300],
  ['keydown', 'Space'], ['wait', 120], ['keyup', 'Space'], ['wait', 700],
  ...(DAY ? [['key', 'KeyL'], ['wait', 900]] : []),
]
for (const [kind, arg] of script) {
  if (kind === 'wait') await page.waitForTimeout(arg)
  else if (kind === 'key') await page.keyboard.press(arg)
  else if (kind === 'keydown') await page.keyboard.down(arg)
  else await page.keyboard.up(arg)
}

await page.waitForTimeout(SECONDS * 1000)

const stats = await page.evaluate(() => {
  const g = window.lob
  if (!g) return { ok: false }
  return {
    ok: true,
    playerPos: g.player.position.toArray().map((v) => Math.round(v * 100) / 100),
    playerHp: Math.round(g.player.health),
    stamina: Math.round(g.player.stamina.currentStamina),
    estus: g.player.estusCharges,
    bobbaHp: Math.round(g.bobba.health),
    skeletons: g.crew.members.length,
    skeletonsAlive: g.crew.members.filter((s) => !s.isDead).length,
    fires: g.ctx.groups.get('ground_fire').length,
    shotsFired: g.player.shotsFired,
    arrowsInFlight: g.player.arrowsInFlight,
    drawing: g.player.isDrawingBow,
    holding: g.player.isHoldingBow,
    timeOfDay: g.lighting.timeOfDay,
    colliders: g.ctx.world.colliderCount,
    renderer: g.rendererInfo?.() ?? null,
  }
})

// Read the frame back from inside the page: the drawing buffer isn't
// preserved, so an external screenshot of a WebGL canvas comes out blank.
const shot = await page.evaluate(() => window.lob?.snapshot?.() ?? null)
if (shot) {
  const { writeFileSync } = await import('node:fs')
  writeFileSync('scripts/last-run.png', Buffer.from(shot.split(',')[1], 'base64'))
}
await browser.close()

console.log('\nSTATE', JSON.stringify(stats, null, 2))
console.log(`\nerrors: ${errors.length}, warnings: ${warnings.length}`)
for (const e of errors.slice(0, 25)) console.log('  ERROR', e)
for (const w of warnings.slice(0, 10)) console.log('  WARN ', w)
process.exit(errors.length > 0 ? 1 : 0)
