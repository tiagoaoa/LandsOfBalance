/** Put the player next to Bobba, swing, and see whether damage lands. */
import { chromium } from 'playwright'
const browser = await chromium.launch({
  executablePath: `${process.env.HOME}/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome`,
  args: ['--use-angle=vulkan', '--enable-features=Vulkan', '--no-sandbox', '--disable-dev-shm-usage'],
})
const page = await browser.newPage({ viewport: { width: 800, height: 500 } })
page.on('pageerror', (e) => console.log('PAGEERROR', e.message))
await page.goto('http://127.0.0.1:5273/?webgl=1&hud=0', { waitUntil: 'domcontentloaded' })
await page.click('.choice[data-class="paladin"]')
await page.waitForSelector('.overlay h1:text("Ready")', { timeout: 180000 })
await page.click('.overlay')
await page.waitForTimeout(1200)

const snap = async (tag) =>
  console.log(tag.padEnd(18), JSON.stringify(await page.evaluate(() => {
    const g = window.lob
    return {
      bobbaHp: Math.round(g.bobba.health),
      bobbaDist: +g.player.position.distanceTo(g.bobba.position).toFixed(2),
      playerHp: Math.round(g.player.health),
      attacking: g.player.isAttacking,
      onFloor: g.player.isOnFloor(),
      stamina: Math.round(g.player.stamina.currentStamina),
    }
  })))

// Park the player right in front of Bobba, facing it, and freeze the fight
// by making the player briefly immune so skeletons can't skew the result.
await page.evaluate(() => {
  const g = window.lob
  const b = g.bobba.position
  g.player.object.position.set(b.x, b.y, b.z + 1.8)
  g.player.velocity.set(0, 0, 0)
  // Look toward Bobba: yaw such that camera-forward points at -Z.
  g.engine.cameraRotation.x = 0
  g.engine.syncPivotRotation()
  g.player.syncCameraPivot()
})
await page.waitForTimeout(500)
await snap('before swing')

for (let i = 0; i < 3; i++) {
  await page.keyboard.press('KeyF')
  await page.waitForTimeout(500)
  await snap(`after swing ${i + 1}`)
}
await page.waitForTimeout(1200)
await snap('settled')
await browser.close()
