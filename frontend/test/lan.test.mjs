import { test } from 'node:test'
import assert from 'node:assert/strict'
import { spawn, spawnSync } from 'node:child_process'
import { once } from 'node:events'
import net from 'node:net'
import { fileURLToPath } from 'node:url'
import { WebSocket } from 'ws'
import { game, peer, within } from './helpers.mjs'

const entry = fileURLToPath(new URL('../bridge.mjs', import.meta.url))

test('LAN-01: CLI exits with a clear configuration error before starting a server', () => {
  const result = spawnSync(process.execPath, [entry], {
    env: { ...process.env, PORT: '0' }, encoding: 'utf8', windowsHide: true, timeout: 5000,
  })
  assert.equal(result.status, 1)
  assert.match(result.stderr, /Battleship bridge configuration: PORT/)
  assert.equal(result.stdout, '')
})

test('automatic CLI reports an unknown interface clearly before opening a listener', () => {
  const env = { ...process.env, LAN_INTERFACE: '__missing_battleship_interface__' }
  delete env.HOST; delete env.PUBLIC_ORIGIN
  const result = spawnSync(process.execPath, [entry], { env, encoding: 'utf8', windowsHide: true, timeout: 5000 })
  assert.equal(result.status, 1)
  assert.match(result.stderr, /Battleship bridge configuration: LAN_INTERFACE/)
})

test('LAN-01: an occupied HTTP port reports the listen address and exits cleanly', async (t) => {
  const occupied = net.createServer()
  occupied.listen(0, '127.0.0.1')
  await within(once(occupied, 'listening'))
  t.after(() => new Promise((resolve) => occupied.close(resolve)))
  const port = occupied.address().port
  const child = spawn(process.execPath, [entry], {
    env: { ...process.env, HOST: '127.0.0.1', PORT: String(port), PUBLIC_ORIGIN: `http://127.0.0.1:${port}` },
    windowsHide: true,
  })
  const exited = once(child, 'exit')
  t.after(() => { if (child.exitCode === null) child.kill() })
  let error = ''
  child.stderr.on('data', (bytes) => { error += bytes })
  assert.deepEqual(await within(exited), [1, null])
  assert.match(error, new RegExp(`Battleship bridge listen \\(127\\.0\\.0\\.1:${port}\\):.*EADDRINUSE`))
  assert.equal(error.includes('Unhandled'), false)
})

test('LAN-01: production CLI serves HTTP on the LAN IP and forwards real Haskell WELCOME for two players', {
  skip: !process.env.BATTLESHIP_LAN_TEST_HOST && 'Set BATTLESHIP_LAN_TEST_HOST to this machine\'s IPv4 LAN address',
}, async (t) => {
  const host = process.env.BATTLESHIP_LAN_TEST_HOST
  assert.equal(net.isIP(host), 4)
  assert.equal(host.startsWith('127.'), false, 'use a real interface address, not loopback')
  const server = await game(t)
  const reserve = net.createServer()
  reserve.listen(0, host)
  await within(once(reserve, 'listening'), 'reserve LAN port')
  const port = reserve.address().port
  await new Promise((resolve) => reserve.close(resolve))
  const origin = `http://${host}:${port}`
  const child = spawn(process.execPath, [entry], {
    env: { ...process.env, HOST: host, PORT: String(port), PUBLIC_ORIGIN: origin, BATTLESHIP_TCP_PORT: String(server.tcpPort) },
    windowsHide: true,
  })
  const exited = once(child, 'exit')
  t.after(async () => { if (child.exitCode === null) child.kill(); await within(exited, 'bridge CLI cleanup') })
  let output = ''
  child.stderr.on('data', (bytes) => { output += bytes })
  await within(new Promise((resolve, reject) => {
    child.once('error', reject)
    child.stdout.on('data', (bytes) => {
      output += bytes
      if (output.includes(`Open ${origin} on each player device.`)) resolve()
    })
    child.once('exit', (code) => reject(new Error(`bridge exited ${code}: ${output}`)))
  }), 'LAN CLI startup')
  const page = await fetch(origin)
  assert.equal(page.status, 200)
  assert.match(await page.text(), /lang="vi"/)

  for (const options of [
    { origin: 'http://untrusted.example' },
    { origin, headers: { Host: `localhost:${port}` } },
  ]) {
    const rejected = new WebSocket(`ws://${host}:${port}/play`, options)
    rejected.on('error', () => {})
    const [, response] = await within(once(rejected, 'unexpected-response'), 'reject unapproved handshake')
    assert.equal(response.statusCode, 401)
    rejected.terminate()
  }
  const first = await peer(port, host); await first.wait('WELCOME 1 P1')
  const second = await peer(port, host); await second.wait('WELCOME 1 P2')
  first.send('QUIT')
  await second.wait('GAME_OVER P2 OPPONENT_LEFT')
  await within(first.closed); await within(second.closed)
  assert.deepEqual(await within(server.exited), [0, null])
  t.diagnostic(`HTTP ${origin}: 200; WebSocket WELCOME 1 P1/P2; invalid Origin/Host: 401; Haskell exit: 0`)
  t.diagnostic('Both connections were made from the server machine via its LAN IP; this is not a two-device hardware acceptance test.')
})

test('automatic CLI discovers LAN without HOST/PUBLIC_ORIGIN; a player resumes from loopback at the real LAN origin', {
  skip: !process.env.BATTLESHIP_LAN_TEST_HOST && 'Set BATTLESHIP_LAN_TEST_HOST to this machine\'s IPv4 LAN address',
}, async (t) => {
  const host = process.env.BATTLESHIP_LAN_TEST_HOST
  const server = await game(t)
  const reserve = net.createServer()
  reserve.listen(0, '0.0.0.0'); await within(once(reserve, 'listening'))
  const port = reserve.address().port
  await new Promise((resolve) => reserve.close(resolve))
  const env = { ...process.env, PORT: String(port), BATTLESHIP_TCP_PORT: String(server.tcpPort) }
  delete env.HOST; delete env.PUBLIC_ORIGIN; delete env.LAN_INTERFACE
  const child = spawn(process.execPath, [entry], { env, windowsHide: true })
  const exited = once(child, 'exit')
  t.after(async () => { if (child.exitCode === null) child.kill(); await within(exited) })
  let output = ''
  await within(new Promise((resolve, reject) => {
    child.once('error', reject)
    child.stdout.on('data', (bytes) => {
      output += bytes
      if (output.includes(`Open http://${host}:${port} on each player device.`)) resolve()
    })
    child.stderr.on('data', (bytes) => { output += bytes })
    child.once('exit', (code) => reject(new Error(`auto bridge exited ${code}: ${output}`)))
  }), 'auto LAN detection')
  assert.match(output, /Listening on 0\.0\.0\.0/)
  assert.equal((await fetch(`http://${host}:${port}`)).status, 200)
  const first = await peer(port); await first.wait('WELCOME 1 P1')
  const { token } = await first.meta('SESSION')
  const second = await peer(port, host); await second.wait('WELCOME 1 P2')
  first.ws.close(); await within(first.closed); await second.meta('CONNECTION')
  const restored = await peer(port, host, token)
  assert.ok((await restored.meta('SESSION')).frames.includes('WELCOME 1 P1'))
  restored.send('QUIT'); await second.wait('GAME_OVER P2 OPPONENT_LEFT')
  assert.deepEqual(await within(server.exited), [0, null])
  t.diagnostic(`Auto-detected ${host}; restored P1 at the LAN origin without creating a new TCP slot.`)
})
