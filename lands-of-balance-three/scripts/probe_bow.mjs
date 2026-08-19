/** Focused probe: watch the archer's bow state across a draw and release. */
import { chromium } from 'playwright'

const browser = await chromium.launch({
  executablePath: `${process.env.HOME}/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome`,
  args: ['--use-angle=vulkan', '--enable-features=Vulkan', '--no-sandbox', '--disable-dev-shm-usage'],
})
const page = await browser.newPage({ viewport: { width: 800, height: 500 } })
page.on('pageerror', (e) => console.log('PAGEERROR', e.message))
page.on('console', (m) => {
  if (m.type() === 'error') console.log('CONSOLE-ERR', m.text())
})

await page.goto('http://127.0.0.1:5273/', { waitUntil: 'domcontentloaded' })
await page.click('.choice[data-class="archer"]')
await page.waitForSelector('.overlay h1:text("Ready")', { timeout: 180000 })
await page.click('.overlay')
await page.waitForTimeout(500)

const snap = async (tag) => {
  const s = await page.evaluate(() => {
    const p = window.lob?.player
    return p
      ? {
          drawing: p.isDrawingBow,
          holding: p.isHoldingBow,
          attacking: p.isAttacking,
          stunned: p.isStunnedDebug ?? null,
          shots: p.shotsFired,
          arrows: p.arrowsInFlight,
          fires: window.lob.ctx.groups.get('ground_fire').length,
          hp: Math.round(p.health),
        }
      : null
  })
  console.log(tag.padEnd(16), JSON.stringify(s))
}

await snap('before')
await page.keyboard.down('KeyF')
for (const ms of [100, 200, 300, 400]) {
  await page.waitForTimeout(ms)
  await snap(`down+${ms}`)
}
await page.keyboard.up('KeyF')
await snap('released')
for (const ms of [300, 600, 1200]) {
  await page.waitForTimeout(ms)
  await snap(`after+${ms}`)
}

await browser.close()
