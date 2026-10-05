import { test, before, after } from 'node:test'
import assert from 'node:assert/strict'
import { mkdir } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import { chromium } from 'playwright'
import { createBridge } from '../bridge.mjs'
import { game, peer, listen, within, winningShots } from './helpers.mjs'

let browser
before(async () => { browser = await chromium.launch({ headless: true }) })
after(async () => { await browser?.close() })
const screenshots = new URL('../test-results/', import.meta.url)
const target = (page, coord) => page.locator('[aria-label="Bàn mục tiêu"] [data-coordinate="' + coord + '"]')
const own = (page, coord) => page.locator('[aria-label="Bàn phòng thủ"] [data-coordinate="' + coord + '"]')
const status = async (page, text) => page.locator('.game-status').filter({ hasText: text }).waitFor()
async function pageFor(t, port, mobile = false) {
  const context = await browser.newContext({ viewport: mobile ? { width: 390, height: 844 } : { width: 1440, height: 1000 } })
  t.after(() => context.close())
  const page = await context.newPage()
  page.setDefaultTimeout(10000)
  const errors = []
  page.on('pageerror', (error) => errors.push(error.message))
  t.after(() => assert.deepEqual(errors, [], 'no browser runtime errors'))
  await page.goto(`http://127.0.0.1:${port}`)
  return page
}
async function placement(page) {
  await page.getByRole('button', { name: 'Vào phòng tác chiến' }).click()
  assert.equal(await page.getByRole('button', { name: 'Chọn Trinh sát' }).isDisabled(), true)
  await page.getByRole('button', { name: 'Chọn Cổ điển' }).click()
}
async function putFleet(page, firstRow) {
  await placement(page)
  assert.equal(await page.getByRole('button', { name: 'Bắt đầu trận' }).isDisabled(), true)
  // These are real clicks on the provided placement UI, not injected fixtures.
  for (const [index, name] of ['Hàng không mẫu hạm', 'Thiết giáp hạm', 'Tuần dương hạm', 'Tàu ngầm', 'Khu trục hạm'].entries()) {
    await page.getByRole('button', { name: new RegExp(name) }).click()
    await page.locator(`.board-panel [data-coordinate="A${firstRow + index}"]`).click()
  }
  assert.equal(await page.locator('.board-cell.occupied').count(), 17)
  await page.getByRole('button', { name: 'Bắt đầu trận' }).click()
}

test('UI: two human-style fleets, invalid placement, miss, hit, sunk, win/loss and no secret reveal', async (t) => {
  const server = await game(t)
  const first = await pageFor(t, server.port)
  const second = await pageFor(t, server.port)
  const sent = []
  first.on('websocket', (ws) => ws.on('framesent', ({ payload }) => sent.push(payload.toString())))
  await placement(first)
  await first.locator('.board-panel [data-coordinate="J10"]').click()
  await first.locator('.placement-status').filter({ hasText: 'vượt biên' }).waitFor()
  assert.equal(await first.locator('.board-cell.occupied').count(), 0)
  for (const [index, name] of ['Hàng không mẫu hạm', 'Thiết giáp hạm', 'Tuần dương hạm', 'Tàu ngầm', 'Khu trục hạm'].entries()) {
    await first.getByRole('button', { name: new RegExp(name) }).click()
    await first.locator(`.board-panel [data-coordinate="A${index + 1}"]`).click()
  }
  await first.getByRole('button', { name: 'Bắt đầu trận' }).click()
  await status(first, 'Chờ đối thủ')
  assert.equal(sent.filter((line) => line.startsWith('PLACE')).length, 1, 'StrictMode must not connect/submit twice')
  assert.equal(await target(first, 'A6').isDisabled(), true)
  assert.equal(await first.getByRole('button', { name: 'Chỉnh đội hình' }).count(), 0)
  await putFleet(second, 6)
  await status(first, 'Đến lượt bạn'); await status(second, 'Lượt đối thủ')
  assert.equal(await target(second, 'A1').isDisabled(), true)
  assert.equal(await first.locator('.enemy-board .occupied').count(), 0)
  assert.equal(await first.locator('.battle-screen .board-cell.selected').count(), 0, 'no placement selection leaks into battle boards')
  const third = await pageFor(t, server.port)
  const thirdSent = []
  third.on('websocket', (ws) => ws.on('framesent', ({ payload }) => thirdSent.push(payload.toString())))
  await putFleet(third, 1)
  await third.getByRole('alert').filter({ hasText: 'Phòng đã đủ hai người' }).waitFor()
  assert.deepEqual(thirdSent, [], 'third player must not submit a fleet before WELCOME')
  // A rapid duplicate DOM click must produce only one server command.
  await target(first, 'J10').evaluate((button) => { button.click(); button.click() })
  await status(second, 'Đến lượt bạn'); await status(first, 'Lượt đối thủ')
  assert.equal(sent.filter((line) => line === 'FIRE J10').length, 1)
  assert.equal(await own(second, 'J10').getAttribute('data-outcome'), 'MISS')
  assert.match(await own(second, 'J10').getAttribute('aria-label'), /Trượt/)
  await target(second, 'J10').click()
  await status(first, 'Đến lượt bạn')
  assert.equal(await target(first, 'J10').isDisabled(), true)
  for (const [index, coord] of winningShots.entries()) {
    await target(first, coord).click()
    const result = index === 16 ? 'WIN' : ({ 4: 'SUNK CV', 8: 'SUNK BB', 11: 'SUNK CR', 14: 'SUNK SB' }[index] ?? 'HIT')
    await target(first, coord).filter({ has: first.locator('.shot-marker') }).waitFor()
    assert.equal(await target(first, coord).getAttribute('data-outcome'), result)
    await own(second, coord).filter({ has: second.locator('.shot-marker') }).waitFor()
    if (result !== 'WIN') await status(first, 'Đến lượt bạn')
    assert.equal(await first.locator('.enemy-board .occupied').count(), 0)
  }
  await status(first, 'Bạn thắng'); await status(second, 'Bạn thua')
  assert.equal(await first.locator('.enemy-board button:not(:disabled)').count(), 0)
  assert.equal(await second.locator('.enemy-board .shot-marker').count(), 1)
  await mkdir(screenshots, { recursive: true })
  await first.evaluate(() => window.scrollTo(0, 0))
  await first.screenshot({ path: fileURLToPath(new URL('victory-desktop.png', screenshots)), fullPage: true })
  assert.deepEqual(await within(server.exited), [0, null])
})

