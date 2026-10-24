// Renders design/icon.html to the 1024 x 1024 app icon PNG (needs Playwright and Chrome).
//   node design/render-icon.mjs <playwright module path> <output.png>
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { resolve } from 'node:path'

const [, , playwrightPath, out] = process.argv
const { chromium } = createRequire(import.meta.url)(playwrightPath)
const browser = await chromium.launch({ channel: 'chrome' })
const page = await browser.newPage({ viewport: { width: 1024, height: 1024 }, deviceScaleFactor: 1 })
await page.goto(pathToFileURL(resolve(import.meta.dirname, 'icon.html')).href)
await page.evaluate(() => document.fonts.ready)
await page.screenshot({ path: out, clip: { x: 0, y: 0, width: 1024, height: 1024 } })
await browser.close()
