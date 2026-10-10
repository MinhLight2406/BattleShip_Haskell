import { test } from 'node:test'
import assert from 'node:assert/strict'
import { spawn, spawnSync } from 'node:child_process'
import { once } from 'node:events'
import net from 'node:net'
import { fileURLToPath } from 'node:url'
import { WebSocket } from 'ws'
import { mkdtempSync, rmSync, writeFileSync, renameSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { createBridge } from '../bridge.mjs'
import { game, peer, within, listen, fleet1, fleet2, winningShots } from './helpers.mjs'

const entry = fileURLToPath(new URL('../bridge.mjs', import.meta.url))

function bridgeEnv(settings = {}) {
  const env = { ...process.env }
  for (const name of ['HOST', 'PORT', 'PUBLIC_ORIGIN', 'WEB_PUBLIC_PORT', 'BATTLESHIP_TCP_HOST',
    'BATTLESHIP_TCP_PORT', 'LAN_ORIGINS_FILE', 'LAN_INTERFACE']) delete env[name]
  return { ...env, ...settings }
}

test('LAN-01: CLI exits with a clear configuration error before starting a server', () => {
  const result = spawnSync(process.execPath, [entry], {
    env: bridgeEnv({ PORT: '0' }), encoding: 'utf8', windowsHide: true, timeout: 5000,
  })
  assert.equal(result.status, 1)
  assert.match(result.stderr, /Battleship bridge configuration: PORT/)
  assert.equal(result.stdout, '')
})

test('automatic CLI reports an unknown interface clearly before opening a listener', () => {
  const env = bridgeEnv({ LAN_INTERFACE: '__missing_battleship_interface__' })
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
    env: bridgeEnv({ HOST: '127.0.0.1', PORT: String(port), PUBLIC_ORIGIN: `http://127.0.0.1:${port}` }),
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
    env: bridgeEnv({ HOST: host, PORT: String(port), PUBLIC_ORIGIN: origin, BATTLESHIP_TCP_PORT: String(server.tcpPort) }),
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
  const env = bridgeEnv({ PORT: String(port), BATTLESHIP_TCP_PORT: String(server.tcpPort) })
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

test('DK-03: CLI rejects invalid backend/public-port/origin-file configuration before listen', () => {
  for (const settings of [
    { BATTLESHIP_TCP_HOST: '' }, { BATTLESHIP_TCP_HOST: 'http://haskell:4000' }, { BATTLESHIP_TCP_HOST: 'haskell:4000' },
    { WEB_PUBLIC_PORT: '' }, { WEB_PUBLIC_PORT: '8081' }, { LAN_ORIGINS_FILE: 'relative.json' },
    { WEB_PUBLIC_PORT: '8081', PUBLIC_ORIGIN: 'http://localhost:8080' },
    { LAN_ORIGINS_FILE: path.join(tmpdir(), '__missing_battleship_dk03__.json') },
  ]) {
    const result = spawnSync(process.execPath, [entry], { env: bridgeEnv(settings), encoding: 'utf8', windowsHide: true, timeout: 5000 })
    assert.equal(result.status, 1, JSON.stringify(settings))
    assert.match(result.stderr, /Battleship bridge configuration:/)
    assert.equal(result.stderr.includes('Unhandled'), false)
    assert.equal(result.stdout, '')
  }
})

async function freePort() {
  const reserve = net.createServer()
  const port = await listen(reserve)
  await new Promise((resolve) => reserve.close(resolve))
  return port
}

async function startCLI(t, settings, origin) {
  const child = spawn(process.execPath, [entry], { env: bridgeEnv(settings), windowsHide: true })
  const exited = once(child, 'exit')
  t.after(async () => { if (child.exitCode === null) child.kill(); await within(exited, 'DK-03 bridge CLI cleanup') })
  let output = ''
  await within(new Promise((resolve, reject) => {
    child.once('error', reject)
    child.stdout.on('data', (bytes) => {
      output += bytes
      if (output.includes(`Open ${origin} on each player device.`)) resolve()
    })
    child.stderr.on('data', (bytes) => { output += bytes })
    child.once('exit', (code) => reject(new Error(`DK-03 bridge exited ${code}: ${output}`)))
  }), 'DK-03 CLI startup')
  return { child, output: () => output }
}

// A raw TCP forwarder preserves Host/Origin exactly, like Compose port mapping.
async function forwardedPort(t, internalPort) {
  const connections = new Set()
  const forwarder = net.createServer((client) => {
    const upstream = net.createConnection({ host: '127.0.0.1', port: internalPort() })
    for (const socket of [client, upstream]) {
      connections.add(socket)
      socket.on('close', () => connections.delete(socket))
      socket.on('error', () => { client.destroy(); upstream.destroy() })
    }
    client.pipe(upstream).pipe(client)
  })
  const port = await listen(forwarder)
  t.after(async () => {
    for (const socket of connections) socket.destroy()
    await new Promise((resolve) => forwarder.close(resolve))
  })
  return port
}

test('DK-03: production CLI plays a full Haskell game through a different published port', async (t) => {
  const server = await game(t)
  const internalPort = await freePort()
  const publicPort = await forwardedPort(t, () => internalPort)
  assert.notEqual(internalPort, publicPort)
  const origin = `http://localhost:${publicPort}`
  const cli = await startCLI(t, { HOST: '0.0.0.0', PORT: String(internalPort), WEB_PUBLIC_PORT: String(publicPort),
    PUBLIC_ORIGIN: origin, BATTLESHIP_TCP_HOST: 'localhost', BATTLESHIP_TCP_PORT: String(server.tcpPort) }, origin)
  assert.ok(cli.output().includes(`TCP localhost:${server.tcpPort}`))
  assert.ok(cli.output().includes(`Listening on 0.0.0.0:${internalPort}.`))
  assert.equal((await fetch(origin)).status, 200)
  for (let count = 0; count < 100; count++) {
    const response = await fetch(`http://127.0.0.1:${internalPort}/healthz`)
    assert.deepEqual(await response.json(), { status: 'ok' })
  }
  for (const options of [
    { origin: `http://localhost:${internalPort}` },
    { origin, headers: { Host: `127.0.0.1:${publicPort}` } },
    { origin: `http://192.168.255.254:${publicPort}`, headers: { Host: `192.168.255.254:${publicPort}` } },
    { origin: 'http://127.0.0.1:5173', headers: { Host: '127.0.0.1:5173' } },
  ]) {
    const ws = new WebSocket(`ws://127.0.0.1:${publicPort}/play`, options)
    ws.on('error', () => {})
    assert.equal((await within(once(ws, 'unexpected-response')))[1].statusCode, 401)
    ws.terminate()
  }
  const first = await peer(publicPort); await first.wait('WELCOME 1 P1')
  const second = await peer(publicPort, 'localhost'); await second.wait('WELCOME 1 P2')
  const third = await peer(publicPort); await third.wait('ERROR SERVER_FULL'); await within(third.closed)
  first.send(fleet1); await first.wait('OK PLACE'); await first.wait('WAITING OPPONENT')
  second.send(fleet2); await second.wait('OK PLACE')
  for (const client of [first, second]) { await client.wait('START P1'); await client.wait('TURN P1') }
  second.send('FIRE A1'); await second.wait('ERROR NOT_YOUR_TURN P1')
  first.send('FIRE K1'); await first.wait('ERROR INVALID_COORDINATE')
  for (const [index, coord] of winningShots.entries()) {
    const outcome = index === 16 ? 'WIN' : ({ 4: 'SUNK CV', 8: 'SUNK BB', 11: 'SUNK CR', 14: 'SUNK SB' }[index] ?? 'HIT')
    first.send(`FIRE ${coord}`)
    await first.wait(`SHOT ${coord} ${outcome}`); await second.wait(`INCOMING ${coord} ${outcome}`)
    if (outcome !== 'WIN') for (const client of [first, second]) await client.wait('TURN P1')
  }
  for (const client of [first, second]) { await client.wait('GAME_OVER P1 ALL_SHIPS_SUNK'); await within(client.closed) }
  assert.deepEqual(await within(server.exited), [0, null])
  assert.equal(first.frames.some((line) => line.includes('CV=A6')), false)
  assert.equal(second.frames.some((line) => line.startsWith('SHOT A6')), false)
  assert.equal((await fetch(`http://127.0.0.1:${internalPort}/healthz`)).status, 200, 'web remains healthy after the game ends')
  t.diagnostic(`Internal ${internalPort}, public ${publicPort}; real HTTP/WS forwarded unchanged; Haskell P1/P2, victory and exit 0.`)
})

test('DK-03: LAN file changes preserve active TCP, pause deadline and private resume history', async (t) => {
  const server = await game(t)
  const directory = mkdtempSync(path.join(tmpdir(), 'battleship-dk03-game-'))
  t.after(() => rmSync(directory, { recursive: true, force: true }))
  const filename = path.join(directory, 'origins.json')
  const oldIP = '192.168.10.20', newIP = '192.168.20.30', publicPort = 8081
  const replace = (ip) => {
    writeFileSync(filename + '.tmp', JSON.stringify({ version: 1, updatedAt: Date.now(), origins: [`http://${ip}:${publicPort}`] }))
    renameSync(filename + '.tmp', filename)
  }
  replace(oldIP)
  t.mock.timers.enable({ apis: ['setInterval'] })
  const bridge = createBridge({ host: '0.0.0.0', tcpPort: server.tcpPort, publicPort, lanOriginsFile: filename })
  const port = await listen(bridge.server)
  t.after(() => bridge.close())
  const connectOrigin = (ip, token = '') => peer(port, '127.0.0.1', token,
    { origin: `http://${ip}:${publicPort}`, headers: { Host: `${ip}:${publicPort}` } })
  const first = await connectOrigin(oldIP); await first.wait('WELCOME 1 P1')
  const { token } = await first.meta('SESSION')
  first.send(fleet1); await first.wait('OK PLACE'); await first.wait('WAITING OPPONENT')
  const second = await connectOrigin(oldIP); await second.wait('WELCOME 1 P2')
  replace(newIP); t.mock.timers.tick(2000)
  first.send('FIRE A6'); await first.wait('ERROR FLEETS_NOT_READY')
  assert.equal(first.ws.readyState, WebSocket.OPEN, 'origin replacement must not close existing sockets')
  first.ws.close(); await within(first.closed)
  const pause = await second.meta('CONNECTION')
  assert.ok(Math.abs(pause.missing[0].deadline - Date.now() - 300000) < 1000)
  replace(newIP); t.mock.timers.tick(2000)
  second.send('FIRE A1')
  assert.deepEqual(await second.meta('CONNECTION'), pause, 'polling must not change the stored disconnect deadline')
  const retained = await connectOrigin(newIP)
  await retained.wait('ERROR SERVER_FULL'); await within(retained.closed)
  const stale = new WebSocket(`ws://127.0.0.1:${port}/play?resume=${token}`, { origin: `http://${oldIP}:${publicPort}`, headers: { Host: `${oldIP}:${publicPort}` } })
  stale.on('error', () => {})
  assert.equal((await within(once(stale, 'unexpected-response')))[1].statusCode, 401)
  stale.terminate()
  const restored = await connectOrigin(newIP, token)
  const replay = await restored.meta('SESSION')
  assert.equal(replay.token, token); assert.equal(replay.fleet, fleet1)
  assert.ok(replay.frames.includes('WELCOME 1 P1'))
  assert.ok(replay.frames.includes('ERROR FLEETS_NOT_READY'))
  assert.equal(JSON.stringify(replay).includes('CV=A6'), false)
  restored.send('QUIT'); await second.wait('GAME_OVER P2 OPPONENT_LEFT')
  assert.deepEqual(await within(server.exited), [0, null])
})
