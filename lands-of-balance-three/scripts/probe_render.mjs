/** Why is the canvas black? Report draw calls, sizes and render errors. */
import { chromium } from 'playwright'

const URL = process.env.URL ?? 'http://127.0.0.1:5273/?post=0'
const browser = await chromium.launch({
  executablePath: `${process.env.HOME}/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome`,
  args: ['--use-angle=vulkan', '--enable-features=Vulkan', '--enable-unsafe-webgpu', '--no-sandbox', '--disable-dev-shm-usage'],
})
const page = await browser.newPage({ viewport: { width: 900, height: 520 } })
page.on('pageerror', (e) => console.log('PAGEERROR', e.message))
page.on('console', (m) => console.log(`[${m.type()}]`, m.text().slice(0, 300)))

await page.goto(URL, { waitUntil: 'domcontentloaded' })
await page.click('.choice[data-class="paladin"]')
await page.waitForSelector('.overlay h1:text("Ready")', { timeout: 180000 })
await page.click('.overlay')
await page.waitForTimeout(1500)

console.log('\n=== diagnostics ===')
console.log(
  JSON.stringify(
    await page.evaluate(async () => {
      const g = window.lob
      const r = g.engine.renderer
      const canvas = document.querySelector('canvas')
      // Force one explicit frame and see what the renderer reports.
      await r.renderAsync(g.engine.scene, g.engine.camera)
      return {
        backend: g.engine.backendName,
        canvasCss: [canvas.clientWidth, canvas.clientHeight],
        canvasBuf: [canvas.width, canvas.height],
        drawCalls: r.info?.render?.drawCalls,
        triangles: r.info?.render?.triangles,
        sceneChildren: g.engine.scene.children.length,
        cameraPos: g.engine.camera.position.toArray().map((v) => Math.round(v * 10) / 10),
        cameraFar: g.engine.camera.far,
        playerPos: g.player.position.toArray().map((v) => Math.round(v * 10) / 10),
        outputColorSpace: r.outputColorSpace,
        toneMapping: r.toneMapping,
      }
    }),
    null,
    2,
  ),
)

await page.screenshot({ path: 'scratch/probe-render.png' })
await browser.close()
