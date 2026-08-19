/** Find meshes whose geometry is missing attributes the materials expect. */
import { chromium } from 'playwright'
const browser = await chromium.launch({
  executablePath: `${process.env.HOME}/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome`,
  args: ['--use-angle=vulkan', '--enable-features=Vulkan', '--no-sandbox', '--disable-dev-shm-usage'],
})
const page = await browser.newPage({ viewport: { width: 640, height: 400 } })
await page.goto('http://127.0.0.1:5273/?webgl=1&hud=0', { waitUntil: 'domcontentloaded' })
await page.click('.choice[data-class="paladin"]')
await page.waitForSelector('.overlay h1:text("Ready")', { timeout: 180000 })
await page.click('.overlay')
await page.waitForTimeout(1500)
console.log(JSON.stringify(await page.evaluate(() => {
  const bad = []
  window.lob.engine.scene.traverse((o) => {
    const g = o.geometry
    if (!g?.attributes) return
    const missing = ['position', 'normal', 'uv'].filter((a) => !g.attributes[a])
    if (missing.length) bad.push({ name: o.name || o.type, type: o.type, missing })
  })
  return bad
}), null, 2))
await browser.close()
