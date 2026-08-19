/** Report measured standing heights so the model scales can be tuned. */
import { chromium } from 'playwright'

const browser = await chromium.launch({
  executablePath: `${process.env.HOME}/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome`,
  args: ['--use-angle=vulkan', '--enable-features=Vulkan', '--no-sandbox', '--disable-dev-shm-usage'],
})
const page = await browser.newPage({ viewport: { width: 640, height: 400 } })
page.on('pageerror', (e) => console.log('PAGEERROR', e.message))

await page.goto('http://127.0.0.1:5273/', { waitUntil: 'domcontentloaded' })
await page.click(`.choice[data-class="${process.argv[2] ?? 'paladin'}"]`)
await page.waitForSelector('.overlay h1:text("Ready")', { timeout: 180000 })
await page.click('.overlay')
await page.waitForTimeout(1500)

console.log('measured rig heights (m):', await page.evaluate(() => window.lob.heights()))
await browser.close()
