import { test } from 'node:test'
import assert from 'node:assert/strict'
import { chromium } from 'playwright'
import { createBridge } from '../bridge.mjs'
import { listen } from './helpers.mjs'

for (const width of [390, 1440]) test(`help dialog opens introduction first and switches tabs at ${width}px`, async (t) => {
  const bridge = createBridge()
  const port = await listen(bridge.server)
  t.after(() => bridge.close())
  const browser = await chromium.launch({ headless: true })
  t.after(() => browser.close())
  const page = await browser.newPage({ viewport: { width, height: 700 } })
  page.setDefaultTimeout(5000)
  const errors = []
  page.on('pageerror', (error) => errors.push(error.message))
  await page.goto(`http://127.0.0.1:${port}`)
  const help = page.getByRole('button', { name: 'Mở hướng dẫn', exact: true })
  await help.click()
  const dialog = page.getByRole('dialog')
  const tabs = dialog.getByRole('tab')
  assert.deepEqual(await tabs.allTextContents(), ['GIỚI THIỆU', 'HƯỚNG DẪN'])
  assert.equal(await tabs.first().getAttribute('aria-selected'), 'true')
  const panel = dialog.getByRole('tabpanel')
  for (const text of [
    'Ngô Đỗ Nhật Minh', '31241025709', 'Phạm Tấn Trung Nam', '31241020538',
    'Phạm Trần Minh Thư', '31241025703', 'Nguyễn Duy Thành Vũ', '31241020208',
    'Nguyễn Văn Tuấn Đạt', '31241020801', 'ThS. Hồ Thị Thanh Tuyến', 'Lập Trình Hàm',
  ]) assert.ok((await panel.innerText()).includes(text), text)
  assert.ok((await panel.innerText()).includes('cảm ơn'))
  await tabs.last().click()
  await dialog.getByRole('heading', { name: 'Ba bước vào trận' }).waitFor()
  assert.equal(await dialog.locator('.help-steps li').count(), 3)
  await tabs.last().press('ArrowLeft')
  assert.equal(await tabs.first().getAttribute('aria-selected'), 'true')
  assert.equal(await tabs.first().evaluate((tab) => tab === document.activeElement), true)
  assert.equal(await dialog.evaluate((element) => {
    const bounds = element.getBoundingClientRect()
    return bounds.top >= 0 && bounds.bottom <= innerHeight && element.scrollWidth <= element.clientWidth
  }), true)
  await dialog.getByRole('button', { name: 'Đã hiểu' }).click()
  await dialog.waitFor({ state: 'detached' })
  await help.click()
  assert.equal(await dialog.getByRole('tab').first().getAttribute('aria-selected'), 'true')
  await page.keyboard.press('Escape')
  await dialog.waitFor({ state: 'detached' })
  assert.equal(await help.evaluate((button) => button === document.activeElement), true)
  assert.deepEqual(errors, [])
})
