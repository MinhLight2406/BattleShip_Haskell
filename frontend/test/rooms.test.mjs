import { test } from 'node:test'
import assert from 'node:assert/strict'
import { chromium } from 'playwright'
import { createBridge } from '../bridge.mjs'
import { listen } from './helpers.mjs'

test('room UI searches names and IDs, shows locks and requests passwords only for locked rooms', async (t) => {
  const bridge = createBridge()
  const port = await listen(bridge.server)
  t.after(() => bridge.close())
  const base = `http://127.0.0.1:${port}`
  const create = async (roomName, password) => (await fetch(`${base}/api/rooms/create`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ roomName, password }),
  })).json()
  const open = await create('Biển xanh', '')
  await create('Bắc Hải', 'secret')
  const browser = await chromium.launch({ headless: true })
  t.after(() => browser.close())
  const page = await browser.newPage({ viewport: { width: 390, height: 844 } })
  const errors = []
  page.on('pageerror', (error) => errors.push(error.message))
  await page.goto(base)
  await page.getByRole('button', { name: 'Vào phòng tác chiến' }).click()
  await page.getByRole('tab', { name: 'Tham gia phòng' }).click()
  const rows = page.locator('.room-list button')
  await rows.filter({ hasText: 'Bắc Hải' }).waitFor()
  assert.equal(await rows.count(), 2)
  assert.equal(await rows.filter({ hasText: 'Bắc Hải' }).locator('.icon').count(), 1)
  assert.equal(await rows.filter({ hasText: 'Biển xanh' }).locator('.icon').count(), 0)
  const search = page.getByLabel('Tìm tên hoặc ID phòng')
  await search.fill('bẮc')
  assert.equal(await rows.count(), 1)
  await search.fill(open.roomId.toLowerCase().slice(0, 10))
  assert.equal(await rows.count(), 1)
  await rows.first().click()
  assert.equal(await page.getByLabel('Mật khẩu phòng', { exact: true }).count(), 0)
  await search.fill('không tồn tại')
  await page.getByText('Không tìm thấy phòng phù hợp.').waitFor()
  await search.fill('')
  await rows.filter({ hasText: 'Bắc Hải' }).click()
  await page.getByLabel('Mật khẩu phòng', { exact: true }).fill('secret')
  let joined
  await page.route('**/api/rooms/join', async (route) => {
    joined = route.request().postDataJSON()
    await route.fulfill({ status: 403, contentType: 'application/json', body: JSON.stringify({ error: 'Thử lại' }) })
  })
  await page.getByRole('button', { name: 'Tham gia', exact: true }).click()
  await page.getByRole('alert').filter({ hasText: 'Thử lại' }).waitFor()
  assert.equal(joined.password, 'secret')
  await rows.filter({ hasText: 'Biển xanh' }).click()
  await page.getByRole('button', { name: 'Tham gia', exact: true }).click()
  await page.getByRole('alert').filter({ hasText: 'Thử lại' }).waitFor()
  assert.equal(joined.room, open.roomId)
  assert.equal(joined.password, '')
  const joinedOpen = await fetch(`${base}/api/rooms/join`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ room: open.roomId, password: '' }),
  })
  assert.equal(joinedOpen.status, 201)
  await rows.filter({ hasText: 'Biển xanh' }).waitFor({ state: 'detached' })
  assert.equal(await page.getByRole('button', { name: 'Tham gia', exact: true }).isDisabled(), true)
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth), true)
  assert.deepEqual(errors, [])
})