for (const duringBattle of [false, true]) test(`UI: closing opponent tab ${duringBattle ? 'mid-game' : 'while waiting'} shows forfeit victory`, async (t) => {
  const server = await game(t)
  const first = await pageFor(t, server.port)
  await putFleet(first, 1); await status(first, 'Chờ đối thủ')
  if (!duringBattle) {
    const opponent = await peer(server.port)
    await opponent.wait('WELCOME 1 P2'); opponent.ws.close()
  } else {
    const second = await pageFor(t, server.port)
    await putFleet(second, 6); await status(first, 'Đến lượt bạn')
    await second.close()
  }
  await status(first, 'Bạn thắng! Đối thủ đã rời trận.')
  assert.deepEqual(await within(server.exited), [0, null])
})

test('UI: explicit leave confirmation forfeits and returns to landing', async (t) => {
  const server = await game(t)
  const first = await pageFor(t, server.port)
  const second = await pageFor(t, server.port)
  await putFleet(first, 1); await status(first, 'Chờ đối thủ')
  await putFleet(second, 6); await status(first, 'Đến lượt bạn')
  second.once('dialog', (dialog) => dialog.accept())
  await second.getByRole('button', { name: 'Rời trận (bỏ cuộc)' }).click()
  await second.getByRole('button', { name: 'Vào phòng tác chiến' }).waitFor()
  await status(first, 'Bạn thắng! Đối thủ đã rời trận.')
  assert.deepEqual(await within(server.exited), [0, null])
})

test('UI: server unavailable is actionable, never a fake ready game', async (t) => {
  const bridge = createBridge({ tcpPort: 1 })
  const port = await listen(bridge.server)
  t.after(() => bridge.close())
  const page = await pageFor(t, port)
  await placement(page)
  await page.getByRole('button', { name: 'Tự bố trí' }).click()
  await page.getByRole('button', { name: 'Bắt đầu trận' }).click()
  await page.getByRole('alert').filter({ hasText: 'server Haskell' }).waitFor()
  assert.equal(await page.locator('.enemy-board button:not(:disabled)').count(), 0)
  await page.getByRole('button', { name: 'Về trang đầu' }).click()
  await page.getByRole('button', { name: 'Vào phòng tác chiến' }).waitFor()
})

test('UI: mobile placement, rotate at J10, keyboard help and responsive board', async (t) => {
  const server = await game(t)
  const page = await pageFor(t, server.port, true)
  await placement(page)
  await page.getByRole('button', { name: /Khu trục hạm/ }).click()
  await page.locator('.board-panel [data-coordinate="I10"]').click()
  await page.getByRole('button', { name: 'Xoay tàu' }).click()
  await page.locator('.placement-status').filter({ hasText: 'Không đủ khoảng trống' }).waitFor()
  assert.equal(await page.locator('.board-panel .occupied').count(), 2)
  await page.getByRole('button', { name: 'Mở hướng dẫn' }).click()
  await page.getByRole('dialog').waitFor()
  await page.keyboard.press('Escape')
  assert.equal(await page.getByRole('dialog').count(), 0)
  await page.getByRole('button', { name: 'Tự bố trí' }).click()
  assert.equal(await page.locator('.board-panel .occupied').count(), 17)
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth), true)
  await mkdir(screenshots, { recursive: true })
  await page.evaluate(() => window.scrollTo(0, 0))
  await page.screenshot({ path: fileURLToPath(new URL('placement-mobile.png', screenshots)), fullPage: true })
  await page.getByRole('button', { name: 'Bắt đầu trận' }).click()
  await status(page, 'Chờ đối thủ')
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth), true)
})
